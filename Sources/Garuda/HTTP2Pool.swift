//===----------------------------------------------------------------------===//
// The tasks HTTP/2 and HTTP/3 streams run in.
//
// A stream whose handler may wait runs in a task of its own, so it holds up
// no other stream; a reset cancels that task. Making a task per stream is
// the most expensive thing Swift concurrency does, so the tasks are kept and
// reused -- but cancellation cannot be undone, so a task that has been
// cancelled is not reused: it finishes the stream it was cancelled for and
// ends, and a new one is made when one is next wanted. Resets are rare, and
// the rapid-reset defence keeps them so, so the handler runs in the pooled
// task itself rather than in a child task made for every stream in case
// one is reset.
//
// Vega's `TaskPool` reuses its tasks whatever happens to them, and takes
// closures, a heap allocation each; this takes the stream itself.
//
// A shard has one for its HTTP/2 connections and one for its HTTP/3
// endpoints (HTTP3.swift).
//===----------------------------------------------------------------------===//

import Synchronization
import Vega

/// A first-in, first-out ring that grows by doubling and never shrinks.
struct H2Ring<Element>: ~Copyable {
    private var storage: UnsafeMutablePointer<Element>
    private var capacity: Int
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
    }

    deinit {
        var i = 0
        while i < count {
            (storage + (head &+ i) % capacity).deinitialize(count: 1)
            i &+= 1
        }
        storage.deallocate()
    }

    mutating func push(_ element: Element) {
        if count == capacity { grow() }
        (storage + (head &+ count) % capacity).initialize(to: element)
        count &+= 1
    }

    mutating func pop() -> Element? {
        guard count > 0 else { return nil }
        let element = (storage + head).move()
        head = (head &+ 1) % capacity
        count &-= 1
        return element
    }

    private mutating func grow() {
        let bigger = UnsafeMutablePointer<Element>.allocate(capacity: capacity * 2)
        var i = 0
        while i < count {
            (bigger + i).moveInitialize(from: storage + (head &+ i) % capacity, count: 1)
            i &+= 1
        }
        storage.deallocate()
        storage = bigger
        capacity *= 2
        head = 0
    }
}

/// A stream to answer, held unretained: it outlives its task, and its
/// connection outlives it.
enum PooledStream {
    case h2(Unmanaged<H2Stream>)
    case h3(Unmanaged<H3Stream>)
}

/// The tasks a shard's HTTP/2 or HTTP/3 streams run in.
final class StreamPool: @unchecked Sendable {
    private struct State: ~Copyable {
        var pending = H2Ring<PooledStream>(capacity: 64)
        var idle = H2Ring<UnsafeContinuation<PooledStream, Never>>(capacity: 64)
        var live = 0
    }

    private let runtime: Runtime
    /// A stream whose handler waits holds its task meanwhile, and streams
    /// past this many queue, so the bound is generous: tasks are only made
    /// when a stream finds none idle.
    private let maxTasks: Int
    private let state = Mutex(State())

    init(runtime: Runtime, maxTasks: Int) {
        self.runtime = runtime
        self.maxTasks = max(1, maxTasks)
    }

    /// Answers `s` in a pooled task: `H2Connection.answer`. The stream is
    /// held unretained: it outlives its task, and its connection outlives
    /// it (H2Connection.end).
    func run(_ s: H2Stream) {
        run(.h2(Unmanaged.passUnretained(s)))
    }

    /// Answers `s` in a pooled task: `QUICEndpoint.answer`. Its endpoint
    /// keeps it, and its connection, until the task has posted its end.
    func run(_ s: H3Stream) {
        run(.h3(Unmanaged.passUnretained(s)))
    }

    private func run(_ stream: PooledStream) {
        let (idle, grow) = state.withLock { state -> (UnsafeContinuation<PooledStream, Never>?, Bool) in
            if let c = state.idle.pop() { return (c, false) }
            state.pending.push(stream)
            // Nobody idle: every task is answering or waiting in a handler.
            if state.live < maxTasks {
                state.live &+= 1
                return (nil, true)
            }
            return (nil, false)
        }
        if let idle {
            idle.resume(returning: stream)
        } else if grow {
            runtime.spawn { await self.loop() }
        }
    }

    private func loop() async {
        while true {
            // Queued streams first, without suspending.
            while let stream = state.withLock({ $0.pending.pop() }) {
                if await answer(stream) { return }
            }
            if await answer(await next()) { return }
        }
    }

    /// Waits for a stream to answer. Not inlined into the loop: a
    /// continuation stored under a lock and inlined into a loop that awaits
    /// is a pattern Swift 6.3's optimiser has miscompiled.
    @inline(never)
    private func next() async -> PooledStream {
        await withUnsafeContinuation { (c: UnsafeContinuation<PooledStream, Never>) in
            let ready = state.withLock { state -> PooledStream? in
                if let stream = state.pending.pop() { return stream }
                state.idle.push(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    /// Answers one stream. True when this task was cancelled meanwhile, by a
    /// reset, and has ended: no later stream may see a cancelled task.
    @inline(__always)
    private func answer(_ stream: PooledStream) async -> Bool {
        switch stream {
        case .h2(let s):
            let s = s.takeUnretainedValue()
            await s.connection.answer(s)
        case .h3(let s):
            let s = s.takeUnretainedValue()
            await s.endpoint.answer(s)
        }
        guard Task.isCancelled else { return false }
        // Whatever is queued still needs a task.
        let replace = state.withLock { state -> Bool in
            state.live &-= 1
            if state.pending.count > 0 && state.live < maxTasks {
                state.live &+= 1
                return true
            }
            return false
        }
        if replace { runtime.spawn { await self.loop() } }
        return true
    }
}

//===----------------------------------------------------------------------===//
// Work that blocks, run off the worker's thread.
//
//     app.get("/thumbnail/:name") { (name: Path<String>) async throws in
//         let bytes = try await blocking { try resize(imageAt: "/srv/images/\(name.value)") }
//         return Bytes(bytes, contentType: "image/png")
//     }
//
// A worker is one thread. A call that blocks it -- a C library doing disk I/O,
// SQLite, a CPU-bound transform that runs for tens of milliseconds -- stops
// every connection on that worker until it returns. `blocking` hands such a
// call to a thread of the worker's blocking pool and suspends the task that
// asked, so the worker goes on serving. When the call returns, the thread
// puts it on a list and writes a byte to a pipe the worker's poller watches;
// the worker takes the list and resumes each task on its own thread, where
// the rest of the handler runs as before.
//
// Each worker process has its own pool, started the first time it is used,
// so a worker that never blocks never starts a thread. Threads are added as
// work waits, up to `--blocking-threads`. Work beyond what they are running
// waits in a queue of at most `--blocking-queue`; past that `blocking` throws
// `BlockingPoolError.full`, a 503, rather than letting a slow dependency hold
// unbounded memory.
//
// Work cannot be interrupted once handed over. A request cancelled while its
// work runs finds out when the work returns.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// Why `blocking` could not run its work.
public enum BlockingPoolError: ResponseError, Equatable, Sendable {
    /// `--blocking-queue` pieces of work were already waiting for a thread.
    case full
    /// The worker could not start a thread or make its pipe.
    case unavailable

    public var status: HTTPStatus { .serviceUnavailable }

    public var reason: String? {
        switch self {
        case .full: return "the blocking pool is full"
        case .unavailable: return "the blocking pool is unavailable"
        }
    }
}

/// Runs `work` on a thread of the worker's blocking pool and returns what it
/// returns, or throws what it throws. The task awaiting it is resumed on its
/// worker.
///
/// `work` runs on another thread while the worker serves other requests, so
/// what it captures and returns is `Sendable`: copy a value out of an
/// extractor, or out of per-worker state, before handing it over.
///
/// Called anywhere but on a worker's thread -- a test outside the test client,
/// a detached task -- `work` runs where it is called.
public func blocking<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
    guard let worker = currentWorker else { return try work() }
    let pool = try worker.pointee.blockingPool()
    let result = await withUnsafeContinuation { (continuation: UnsafeContinuation<BlockingOutcome<T>, Never>) in
        let job = BlockingJob()
        nonisolated(unsafe) var outcome: BlockingOutcome<T> = .refused(.unavailable)
        job.run = {
            do { outcome = .returned(try work()) } catch { outcome = .threw(error) }
        }
        job.finish = { continuation.resume(returning: outcome) }
        if let refusal = pool.submit(job) { continuation.resume(returning: .refused(refusal)) }
    }
    switch result {
    case .returned(let value):
        return value
    case .threw(let error):
        throw error
    case .refused(let refusal):
        throw refusal
    }
}

enum BlockingOutcome<T> {
    case returned(T)
    case threw(any Error)
    case refused(BlockingPoolError)
}

/// Work handed to a pool thread, and what the worker runs once it is done.
final class BlockingJob: @unchecked Sendable {
    /// Runs on a pool thread.
    var run: () -> Void = {}
    /// Runs on the worker.
    var finish: () -> Void = {}
}

/// A worker's blocking threads, the work waiting for them and the work they
/// have finished. Everything but `finished` delivery is under `lock`.
final class BlockingPool: @unchecked Sendable {
    private let lock: OpaquePointer
    private let ready: OpaquePointer
    private var pending: [BlockingJob] = []
    private var pendingHead = 0
    private var done: [BlockingJob] = []
    private var threads = 0
    private var idle = 0
    /// Threads started but not yet serving, each about to take work.
    private var starting = 0
    private var stopping = false
    let maxThreads: Int
    let queueLimit: Int
    /// The pipe a thread writes to when it finishes work: the worker polls
    /// the read end. Closed when the last thread holding the pool has gone.
    let readFD: Int32
    let writeFD: Int32

    init?(threads: Int, queue: Int) {
        var fds: (Int32, Int32) = (-1, -1)
        let piped = withUnsafeMutableBytes(of: &fds) { raw in
            av_pipe(raw.baseAddress!.assumingMemoryBound(to: Int32.self))
        }
        guard piped == 0, let lock = av_mutex_new() else { return nil }
        guard let ready = av_cond_new() else {
            av_mutex_free(lock)
            return nil
        }
        self.lock = lock
        self.ready = ready
        readFD = fds.0
        writeFD = fds.1
        maxThreads = max(1, threads)
        queueLimit = max(0, queue)
    }

    deinit {
        _ = av_close(readFD)
        _ = av_close(writeFD)
        av_cond_free(ready)
        av_mutex_free(lock)
    }

    /// Queues `job` for a thread, starting one if every thread is busy and
    /// there is room for another. Nil once queued, or why it was not.
    func submit(_ job: BlockingJob) -> BlockingPoolError? {
        av_mutex_lock(lock)
        let waiting = pending.count - pendingHead
        // What waits for a thread: the work no idle or starting thread is
        // about to take, once no more threads can start.
        if threads >= maxThreads && waiting - idle - starting >= queueLimit {
            av_mutex_unlock(lock)
            return .full
        }
        pending.append(job)
        var spawn = false
        if idle + starting > waiting {
            if idle > 0 { av_cond_signal(ready) }
        } else if threads < maxThreads {
            threads += 1
            starting += 1
            spawn = true
        }
        av_mutex_unlock(lock)
        guard spawn else { return nil }
        let retained = Unmanaged.passRetained(self).toOpaque()
        if av_thread_spawn({ BlockingPool.threadMain($0!) }, retained) != 0 {
            Unmanaged<BlockingPool>.fromOpaque(retained).release()
            av_mutex_lock(lock)
            threads -= 1
            starting -= 1
            // With no thread at all the work would wait forever.
            let stranded = threads == 0
            if stranded {
                pending.removeLast()
            }
            av_mutex_unlock(lock)
            if stranded {
                Log.error("cannot start a blocking pool thread")
                return .unavailable
            }
        }
        return nil
    }

    private static func threadMain(_ raw: UnsafeMutableRawPointer) {
        let pool = Unmanaged<BlockingPool>.fromOpaque(raw).takeRetainedValue()
        pool.serve()
    }

    private func serve() {
        av_mutex_lock(lock)
        starting -= 1
        while true {
            while pendingHead == pending.count && !stopping {
                idle += 1
                av_cond_wait(ready, lock)
                idle -= 1
            }
            if pendingHead == pending.count {
                threads -= 1
                av_mutex_unlock(lock)
                return
            }
            let job = pending[pendingHead]
            pendingHead += 1
            if pendingHead == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingHead = 0
            } else if pendingHead >= 64 && pendingHead * 2 >= pending.count {
                pending.removeFirst(pendingHead)
                pendingHead = 0
            }
            av_mutex_unlock(lock)

            job.run()

            av_mutex_lock(lock)
            done.append(job)
            if done.count == 1 {
                // The worker takes the whole list when the byte arrives, so
                // one byte per list is enough.
                var byte: UInt8 = 1
                _ = av_write(writeFD, &byte, 1)
            }
        }
    }

    /// The work finished since the last call, taken by the worker.
    func takeFinished() -> [BlockingJob] {
        var byte = [UInt8](repeating: 0, count: 64)
        while byte.withUnsafeMutableBytes({ av_read(readFD, $0.baseAddress!, $0.count) }) > 0 {}
        av_mutex_lock(lock)
        let finished = done
        done = []
        av_mutex_unlock(lock)
        return finished
    }

    /// Lets idle threads end, and busy ones once their work is done.
    func stop() {
        av_mutex_lock(lock)
        stopping = true
        av_cond_broadcast(ready)
        av_mutex_unlock(lock)
    }
}

extension Worker {
    /// The worker's blocking pool, started on first use with its pipe on the
    /// poller.
    mutating func blockingPool() throws(BlockingPoolError) -> BlockingPool {
        if let pool = blockingThreads { return pool }
        guard let pool = BlockingPool(threads: config.blockingThreads, queue: config.blockingQueue),
              poller.add(pool.readFD, .read, token: PollToken.blocking) else {
            Log.error("cannot start the blocking pool")
            throw .unavailable
        }
        blockingThreads = pool
        return pool
    }

    /// Resumes the tasks whose blocking work has finished.
    mutating func handleBlockingFinished() {
        guard let pool = blockingThreads else { return }
        for job in pool.takeFinished() { job.finish() }
        runHandlerTasks()
    }

    /// Stops the pool's threads. Work still running finishes, and nobody
    /// hears of it.
    mutating func stopBlockingPool() {
        guard let pool = blockingThreads else { return }
        _ = poller.remove(pool.readFD, last: .read)
        pool.stop()
        blockingThreads = nil
    }
}

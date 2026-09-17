//===----------------------------------------------------------------------===//
// Async handlers, run on tasks the worker keeps.
//
// A new `Task` per request costs 1.2-2.3 µs and five allocations; resuming a
// long-lived one costs about 360 ns and none (benchmarks/async-probes/). So
// each worker owns an executor that runs jobs only on the worker's thread,
// when the worker drains it, and a pool of tasks that prefer that executor. A
// request for an async handler resumes an idle task, which runs the handler
// inline, in the same loop turn, until it answers or waits. When every task is
// busy a new one joins the pool, up to `Worker.handlerTaskLimit`; past that
// the request waits in the pool's queue for the next task to come free.
//
// To the rest of the engine, a request on a task is a continuation of kind
// `.task`. Closing the connection, resetting the stream or starting the next
// request cancels it through `cancelOps`, which wakes a task waiting on the
// engine: the wait throws, the handler unwinds, and the task goes back to the
// pool. Every resume keeps its (slot, generation, request id) check.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// An async handler over the raw request. It reads what it needs from the
/// request before its first `await`: the request is a view of a connection
/// slot, and only a wait on the engine (`Response.sleep`) checks, on resuming,
/// that the slot still holds the same request.
public typealias AsyncHandler = (borrowing Request, inout Response) async throws -> Void

/// Why a wait on the engine did not complete.
public enum HandlerWaitError: Error, Equatable {
    /// The request ended first: its connection closed, its stream was reset,
    /// or it was answered.
    case cancelled
    /// The worker had no room left to wait in.
    case exhausted
}

/// Runs the jobs of a worker's handler tasks, on the worker's thread, when the
/// worker drains it. Nothing here is atomic, so a job enqueued from another
/// thread is refused loudly; a way in from other threads is step 3's.
final class WorkerExecutor: TaskExecutor, @unchecked Sendable {
    private let worker: UnsafeMutableRawPointer
    private var jobs: UnsafeMutablePointer<UnownedJob>
    /// A power of two, so the ring's indices wrap with a mask.
    private var capacity: Int
    private var head = 0
    private(set) var count = 0
    private var draining = false

    init(worker: UnsafeMutablePointer<Worker>, capacity: Int = 64) {
        self.worker = UnsafeMutableRawPointer(worker)
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        jobs = UnsafeMutablePointer<UnownedJob>.allocate(capacity: size)
    }

    deinit {
        jobs.deallocate()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        precondition(av_worker_current() == worker,
                     "a handler task was resumed off its worker's thread")
        if count == capacity { grow() }
        (jobs + ((head &+ count) & (capacity &- 1))).initialize(to: UnownedJob(job))
        count += 1
    }

    /// Runs queued jobs, and the jobs they queue, until none is left. Called
    /// from inside a job it returns at once: the drain already running picks
    /// up whatever that job adds.
    func drain() {
        if draining { return }
        draining = true
        while count > 0 {
            let job = (jobs + head).move()
            head = (head &+ 1) & (capacity &- 1)
            count -= 1
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
        draining = false
    }

    /// Only while tasks are being added faster than they run, so the ring
    /// stops growing once the pool is warm.
    private func grow() {
        let larger = UnsafeMutablePointer<UnownedJob>.allocate(capacity: capacity * 2)
        for i in 0..<count {
            (larger + i).initialize(to: (jobs + ((head &+ i) & (capacity &- 1))).move())
        }
        jobs.deallocate()
        jobs = larger
        capacity *= 2
        head = 0
    }
}

/// A worker's handler tasks, and the requests waiting for one.
final class HandlerTaskPool: @unchecked Sendable {
    /// A request handed to a task.
    struct Work: @unchecked Sendable {
        var slot: Int
        var generation: UInt32
        var requestId: UInt32
        var handler: AsyncHandler
    }

    struct Record {
        /// Set while the task is idle. Resuming it hands over a request, or
        /// nil to end the task.
        var inbox: UnsafeContinuation<Work?, Never>? = nil
        /// Set while the task waits on the engine. Resuming it says whether
        /// the wait completed (true) or its request was cancelled (false).
        var wake: UnsafeContinuation<Bool, Never>? = nil
    }

    let worker: UnsafeMutablePointer<Worker>
    let executor: WorkerExecutor
    let limit: Int
    /// Tasks started, each numbered by its index into `records`.
    private(set) var count = 0
    private let records: UnsafeMutablePointer<Record>
    /// A stack of the idle tasks' numbers.
    private let idle: UnsafeMutablePointer<Int32>
    private(set) var idleCount = 0
    /// Requests that found every task busy, oldest first. A cancelled one
    /// stays until it is reached, and is skipped then.
    private var waiting: ReadyQueue

    init(worker: UnsafeMutablePointer<Worker>, limit: Int, slots: Int) {
        precondition(limit > 0)
        self.worker = worker
        self.limit = limit
        executor = WorkerExecutor(worker: worker)
        records = UnsafeMutablePointer<Record>.allocate(capacity: limit)
        records.initialize(repeating: Record(), count: limit)
        idle = UnsafeMutablePointer<Int32>.allocate(capacity: limit)
        waiting = ReadyQueue(minimumCapacity: max(slots, 1))
    }

    deinit {
        records.deinitialize(count: limit)
        records.deallocate()
        idle.deallocate()
        waiting.destroy()
    }

    /// Hands `work` to an idle task, or to a new one while the pool is under
    /// its limit, and runs it until it answers or waits. False when every
    /// task is busy: the caller queues the request with `enqueue`.
    func start(_ work: Work) -> Bool {
        if idleCount > 0 {
            idleCount -= 1
            let index = Int(idle[idleCount])
            guard let inbox = records[index].inbox.take() else {
                preconditionFailure("an idle handler task has no inbox")
            }
            inbox.resume(returning: work)
        } else if count < limit {
            spawn(count, first: work)
            count += 1
        } else {
            return false
        }
        executor.drain()
        return true
    }

    /// Queues a request that found every task busy.
    func enqueue(slot: Int, generation: UInt32, requestId: UInt32) {
        let entry = ReadyEntry(slot: Int32(slot), generation: generation,
                               requestId: requestId, ticket: 0)
        if waiting.push(entry) { return }
        // Full. A slot has at most one request waiting that is still its
        // own, and there is room for every slot, so some entries are stale.
        let worker = self.worker
        waiting.compact { HandlerTaskPool.isQueued($0, in: worker.pointee.table) }
        let pushed = waiting.push(entry)
        precondition(pushed, "handler task queue full of live requests")
    }

    /// Resumes the task waiting on the engine for a request, to carry on.
    func wake(_ index: Int) {
        records[index].wake.take()?.resume(returning: true)
        executor.drain()
    }

    /// Resumes the task waiting on the engine for a request, to carry on,
    /// when the worker next drains the executor rather than here.
    func resume(_ index: Int) {
        records[index].wake.take()?.resume(returning: true)
    }

    /// Resumes the task waiting on the engine for a request, to throw
    /// `cancelled`. It runs when the worker next drains the executor, not
    /// here: the caller is part-way through closing the request.
    func cancel(_ index: Int) {
        records[index].wake.take()?.resume(returning: false)
    }

    /// Parks the task running a request until the engine resumes it.
    func park(_ index: Int, _ wake: UnsafeContinuation<Bool, Never>) {
        records[index].wake = wake
    }

    /// Ends every task that can be ended: the idle ones, and those whose
    /// request was cancelled and so unwound. One suspended on something other
    /// than the engine is left to finish on its own.
    func shutdown() {
        while waiting.pop() != nil {}
        executor.drain()
        while idleCount > 0 {
            idleCount -= 1
            records[Int(idle[idleCount])].inbox.take()?.resume(returning: nil)
        }
        executor.drain()
    }

    private func spawn(_ index: Int, first: Work) {
        let pool = self
        Task(executorPreference: executor) {
            var next: Work? = first
            while let work = next {
                await pool.run(index, work)
                if let queued = pool.dequeue() {
                    next = queued
                } else {
                    next = await withUnsafeContinuation { pool.parkIdle(index, $0) }
                }
            }
        }
    }

    private func parkIdle(_ index: Int, _ inbox: UnsafeContinuation<Work?, Never>) {
        records[index].inbox = inbox
        idle[idleCount] = Int32(index)
        idleCount += 1
    }

    /// The oldest queued request that is still waiting for a task.
    private func dequeue() -> Work? {
        while let entry = waiting.pop() {
            guard HandlerTaskPool.isQueued(entry, in: worker.pointee.table) else { continue }
            let c = worker.pointee.table[Int(entry.slot)]
            guard let handler = c.pointee.contAsyncHandler else { continue }
            return Work(slot: Int(entry.slot), generation: entry.generation,
                        requestId: entry.requestId, handler: handler)
        }
        return nil
    }

    private static func isQueued(_ entry: ReadyEntry, in table: ConnectionTable) -> Bool {
        let c = table[Int(entry.slot)]
        return c.pointee.state != .free
            && c.pointee.generation == entry.generation
            && c.pointee.requestId == entry.requestId
            && c.pointee.contKind == .task
            && c.pointee.contTask < 0
    }

    private func run(_ index: Int, _ work: Work) async {
        let worker = self.worker
        let c = worker.pointee.table[work.slot]
        // Cancelled between being handed over and starting.
        guard c.pointee.state != .free, c.pointee.generation == work.generation,
              c.pointee.requestId == work.requestId, c.pointee.contKind == .task,
              c.pointee.contTask < 0 else { return }
        c.pointee.contTask = Int32(index)
        c.pointee.contState = .none
        c.pointee.contAsyncHandler = nil
        let request = Request(worker: worker, slot: work.slot)
        var response = Response(worker: worker, slot: work.slot,
                                generation: work.generation, requestId: work.requestId)
        var failure: (any Error)? = nil
        do {
            try await work.handler(request, &response)
            // A handler that returned a streamed body (`StreamingBody`,
            // `EventStream`) has had its head sent; the body is written here,
            // still on this task.
            if let produce = worker.pointee.takeStreamProducer(work.slot, generation: work.generation,
                                                               requestId: work.requestId) {
                try await produce(ResponseBodyWriter(response))
            }
        } catch {
            failure = error
        }
        worker.pointee.taskFinished(index, work.slot, generation: work.generation,
                                    requestId: work.requestId, failure)
    }
}

extension Worker {
    /// Runs an async handler for the request on `slot` on one of the worker's
    /// tasks, or queues it for the next one to come free.
    mutating func runOnTask(_ slot: Int, _ handler: @escaping AsyncHandler) {
        let c = table[slot]
        c.pointee.contKind = .task
        c.pointee.contTask = -1
        // Not the handler's to answer until a task picks it up.
        c.pointee.contState = .waiting
        let pool = handlerTasks ?? makeHandlerTasks()
        let generation = c.pointee.generation
        let requestId = c.pointee.requestId
        let work = HandlerTaskPool.Work(slot: slot, generation: generation,
                                        requestId: requestId, handler: handler)
        if pool.start(work) { return }
        c.pointee.contAsyncHandler = handler
        pool.enqueue(slot: slot, generation: generation, requestId: requestId)
    }

    /// Made on the first async request, so a worker serving only synchronous
    /// handlers never has one.
    mutating func makeHandlerTasks() -> HandlerTaskPool {
        guard let me = currentWorker else {
            preconditionFailure("an async handler ran outside its worker's loop")
        }
        let pool = HandlerTaskPool(worker: me, limit: max(1, min(handlerTaskLimit, table.capacity)),
                                   slots: table.capacity)
        handlerTasks = pool
        return pool
    }

    /// Runs whatever the handler tasks have ready: tasks woken to unwind a
    /// cancelled request. A worker with no async handler pays one check.
    @inline(__always)
    mutating func runHandlerTasks() {
        guard let pool = handlerTasks, pool.executor.count > 0 else { return }
        pool.executor.drain()
    }

    /// Settles the request a task's handler has finished with, if it is still
    /// that task's to settle.
    mutating func taskFinished(_ index: Int, _ slot: Int, generation: UInt32,
                               requestId: UInt32, _ failure: (any Error)?) {
        let c = table[slot]
        guard c.pointee.state != .free, c.pointee.generation == generation,
              c.pointee.requestId == requestId, c.pointee.contKind == .task,
              c.pointee.contTask == Int32(index) else { return }
        c.pointee.contKind = .none
        c.pointee.contTask = -1
        c.pointee.contState = .none
        if c.pointee.flags.contains(.streamingResponse)
            && !c.pointee.flags.contains(.responseComplete) {
            streamingHandlerFinished(slot, failure)
            return
        }
        guard let failure else {
            handlerReturned(slot, generation: generation, requestId: requestId)
            return
        }
        if let wait = failure as? HandlerWaitError {
            switch wait {
            case .exhausted:
                if handlerOwes(slot, generation: generation, requestId: requestId) {
                    respond(slot, status: 503, nil, 0)
                }
            case .cancelled:
                // The request ended, or something answered for it. There is
                // nothing to say and nobody to say it to, so this is not a
                // fault and is not logged as one.
                break
            }
            return
        }
        handlerThrew(slot, generation: generation, requestId: requestId, failure)
    }

    /// Cancels the task, or the place in the queue, of the request on `slot`.
    mutating func cancelTask(_ slot: Int) {
        let c = table[slot]
        c.pointee.contAsyncHandler = nil
        if c.pointee.contTask >= 0 { handlerTasks?.cancel(Int(c.pointee.contTask)) }
        c.pointee.contTask = -1
    }

    /// Arms a timer for the task running the request, and says which task
    /// that is.
    mutating func armTaskWait(_ slot: Int, generation: UInt32, requestId: UInt32,
                              milliseconds: UInt64) throws(HandlerWaitError) -> Int {
        let c = table[slot]
        guard c.pointee.state == .dispatching, c.pointee.generation == generation,
              c.pointee.requestId == requestId, c.pointee.contKind == .task,
              c.pointee.contTask >= 0, c.pointee.contState == .none,
              // A streamed body is still being written, so its handler may
              // still wait between writes.
              !c.pointee.flags.contains(.responseStarted)
                || isStreaming(slot, generation: generation, requestId: requestId) else {
            throw .cancelled
        }
        guard armTimer(slot, ms: milliseconds, kind: .task) else { throw .exhausted }
        return Int(c.pointee.contTask)
    }
}

extension Response {
    /// Waits `milliseconds` on the worker's timers, from an async handler.
    /// Throws `cancelled` if the request ends first, and `exhausted` when the
    /// worker has no room left to wait in, which is answered 503.
    public func sleep(milliseconds: UInt64) async throws(HandlerWaitError) {
        let worker = self.worker
        let index = try worker.pointee.armTaskWait(slot, generation: generation,
                                                   requestId: requestId,
                                                   milliseconds: milliseconds)
        let completed = await withUnsafeContinuation {
            worker.pointee.handlerTasks!.park(index, $0)
        }
        if !completed { throw .cancelled }
    }
}

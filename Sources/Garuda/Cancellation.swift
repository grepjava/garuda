//===----------------------------------------------------------------------===//
// Giving up on a wait the engine does not own.
//
//     app.onAsync(.get, "/report") { request, response in
//         let rows = try await response.cancellable { try await upstream.fetch() }
//         try response.send(JSON(rows))
//     }
//
// The engine ends its own waits when a request ends: reading a body, writing
// a streamed response, sleeping, waiting for a connection from a pool. The
// handler is resumed and throws `cancelled`, and that is the end of it.
//
// A wait that is not the engine's is another matter. A handler suspended on a
// library's own continuation is not woken by a client hanging up, because
// nothing knows to wake it, and it holds a handler task until whatever it is
// waiting for finishes on its own. Enough of those and a worker has no
// handlers left for requests anybody is still listening for.
//
// The task cannot simply be cancelled. Handler tasks are pooled and reused,
// and a task cancelled in Swift's sense stays cancelled for good, so
// cancelling one would spend it. `cancellable` runs the wait in a task of its
// own instead -- a fresh one, which may be cancelled -- and races it against
// the request ending. Whichever happens first wins. If the request ends first
// the body is cancelled and the handler throws at once, without waiting to
// see what the body makes of that.
//
// What this does not do is stop the abandoned work. A body that ignores
// cancellation runs to its end, on this worker's one thread, and the handler
// it was holding is the only thing it gives back. So the worker counts what
// it is carrying, says so in the log once, and answers the health check 503
// past `ServerConfig.maxAbandonedWaits` -- which takes the worker out of
// rotation until it catches up, rather than failing requests that have
// nothing to do with whatever is stuck. Refusing every request would punish
// the wrong ones; looking healthy would be a lie.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// One waiter's place in the queue for the request ending, so that a race
/// settled by the body takes its own continuation back and leaves the rest
/// alone.
final class CancelWaiter: @unchecked Sendable {
    private var wake: UnsafeContinuation<Void, Never>? = nil
    /// Set when whoever it was waiting for has already happened, so a park
    /// that arrives afterwards does not wait for something that is over.
    private var settled = false

    /// Suspends until `resume`, or returns at once when that has been.
    func park(_ continuation: UnsafeContinuation<Void, Never>) {
        if settled { continuation.resume() } else { wake = continuation }
    }

    func resume() {
        settled = true
        wake.take()?.resume()
    }
}

extension Worker {
    /// Whether anything is waiting for this request to end.
    func hasCancelWaiting(_ slot: Int) -> Bool {
        !table[slot].pointee.cancelWaiters.isEmpty
    }

    /// Tells everything waiting for this request that it is over. Called
    /// wherever a request ends: the connection closed, the stream reset, the
    /// deadline passed, the next request taking the slot.
    mutating func wakeCancelWaiters(_ slot: Int) {
        let waiting = table[slot].pointee.cancelWaiters
        guard !waiting.isEmpty else { return }
        table[slot].pointee.cancelWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// How many bodies are still running whose request has ended.
    var abandonedWaits: Int { abandonedWaitCount }

    /// Whether the worker is carrying so much abandoned work that taking
    /// another request would be a promise it cannot keep.
    var isOverAbandoned: Bool {
        config.maxAbandonedWaits > 0 && abandonedWaitCount > config.maxAbandonedWaits
    }

    mutating func noteAbandoned(_ started: Bool) {
        abandonedWaitCount += started ? 1 : -1
        guard started, config.maxAbandonedWaits > 0,
              abandonedWaitCount == config.maxAbandonedWaits + 1 else { return }
        // Once, on the way past: a line per abandoned wait would be a line
        // per request on a worker in this state.
        Log.error("more work is outliving its requests than this worker can carry; the health check says 503 until it catches up")
    }
}

extension Response {
    /// Runs `body`, and gives up on it if this request ends first.
    ///
    /// For a wait the engine does not own -- a library with a continuation of
    /// its own, an upstream call, anything that would otherwise keep a
    /// handler after the client had gone. Throws `HandlerWaitError.cancelled`
    /// the moment the request ends, and does not wait to see what `body`
    /// makes of being cancelled.
    ///
    /// Inside `body`, Swift cancellation works as it does anywhere:
    /// `Task.isCancelled` becomes true and `withTaskCancellationHandler`
    /// runs, because the task it runs in is a fresh one rather than the
    /// pooled task running the handler. A body that pays no attention to
    /// either keeps running on this worker's thread until it finishes; it
    /// simply no longer holds the handler.
    ///
    /// `body` runs on the worker's thread and must be resumed on it, which is
    /// Garuda's rule for everything, not something this relaxes: a library
    /// that resumes a continuation from a thread of its own breaks the engine
    /// here as it would anywhere, and `blocking` is the way in from another
    /// thread.
    ///
    ///     let rows = try await response.cancellable {
    ///         try await upstream.fetch(id)
    ///     }
    public func cancellable<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await Cancellation(response: self).running(body)
    }
}

/// What a typed handler asks for to give up on a wait the engine does not own.
///
///     app.get("/report/:id") { (id: Path<Int>, upstream: Cancellation) async throws -> JSON<Report> in
///         JSON(try await upstream.running { try await client.report(id.value) })
///     }
///
/// It is the same thing as `Response.cancellable`, for handlers that do not
/// take a response.
///
/// Unchecked on the same ground as the rest of the engine: the worker it names
/// is one process and one thread, and a handler and the task it starts both
/// run on that thread.
public struct Cancellation: RequestExtractor, @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let generation: UInt32
    let requestId: UInt32

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Cancellation {
        let c = request.worker.pointee.table[request.slot]
        return Cancellation(worker: request.worker, slot: request.slot,
                            generation: c.pointee.generation, requestId: c.pointee.requestId)
    }

    init(worker: UnsafeMutablePointer<Worker>, slot: Int, generation: UInt32, requestId: UInt32) {
        self.worker = worker
        self.slot = slot
        self.generation = generation
        self.requestId = requestId
    }

    init(response: borrowing Response) {
        worker = response.worker
        slot = response.slot
        generation = response.generation
        requestId = response.requestId
    }

    /// Whether the request is still the one this was made for.
    public var isActive: Bool {
        worker.pointee.stillHolds(slot, generation: generation, requestId: requestId)
    }

    /// Runs `body`, and gives up on it if the request ends first. See
    /// `Response.cancellable`, which is the same call.
    public func running<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a request was waited on off its worker's thread")
        // Over before it started: no task, no race.
        guard isActive else { throw HandlerWaitError.cancelled }
        let worker = self.worker
        let slot = self.slot
        let pool = worker.pointee.handlerTasks ?? worker.pointee.makeHandlerTasks()
        let waiter = CancelWaiter()
        let answer = CancellationAnswer<Value>()
        // Registered before the body is started, so that a request ending
        // while the body runs is not missed.
        worker.pointee.table[slot].pointee.cancelWaiters.append(waiter)
        let carried = Unsafely((worker: worker, waiter: waiter, answer: answer))
        let work = Task(executorPreference: pool.executor) {
            do {
                carried.value.answer.result = .success(try await body())
            } catch {
                carried.value.answer.result = .failure(error)
            }
            // Whether it won or lost the race, the waiter is what wakes the
            // handler, and a lost race is counted back in here.
            if carried.value.answer.abandoned {
                carried.value.worker.pointee.noteAbandoned(false)
            } else {
                carried.value.waiter.resume()
            }
        }
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            waiter.park(continuation)
        }
        // Whoever woke it, this request is no longer waiting on the list.
        worker.pointee.table[slot].pointee.cancelWaiters.removeAll { $0 === waiter }
        if let result = answer.result { return try result.get() }
        // The request ended first. The body carries on for as long as it
        // takes; what it does not carry on holding is the handler.
        answer.abandoned = true
        worker.pointee.noteAbandoned(true)
        work.cancel()
        throw HandlerWaitError.cancelled
    }
}

/// Where the body leaves what it returned, for the handler to pick up.
final class CancellationAnswer<Value>: @unchecked Sendable {
    var result: Result<Value, any Error>? = nil
    /// Set when the handler gave up first, so the body knows to count itself
    /// back in rather than wake a handler that has gone.
    var abandoned = false
}

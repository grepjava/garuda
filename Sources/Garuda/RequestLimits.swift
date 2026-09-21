//===----------------------------------------------------------------------===//
// Limits a scope puts on its requests: how large a body, and how many at once.
//
//     app.maxBodySize(64 << 20) {
//         app.post("/photos") { … }            // up to 64 MiB, whatever --max-body says
//     }
//     app.concurrencyLimit(8) {
//         app.post("/reports") { … }           // eight at a time per worker, then 503
//     }
//
// **Body size.** `--max-body` is the server's limit for a body given whole.
// Inside `maxBodySize`, routes have their own, larger or smaller. It is
// applied where `--max-body` is: a declared length past it is answered 413
// before a byte of the body is read, and a body that grows past it as it
// arrives is refused when it does. For that, a request with a body is matched
// to its route at its head. A route that streams its body keeps the limit it
// was registered with.
//
// **Concurrency.** A scope's handlers may be running at most `max` at once in
// each worker process; one more is answered 503 without running. It counts
// handlers, from when one starts to when it returns: middleware runs first
// and is not counted, so a request the scope's authentication refuses takes
// no place. A handler that streams its response holds its place until it
// finishes writing, while a synchronous one that waits with `response.after`
// gives it back when it returns, before the wait. Nested limits all apply, so
// a route inside two counts against both.
//
// One worker is one process, so the count is per worker: four workers with
// `concurrencyLimit(8)` run up to 32. What this bounds is what one worker
// holds for a scope at once -- database connections, memory, a slow upstream
// -- not the server's total.
//===----------------------------------------------------------------------===//

import Synchronization

extension Application {
    /// Holds the bodies of routes registered inside `register` to `bytes`, in
    /// place of `--max-body`. Nested calls apply the innermost.
    public func maxBodySize(_ bytes: Int, _ register: () -> Void) {
        precondition(compiled == nil, "body limit added after the application was compiled")
        precondition(bytes >= 0, "a body limit cannot be negative")
        let previous = routes.currentBodyLimit
        routes.currentBodyLimit = bytes
        defer { routes.currentBodyLimit = previous }
        register()
    }

    /// Lets at most `max` handlers of the routes registered inside `register`
    /// run at once in each worker, and answers 503 past that.
    ///
    /// A handler that streams its body holds its place until the body has been
    /// written, including one that returns a `StreamingBody` or an
    /// `EventStream` for the task to write after the handler itself is done.
    public func concurrencyLimit(_ max: Int, _ register: () -> Void) {
        precondition(compiled == nil, "concurrency limit added after the application was compiled")
        precondition(max > 0, "a concurrency limit is at least 1")
        routes.currentLimiters.append(ConcurrencyLimiter(max: max))
        defer { routes.currentLimiters.removeLast() }
        register()
    }
}

extension Router {
    public func maxBodySize(_ bytes: Int, _ register: () -> Void) {
        precondition(bytes >= 0, "a body limit cannot be negative")
        scoped(register) { .maxBodySize(bytes, $0) }
    }

    public func concurrencyLimit(_ max: Int, _ register: () -> Void) {
        precondition(max > 0, "a concurrency limit is at least 1")
        scoped(register) { .concurrencyLimit(max, $0) }
    }
}

/// One handler's place while the handler runs, and what becomes of it when the
/// handler returns.
///
/// A handler that returned a `StreamingBody` or an `EventStream` has not
/// finished: its head has been sent and the body is written afterwards, on the
/// same task, by the producer it left behind. Giving the place back when the
/// handler returned would let `concurrencyLimit(1)` admit the next request
/// while this one is still writing -- which is the case the limit exists for,
/// since a streamed body is the long one. So the place goes to the body, and
/// `HandlerTasks` gives it back once the writing has ended.
struct PermitHold {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let generation: UInt32
    let requestId: UInt32
    let permit: LimitPermit

    init(_ worker: UnsafeMutablePointer<Worker>, _ slot: Int, _ generation: UInt32,
         _ requestId: UInt32, _ permit: LimitPermit) {
        self.worker = worker
        self.slot = slot
        self.generation = generation
        self.requestId = requestId
        self.permit = permit
    }

    /// The handler has returned. Parks the place with a body still to be
    /// written, or gives it back now.
    func done() {
        if !worker.pointee.parkPermit(slot, generation: generation, requestId: requestId,
                                      permit) {
            permit.release()
        }
    }
}

extension Worker {
    /// Parks `permit` with a streamed body the handler left to be written.
    /// False where there is no such body, and the caller gives it back itself.
    func parkPermit(_ slot: Int, generation: UInt32, requestId: UInt32,
                    _ permit: LimitPermit) -> Bool {
        let c = table[slot]
        guard let context = c.pointee.context, context.streamProducer != nil,
              context.generation == generation, context.requestId == requestId else {
            return false
        }
        context.streamPermit = permit
        return true
    }

    /// Gives back a place parked with a streamed body, if there is one. Called
    /// once the task has finished with the request, whether the body was
    /// written, threw part way, or never ran at all.
    func releaseParkedPermit(_ slot: Int, generation: UInt32, requestId: UInt32) {
        guard let context = table[slot].pointee.context,
              context.generation == generation, context.requestId == requestId else { return }
        context.streamPermit.take()?.release()
    }
}

/// Handlers of one scope running now, against the most allowed.
final class ConcurrencyLimiter: Sendable {
    let max: Int
    let running = Atomic<Int>(0)

    init(max: Int) {
        self.max = max
    }

    /// A place for one handler under every limiter in `limiters`, or nil,
    /// holding none, when any is full.
    static func acquire(_ limiters: [ConcurrencyLimiter]) -> LimitPermit? {
        for (i, limiter) in limiters.enumerated() {
            let taken = limiter.running.add(1, ordering: .relaxed).newValue
            if taken > limiter.max {
                limiter.running.subtract(1, ordering: .relaxed)
                for held in limiters[..<i] { held.running.subtract(1, ordering: .relaxed) }
                return nil
            }
        }
        return LimitPermit(limiters)
    }
}

/// One handler's place. Given back once, by `release` or, for a handler that
/// never got to run, when the permit goes away.
final class LimitPermit: @unchecked Sendable {
    private var limiters: [ConcurrencyLimiter]

    init(_ limiters: [ConcurrencyLimiter]) {
        self.limiters = limiters
    }

    func release() {
        for limiter in limiters { limiter.running.subtract(1, ordering: .relaxed) }
        limiters = []
    }

    deinit { release() }
}

extension Routes {
    /// The route's handler, and its async handler if it has one, answering
    /// 503 instead of running when the scope's limits are full.
    func limited(_ index: Int, _ handler: @escaping Handler,
                 _ asyncHandler: AsyncHandler?) -> (Handler, AsyncHandler?) {
        let limiters = routeLimiters[index]
        guard !limiters.isEmpty else { return (handler, asyncHandler) }
        guard let asyncHandler else {
            return ({ request, response in
                guard let permit = ConcurrencyLimiter.acquire(limiters) else {
                    response.send(status: .serviceUnavailable)
                    return
                }
                defer { permit.release() }
                try handler(request, &response)
            }, nil)
        }
        // Called on a task, from a chain already running there.
        let onTask: AsyncHandler = { request, response in
            guard let permit = ConcurrencyLimiter.acquire(limiters) else {
                response.send(status: .serviceUnavailable)
                return
            }
            let hold = PermitHold(request.worker, request.slot,
                                  response.generation, response.requestId, permit)
            defer { hold.done() }
            try await asyncHandler(request, &response)
        }
        // Called on the worker: a full scope is answered there, without
        // costing a task, and the place goes to the task with the handler.
        let onWorker: Handler = { request, response in
            guard let permit = ConcurrencyLimiter.acquire(limiters) else {
                response.send(status: .serviceUnavailable)
                return
            }
            request.worker.pointee.runOnTask(request.slot) { request, response in
                let hold = PermitHold(request.worker, request.slot,
                                      response.generation, response.requestId, permit)
                defer { hold.done() }
                try await asyncHandler(request, &response)
            }
        }
        return (onWorker, onTask)
    }
}

//===----------------------------------------------------------------------===//
// Dispatch: from a parsed request in an exchange to its answer in the same
// exchange -- the route, the trailing-slash and fallback rules, 404 and 405,
// CORS preflights, the heavy lane, and what a handler that throws or does
// not answer is answered with.
//
// A function of the exchange alone, so every protocol that fills one -- an
// HTTP/1 connection, an HTTP/2 stream -- reaches the application the same
// way, and frames what it gets back in its own way.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega

/// Finds the route and runs its handler, answering for it when it throws
/// or returns without answering. `matched` is the route when it was
/// matched already, with its parameters in the exchange, or -1.
func dispatch(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, matched: Int32 = -1,
              observing: Bool) async {
    await dispatchInline(x, app, matched: matched, observing: observing)
}

/// `dispatch`, for a caller that saves the hops into and out of it -- an
/// executor check each, under a lock while the task prefers an executor -- by
/// having it inlined: HTTP/2 streams.
@inline(__always)
func dispatchInline(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, matched: Int32 = -1,
                    observing: Bool) async {
    // --static-dir comes before the routes; a path naming no file falls
    // through to them (StaticFiles.swift).
    if x.pointee.compress { x.pointee.negotiateCoding() }
    if x.pointee.site != nil, await serveStatic(x) { return }
    let path = x.pointee.head.path
    let base = x.pointee.base + Int(path.offset)
    var count = path.count
    var route = matched >= 0 ? matched
        : app.table.match(x.pointee.head.method, base, count, into: &x.pointee.parameters)
    // A trailing slash no route has, under `app.trailingSlash`: redirected,
    // or matched again without it (TrailingSlash.swift). Only a miss looks.
    if route < 0 && app.trailingSlash != .strict,
       let trimmed = pathWithoutTrailingSlash(app, base, count, &x.pointee.parameters) {
        if app.trailingSlash == .redirect {
            if redirectWithoutTrailingSlash(x) { return }
        } else {
            count = trimmed
            route = app.table.match(x.pointee.head.method, base, count, into: &x.pointee.parameters)
        }
    }
    guard route >= 0 else {
        let allowed = app.table.allowedMethods(base, count, into: &x.pointee.parameters)
        x.pointee.parameters = RouteParameters()
        if allowed.isEmpty {
            // The fallback of the most specific scope the path is in,
            // when there is one (Fallbacks.swift). It answers with no
            // route: `x.pointee.route` stays -1.
            let fallback = app.fallbacks.isEmpty ? -1 : app.fallbacks.match(base, count)
            if fallback >= 0 { return await runHandler(x, app, Int(fallback), observing: observing) }
            // A browser navigating to a single-page application's route.
            if x.pointee.site != nil, await serveSPAFallback(x) { return }
            x.pointee.answer(404, nil, 0)
        } else if x.pointee.head.method == .options && app.hasCORS
                    && answerPreflight(x, app, allowed: allowed, base, count) {
            // A CORS preflight to a path routed only for other methods:
            // the policy of a route there answers it rather than a 405
            // (CORS.swift). Only an OPTIONS that matched nothing, in an
            // application with a policy, gets this far.
        } else {
            var list = ""
            for method in allowed {
                if !list.isEmpty { list += ", " }
                list += method.name
            }
            Response(x).addHeader("allow", list)
            x.pointee.answer(405, nil, 0)
        }
        return
    }
    x.pointee.route = route
    await runHandler(x, app, Int(route), observing: observing)
}

/// Runs handler `index`: a route's, or a fallback's.
@inline(__always)
func runHandler(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, _ index: Int,
                observing: Bool) async {
    let handler = app.handlers[index]
    let costs = app.costs
    let heavy = costs.isHeavy(index)
    let lane = heavy ? costs.lane : nil
    // Only fails once the lane is closed, at shutdown: run regardless.
    if let lane { try? await lane.acquireIgnoringCancellation() }
    let start = monotonicNanos()
    let sampled = costs.shouldSample(index, heavy: heavy, now: start)
    let stamp = sampled ? Runtime.currentJobStamp : .none
    do {
        try await handler(Request(x), Response(x))
        if let produce = x.pointee.producer {
            // A returned `StreamingBody`, now that the middleware on its way
            // out has had its say (StreamingResponse.swift).
            try await runProducer(x, produce)
        } else if !x.pointee.answered {
            Log.error("a handler returned without answering; answering 500")
            if observing { x.pointee.failure = "the handler returned without answering" }
            x.pointee.answer(500, nil, 0)
        }
    } catch let error as any ResponseError {
        if !cutStream(x, error, observing: observing) { answerError(x, error) }
    } catch is CancellationError where Task.isCancelled {
        // Cancelled because nobody wants the answer -- an HTTP/2 stream the
        // client reset -- which is not the handler's failure to report.
        if !cutStream(x, nil, observing: false) { answerFailure(x) }
    } catch is HandlerWaitError {
        // A streamed body's client went away: nothing to answer, and nobody
        // to answer it to.
        if !cutStream(x, nil, observing: false) { answerFailure(x) }
    } catch {
        if !cutStream(x, error, observing: observing) {
            Log.error("handler threw: \(error)")
            if observing { x.pointee.failure = "handler threw: \(error)" }
            answerFailure(x)
        }
    }
    // A handler that suspended gave its thread up; its time says nothing.
    if sampled && Runtime.currentJobStamp == stamp {
        costs.record(index, nanos: monotonicNanos() &- start)
    }
    lane?.release()
}

/// A handler threw: when its answer was a streamed body, cuts the body off
/// rather than answering, and says so. False when there is no streamed body,
/// for the error to be answered as any other.
func cutStream(_ x: UnsafeMutablePointer<Exchange>, _ error: (any Error)?, observing: Bool) -> Bool {
    guard let channel = x.pointee.channel else {
        // A `StreamingBody` returned, and then a layer on its way out threw:
        // the body never started, and the error is the answer.
        if x.pointee.producer != nil {
            x.pointee.producer = nil
            x.pointee.answered = false
        }
        return false
    }
    channel.handlerFailed = true
    if let error {
        Log.error("handler threw part-way through a streamed response: \(error)")
        if observing { x.pointee.failure = "handler threw part-way through a streamed response: \(error)" }
    }
    return true
}

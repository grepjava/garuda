//===----------------------------------------------------------------------===//
// app.onResponse: a look at every request once it is answered.
//
//     app.onResponse { done in
//         if done.status >= 500 {
//             AppLog.error("request failed", ["route": .string(done.route ?? "-"),
//                                             "failure": .string(done.failure ?? "-")])
//         }
//         latency.record(route: done.route, microseconds: done.microseconds)
//     }
//
// What a tracing layer does around a handler, from outside it: per-route
// metrics, an access log of the application's own design, errors reported to
// a service. An observer sees every answer the server gives -- a route's, a
// 404, a 429, a static file, a cached copy, a WebSocket's 101 -- once its head
// is settled, which is where the access log's line is written and its
// duration measured. The body of a streamed response is still to come.
//
// `route` is the pattern that matched, not the path, so it is safe to use as
// a metric label: there are as many as there are routes. It is nil when no
// route answered.
//
// `failure` says why a route answered 5xx on its own account: a handler threw
// something that is not a `ResponseError`, returned without answering, or ran
// past its deadline. A failure after the response has started -- a throw
// part-way through a streamed body -- comes after this call, and is not in it.
//
// Observers run on the worker, in the order added, while the response is
// being written. One that blocks holds up every connection on the worker; a
// slow export belongs on a task or in a buffer that something else drains.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// A request as it was answered, for `Application.onResponse`.
public struct CompletedRequest: Sendable {
    public let method: String
    /// The path as the client sent it, still percent-encoded, without the query.
    public let path: String
    /// The pattern of the route that matched, as registered with its group
    /// prefixes (`/api/users/:id`). Nil when no route answered.
    public let route: String?
    public let status: Int
    /// From the request's dispatch to its response head being settled.
    public let microseconds: Int
    /// "HTTP/1.1", "HTTP/1.0", "HTTP/2" or "HTTP/3".
    public let protocolName: String
    /// The client's address, or the one a trusted proxy forwarded for it.
    public let remoteAddress: String
    /// With --request-id.
    public let requestID: String?
    /// With --trace-context, from a traceparent the request carried.
    public let traceID: String?
    public let parentID: String?
    /// Why the route answered 5xx on its own account, when it did.
    public let failure: String?
}

extension Application {
    /// Calls `observer` with every request once it is answered. See
    /// ResponseObservers.swift for what it sees and when.
    public func onResponse(_ observer: @escaping (CompletedRequest) -> Void) {
        precondition(compiled == nil, "response observer added after the application was compiled")
        responseObservers.append(observer)
    }
}

extension Worker {
    /// Whether anything is watching responses, which is what makes a request
    /// worth timing when neither the access log nor metrics are on.
    var observesResponses: Bool { application?.pointee.onResponse != nil }

    /// Notes why a route failed, for the observers to see with its answer.
    mutating func noteHandlerFailure(_ slot: Int, _ description: @autoclosure () -> String) {
        if tracer != nil { requestSpanFailed(slot, nil, description()) }
        guard observesResponses else { return }
        let c = table[slot]
        handlerFailures[slot] = (c.pointee.generation, c.pointee.requestId, description())
    }

    mutating func reportResponse(_ slot: Int, status: Int, _ observe: (CompletedRequest) -> Void) {
        let c = table[slot]
        let base = c.pointee.headBase()
        var failure: String? = nil
        if let noted = handlerFailures.removeValue(forKey: slot),
           noted.generation == c.pointee.generation, noted.requestId == c.pointee.requestId {
            failure = noted.description
        }
        var route: String? = nil
        let index = Int(c.pointee.routeIndex)
        if index >= 0, let patterns = application?.pointee.routePatterns, index < patterns.count {
            route = patterns[index]
        }
        let hasTrace = c.pointee.traceContext.readableBytes
            == TraceContext.traceIDLength + TraceContext.parentIDLength
        // An empty buffer may never have been given storage to point into.
        var traceID: String? = nil
        var parentID: String? = nil
        if hasTrace {
            let trace = UnsafePointer(c.pointee.traceContext.readPointer)
            traceID = ByteSpan(trace, TraceContext.traceIDLength).string
            parentID = ByteSpan(trace + TraceContext.traceIDLength, TraceContext.parentIDLength).string
        }
        let idLength = c.pointee.requestID.readableBytes
        let completed = CompletedRequest(
            method: c.pointee.head.methodSlice.span(in: base).string,
            path: c.pointee.head.path.span(in: base).string,
            route: route,
            status: status,
            microseconds: c.pointee.requestStartUs == 0
                ? 0 : Int(av_monotonic_us() &- c.pointee.requestStartUs),
            protocolName: String(describing: protocolName(slot)),
            remoteAddress: requestClient(slot).address.string,
            requestID: idLength > 0 ? c.pointee.requestID.readableSpan.string : nil,
            traceID: traceID,
            parentID: parentID,
            failure: failure)
        observe(completed)
    }
}

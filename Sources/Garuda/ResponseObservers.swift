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
// a service. An observer sees every answer the connection gives -- a route's,
// a 404, a 405, a 413 for a body too large, a 400 for a head that would not
// parse -- once its head is written into the connection's output, which is
// where the access log's line is written and its duration measured.
//
// `route` is the pattern that matched, not the path, so it is safe to use as
// a metric label: there are as many as there are routes. It is nil when no
// route answered.
//
// `failure` says why a route answered 5xx on its own account: a handler threw
// something that is not a `ResponseError`, returned without answering, or ran
// past its deadline.
//
// Observers run in the connection's task, in the order added, before the
// connection reads its next request. One that blocks holds that connection
// and the thread under it; a slow export belongs on a task or in a buffer
// that something else drains. An application with none pays one check of a
// flag the connection works out once.
//===----------------------------------------------------------------------===//

import GarudaWire

/// A request as it was answered, for `Application.onResponse`.
public struct CompletedRequest: Sendable {
    /// Empty for a request whose head could not be read.
    public let method: String
    /// The path as the client sent it, still percent-encoded, without the
    /// query. Empty for a request whose head could not be read.
    public let path: String
    /// The pattern of the route that matched, as registered with its group
    /// prefixes (`/api/users/:id`). Nil when no route answered.
    public let route: String?
    public let status: Int
    /// From the request's dispatch to its response head being written.
    public let microseconds: Int
    /// "HTTP/1.1" or "HTTP/1.0".
    public let protocolName: String
    /// The client's address.
    public let remoteAddress: String
    /// With --request-id.
    public let requestID: String?
    /// With --trace-context, from a traceparent the request carried.
    public let traceID: String?
    public let parentID: String?
    /// Why the route answered 5xx on its own account, when it did.
    public let failure: String?
}

/// What `onResponse` registers.
public typealias ResponseObserver = @Sendable (CompletedRequest) -> Void

extension Application {
    /// Calls `observer` with every request once it is answered. See
    /// ResponseObservers.swift for what it sees and when.
    public func onResponse(_ observer: @escaping ResponseObserver) {
        precondition(compiledApplication == nil, "response observer added after the application was compiled")
        responseObservers.append(observer)
    }
}

extension HTTP1Connection {
    /// Tells the observers and the access log how the request was answered.
    /// `headParsed`: false for a request refused before its head could be
    /// read, which has no method or path to report.
    mutating func report(status: Int, headParsed: Bool = true) {
        let started = x.pointee.started
        let micros = started == 0 ? 0 : Int((monotonicNanos() &- started) / 1000)
        if let app = x.pointee.application {
            app._withUnsafeGuaranteedRef { app in
                guard !app.observers.isEmpty else { return }
                let completed = completedRequest(app, status: status, micros: micros, headParsed: headParsed)
                for observe in app.observers { observe(completed) }
            }
        }
        if limits.accessLog { logAccess(status: status, micros: micros, headParsed: headParsed) }
    }

    func completedRequest(_ app: CompiledApplication, status: Int, micros: Int,
                          headParsed: Bool) -> CompletedRequest {
        let head = x.pointee.head
        let index = Int(x.pointee.route)
        let trace = x.pointee.traceIDs
        return CompletedRequest(
            method: headParsed ? x.pointee.slice(head.methodSlice).string : "",
            path: headParsed ? x.pointee.slice(head.path).string : "",
            route: index >= 0 && index < app.patterns.count ? app.patterns[index] : nil,
            status: status,
            microseconds: micros,
            protocolName: headParsed && head.httpMinor == 0 ? "HTTP/1.0" : "HTTP/1.1",
            remoteAddress: x.pointee.remote.address,
            requestID: x.pointee.requestIDBytes?.string,
            traceID: trace?.trace.string,
            parentID: trace?.parent.string,
            failure: x.pointee.failure)
    }
}

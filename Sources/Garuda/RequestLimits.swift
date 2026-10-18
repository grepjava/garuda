//===----------------------------------------------------------------------===//
// Limits a scope puts on its requests: how large a body, and how many at once.
//
//     app.maxBodySize(64 << 20) {
//         app.post("/photos") { … }            // up to 64 MiB, whatever --max-body says
//     }
//     app.concurrencyLimit(8) {
//         app.post("/reports") { … }           // eight at a time per shard, then 503
//     }
//
// Both are scopes, as `deadline` is: a group with no prefix of its own,
// holding a marker the application reads when it compiles and takes out of
// the routes' middleware, so neither costs a layer.
//
// **Body size.** `--max-body` is the server's limit for a body. Inside
// `maxBodySize`, routes have their own, larger or smaller; nested calls apply
// the innermost. It is applied where `--max-body` is: a declared length past
// it is answered 413 before a byte of the body is read, and a chunked body
// that grows past it as it arrives is refused when it does. For that, the
// connection matches a request with a body to its route at its head, before
// reading the body, and remembers the match so the dispatch does not make it
// again. Only an application with some limit of its own does this; the rest
// read every body against `--max-body` as they always have.
//
// **Concurrency.** A scope's handlers may be running at most `max` at once in
// each shard; one more is answered 503 without running. It counts handlers,
// from when one starts to when it returns: middleware runs first and is not
// counted, so a request the scope's authentication refuses takes no place.
// Nested limits all apply, so a route inside two counts against both, and
// takes a place in both or in neither. A limit is one of Vega's semaphores,
// only ever tried, never waited on: a request past the limit is answered at
// once rather than queued behind the ones it would wait for.
//
// A shard is a process, so the count is per shard: four shards with
// `concurrencyLimit(8)` run up to 32. What this bounds is what one shard
// holds for a scope at once -- database connections, memory, a slow upstream
// -- not the server's total. A router merged twice has a limit for each
// place it is merged.
//===----------------------------------------------------------------------===//

import Vega

extension RouteBuilder {
    /// Holds the bodies of routes registered inside `register` to `bytes`, in
    /// place of `--max-body`. Nested calls apply the innermost.
    public func maxBodySize(_ bytes: Int, _ register: () -> Void) {
        precondition(bytes >= 0, "a body limit cannot be negative")
        group("/") {
            use(BodyLimitMarker(bytes: bytes))
            register()
        }
    }

    /// Lets at most `max` handlers of the routes registered inside `register`
    /// run at once in each shard, and answers 503 past that. The scope's
    /// middleware runs first, and is not counted.
    public func concurrencyLimit(_ max: Int, _ register: () -> Void) {
        precondition(max > 0, "a concurrency limit is at least 1")
        group("/") {
            use(ConcurrencyLimitMarker(max: max))
            register()
        }
    }
}

/// What the scopes say, read out of the middleware when the application
/// compiles. Never run as middleware: `Application.middleware(of:)` leaves
/// it out of the chain.
protocol ScopeLimitMarker: Middleware {}

extension ScopeLimitMarker {
    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        try await next()
    }
}

/// `maxBodySize`'s scope.
struct BodyLimitMarker: ScopeLimitMarker {
    let bytes: Int
}

/// `concurrencyLimit`'s scope.
struct ConcurrencyLimitMarker: ScopeLimitMarker {
    let max: Int
}

/// `onStreamingBody`'s scope, around its one route: the body is read as it
/// arrives, held to `bytes` (RequestBody.swift).
struct StreamingBodyMarker: ScopeLimitMarker {
    let bytes: Int
}

// MARK: - Compiling

/// The limits of each scope, made as the application compiles.
struct ScopeLimits {
    /// One semaphore per limited group, by group index: made once, so
    /// every route of the group shares it, and per group, so a router
    /// merged twice has two.
    private var semaphores: [Int: Vega.Semaphore] = [:]

    /// The body limit of a route in `groups` (outermost first), or -1 for
    /// `--max-body`; whether its handler reads the body as it arrives; and
    /// the semaphores its handler takes a place in.
    mutating func limits(of groups: [Int],
                         in scopes: [(prefix: String, middleware: [any Middleware])])
        -> (bodyLimit: Int, streamed: Bool, permits: [Vega.Semaphore]) {
        var bodyLimit = -1
        var streamed = false
        var permits: [Vega.Semaphore] = []
        for group in groups {
            for layer in scopes[group].middleware {
                if let marker = layer as? BodyLimitMarker {
                    bodyLimit = marker.bytes
                } else if let marker = layer as? StreamingBodyMarker {
                    bodyLimit = marker.bytes
                    streamed = true
                } else if let marker = layer as? ConcurrencyLimitMarker {
                    if semaphores[group] == nil { semaphores[group] = Vega.Semaphore(permits: marker.max) }
                    permits.append(semaphores[group]!)
                }
            }
        }
        return (bodyLimit, streamed, permits)
    }
}

/// `handler`, answering 503 instead of running when any of `permits` is
/// full. The handler of a route with no limit is left as it is.
func limited(_ handler: @escaping Handler, _ permits: [Vega.Semaphore]) -> Handler {
    guard !permits.isEmpty else { return handler }
    return { request, response in
        guard acquirePlaces(permits) else {
            return response.send(status: .serviceUnavailable)
        }
        defer { for semaphore in permits { semaphore.release() } }
        try await handler(request, response)
    }
}

/// A place in every one of `permits`, or in none: false, holding nothing,
/// when any is full.
func acquirePlaces(_ permits: [Vega.Semaphore]) -> Bool {
    for (i, semaphore) in permits.enumerated() where !semaphore.tryAcquire() {
        for held in permits[..<i] { held.release() }
        return false
    }
    return true
}

// MARK: - The connection side

extension HTTP1Client {
    /// `bodyRule(_:_:_:matched:)` for this connection's exchange.
    mutating func bodyRule(_ app: CompiledApplication, matched: inout Int32) -> BodyRule {
        Garuda.bodyRule(x, app, limits, matched: &matched)
    }
}

/// What the route a request goes to says of its body, worked out from the
/// head: the most it may be, and whether the handler reads it as it arrives
/// rather than being given it whole (RequestBody.swift).
struct BodyRule {
    var limit: Int
    var streamed = false
}

/// The body rule of the route the request's head goes to, in an
/// application where some scope has one: matched now, before the body is
/// read. A route that matched as the path came is put in `matched`, with
/// its parameters in the exchange, for the dispatch to use rather than
/// match again; any other outcome -- a trailing slash, a fallback, a miss
/// -- the dispatch works out again, as it is rare and cheap next to a
/// body. An HTTP/2 stream asks the same when its HEADERS arrive (HTTP2.swift).
func bodyRule(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, _ limits: ConnectionLimits,
              matched: inout Int32) -> BodyRule {
    let path = x.pointee.head.path
    let base = x.pointee.base + Int(path.offset)
    let method = x.pointee.head.method
    var route = app.table.match(method, base, path.count, into: &x.pointee.parameters)
    if route >= 0 {
        matched = route
    } else {
        x.pointee.parameters = RouteParameters()
        var scratch = RouteParameters()
        var count = path.count
        if app.trailingSlash == .ignore,
           let trimmed = pathWithoutTrailingSlash(app, base, count, &scratch) {
            count = trimmed
            route = app.table.match(method, base, count, into: &scratch)
        }
        if route < 0 && app.table.allowedMethods(base, count, into: &scratch).isEmpty {
            route = app.fallbacks.match(base, count)
        }
    }
    guard route >= 0 else { return BodyRule(limit: limits.maxBodySize) }
    let limit = app.bodyLimits[Int(route)]
    return BodyRule(limit: limit >= 0 ? limit : limits.maxBodySize, streamed: app.streamedBodies[Int(route)])
}

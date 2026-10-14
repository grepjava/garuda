//===----------------------------------------------------------------------===//
// Routes whose handler blocks, run on the blocking pool.
//
//     app.offload.post("/thumbnail") { (image: Body<Upload>) -> Bytes in
//         Bytes(resize(image.value.bytes), contentType: "image/png")
//     }
//
// A shard has a few worker threads, one a core, and every connection of the
// shard is served on them. A handler that blocks its thread -- a synchronous
// file read, a C library that waits on a lock or the network, a call into
// something that sleeps -- takes one of those threads away from every other
// request until it returns; a few of them at once and the shard stops
// answering. An offloaded route takes its extractors on the worker as any
// typed route does, runs its handler on Vega's blocking pool
// (`Runtime.blocking`, Tokio's `spawn_blocking`), and writes what the handler
// returned back on the worker, which serves other requests meanwhile. It is
// `try await Runtime.blocking { … }` around the whole handler, said where the
// route is declared.
//
// Work that only computes for long is the heavy lane's (HeavyLane.swift):
// it bounds how many threads such handlers hold, measured or declared with
// `app.heavy`, and keeps them on the workers, where they need no thread of
// their own. Offloading is for work that does not compute while it holds its
// thread.
//
// Only a synchronous handler can go: it runs on a pool thread, where nothing
// awaits, so the work that awaits -- the database, the HTTP client -- belongs
// in an ordinary async route. What it is handed and what it returns cross to
// the pool's thread and back, so they must be `Sendable`. Every extractor is
// a value copied out of the request, and `State` is shared by every thread of
// its shard already, so any of them may be taken.
//
// A pool thread cannot be stopped. A deadline (Deadline.swift) does not cut
// an offloaded handler short, and a client that goes away does not either:
// the handler runs to its end and its answer is dropped.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega

/// The routes of a builder whose handlers run on the blocking pool:
/// `app.offload.get(…)`.
public struct OffloadedRoutes<Builder: RouteBuilder> {
    @usableFromInline
    let builder: Builder

    @usableFromInline
    init(builder: Builder) {
        self.builder = builder
    }

    /// Registers an offloaded handler for `method` and `pattern`, and returns
    /// its OpenAPI entry, as a typed route does.
    @inlinable @discardableResult
    public func on<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        // A typed route whose handler is the hop: the extractors are taken
        // on the worker, the handler runs on the pool, and the answer is
        // written back on the worker by the typed route's own code, which
        // also notes the route for `problems()` and the OpenAPI document.
        builder.on(method, pattern, offloading(handler))
    }

    @inlinable @discardableResult
    public func get<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.get, pattern, handler)
    }

    @inlinable @discardableResult
    public func post<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.post, pattern, handler)
    }

    @inlinable @discardableResult
    public func put<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.put, pattern, handler)
    }

    @inlinable @discardableResult
    public func patch<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.patch, pattern, handler)
    }

    @inlinable @discardableResult
    public func delete<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.delete, pattern, handler)
    }
}

/// `handler` as an async handler that runs it on the blocking pool.
@inlinable
func offloading<each E: Sendable, R: Sendable>(
    _ handler: @escaping @Sendable (repeat each E) throws -> R
) -> @Sendable (repeat each E) async throws -> R {
    { (values: repeat each E) async throws -> R in
        try await Runtime.blocking { try handler(repeat each values) }
    }
}

extension RouteBuilder {
    /// Registers routes whose handlers block, and run on the blocking pool
    /// rather than on one of the shard's worker threads: `app.offload.get(…)`.
    public var offload: OffloadedRoutes<Self> { OffloadedRoutes(builder: self) }
}

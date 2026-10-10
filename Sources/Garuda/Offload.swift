//===----------------------------------------------------------------------===//
// Routes whose handler only computes, run off the worker.
//
//     app.offload.post("/thumbnail") { (image: Body<Upload>) -> Bytes in
//         Bytes(resize(image.value.bytes), contentType: "image/png")
//     }
//
// A worker is one thread, so a handler that computes for long holds up every
// other request on it (SlowHandlers.swift). An offloaded route takes its
// extractors on the worker as any typed route does, runs its handler on the
// worker's blocking pool (BlockingPool.swift), and writes what the handler
// returned back on the worker, which serves other requests meanwhile. It is
// `try await blocking { … }` around the whole handler, said where the route is
// declared.
//
// Only a handler that computes can go: it is synchronous, so it cannot await
// the database, Redis or the HTTP client, which belong to their worker and
// refuse to be used from another thread. What it is handed and what it returns
// cross to the pool's thread and back, so they must be `Sendable`. `State` is
// not, so a worker's pools stay on their worker; `Cancellation` and `Session`
// are, but point into the worker, and are refused when the route is
// registered.
//===----------------------------------------------------------------------===//

import AvianHTTP

/// The routes of a builder whose handlers run on the worker's blocking pool:
/// `app.offload.get(…)`.
public struct OffloadedRoutes<Builder: RouteBuilder> {
    let builder: Builder

    /// Registers an offloaded handler for `method` and `pattern`.
    @discardableResult
    public func on<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        repeat requireOffloadable((each E).self, method, pattern)
        builder.onAsync(method, pattern) { request, response in
            var parameter = 0
            let values = (repeat (each E).awaitsExtraction
                ? try await extractForAsyncRoute((each E).self, request, &parameter, response)
                : try (each E).extract(from: request, parameter: &parameter))
            let answer = try await blocking { try handler(repeat each values) }
            try answer.write(to: response)
        }
        return builder.documented(method, pattern, (repeat each E).self, R.self)
    }

    @discardableResult
    public func get<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.get, pattern, handler)
    }

    @discardableResult
    public func post<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.post, pattern, handler)
    }

    @discardableResult
    public func put<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.put, pattern, handler)
    }

    @discardableResult
    public func patch<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.patch, pattern, handler)
    }

    @discardableResult
    public func delete<each E: RequestExtractor & Sendable, R: ResponseConvertible & Sendable>(
        _ pattern: String, _ handler: @Sendable @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.delete, pattern, handler)
    }
}

extension RouteBuilder {
    /// Registers routes whose handlers only compute, and run on the worker's
    /// blocking pool rather than on the worker: `app.offload.get(…)`.
    public var offload: OffloadedRoutes<Self> { OffloadedRoutes(builder: self) }
}

/// An extractor that is `Sendable` but points into its worker, and so cannot
/// be handed to an offloaded handler.
protocol WorkerBoundExtractor {}

extension Cancellation: WorkerBoundExtractor {}
extension Session: WorkerBoundExtractor {}
extension Optional: WorkerBoundExtractor where Wrapped: WorkerBoundExtractor {}
extension Result: WorkerBoundExtractor where Success: WorkerBoundExtractor {}

/// Stops the program when an offloaded route takes an extractor that points
/// into its worker.
func requireOffloadable<E: RequestExtractor>(_ type: E.Type, _ method: HTTPMethod, _ pattern: String) {
    precondition(!(E.self is any WorkerBoundExtractor.Type),
                 "route \(pattern): \(E.self) belongs to the worker, so an offloaded handler "
                    + "cannot take it; register the route without offload")
}

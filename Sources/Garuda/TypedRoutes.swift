//===----------------------------------------------------------------------===//
// Routes that take what they need and return what they mean.
//
//     app.get("/user/:id") { (id: Path<Int>) in JSON(user(id.value)) }
//
// The registration is generic over a pack of extractors, so a handler may take
// none, one or several, of any kinds. Each is taken from the request on the
// worker thread, in the order declared, before the handler runs; the value the
// handler returns writes itself through the response sink.
//
// The raw `(borrowing Request, inout Response)` handlers are still registered
// by the same names: a closure taking a request and a response is not a pack
// of extractors returning a response, so the two never compete.
//===----------------------------------------------------------------------===//

import AvianHTTP

extension Application {
    /// Registers a typed handler for `method` and `pattern`.
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(method, pattern) { request, response in
            var parameter = 0
            let answer = try handler(
                repeat try (each E).extract(from: request, parameter: &parameter))
            try answer.write(to: response)
        }
    }

    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.get, pattern, handler)
    }

    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.head, pattern, handler)
    }

    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.post, pattern, handler)
    }

    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.put, pattern, handler)
    }

    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.delete, pattern, handler)
    }

    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.patch, pattern, handler)
    }

    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        on(.options, pattern, handler)
    }
}

// MARK: - Async

// The same names again, for a handler that awaits. A closure that does not
// await is not async, so it takes the overloads above and keeps the
// synchronous path; one that does runs on the worker's handler task pool,
// where every resumption is back on the worker's own thread. Extraction still
// happens before the handler body, in the order declared.

extension Application {
    /// Registers an async typed handler for `method` and `pattern`.
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        onAsync(method, pattern) { request, response in
            var parameter = 0
            let answer = try await handler(
                repeat try (each E).extract(from: request, parameter: &parameter))
            try answer.write(to: response)
        }
    }

    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.get, pattern, handler)
    }

    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.head, pattern, handler)
    }

    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.post, pattern, handler)
    }

    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.put, pattern, handler)
    }

    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.delete, pattern, handler)
    }

    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.patch, pattern, handler)
    }

    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) {
        on(.options, pattern, handler)
    }
}

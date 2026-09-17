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

extension RouteBuilder {
    /// Registers a typed handler for `method` and `pattern`.
    @discardableResult
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        repeat requireSynchronousExtractor((each E).self, method, pattern)
        on(method, pattern) { request, response in
            var parameter = 0
            let answer = try handler(
                repeat try (each E).extract(from: request, parameter: &parameter))
            try answer.write(to: response)
        }
        return documented(method, pattern, (repeat each E).self, R.self)
    }

    @discardableResult
    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.get, pattern, handler)
    }

    @discardableResult
    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.head, pattern, handler)
    }

    @discardableResult
    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.post, pattern, handler)
    }

    @discardableResult
    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.put, pattern, handler)
    }

    @discardableResult
    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.delete, pattern, handler)
    }

    @discardableResult
    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.patch, pattern, handler)
    }

    @discardableResult
    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping (repeat each E) throws -> R
    ) -> OpenAPIOperation {
        on(.options, pattern, handler)
    }
}

// MARK: - Async

// The same names again, for a handler that awaits. A closure that does not
// await is not async, so it takes the overloads above and keeps the
// synchronous path; one that does runs on the worker's handler task pool,
// where every resumption is back on the worker's own thread. Extraction still
// happens before the handler body, in the order declared.

extension RouteBuilder {
    /// Registers an async typed handler for `method` and `pattern`.
    @discardableResult
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        onAsync(method, pattern) { request, response in
            var parameter = 0
            let answer = try await handler(
                repeat try await extractForAsyncRoute((each E).self, request, &parameter, response))
            try answer.write(to: response)
        }
        return documented(method, pattern, (repeat each E).self, R.self)
    }

    @discardableResult
    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.get, pattern, handler)
    }

    @discardableResult
    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.head, pattern, handler)
    }

    @discardableResult
    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.post, pattern, handler)
    }

    @discardableResult
    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.put, pattern, handler)
    }

    @discardableResult
    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.delete, pattern, handler)
    }

    @discardableResult
    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.patch, pattern, handler)
    }

    @discardableResult
    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: sending @escaping (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.options, pattern, handler)
    }
}

extension RouteBuilder {
    /// The operation for a typed route, filled in from its extractors and
    /// answer, and given to the route registered last.
    func documented<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String, _ extractors: (repeat each E).Type, _ answer: R.Type
    ) -> OpenAPIOperation {
        let operation = OpenAPIOperation(method, pattern)
        repeat operation.describeExtractor((each E).self)
        operation.describeResponse(R.self)
        document(operation)
        return operation
    }
}

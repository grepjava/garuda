//===----------------------------------------------------------------------===//
// Routes that take what they need and return what they mean.
//
//     app.get("/user/:id") { (id: Path<Int>) in JSON(user(id.value)) }
//     app.get("/feed") { (user: Session<User>) async throws in
//         JSON(try await feed(for: user.value))
//     }
//
// One API, async: a closure that never awaits converts to it, and the
// connection calls it directly, so a handler that does not suspend runs in
// the connection's task with no hop to anywhere else. The registration is
// generic over a pack of extractors, so a handler may take none, one or
// several, of any kinds. Each is taken from the request in the order
// declared, before the handler runs; the value the handler returns writes
// itself into the response.
//
// Registration returns the route's OpenAPI entry (OpenAPI.swift), already
// filled in from the extractor and answer types, for a summary or tags to be
// added to.
//
// The raw `(borrowing Request, borrowing Response)` handlers are registered
// by the same names: a closure taking a request and a response is not a pack
// of extractors returning a response, so the two never compete.
//===----------------------------------------------------------------------===//

import GarudaWire

extension RouteBuilder {
    /// Registers a typed handler for `method` and `pattern`, and returns its
    /// OpenAPI entry, filled in from its extractors and answer.
    @inlinable @discardableResult
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(method, pattern) { request, response in
            var parameter = 0
            let values = HandOver((repeat try await (each E).extract(from: request, parameter: &parameter)))
            try await callTyped(handler, values).value.write(to: response)
        }
        var claims = 0
        var states: [Any.Type] = []
        repeat claims += pathClaims((each E).self)
        repeat states += requiredState((each E).self)
        noteRoute(method, pattern, pathParameters: claims, states: states)
        // What the types say for the document, read once, here: nothing of
        // it is looked at again by a request (OpenAPI.swift).
        let operation = OpenAPIOperation(method, pattern)
        repeat operation.describeExtractor((each E).self)
        operation.describeResponse(R.self)
        document(operation)
        return operation
    }

    @inlinable @discardableResult
    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.get, pattern, handler)
    }

    @inlinable @discardableResult
    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.head, pattern, handler)
    }

    @inlinable @discardableResult
    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.post, pattern, handler)
    }

    @inlinable @discardableResult
    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.put, pattern, handler)
    }

    @inlinable @discardableResult
    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.delete, pattern, handler)
    }

    @inlinable @discardableResult
    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.patch, pattern, handler)
    }

    @inlinable @discardableResult
    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) -> OpenAPIOperation {
        on(.options, pattern, handler)
    }
}

/// A typed handler's values on their way to it and its answer on the way
/// back. The handler is `@concurrent` -- a nonsending function type with a
/// parameter pack crashes SILGen (Swift 6.3) in every module that passes a
/// closure as one -- so the call crosses from the route's isolation to the
/// generic executor's, and the checker cannot follow a pack's region across.
/// Nothing else holds either: the task that made them carries them over.
@usableFromInline
struct HandOver<T>: @unchecked Sendable {
    @usableFromInline var value: T
    @inlinable init(_ value: T) { self.value = value }
}

/// `handler` applied to the values.
@inlinable @concurrent
func callTyped<each E, R>(_ handler: @concurrent @Sendable (repeat each E) async throws -> R,
                          _ values: HandOver<(repeat each E)>) async throws -> HandOver<R> {
    HandOver(try await handler(repeat each values.value))
}

/// 1 when `E` takes a path parameter by position.
@usableFromInline
func pathClaims<E: RequestExtractor>(_ type: E.Type) -> Int {
    type is any PathClaiming.Type ? 1 : 0
}

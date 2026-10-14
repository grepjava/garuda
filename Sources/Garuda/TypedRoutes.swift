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
// The raw `(borrowing Request, borrowing Response)` handlers are registered
// by the same names: a closure taking a request and a response is not a pack
// of extractors returning a response, so the two never compete.
//===----------------------------------------------------------------------===//

import GarudaWire

extension RouteBuilder {
    /// Registers a typed handler for `method` and `pattern`.
    @inlinable
    public func on<each E: RequestExtractor, R: ResponseConvertible>(
        _ method: HTTPMethod, _ pattern: String,
        _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(method, pattern) { request, response in
            var parameter = 0
            let answer = try await handler(
                repeat try await (each E).extract(from: request, parameter: &parameter))
            try answer.write(to: response)
        }
        var claims = 0
        repeat claims += pathClaims((each E).self)
        noteRoute(method, pattern, pathParameters: claims)
    }

    @inlinable
    public func get<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.get, pattern, handler)
    }

    @inlinable
    public func head<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.head, pattern, handler)
    }

    @inlinable
    public func post<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.post, pattern, handler)
    }

    @inlinable
    public func put<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.put, pattern, handler)
    }

    @inlinable
    public func delete<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.delete, pattern, handler)
    }

    @inlinable
    public func patch<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.patch, pattern, handler)
    }

    @inlinable
    public func options<each E: RequestExtractor, R: ResponseConvertible>(
        _ pattern: String, _ handler: @escaping @Sendable (repeat each E) async throws -> R
    ) {
        on(.options, pattern, handler)
    }
}

/// 1 when `E` takes a path parameter by position.
@usableFromInline
func pathClaims<E: RequestExtractor>(_ type: E.Type) -> Int {
    type is any PathClaiming.Type ? 1 : 0
}

//===----------------------------------------------------------------------===//
// Extractors of your own: synchronous, awaiting, optional, or with their
// failure in hand.
//
//     struct SignedInUser: AsyncRequestExtractor {
//         let user: User
//
//         static func extract(from request: borrowing Request,
//                             parameter: inout Int) async throws -> SignedInUser {
//             guard let header = request.header("authorization"), header.hasPrefix("Bearer ") else {
//                 throw HTTPError.unauthorized
//             }
//             let db = try request.state(SQLiteDatabase.self)
//             guard let user = try await db.first(User.self, "...", String(header.dropFirst(7))) else {
//                 throw HTTPError.unauthorized
//             }
//             return SignedInUser(user: user)
//         }
//     }
//
//     app.get("/me") { (me: SignedInUser) async in JSON(me.user) }
//     app.get("/greeting") { (me: SignedInUser?) async in "hello \(me?.user.username ?? "stranger")" }
//
// A `RequestExtractor` takes what it needs from the request at once. An
// `AsyncRequestExtractor` may await -- a database, a session store, another
// service -- and is extracted only by async handlers: a synchronous handler
// that asks for one is a mistake found when the route is registered. It reads
// the request before its first await, as a handler does; once it returns, a
// request that ended in the meantime stops there, before the extractors after
// it read a slot that holds something else.
//
// `Optional<E>` is nil where `E` would have refused the request, and
// `Result<E, any Error>` hands the handler the refusal to answer as it likes.
// Either way the path parameters `E` would have claimed are left for the next
// extractor.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

/// An extractor that awaits. Handlers that take one must be async.
public protocol AsyncRequestExtractor: RequestExtractor {
    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Self
}

extension AsyncRequestExtractor {
    /// Never used for a route: registering a synchronous handler that takes
    /// an async extractor stops the program.
    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Self {
        throw HTTPError(.internalServerError, "\(Self.self) is extracted only by async handlers")
    }
}

extension Optional: RequestExtractor where Wrapped: RequestExtractor {
    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Wrapped? {
        let start = parameter
        do {
            return try Wrapped.extract(from: request, parameter: &parameter)
        } catch {
            parameter = start
            return nil
        }
    }
}

extension Optional: AsyncRequestExtractor where Wrapped: AsyncRequestExtractor {
    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Wrapped? {
        let start = parameter
        do {
            return try await Wrapped.extract(from: request, parameter: &parameter)
        } catch {
            parameter = start
            return nil
        }
    }
}

extension Result: RequestExtractor where Success: RequestExtractor, Failure == any Error {
    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Result {
        let start = parameter
        do {
            return .success(try Success.extract(from: request, parameter: &parameter))
        } catch {
            parameter = start
            return .failure(error)
        }
    }
}

extension Result: AsyncRequestExtractor where Success: AsyncRequestExtractor, Failure == any Error {
    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Result {
        let start = parameter
        do {
            return .success(try await Success.extract(from: request, parameter: &parameter))
        } catch {
            parameter = start
            return .failure(error)
        }
    }
}

extension Optional: OpenAPIExtractorDescribing where Wrapped: RequestExtractor {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeExtractor(Wrapped.self)
    }
}

extension Result: OpenAPIExtractorDescribing where Success: RequestExtractor, Failure == any Error {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeExtractor(Success.self)
    }
}

// MARK: - Extraction in routes

/// Takes `E` for an async route, awaiting it when it is an async extractor,
/// and stops when the request ended while it waited.
func extractForAsyncRoute<E: RequestExtractor>(_ type: E.Type, _ request: borrowing Request,
                                              _ parameter: inout Int,
                                              _ response: borrowing Response) async throws -> E {
    guard let awaiting = E.self as? any AsyncRequestExtractor.Type else {
        return try E.extract(from: request, parameter: &parameter)
    }
    let value = try await extractAwaiting(awaiting, request, &parameter)
    guard response.isActive else { throw HandlerWaitError.cancelled }
    return value as! E
}

private func extractAwaiting<A: AsyncRequestExtractor>(_ type: A.Type, _ request: borrowing Request,
                                                       _ parameter: inout Int) async throws -> Any {
    try await A.extract(from: request, parameter: &parameter)
}

/// Stops the program when a synchronous route takes an extractor that awaits.
func requireSynchronousExtractor<E: RequestExtractor>(_ type: E.Type, _ method: HTTPMethod, _ pattern: String) {
    precondition(!(E.self is any AsyncRequestExtractor.Type),
                 "route \(pattern): \(E.self) awaits, so it needs an async handler; "
                    + "WebSocket and WebTransport routes take extractors that do not")
}

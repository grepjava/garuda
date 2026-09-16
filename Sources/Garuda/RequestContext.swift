//===----------------------------------------------------------------------===//
// A request's typed context: values a handler keeps for the rest of its
// request, across `Response.after`, under a key type of its own.
//
//     enum CurrentUser: RequestContextKey { typealias Value = User }
//
//     request[context: CurrentUser.self] = user
//     let user = request[context: CurrentUser.self]
//
// The storage is made the first time a value is stored, so a request that
// stores none allocates nothing for it. It is tagged with the connection's
// generation and the request's ID, and cleared when the next request on the
// connection begins and when the connection closes: a value never reaches
// another request, and a read that finds another request's storage is nil.
//===----------------------------------------------------------------------===//

/// A key for a value in a request's context. The key's type is the key: two
/// modules that each declare one cannot collide.
public protocol RequestContextKey {
    associatedtype Value
}

/// A request's context values, and the request they belong to.
final class RequestContext {
    let generation: UInt32
    let requestId: UInt32
    var values: [ObjectIdentifier: Any] = [:]
    /// What `Response.onSend` asked to run before the response is sent.
    var sendHooks: [SendHook] = []

    init(generation: UInt32, requestId: UInt32) {
        self.generation = generation
        self.requestId = requestId
    }
}

extension Request {
    /// The value this request holds under `key`, or nil. Setting nil removes it.
    public subscript<Key: RequestContextKey>(context key: Key.Type) -> Key.Value? {
        get {
            let c = connection
            guard let context = c.pointee.context,
                  context.generation == c.pointee.generation,
                  context.requestId == c.pointee.requestId else { return nil }
            return context.values[ObjectIdentifier(key)] as? Key.Value
        }
        nonmutating set {
            guard let newValue else {
                let c = connection
                if let context = c.pointee.context, context.generation == c.pointee.generation,
                   context.requestId == c.pointee.requestId {
                    context.values[ObjectIdentifier(key)] = nil
                }
                return
            }
            worker.pointee.requestContext(slot).values[ObjectIdentifier(key)] = newValue
        }
    }
}

/// A value middleware stored in the request's context, asked for by its key:
///
///     app.use { request, _ async throws -> (any ResponseConvertible)? in
///         request[context: CurrentUser.self] = try await sessions.user(for: request)
///         return nil
///     }
///     app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
///
/// A request that reaches the handler without the value is answered 500: the
/// middleware that should have stored it did not run, which is a fault in the
/// program rather than the client's mistake.
public struct Context<Key: RequestContextKey>: RequestExtractor {
    public var value: Key.Value

    public init(_ value: Key.Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        guard let value = request[context: Key.self] else {
            throw HTTPError(.internalServerError,
                            "nothing stored \(Key.self) in the request's context")
        }
        return Context(value)
    }
}

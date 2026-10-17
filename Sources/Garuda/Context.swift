//===----------------------------------------------------------------------===//
// A request's typed context: values middleware stores for the layers inside
// it and the handler, under key types of their own.
//
//     enum CurrentUser: RequestContextKey { typealias Value = User }
//
//     app.use { request, response, next in
//         request[context: CurrentUser.self] = try await sessions.user(for: request)
//         try await next()
//     }
//     app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
//
// The first four values live in the exchange itself; more than that go to a
// dictionary made for the request that needs it. Everything is cleared when
// the next request on the connection begins, so a value never reaches
// another request.
//===----------------------------------------------------------------------===//

/// A key for a value in a request's context. The key's type is the key: two
/// modules that each declare one cannot collide.
public protocol RequestContextKey {
    associatedtype Value
}

/// A request's context values: four inline, the rest in a dictionary.
@usableFromInline
struct ContextSlots {
    var key0: ObjectIdentifier?, key1: ObjectIdentifier?, key2: ObjectIdentifier?, key3: ObjectIdentifier?
    var value0: Any?, value1: Any?, value2: Any?, value3: Any?
    var more: [ObjectIdentifier: Any]?
    @usableFromInline var isEmpty = true

    init() {}

    func get(_ key: ObjectIdentifier) -> Any? {
        if key0 == key { return value0 }
        if key1 == key { return value1 }
        if key2 == key { return value2 }
        if key3 == key { return value3 }
        return more?[key]
    }

    mutating func set(_ key: ObjectIdentifier, _ value: Any?) {
        isEmpty = false
        if key0 == key { value0 = value; if value == nil { key0 = nil }; return }
        if key1 == key { value1 = value; if value == nil { key1 = nil }; return }
        if key2 == key { value2 = value; if value == nil { key2 = nil }; return }
        if key3 == key { value3 = value; if value == nil { key3 = nil }; return }
        if more?[key] != nil || value == nil {
            more?[key] = value
            return
        }
        if key0 == nil { (key0, value0) = (key, value); return }
        if key1 == nil { (key1, value1) = (key, value); return }
        if key2 == nil { (key2, value2) = (key, value); return }
        if key3 == nil { (key3, value3) = (key, value); return }
        more = more ?? [:]
        more![key] = value
    }

    @usableFromInline mutating func clear() {
        self = ContextSlots()
    }
}

extension Request {
    /// The value this request holds under `key`, or nil. Setting nil removes it.
    public subscript<Key: RequestContextKey>(context key: Key.Type) -> Key.Value? {
        get { exchange.pointee.context.get(ObjectIdentifier(key)) as? Key.Value }
        nonmutating set { exchange.pointee.context.set(ObjectIdentifier(key), newValue) }
    }
}

/// A value middleware stored in the request's context, asked for by its key.
/// A request that reaches the handler without it is answered 500: the
/// middleware that should have stored it did not run, which is a fault in the
/// program rather than the client's mistake.
public struct Context<Key: RequestContextKey>: RequestExtractor {
    public var value: Key.Value

    public init(_ value: Key.Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Self {
        guard let value = request[context: Key.self] else {
            throw HTTPError(.internalServerError, "nothing stored \(Key.self) in the request's context")
        }
        return Context(value)
    }
}

extension Context: Sendable where Key.Value: Sendable {}

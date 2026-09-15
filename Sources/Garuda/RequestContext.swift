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
            let c = connection
            let current = c.pointee.context.flatMap { context in
                context.generation == c.pointee.generation
                    && context.requestId == c.pointee.requestId ? context : nil
            }
            guard let newValue else {
                current?.values[ObjectIdentifier(key)] = nil
                return
            }
            let context = current ?? RequestContext(generation: c.pointee.generation,
                                                    requestId: c.pointee.requestId)
            context.values[ObjectIdentifier(key)] = newValue
            c.pointee.context = context
        }
    }
}

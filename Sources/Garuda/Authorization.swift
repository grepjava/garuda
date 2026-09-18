//===----------------------------------------------------------------------===//
// Authorization: who may reach a route, once it is known whose request it is.
//
// Authentication says who is asking (Authentication.swift, JWT.swift, and the
// session stores). This says whether they may, as a rule named once and used
// wherever it applies:
//
//     extension Policy where Value == User {
//         static let admin = Policy(needs: "an administrator") { $0.role == .admin }
//         static let billing = Policy(needs: "the billing role") { $0.roles.contains("billing") }
//     }
//
//     app.group("/admin") {
//         app.authenticate(bearer: CurrentUser.self) { try await users.find(token: $0) }
//         app.authorize(CurrentUser.self, .admin)
//         app.get("/users") { ... }              // every route in the group
//     }
//
//     app.group("/invoices") {
//         app.authenticate(bearer: CurrentUser.self) { try await users.find(token: $0) }
//         app.authorize(CurrentUser.self, .admin.or(.billing))
//     }
//
// A rule that does not hold is 403: the request was understood and the
// credentials are good, and it is still refused. `{"error":"this route needs
// an administrator"}` -- which is what `needs` is for, so the answer says what
// would have been enough. A request with nobody under the key is 401 instead:
// nothing is known about who is asking, so signing in may be the answer.
//
// A policy is a rule about a value in hand, so it does not await and cannot
// fail: it is `(Value) -> Bool`, testable on its own (`Policy.admin(user)`)
// and combinable with `and` and `or`. A rule that has to ask a database takes
// the closure form of `authorize`; a rule about one row -- whether this order
// is this customer's -- belongs in the handler, which has the row, and throws
// `AuthorizationError(needs:)` to answer the same way.
//===----------------------------------------------------------------------===//

/// A named rule about who may reach a route.
///
/// `Sendable`, because a policy is written once and used from every worker: a
/// `static let` is how a rule is named, and that is a global.
public struct Policy<Value>: Sendable {
    /// What the route needs, written to follow "this route needs": "an
    /// administrator", "the scope orders:write".
    public let needs: String

    /// Whether a value satisfies the rule.
    public let allows: @Sendable (Value) -> Bool

    public init(needs: String, _ allows: @escaping @Sendable (Value) -> Bool) {
        self.needs = needs
        self.allows = allows
    }

    /// Whether `value` satisfies the rule: `Policy.admin(user)`, which is how
    /// a test reaches a rule without a request.
    public func callAsFunction(_ value: Value) -> Bool { allows(value) }

    /// Both rules, and a name that says both.
    public func and(_ other: Policy<Value>) -> Policy<Value> {
        Policy(needs: needs + " and " + other.needs) { [allows] value in
            allows(value) && other.allows(value)
        }
    }

    /// Either rule.
    public func or(_ other: Policy<Value>) -> Policy<Value> {
        Policy(needs: needs + " or " + other.needs) { [allows] value in
            allows(value) || other.allows(value)
        }
    }

    /// The rule about part of a larger value, so a rule written about a role
    /// can guard a route that holds a user:
    ///
    ///     app.authorize(CurrentUser.self, Policy.admin.about { (user: User) in user.role })
    public func about<Whole>(_ part: @escaping @Sendable (Whole) -> Value) -> Policy<Whole> {
        Policy<Whole>(needs: needs) { [allows] whole in allows(part(whole)) }
    }
}

/// A request refused although it is known whose it is: 403, saying what would
/// have been enough.
///
/// Thrown by `authorize`, and by a handler with a rule of its own:
///
///     guard order.customer == user.id else { throw AuthorizationError(needs: "the customer") }
public struct AuthorizationError: ResponseError, Equatable, Hashable, Sendable {
    /// What the route needs, or nil when saying so would tell whoever is
    /// asking more than they should know.
    public let needs: String?

    public init(needs: String? = nil) {
        self.needs = needs
    }

    public var status: HTTPStatus { .forbidden }

    public var reason: String? {
        guard let needs else { return "you may not do this" }
        return "this route needs " + needs
    }
}

extension RouteBuilder {
    /// Requires `policy` of whoever the request belongs to, for every route in
    /// the current scope. It runs in the order of `use`, so it goes after the
    /// `authenticate` that puts them under `key`.
    ///
    /// A request the rule refuses is 403. A request with nothing under `key`
    /// is 401 with no challenge: `authorize` does not know what the scope
    /// authenticates with, and the `authenticate` in front of it is what
    /// challenges a request that brought no credentials at all.
    public func authorize<Key: RequestContextKey>(_ key: Key.Type, _ policy: Policy<Key.Value>) {
        describeForbidden(policy.needs)
        use { request, _ in
            guard let who = request[context: key] else { throw HTTPError.unauthorized }
            guard policy.allows(who) else { throw AuthorizationError(needs: policy.needs) }
            return nil
        }
    }

    /// `authorize` with the rule written where it is used rather than named:
    ///
    ///     app.authorize(CurrentUser.self, needs: "an administrator") { $0.role == .admin }
    public func authorize<Key: RequestContextKey>(
        _ key: Key.Type, needs: String? = nil, _ allows: @escaping (Key.Value) -> Bool
    ) {
        describeForbidden(needs)
        use { request, _ in
            guard let who = request[context: key] else { throw HTTPError.unauthorized }
            guard allows(who) else { throw AuthorizationError(needs: needs) }
            return nil
        }
    }

    /// `authorize` for a rule that has to ask something: whether this account
    /// is a member of this project, whether the subscription is paid up. It
    /// runs on every request in the scope, so what it asks should be quick or
    /// cached; a rule about the row a handler is about belongs in the handler.
    public func authorize<Key: RequestContextKey>(
        _ key: Key.Type, needs: String? = nil,
        _ allows: sending @escaping (Key.Value) async throws -> Bool
    ) {
        nonisolated(unsafe) let allows = allows
        describeForbidden(needs)
        use { request, _ async throws -> (any ResponseConvertible)? in
            guard let who = request[context: key] else { throw HTTPError.unauthorized }
            guard try await allows(who) else { throw AuthorizationError(needs: needs) }
            return nil
        }
    }

    /// Requires `policy` of the claims of the token `authenticate(jwt:)`
    /// checked, for every route in the current scope.
    ///
    ///     app.authenticate(jwt: AccessClaims.self, verifier: keys)
    ///     app.authorize(jwt: AccessClaims.self, .scope("orders:write"))
    public func authorize<Claims: Decodable>(jwt claims: Claims.Type, _ policy: Policy<Claims>) {
        describeForbidden(policy.needs)
        use { request, _ in
            guard let jwt = request[context: JWTContextKey<Claims>.self] else {
                throw HTTPError.unauthorized
            }
            guard policy.allows(jwt.claims) else { throw AuthorizationError(needs: policy.needs) }
            return nil
        }
    }

    /// `authorize(jwt:)` with the rule written where it is used.
    public func authorize<Claims: Decodable>(
        jwt claims: Claims.Type, needs: String? = nil, _ allows: @escaping (Claims) -> Bool
    ) {
        describeForbidden(needs)
        use { request, _ in
            guard let jwt = request[context: JWTContextKey<Claims>.self] else {
                throw HTTPError.unauthorized
            }
            guard allows(jwt.claims) else { throw AuthorizationError(needs: needs) }
            return nil
        }
    }
}

extension RouteBuilder {
    /// The 403 every route in this scope can now answer, in the OpenAPI
    /// document, saying what would have been enough.
    func describeForbidden(_ needs: String?) {
        let description = needs.map { "Needs " + $0 } ?? "Not allowed"
        describeRoutes { $0.scopeResponse(.forbidden, description) }
    }
}

// MARK: - OAuth 2.0 scopes

/// Claims that carry OAuth 2.0 scopes, so `Policy.scope(_:)` can read them.
///
/// The claim is one string of scopes separated by spaces, as RFC 6749 section
/// 3.3 has it, which is what an authorization server issues.
public protocol ScopedClaims {
    /// The `scope` claim, or nil in a token that carries none.
    var scope: String? { get }
}

extension ScopedClaims {
    /// Whether the token carries `scope`. Whole scopes only, so `orders` does
    /// not match `orders:write` and `write` does not match either.
    public func hasScope(_ wanted: String) -> Bool {
        guard let scope, !wanted.isEmpty else { return false }
        return scope.split(separator: " ").contains { $0 == wanted }
    }

    /// Every scope the token carries, in the order it lists them.
    public var scopes: [String] {
        scope.map { $0.split(separator: " ").map(String.init) } ?? []
    }
}

extension Policy {
    /// A token carrying an OAuth 2.0 scope.
    public static func scope(_ wanted: String) -> Policy<Value> where Value: ScopedClaims {
        Policy(needs: "the scope " + wanted) { $0.hasScope(wanted) }
    }
}

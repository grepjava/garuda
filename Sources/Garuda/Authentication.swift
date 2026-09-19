//===----------------------------------------------------------------------===//
// HTTP authentication: bearer tokens and Basic credentials.
//
//     enum CurrentUser: RequestContextKey { typealias Value = User }
//
//     app.group("/api") {
//         app.authenticate(bearer: CurrentUser.self) { token in
//             try await sessions.user(forToken: token)
//         }
//         app.get("/me") { (user: Context<CurrentUser>) in user.value }
//     }
//
// `authenticate` is a middleware in the scope it is called in, in the order
// of `use`. It reads the Authorization header, hands what it carries to the
// closure, and keeps what the closure returns in the request's context for
// the middleware and handlers after it. A request without the header, with a
// malformed one, or whose credentials the closure returns nil for is answered
// 401 with the WWW-Authenticate challenge RFC 9110 requires. A closure that
// throws answers as a handler that throws does.
//
// `BearerToken` and `BasicCredentials` are the same parsing as extractors, for
// a handler that checks credentials itself. `constantTimeEquals` compares a
// secret without telling a caller, by how long it took, how much was right.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP
import GarudaPostgres

/// The token of an `Authorization: Bearer` header (RFC 6750). A request
/// without one is answered 401 with `WWW-Authenticate: Bearer`.
public struct BearerToken: RequestExtractor, Sendable {
    public var token: String

    public init(_ token: String) {
        self.token = token
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Self {
        guard let header = request.header("authorization"), let token = parseBearer(header) else {
            request.worker.pointee.addHeader(request.slot, "www-authenticate", "Bearer")
            throw HTTPError.unauthorized
        }
        return BearerToken(token)
    }
}

/// The user name and password of an `Authorization: Basic` header (RFC 7617).
/// A request without one is answered 401 with a Basic challenge.
public struct BasicCredentials: RequestExtractor, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Self {
        guard let header = request.header("authorization"), let credentials = parseBasic(header) else {
            request.worker.pointee.addHeader(request.slot, "www-authenticate", basicChallenge("restricted"))
            throw HTTPError.unauthorized
        }
        return credentials
    }
}

/// Whether `a` and `b` hold the same bytes, taking as long whichever byte
/// differs. It still takes longer for a longer `a`, so compare against the
/// secret as `b`: what the caller sent decides the time, not the secret.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    var a = a
    var b = b
    return a.withUTF8 { x in
        b.withUTF8 { y in
            var difference: UInt8 = x.count == y.count ? 0 : 1
            var i = 0
            while i < x.count {
                // Past the end of `b`, compare with its own bytes again, so
                // the loop does the same work whatever the lengths.
                difference |= x[i] ^ (y.isEmpty ? 0 : y[i % y.count])
                i &+= 1
            }
            return difference == 0
        }
    }
}

extension RouteBuilder {
    /// Requires an `Authorization: Bearer` token of every request in the
    /// current scope. `verify` returns who the token belongs to, kept under
    /// `key` in the request's context, or nil to answer 401.
    public func authenticate<Key: RequestContextKey>(
        bearer key: Key.Type, _ verify: @escaping (_ token: String) throws -> Key.Value?
    ) {
        describeBearerScope()
        use { request, _ in
            guard let header = request.header("authorization"), let token = parseBearer(header),
                  let who = try verify(token) else {
                return Challenge("Bearer")
            }
            request[context: key] = who
            return nil
        }
    }

    /// `authenticate(bearer:)` with a `verify` that awaits: a session store,
    /// a database, another service.
    public func authenticate<Key: RequestContextKey>(
        bearer key: Key.Type, _ verify: sending @escaping (_ token: String) async throws -> Key.Value?
    ) {
        nonisolated(unsafe) let verify = verify
        describeBearerScope()
        use { request, _ async throws -> (any ResponseConvertible)? in
            guard let header = request.header("authorization"), let token = parseBearer(header),
                  let who = try await verify(token) else {
                return Challenge("Bearer")
            }
            request[context: key] = who
            return nil
        }
    }

    /// Requires `Authorization: Basic` credentials of every request in the
    /// current scope. `verify` returns who they belong to, kept under `key`
    /// in the request's context, or nil to answer 401 with a challenge for
    /// `realm`.
    public func authenticate<Key: RequestContextKey>(
        basic key: Key.Type, realm: String = "restricted",
        _ verify: @escaping (_ username: String, _ password: String) throws -> Key.Value?
    ) {
        let challenge = basicChallenge(realm)
        describeBasicScope()
        use { request, _ in
            guard let header = request.header("authorization"), let credentials = parseBasic(header),
                  let who = try verify(credentials.username, credentials.password) else {
                return Challenge(challenge)
            }
            request[context: key] = who
            return nil
        }
    }

    /// `authenticate(basic:)` with a `verify` that awaits.
    public func authenticate<Key: RequestContextKey>(
        basic key: Key.Type, realm: String = "restricted",
        _ verify: sending @escaping (_ username: String, _ password: String) async throws -> Key.Value?
    ) {
        let challenge = basicChallenge(realm)
        nonisolated(unsafe) let verify = verify
        describeBasicScope()
        use { request, _ async throws -> (any ResponseConvertible)? in
            guard let header = request.header("authorization"), let credentials = parseBasic(header),
                  let who = try await verify(credentials.username, credentials.password) else {
                return Challenge(challenge)
            }
            request[context: key] = who
            return nil
        }
    }
}

extension RouteBuilder {
    /// `authenticate(bearer:)` with what `app.state` built for `Service` in
    /// the worker -- the database the sessions are in -- handed to `verify`.
    ///
    /// ```
    /// app.authenticate(bearer: CurrentUser.self, state: SQLiteDatabase.self) { token, db in
    ///     try await db.first(User.self, "select ... where token_digest = ?", Tokens.digest(token))
    /// }
    /// ```
    public func authenticate<Key: RequestContextKey, Service>(
        bearer key: Key.Type, state service: Service.Type,
        _ verify: sending @escaping (_ token: String, _ state: Service) async throws -> Key.Value?
    ) {
        nonisolated(unsafe) let verify = verify
        describeBearerScope()
        use { request, _ async throws -> (any ResponseConvertible)? in
            let state = try request.state(Service.self)
            guard let header = request.header("authorization"), let token = parseBearer(header) else {
                return Challenge("Bearer")
            }
            nonisolated(unsafe) let unsafeState = state
            guard let who = try await verify(token, unsafeState) else { return Challenge("Bearer") }
            request[context: key] = who
            return nil
        }
    }

    /// `authenticate(basic:)` with what `app.state` built for `Service` in the
    /// worker handed to `verify`.
    public func authenticate<Key: RequestContextKey, Service>(
        basic key: Key.Type, realm: String = "restricted", state service: Service.Type,
        _ verify: sending @escaping (_ username: String, _ password: String, _ state: Service) async throws -> Key.Value?
    ) {
        let challenge = basicChallenge(realm)
        nonisolated(unsafe) let verify = verify
        describeBasicScope()
        use { request, _ async throws -> (any ResponseConvertible)? in
            let state = try request.state(Service.self)
            guard let header = request.header("authorization"), let credentials = parseBasic(header) else {
                return Challenge(challenge)
            }
            nonisolated(unsafe) let unsafeState = state
            guard let who = try await verify(credentials.username, credentials.password, unsafeState) else {
                return Challenge(challenge)
            }
            request[context: key] = who
            return nil
        }
    }
}

extension RouteBuilder {
    /// What every route of this scope takes and can answer, once an
    /// `authenticate` guards it. The same words the `BearerToken` and
    /// `BasicCredentials` extractors use, so a route guarded either way reads
    /// the same in the document.
    func describeBearerScope(format: String? = nil) {
        describeRoutes { operation in
            operation.security(.bearer(format: format))
            operation.scopeResponse(.unauthorized, "No valid bearer token")
        }
    }

    func describeBasicScope() {
        describeRoutes { operation in
            operation.security(.basic)
            operation.scopeResponse(.unauthorized, "No valid credentials")
        }
    }
}

/// A 401 with its challenge.
struct Challenge: ResponseConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    func write(to response: borrowing Response) throws {
        response.addHeader("www-authenticate", value)
        try HTTPStatus.unauthorized.write(to: response)
    }
}

/// `Basic realm="…", charset="UTF-8"`, with the realm's quotes and
/// backslashes escaped.
func basicChallenge(_ realm: String) -> String {
    var quoted = ""
    for character in realm {
        if character == "\"" || character == "\\" { quoted.append("\\") }
        quoted.append(character)
    }
    return "Basic realm=\"\(quoted)\", charset=\"UTF-8\""
}

/// The credentials after an auth scheme, compared without regard to case,
/// and the spaces that follow it. Nil for another scheme or nothing after it.
private func credentials(_ header: String, scheme: String) -> Substring? {
    let bytes = header.utf8
    guard bytes.count > scheme.utf8.count else { return nil }
    var index = bytes.startIndex
    for expected in scheme.utf8 {
        guard asciiLower(bytes[index]) == expected else { return nil }
        index = bytes.index(after: index)
    }
    guard bytes[index] == 0x20 else { return nil }
    let rest = header[index...].drop { $0 == " " }
    return rest.isEmpty ? nil : rest
}

/// The token68 of a Bearer header, or nil.
///
/// Read as bytes: it is on the path of every request a token guards.
func parseBearer(_ header: String) -> String? {
    var header = header
    return header.withUTF8 { bytes -> String? in
        let scheme = 6
        guard bytes.count > scheme + 1 else { return nil }
        var i = 0
        for expected in "bearer".utf8 {
            guard asciiLower(bytes[i]) == expected else { return nil }
            i += 1
        }
        guard bytes[i] == 0x20 else { return nil }
        while i < bytes.count && bytes[i] == 0x20 { i += 1 }
        guard i < bytes.count else { return nil }
        let start = i
        // token68: letters, digits, -._~+/ and trailing =.
        var seenEquals = false
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "="):
                seenEquals = true
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                if seenEquals { return nil }
            default:
                return nil
            }
            i += 1
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self)
    }
}

/// The user name and password of a Basic header, or nil for one that is not
/// base64 of UTF-8 with a colon.
func parseBasic(_ header: String) -> BasicCredentials? {
    guard let encoded = credentials(header, scheme: "basic"),
          let decoded = Base64.decode(String(encoded)),
          let colon = decoded.firstIndex(of: UInt8(ascii: ":")) else { return nil }
    guard let username = String(validating: decoded[..<colon], as: UTF8.self),
          let password = String(validating: decoded[(colon + 1)...], as: UTF8.self) else { return nil }
    return BasicCredentials(username: username, password: password)
}

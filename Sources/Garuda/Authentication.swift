//===----------------------------------------------------------------------===//
// HTTP authentication: bearer tokens and Basic credentials.
//
//     enum CurrentUser: RequestContextKey { typealias Value = User }
//
//     app.group("/api") {
//         app.authenticate(bearer: CurrentUser.self) { token in
//             try await sessions.user(forToken: token)
//         }
//         app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
//     }
//
// `authenticate` is a middleware in the scope it is called in, in the order
// of `use`. It reads the Authorization header, hands what it carries to the
// closure, and keeps what the closure returns in the request's context
// (`request[context: CurrentUser.self]`) for the middleware and handlers
// inside it. A request without the header, with a malformed one, or whose
// credentials the closure returns nil for is answered 401 with the
// WWW-Authenticate challenge RFC 9110 requires, and the handler never runs. A
// closure that throws answers as a handler that throws does.
//
// The header is read where it lies; the only allocation is the String the
// closure is handed.
//
// `BearerToken` and `BasicCredentials` are the same parsing as extractors, for
// a handler that checks credentials itself. `constantTimeEquals` compares a
// secret without telling a caller, by how long it took, how much was right.
//
// Each `authenticate` also writes its security scheme and its 401 into the
// OpenAPI entry of every route in its scope (`describeBearerScope`,
// `describeBasicScope`), when the document is built: nothing per request.
//===----------------------------------------------------------------------===//

import GarudaWire

/// The token of an `Authorization: Bearer` header (RFC 6750). A request
/// without one is answered 401 with `WWW-Authenticate: Bearer`.
public struct BearerToken: RequestExtractor, Sendable {
    public var token: String

    public init(_ token: String) {
        self.token = token
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Self {
        guard let token = bearerToken(request) else { throw Unauthenticated(challenge: "Bearer") }
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

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Self {
        guard let credentials = basicCredentials(request) else {
            throw Unauthenticated(challenge: basicChallenge("restricted"))
        }
        return credentials
    }
}

/// A request refused for want of credentials, or for the ones it brought:
/// 401, with the `WWW-Authenticate` challenge that says what would do.
///
/// The challenge is added when the error becomes the answer, not before, so
/// an extractor made optional -- `BearerToken?` -- that is refused leaves no
/// challenge on a response that went on without it.
public struct Unauthenticated: ResponseError, Equatable, Sendable {
    /// The `WWW-Authenticate` value: `Bearer`, `Basic realm="…"`.
    public var challenge: String
    public var reason: String?

    public init(challenge: String, reason: String? = nil) {
        self.challenge = challenge
        self.reason = reason
    }

    public var status: HTTPStatus { .unauthorized }
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

// MARK: - Middleware

/// `authenticate(bearer:)`.
struct BearerAuthentication<Key: RequestContextKey>: Middleware {
    let verify: @Sendable (_ token: String, _ request: borrowing Request) async throws -> Key.Value?

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard let token = bearerToken(request), let who = try await verify(token, request) else {
            return challenge(response, "Bearer")
        }
        request[context: Key.self] = who
        try await next()
    }
}

/// `authenticate(basic:)`.
struct BasicAuthentication<Key: RequestContextKey>: Middleware {
    let challenge: String
    let verify: @Sendable (_ username: String, _ password: String,
                           _ request: borrowing Request) async throws -> Key.Value?

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard let credentials = basicCredentials(request),
              let who = try await verify(credentials.username, credentials.password, request) else {
            return Garuda.challenge(response, challenge)
        }
        request[context: Key.self] = who
        try await next()
    }
}

extension RouteBuilder {
    /// Requires an `Authorization: Bearer` token of every request in the
    /// current scope. `verify` returns who the token belongs to, kept under
    /// `key` in the request's context, or nil to answer 401.
    public func authenticate<Key: RequestContextKey>(
        bearer key: Key.Type, _ verify: @escaping @Sendable (_ token: String) async throws -> Key.Value?
    ) {
        use(BearerAuthentication<Key> { token, _ in try await verify(token) })
        describeBearerScope()
    }

    /// Requires `Authorization: Basic` credentials of every request in the
    /// current scope. `verify` returns who they belong to, kept under `key`
    /// in the request's context, or nil to answer 401 with a challenge for
    /// `realm`.
    public func authenticate<Key: RequestContextKey>(
        basic key: Key.Type, realm: String = "restricted",
        _ verify: @escaping @Sendable (_ username: String, _ password: String) async throws -> Key.Value?
    ) {
        use(BasicAuthentication<Key>(challenge: basicChallenge(realm)) { username, password, _ in
            try await verify(username, password)
        })
        describeBasicScope()
    }

    /// `authenticate(bearer:)` with what `app.state` built for `Service` in
    /// the shard -- the database the sessions are in -- handed to `verify`.
    ///
    /// ```
    /// app.authenticate(bearer: CurrentUser.self, state: Database.self) { token, db in
    ///     try await db.user(forTokenDigest: Tokens.digest(token))
    /// }
    /// ```
    ///
    /// A shard without that state answers 500: the program never built it.
    public func authenticate<Key: RequestContextKey, Service: Sendable>(
        bearer key: Key.Type, state service: Service.Type,
        _ verify: @escaping @Sendable (_ token: String, _ state: Service) async throws -> Key.Value?
    ) {
        use(BearerAuthentication<Key> { token, request in
            try await verify(token, try request.state(Service.self))
        })
        describeBearerScope()
    }

    /// `authenticate(basic:)` with what `app.state` built for `Service` in
    /// the shard handed to `verify`.
    public func authenticate<Key: RequestContextKey, Service: Sendable>(
        basic key: Key.Type, realm: String = "restricted", state service: Service.Type,
        _ verify: @escaping @Sendable (_ username: String, _ password: String, _ state: Service) async throws -> Key.Value?
    ) {
        use(BasicAuthentication<Key>(challenge: basicChallenge(realm)) { username, password, request in
            try await verify(username, password, try request.state(Service.self))
        })
        describeBasicScope()
    }

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

/// Answers 401 with the challenge `value`.
func challenge(_ response: borrowing Response, _ value: String) {
    response.addHeader("www-authenticate", value)
    response.send(status: .unauthorized)
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

// MARK: - Parsing

/// The token of the request's Bearer header, or nil.
func bearerToken(_ request: borrowing Request) -> String? {
    guard let header = request.headerBytes("authorization") else { return nil }
    return parseBearer(UnsafeBufferPointer(start: header.base, count: header.count))
}

/// The credentials of the request's Basic header, or nil.
func basicCredentials(_ request: borrowing Request) -> BasicCredentials? {
    guard let header = request.headerBytes("authorization") else { return nil }
    return parseBasic(UnsafeBufferPointer(start: header.base, count: header.count))
}

/// The token68 of a Bearer header, or nil.
func parseBearer(_ header: String) -> String? {
    var header = header
    return header.withUTF8 { parseBearer($0) }
}

/// The same, read as bytes: it is on the path of every request a token
/// guards.
func parseBearer(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
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

/// The user name and password of a Basic header, or nil for one that is not
/// base64 of UTF-8 with a colon.
func parseBasic(_ header: String) -> BasicCredentials? {
    var header = header
    return header.withUTF8 { parseBasic($0) }
}

func parseBasic(_ bytes: UnsafeBufferPointer<UInt8>) -> BasicCredentials? {
    // The scheme, compared without regard to case, a space, and any more
    // spaces before the credentials.
    let scheme = 5
    guard bytes.count > scheme + 1 else { return nil }
    var i = 0
    for expected in "basic".utf8 {
        guard asciiLower(bytes[i]) == expected else { return nil }
        i += 1
    }
    guard bytes[i] == 0x20 else { return nil }
    while i < bytes.count && bytes[i] == 0x20 { i += 1 }
    guard i < bytes.count else { return nil }
    // The standard alphabet only, as StandardBase64.decode has it.
    let encoded = UnsafeBufferPointer(rebasing: bytes[i...])
    for byte in encoded where byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") { return nil }
    guard let decoded = base64Decode(encoded),
          let colon = decoded.firstIndex(of: UInt8(ascii: ":")),
          let username = String(validating: decoded[..<colon], as: UTF8.self),
          let password = String(validating: decoded[(colon + 1)...], as: UTF8.self) else { return nil }
    return BasicCredentials(username: username, password: password)
}

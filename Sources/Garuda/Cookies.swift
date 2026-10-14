//===----------------------------------------------------------------------===//
// Cookies: reading them, setting them, and cookies a client cannot forge or
// read.
//
//     app.post("/login") { request, response in
//         response.setCookie(Cookie("theme", "dark"))
//         response.setCookie(Cookie("session", token), key: keys, .encrypted)
//         response.send(status: .noContent)
//     }
//     app.get("/") { request, response in
//         let theme = request.cookie("theme") ?? "light"
//         let session = request.cookie("session", key: keys, .encrypted)   // nil if tampered with
//         …
//     }
//
// **Reading.** The Cookie headers are read where they arrived, byte by byte;
// only the value asked for becomes a String. `request.cookies`, and the
// `Cookies` extractor, make every one of them into a dictionary, for the
// handler that wants them all.
//
// **Defaults.** A cookie made here is `Path=/`, `HttpOnly` and
// `SameSite=Lax` unless it says otherwise, and `Secure` when the request came
// over HTTPS (`Request.arrivedOverHTTPS`). Those are the settings a session
// cookie wants, and the ones a cookie gets wrong most when they have to be
// remembered. `SameSite=None` is always `Secure`, since browsers refuse it
// otherwise.
//
// **Values.** RFC 6265 allows a cookie value only a subset of ASCII. A plain
// cookie's value must already be in it -- `setCookie` refuses one that is not,
// rather than send a header a browser would cut short. A signed or encrypted
// cookie carries any string, since its value is encoded.
//
// **Signed** cookies are readable by the client but cannot be changed: the
// value travels with an HMAC-SHA256 over the cookie's name and value. **Encrypted**
// cookies can be neither read nor changed: AES-256-GCM with a random nonce,
// the name as associated data. Either way the name is bound in, so a value
// cannot be moved from one cookie to another, and a cookie that fails its
// check reads as absent. The cryptography is VegaCrypto's.
//
// A `CookieKey` is a secret of at least 32 bytes. Signing and encryption use
// different keys derived from it with HKDF. Previous secrets can be given
// with it: cookies are read with any of them and written with the current
// one, so a secret can be replaced without logging everyone out.
//===----------------------------------------------------------------------===//

import GarudaWire
import VegaCrypto

/// A cookie to set.
public struct Cookie: Sendable, Equatable {
    public enum SameSite: String, Sendable {
        case strict = "Strict"
        case lax = "Lax"
        case none = "None"
    }

    public var name: String
    public var value: String
    public var path: String? = "/"
    public var domain: String? = nil
    /// Seconds until the cookie expires. Nil for a cookie that ends with the
    /// browser session; 0 or less removes it.
    public var maxAge: Int? = nil
    /// When the cookie expires, in seconds since the Unix epoch, for clients
    /// older than Max-Age. Usually left nil in favour of `maxAge`.
    public var expires: Int64? = nil
    /// Nil: `Secure` when the request came over HTTPS.
    public var secure: Bool? = nil
    public var httpOnly = true
    public var sameSite: SameSite? = .lax
    /// CHIPS: a cookie kept per top-level site.
    public var partitioned = false

    public init(_ name: String, _ value: String, path: String? = "/", domain: String? = nil,
                maxAge: Int? = nil, secure: Bool? = nil, httpOnly: Bool = true,
                sameSite: SameSite? = .lax) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.maxAge = maxAge
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }
}

/// How a cookie's value is protected.
public enum CookieProtection: Sendable {
    /// Readable by the client, but changing it makes the cookie read as absent.
    case signed
    /// Neither readable nor changeable by the client.
    case encrypted
}

/// The secret signed and encrypted cookies are made with, and any it replaced.
public struct CookieKey: Sendable {
    struct Derived: Sendable {
        let signing: [UInt8]
        let encryption: [UInt8]
    }

    /// The current secret's keys first, then each previous one's.
    let keys: [Derived]

    /// `secret` is at least 32 random bytes, kept out of the source: from the
    /// environment, a secrets manager, or `CookieKey.randomSecret()` once.
    /// Cookies made with a `previous` secret still read.
    public init(secret: [UInt8], previous: [[UInt8]] = []) {
        precondition(secret.count >= 32, "a cookie secret is at least 32 bytes")
        precondition(previous.allSatisfy { $0.count >= 32 }, "a cookie secret is at least 32 bytes")
        keys = ([secret] + previous).map(CookieKey.derive)
    }

    /// The same from base64 or base64url text, as a secret is usually stored.
    /// Nil when any of them is not base64 or is shorter than 32 bytes.
    public init?(base64 secret: String, previous: [String] = []) {
        guard let current = base64Decode(secret), current.count >= 32 else { return nil }
        var older: [[UInt8]] = []
        for text in previous {
            guard let bytes = base64Decode(text), bytes.count >= 32 else { return nil }
            older.append(bytes)
        }
        self.init(secret: current, previous: older)
    }

    /// A new 32-byte secret in base64url, to generate once and keep.
    public static func randomSecret() -> String {
        base64URLEncode(SecureRandom.bytes(32))
    }

    private static func derive(_ secret: [UInt8]) -> Derived {
        let prk = HKDF.extract(.sha256, salt: Array("garuda cookies".utf8), inputKeyMaterial: secret)
        func expand(_ info: String) -> [UInt8] {
            do {
                return try HKDF.expand(.sha256, pseudoRandomKey: prk, info: Array(info.utf8), length: 32)
            } catch {
                preconditionFailure("HKDF is unavailable: \(error)")
            }
        }
        return Derived(signing: expand("signing"), encryption: expand("encryption"))
    }
}

// MARK: - Reading

extension Request {
    /// The value of the cookie `name`, or nil. When a client sends the name
    /// twice, the first is taken: browsers send the most specific path first.
    public func cookie(_ name: String) -> String? {
        let x = exchange
        var wanted = name
        return wanted.withUTF8 { wanted -> String? in
            var found: String? = nil
            x.pointee.forEachCookie { cookieName, value in
                guard cookieName.equals(wanted) else { return true }
                found = value.string
                return false
            }
            return found
        }
    }

    /// Every cookie the request carries, the first value of each name.
    public var cookies: [String: String] {
        var all: [String: String] = [:]
        exchange.pointee.forEachCookie { name, value in
            let key = name.string
            if all[key] == nil { all[key] = value.string }
            return true
        }
        return all
    }

    /// The value of a signed or encrypted cookie, or nil when it is absent or
    /// fails its check under every secret `key` holds. A copy that fails does
    /// not hide a genuine one sent after it under the same name.
    public func cookie(_ name: String, key: CookieKey, _ protection: CookieProtection) -> String? {
        let x = exchange
        var wanted = name
        return wanted.withUTF8 { wanted -> String? in
            var found: String? = nil
            x.pointee.forEachCookie { cookieName, value in
                guard cookieName.equals(wanted) else { return true }
                found = unprotectCookie(name: name, value: value.string, key: key, protection)
                return found == nil
            }
            return found
        }
    }
}

extension Exchange {
    /// Calls `body` with each cookie's name and value in the Cookie headers,
    /// in order, until it returns false. HTTP/2 and HTTP/3 clients may send
    /// one header per cookie. A pair is `name=value` between semicolons,
    /// spaces around it dropped and a quoted value unquoted; one without `=`
    /// or with no name is passed over.
    func forEachCookie(_ body: (ByteSpan, ByteSpan) -> Bool) {
        var h = 0
        while h < head.headerCount {
            let header = headers[h]
            h &+= 1
            guard header.name.count == 6, equalsLowercased(base + Int(header.name.offset), 6, "cookie") else {
                continue
            }
            let v = header.value.span(in: base).base
            let n = Int(header.value.count)
            var p = 0
            while p < n {
                var end = p
                while end < n && v[end] != 0x3B { end &+= 1 }               // ;
                var start = p
                while start < end && isCookieSpace(v[start]) { start &+= 1 }
                var equals = start
                while equals < end && v[equals] != 0x3D { equals &+= 1 }   // =
                if equals < end {
                    var nameEnd = equals
                    while nameEnd > start && isCookieSpace(v[nameEnd &- 1]) { nameEnd &-= 1 }
                    var valueStart = equals &+ 1
                    var valueEnd = end
                    while valueEnd > valueStart && isCookieSpace(v[valueEnd &- 1]) { valueEnd &-= 1 }
                    if valueEnd &- valueStart >= 2 && v[valueStart] == 0x22 && v[valueEnd &- 1] == 0x22 {
                        valueStart &+= 1
                        valueEnd &-= 1
                    }
                    if nameEnd > start,
                       !body(ByteSpan(v + start, nameEnd &- start), ByteSpan(v + valueStart, valueEnd &- valueStart)) {
                        return
                    }
                }
                p = end &+ 1
            }
        }
    }
}

@inline(__always)
private func isCookieSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

extension ByteSpan {
    /// Whether the span holds exactly `bytes`.
    func equals(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard count == bytes.count else { return false }
        return count == 0 || memcmpEqual(base, bytes.baseAddress!, count)
    }
}

/// The cookies a request carries, as an extractor.
public struct Cookies: RequestExtractor, Sendable {
    public let all: [String: String]

    public subscript(_ name: String) -> String? { all[name] }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Cookies {
        Cookies(all: request.cookies)
    }
}

// MARK: - Writing

extension Response {
    /// Adds a Set-Cookie header for `cookie`. False, adding nothing, when its
    /// name is not a token, its value holds a character a cookie value may
    /// not, its path or domain holds `;` or a control character, or the
    /// response has already been written.
    @discardableResult
    public func setCookie(_ cookie: Cookie) -> Bool {
        guard let header = setCookieHeader(cookie, value: cookie.value) else { return false }
        return addHeader("set-cookie", header)
    }

    /// Adds a Set-Cookie header for a cookie whose value is signed or
    /// encrypted with `key`'s current secret. Its value may be any string.
    @discardableResult
    public func setCookie(_ cookie: Cookie, key: CookieKey, _ protection: CookieProtection) -> Bool {
        guard !exchange.pointee.committed else { return false }
        let value = protectCookie(name: cookie.name, value: cookie.value, key: key, protection)
        guard let header = setCookieHeader(cookie, value: value) else { return false }
        return addHeader("set-cookie", header)
    }

    /// Tells the client to forget the cookie `name`. The path and domain must
    /// be the ones it was set with.
    @discardableResult
    public func removeCookie(_ name: String, path: String? = "/", domain: String? = nil) -> Bool {
        var cookie = Cookie(name, "", path: path, domain: domain, maxAge: 0)
        cookie.expires = 0
        return setCookie(cookie)
    }

    func setCookieHeader(_ cookie: Cookie, value: String) -> String? {
        Garuda.setCookieHeader(cookie, value: value, https: Request(exchange).arrivedOverHTTPS)
    }
}

/// The Set-Cookie header for `cookie` holding `value`, or nil when the name,
/// value, path or domain cannot be sent. `https` is whether the request came
/// over HTTPS, which a cookie whose `secure` is nil follows.
func setCookieHeader(_ cookie: Cookie, value: String, https: Bool) -> String? {
    guard isCookieName(cookie.name), isCookieValue(value) else { return nil }
    var header = cookie.name + "=" + value
    if let path = cookie.path {
        guard isAttributeValue(path) else { return nil }
        header += "; Path=" + path
    }
    if let domain = cookie.domain {
        guard isAttributeValue(domain), !domain.isEmpty else { return nil }
        header += "; Domain=" + domain
    }
    if let maxAge = cookie.maxAge { header += "; Max-Age=\(max(0, maxAge))" }
    if let expires = cookie.expires {
        let date = String(unsafeUninitializedCapacity: 29) { buffer in
            DateCache.format(expires, into: buffer.baseAddress!)
            return 29
        }
        header += "; Expires=" + date
    }
    let secure = cookie.secure ?? https
    if secure || cookie.sameSite == Cookie.SameSite.none { header += "; Secure" }
    if cookie.httpOnly { header += "; HttpOnly" }
    if let sameSite = cookie.sameSite { header += "; SameSite=" + sameSite.rawValue }
    if cookie.partitioned { header += "; Partitioned" }
    return header
}

// MARK: - Checks and protection

/// A token: visible ASCII, no separators.
func isCookieName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.allSatisfy { c in
        c > 0x20 && c < 0x7F && !"()<>@,;:\\\"/[]?={}".utf8.contains(c)
    }
}

/// RFC 6265 cookie-octet: visible ASCII but for `"`, `,`, `;` and `\`.
func isCookieValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { c in
        c == 0x21 || (c >= 0x23 && c <= 0x2B) || (c >= 0x2D && c <= 0x3A) || (c >= 0x3C && c <= 0x5B)
            || (c >= 0x5D && c <= 0x7E)
    }
}

func isAttributeValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F && $0 != 0x3B }
}

/// The value to send for a protected cookie.
func protectCookie(name: String, value: String, key: CookieKey, _ protection: CookieProtection) -> String {
    let current = key.keys[0]
    switch protection {
    case .signed:
        let encoded = base64URLEncode(Array(value.utf8))
        return encoded + "." + base64URLEncode(cookieMAC(current.signing, name: name, encoded: encoded))
    case .encrypted:
        let nonce = SecureRandom.bytes(AEADAlgorithm.nonceByteCount)
        do {
            let aead = try AEAD(.aes256GCM, key: current.encryption)
            let sealed = try aead.seal(nonce: nonce, aad: Array(name.utf8), plaintext: Array(value.utf8))
            return base64URLEncode(nonce + sealed)
        } catch {
            preconditionFailure("AES-256-GCM failed to seal: \(error)")
        }
    }
}

/// The value a protected cookie carries, or nil when no secret accepts it.
func unprotectCookie(name: String, value: String, key: CookieKey, _ protection: CookieProtection) -> String? {
    switch protection {
    case .signed:
        guard let dot = value.lastIndex(of: "."),
              let mac = base64Decode(String(value[value.index(after: dot)...])), mac.count == 32 else { return nil }
        let encoded = String(value[..<dot])
        for keys in key.keys where ConstantTime.equals(cookieMAC(keys.signing, name: name, encoded: encoded), mac) {
            guard let bytes = base64Decode(encoded) else { return nil }
            return String(validating: bytes, as: UTF8.self)
        }
        return nil
    case .encrypted:
        let tag = AEADAlgorithm.tagByteCount
        let nonceCount = AEADAlgorithm.nonceByteCount
        guard let bytes = base64Decode(value), bytes.count >= nonceCount + tag else { return nil }
        let nonce = Array(bytes[0..<nonceCount])
        let sealed = Array(bytes[nonceCount...])
        let aad = Array(name.utf8)
        for keys in key.keys {
            guard let aead = try? AEAD(.aes256GCM, key: keys.encryption) else { return nil }
            if let plain = try? aead.open(nonce: nonce, aad: aad, ciphertext: sealed) {
                return String(validating: plain, as: UTF8.self)
            }
        }
        return nil
    }
}

private func cookieMAC(_ key: [UInt8], name: String, encoded: String) -> [UInt8] {
    HMAC.authenticationCode(.sha256, key: key, data: Array((name + "=" + encoded).utf8))
}

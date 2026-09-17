//===----------------------------------------------------------------------===//
// Cookies: reading them, setting them, and cookies a client cannot forge or
// read.
//
//     app.post("/login") { request, response in
//         response.setCookie(Cookie("theme", "dark"))
//         response.setCookie(Cookie("session", token), key: keys, .encrypted)
//     }
//     app.get("/") { request, response in
//         let theme = request.cookie("theme") ?? "light"
//         let session = request.cookie("session", key: keys, .encrypted)   // nil if tampered with
//     }
//
// **Defaults.** A cookie made here is `Path=/`, `HttpOnly` and
// `SameSite=Lax` unless it says otherwise, and `Secure` when the request came
// over HTTPS (directly, or from a trusted proxy that said so). Those are the
// settings a session cookie wants, and the ones a cookie gets wrong most when
// they have to be remembered. `SameSite=None` is always `Secure`, since
// browsers refuse it otherwise.
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
// check reads as absent.
//
// A `CookieKey` is a secret of at least 32 bytes. Signing and encryption use
// different keys derived from it with HKDF. Previous secrets can be given
// with it: cookies are read with any of them and written with the current
// one, so a secret can be replaced without logging everyone out.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import GarudaPostgres

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
    /// When the cookie expires, for clients older than Max-Age. Usually left
    /// nil in favour of `maxAge`.
    public var expires: Timestamp? = nil
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
        base64URLEncode(randomBytes(32))
    }

    private static func derive(_ secret: [UInt8]) -> Derived {
        var prk = [UInt8](repeating: 0, count: 32)
        let salt = Array("garuda cookies".utf8)
        let extracted = secret.withUnsafeBytes { s in
            salt.withUnsafeBytes { a in
                prk.withUnsafeMutableBytes { o in
                    av_hkdf_extract(Int32(AV_SHA256), a.baseAddress, a.count, s.baseAddress, s.count,
                                    o.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }
        precondition(extracted >= 0, "HKDF is unavailable")
        func expand(_ info: String) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            let label = Array(info.utf8)
            let rc = prk.withUnsafeBytes { p in
                label.withUnsafeBytes { l in
                    out.withUnsafeMutableBytes { o in
                        av_hkdf_expand(Int32(AV_SHA256), p.baseAddress, p.count, l.baseAddress, l.count,
                                       o.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                    }
                }
            }
            precondition(rc >= 0, "HKDF is unavailable")
            return out
        }
        return Derived(signing: expand("signing"), encryption: expand("encryption"))
    }
}

// MARK: - Reading

extension Request {
    /// The value of the cookie `name`, or nil. When a client sends the name
    /// twice, the first is taken: browsers send the most specific path first.
    public func cookie(_ name: String) -> String? {
        var found: String? = nil
        forEachCookie { cookieName, value in
            if found == nil && cookieName == name { found = value }
        }
        return found
    }

    /// Every cookie the request carries, the first value of each name.
    public var cookies: [String: String] {
        var all: [String: String] = [:]
        forEachCookie { name, value in
            if all[name] == nil { all[name] = value }
        }
        return all
    }

    /// The value of a signed or encrypted cookie, or nil when it is absent or
    /// fails its check under every secret `key` holds.
    public func cookie(_ name: String, key: CookieKey, _ protection: CookieProtection) -> String? {
        var found: String? = nil
        forEachCookie { cookieName, value in
            guard found == nil, cookieName == name else { return }
            found = unprotectCookie(name: name, value: value, key: key, protection)
        }
        return found
    }

    /// Calls `body` with each name and value in the Cookie headers, in order.
    /// HTTP/2 and HTTP/3 clients may send one header per cookie.
    func forEachCookie(_ body: (String, String) -> Void) {
        forEachHeader { name, value in
            guard name.count == 6, equalsLowercasedSpan(name, "cookie") else { return }
            let text = value.string
            for pair in text.split(separator: ";", omittingEmptySubsequences: true) {
                let trimmed = pair.drop { $0 == " " || $0 == "\t" }
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let cookieName = trimmed[..<equals].trimmingTrailingSpaces()
                var cookieValue = trimmed[trimmed.index(after: equals)...].trimmingTrailingSpaces()
                if cookieValue.count >= 2, cookieValue.hasPrefix("\""), cookieValue.hasSuffix("\"") {
                    cookieValue = String(cookieValue.dropFirst().dropLast())
                }
                guard !cookieName.isEmpty else { continue }
                body(cookieName, cookieValue)
            }
        }
    }
}

/// The cookies a request carries, as an extractor.
public struct Cookies: RequestExtractor, Sendable {
    public let all: [String: String]

    public subscript(_ name: String) -> String? { all[name] }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Cookies {
        Cookies(all: request.cookies)
    }
}

// MARK: - Writing

extension Response {
    /// Adds a Set-Cookie header for `cookie`. False, adding nothing, when its
    /// name is not a token, its value holds a character a cookie value may
    /// not, or its path or domain holds `;` or a control character.
    @discardableResult
    public func setCookie(_ cookie: Cookie) -> Bool {
        guard isActive, let header = setCookieHeader(cookie, value: cookie.value) else { return false }
        return addHeader("set-cookie", header)
    }

    /// Adds a Set-Cookie header for a cookie whose value is signed or
    /// encrypted with `key`'s current secret. Its value may be any string.
    @discardableResult
    public func setCookie(_ cookie: Cookie, key: CookieKey, _ protection: CookieProtection) -> Bool {
        guard isActive else { return false }
        let value = protectCookie(name: cookie.name, value: cookie.value, key: key, protection)
        guard let header = setCookieHeader(cookie, value: value) else { return false }
        return addHeader("set-cookie", header)
    }

    /// Tells the client to forget the cookie `name`. The path and domain must
    /// be the ones it was set with.
    @discardableResult
    public func removeCookie(_ name: String, path: String? = "/", domain: String? = nil) -> Bool {
        var cookie = Cookie(name, "", path: path, domain: domain, maxAge: 0)
        cookie.expires = Timestamp(secondsSinceEpoch: 0)
        return setCookie(cookie)
    }

    func setCookieHeader(_ cookie: Cookie, value: String) -> String? {
        let https = String(describing: worker.pointee.requestScheme(slot)) == "https"
        return Garuda.setCookieHeader(cookie, value: value, https: https)
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
        var date = [CChar](repeating: 0, count: 30)
        let seconds = expires.microsecondsSinceEpoch / 1_000_000
        _ = date.withUnsafeMutableBufferPointer { av_http_date($0.baseAddress!, seconds) }
        header += "; Expires=" + String(decoding: date.prefix(29).map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

func equalsLowercasedSpan(_ span: Span<UInt8>, _ literal: StaticString) -> Bool {
    guard span.count == literal.utf8CodeUnitCount else { return false }
    for i in span.indices {
        var c = span[i]
        if c >= 0x41 && c <= 0x5A { c |= 0x20 }
        if c != literal.utf8Start[i] { return false }
    }
    return true
}

extension Substring {
    func trimmingTrailingSpaces() -> String {
        var end = endIndex
        while end > startIndex, self[index(before: end)] == " " || self[index(before: end)] == "\t" {
            end = index(before: end)
        }
        return String(self[..<end])
    }
}

/// The value to send for a protected cookie.
func protectCookie(name: String, value: String, key: CookieKey, _ protection: CookieProtection) -> String {
    let current = key.keys[0]
    switch protection {
    case .signed:
        let encoded = base64URLEncode(Array(value.utf8))
        return encoded + "." + base64URLEncode(cookieMAC(current.signing, name: name, encoded: encoded))
    case .encrypted:
        let nonce = randomBytes(12)
        let sealed = aeadSeal(current.encryption, nonce: nonce, aad: Array(name.utf8), Array(value.utf8))
        return base64URLEncode(nonce + sealed)
    }
}

/// The value a protected cookie carries, or nil when no secret accepts it.
func unprotectCookie(name: String, value: String, key: CookieKey, _ protection: CookieProtection) -> String? {
    switch protection {
    case .signed:
        guard let dot = value.lastIndex(of: "."),
              let mac = base64Decode(String(value[value.index(after: dot)...])), mac.count == 32 else { return nil }
        let encoded = String(value[..<dot])
        for keys in key.keys where constantTimeEquals(cookieMAC(keys.signing, name: name, encoded: encoded), mac) {
            guard let bytes = base64Decode(encoded) else { return nil }
            return String(validating: bytes, as: UTF8.self)
        }
        return nil
    case .encrypted:
        guard let bytes = base64Decode(value), bytes.count >= 12 + 16 else { return nil }
        let nonce = Array(bytes[0..<12])
        let sealed = Array(bytes[12...])
        for keys in key.keys {
            if let plain = aeadOpen(keys.encryption, nonce: nonce, aad: Array(name.utf8), sealed) {
                return String(validating: plain, as: UTF8.self)
            }
        }
        return nil
    }
}

private func cookieMAC(_ key: [UInt8], name: String, encoded: String) -> [UInt8] {
    let message = Array((name + "=" + encoded).utf8)
    var out = [UInt8](repeating: 0, count: 32)
    let rc = key.withUnsafeBytes { k in
        message.withUnsafeBytes { m in
            out.withUnsafeMutableBytes { o in
                av_hmac(Int32(AV_SHA256), k.baseAddress, k.count, m.baseAddress, m.count,
                        o.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
    }
    precondition(rc >= 0, "HMAC-SHA256 is unavailable")
    return out
}

private func aeadSeal(_ key: [UInt8], nonce: [UInt8], aad: [UInt8], _ plain: [UInt8]) -> [UInt8] {
    guard let aead = key.withUnsafeBufferPointer({ av_aead_new(Int32(AV_AEAD_AES256GCM), $0.baseAddress) }) else {
        fatalError("AES-256-GCM is unavailable")
    }
    defer { av_aead_free(aead) }
    var out = [UInt8](repeating: 0, count: plain.count + 16)
    let n = nonce.withUnsafeBufferPointer { nb in
        aad.withUnsafeBytes { a in
            plain.withUnsafeBytes { p in
                out.withUnsafeMutableBufferPointer { o in
                    av_aead_seal(aead, nb.baseAddress, a.baseAddress, a.count, p.baseAddress, p.count, o.baseAddress)
                }
            }
        }
    }
    precondition(n == plain.count + 16, "AES-256-GCM failed to seal")
    return out
}

private func aeadOpen(_ key: [UInt8], nonce: [UInt8], aad: [UInt8], _ sealed: [UInt8]) -> [UInt8]? {
    guard let aead = key.withUnsafeBufferPointer({ av_aead_new(Int32(AV_AEAD_AES256GCM), $0.baseAddress) }) else {
        return nil
    }
    defer { av_aead_free(aead) }
    var out = [UInt8](repeating: 0, count: sealed.count)
    let n = nonce.withUnsafeBufferPointer { nb in
        aad.withUnsafeBytes { a in
            sealed.withUnsafeBytes { s in
                out.withUnsafeMutableBufferPointer { o in
                    av_aead_open(aead, nb.baseAddress, a.baseAddress, a.count, s.baseAddress, s.count, o.baseAddress)
                }
            }
        }
    }
    guard n >= 0 else { return nil }
    return Array(out.prefix(n))
}

func randomBytes(_ count: Int) -> [UInt8] {
    var raw = [UInt8](repeating: 0, count: count)
    guard raw.withUnsafeMutableBytes({ av_random_bytes($0.baseAddress, $0.count) }) == 0 else {
        fatalError("the system's random number generator failed")
    }
    return raw
}

func base64URLEncode(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    for c in Base64.encode(bytes).utf8 {
        switch c {
        case UInt8(ascii: "+"): out.append(UInt8(ascii: "-"))
        case UInt8(ascii: "/"): out.append(UInt8(ascii: "_"))
        case UInt8(ascii: "="): break
        default: out.append(c)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Base64 or base64url, padded or not.
func base64Decode(_ text: String) -> [UInt8]? {
    var standard: [UInt8] = []
    for c in text.utf8 {
        switch c {
        case UInt8(ascii: "-"): standard.append(UInt8(ascii: "+"))
        case UInt8(ascii: "_"): standard.append(UInt8(ascii: "/"))
        case UInt8(ascii: "="): break
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
            standard.append(c)
        default:
            return nil
        }
    }
    if standard.count % 4 == 1 { return nil }
    while standard.count % 4 != 0 { standard.append(UInt8(ascii: "=")) }
    return Base64.decode(String(decoding: standard, as: UTF8.self))
}

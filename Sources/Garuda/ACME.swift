//===----------------------------------------------------------------------===//
// Getting a certificate from an ACME CA (RFC 8555), with tls-alpn-01 (RFC 8737).
//
// This runs in a helper process the supervisor forks, never in a worker: a CA
// that is slow, down, or rate-limiting us costs one waiting process and
// nothing that serves requests. The helper's only output is two files and an
// exit status. When it exits 0 the supervisor reloads the workers, each of
// which reads the new certificate off disk exactly as a SIGHUP would have it
// do -- the same zero-downtime path, with nothing new to trust.
//
// tls-alpn-01 rather than http-01, because it is answered on the port that is
// already being served. The CA opens a TLS connection offering only the
// `acme-tls/1` protocol; the worker that accepts it serves the challenge
// certificate this process wrote into the cache directory, and closes. No
// port 80, no web root, and no window in which a route has to be kept free.
//
// The protocol is JSON over HTTPS and it is small, so it is here in Swift with
// a JSON reader just large enough for it. Everything that needs OpenSSL -- the
// account key, ES256, the CSR, the challenge certificate, TLS to the CA -- is
// in avian_acme.c.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CAvian
import AvianCore

// MARK: - JSON, enough of it

indirect enum ACMEJSON {
    case object([(String, ACMEJSON)])
    case array([ACMEJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> ACMEJSON? {
        guard case .object(let members) = self else { return nil }
        for (k, v) in members where k == key { return v }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var array: [ACMEJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    static func parse(_ bytes: [UInt8]) -> ACMEJSON? {
        var reader = Reader(bytes: bytes)
        guard let value = reader.value() else { return nil }
        reader.skipSpace()
        return reader.index == bytes.count ? value : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func skipSpace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x0A
                  || bytes[index] == 0x0D || bytes[index] == 0x09 {
                index += 1
            }
        }

        mutating func value() -> ACMEJSON? {
            skipSpace()
            guard index < bytes.count else { return nil }
            depth += 1
            defer { depth -= 1 }
            if depth > 64 { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: StaticString, _ result: ACMEJSON) -> ACMEJSON? {
            let n = word.utf8CodeUnitCount
            guard index + n <= bytes.count else { return nil }
            for k in 0..<n where bytes[index + k] != word.utf8Start[k] { return nil }
            index += n
            return result
        }

        mutating func number() -> ACMEJSON? {
            let start = index
            while index < bytes.count {
                let c = bytes[index]
                let numeric = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B
                    || c == 0x2E || c == 0x65 || c == 0x45
                if !numeric { break }
                index += 1
            }
            guard index > start else { return nil }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            return Double(text).map { .number($0) }
        }

        mutating func string() -> String? {
            index += 1   // opening quote
            var out: [UInt8] = []
            while index < bytes.count {
                let c = bytes[index]
                index += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                if c != UInt8(ascii: "\\") {
                    out.append(c)
                    continue
                }
                guard index < bytes.count else { return nil }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var scalar = hex4() else { return nil }
                    // A surrogate pair is one character in two escapes.
                    if scalar >= 0xD800 && scalar <= 0xDBFF,
                       index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                        index += 2
                        guard let low = hex4(), low >= 0xDC00 && low <= 0xDFFF else { return nil }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(scalar) else { return nil }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    return nil
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                index += 1
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: return nil
                }
                v = v * 16 + d
            }
            return v
        }

        mutating func array() -> ACMEJSON? {
            index += 1
            var items: [ACMEJSON] = []
            skipSpace()
            if index < bytes.count && bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object() -> ACMEJSON? {
            index += 1
            var members: [(String, ACMEJSON)] = []
            skipSpace()
            if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""),
                      let key = string() else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let v = value() else { return nil }
                members.append((key, v))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }
    }
}

/// A JSON string literal for `s`.
func acmeQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                        "8", "9", "a", "b", "c", "d", "e", "f"]
                out += "\\u00"
                out.append(hex[Int(u.value >> 4)])
                out.append(hex[Int(u.value & 0xF)])
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

/// The text in a NUL-terminated buffer a C function filled.
func acmeText(_ buffer: [CChar]) -> String {
    let end = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// MARK: - Logging strings

private func acmeLog(_ level: LogLevel, _ prefix: StaticString, _ message: String) {
    let bytes = Array(message.utf8)
    let body: (inout LogLine) -> Void = { line in
        line.str("acme: ")
        line.str(prefix)
        bytes.withUnsafeBufferPointer { b in
            if let base = b.baseAddress { line.bytes(base, b.count) }
        }
    }
    switch level {
    case .error: Log.error(body)
    case .warning: Log.warn(body)
    default: Log.info(body)
    }
}

// MARK: - The client

struct ACMEClient {
    struct Response {
        var status: Int
        var body: [UInt8]
        var location: String?
        var json: ACMEJSON? { ACMEJSON.parse(body) }
        var bodyText: String { String(decoding: body.prefix(512), as: UTF8.self) }
    }

    let directoryURL: String
    let caFile: String?
    let key: OpaquePointer
    let jwk: String
    let thumbprint: String
    var nonce: String? = nil
    var kid: String? = nil
    var newNonceURL = ""
    var newAccountURL = ""
    var newOrderURL = ""

    /// Loads or creates the account key. nil, logged, on failure.
    init?(directoryURL: String, caFile: String?, accountKeyPath: String) {
        var error = [CChar](repeating: 0, count: 256)
        guard let key = accountKeyPath.withCString({ path in
            error.withUnsafeMutableBufferPointer {
                av_acme_key_load_or_create(path, $0.baseAddress, 256)
            }
        }) else {
            acmeLog(.error, "", acmeText(error))
            return nil
        }
        var jwkBuffer = [CChar](repeating: 0, count: 256)
        var thumbBuffer = [CChar](repeating: 0, count: 64)
        guard av_acme_jwk(key, &jwkBuffer, 256) > 0,
              av_acme_thumbprint(key, &thumbBuffer, 64) > 0 else {
            av_acme_key_free(key)
            acmeLog(.error, "", "cannot describe the account key")
            return nil
        }
        self.directoryURL = directoryURL
        self.caFile = caFile
        self.key = key
        self.jwk = acmeText(jwkBuffer)
        self.thumbprint = acmeText(thumbBuffer)
    }

    func destroy() { av_acme_key_free(key) }

    // MARK: HTTP

    func request(_ method: String, _ url: String, body: [UInt8]? = nil,
                 accept: String = "application/json") -> Response? {
        var error = [CChar](repeating: 0, count: 512)
        let resp: OpaquePointer? = method.withCString { m in
            url.withCString { u in
                accept.withCString { a in
                    withOptionalCString(caFile) { ca in
                        error.withUnsafeMutableBufferPointer { e in
                            if let body {
                                return body.withUnsafeBufferPointer { b in
                                    av_acme_https(m, u, "application/jose+json",
                                                  b.baseAddress, b.count, a, ca,
                                                  e.baseAddress, 512)
                                }
                            }
                            return av_acme_https(m, u, nil, nil, 0, a, ca, e.baseAddress, 512)
                        }
                    }
                }
            }
        }
        guard let resp else {
            acmeLog(.error, "", acmeText(error))
            return nil
        }
        defer { av_acme_resp_free(resp) }
        var length = 0
        let base = av_acme_resp_body(resp, &length)
        let bytes = base.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? []
        return Response(status: Int(av_acme_resp_status(resp)), body: bytes,
                        location: header(resp, "location"))
    }

    private func header(_ resp: OpaquePointer, _ name: StaticString) -> String? {
        var out = [CChar](repeating: 0, count: 2048)
        let n = UnsafeRawPointer(name.utf8Start).withMemoryRebound(
            to: CChar.self, capacity: name.utf8CodeUnitCount + 1) {
            av_acme_resp_header(resp, $0, &out, 2048)
        }
        return n >= 0 ? acmeText(out) : nil
    }

    private func nonceHeader(_ url: String) -> String? {
        var error = [CChar](repeating: 0, count: 512)
        let resp: OpaquePointer? = url.withCString { u in
            withOptionalCString(caFile) { ca in
                error.withUnsafeMutableBufferPointer { e in
                    av_acme_https("HEAD", u, nil, nil, 0, "application/json", ca, e.baseAddress, 512)
                }
            }
        }
        guard let resp else {
            acmeLog(.error, "", acmeText(error))
            return nil
        }
        defer { av_acme_resp_free(resp) }
        return header(resp, "replay-nonce")
    }

    // MARK: JWS

    private func b64(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out = [CChar](repeating: 0, count: bytes.count * 4 / 3 + 8)
        let n = bytes.withUnsafeBufferPointer {
            av_acme_b64url($0.baseAddress, $0.count, &out, out.count)
        }
        return n >= 0 ? acmeText(out) : ""
    }

    /// A signed POST. `payload` nil is POST-as-GET, which is how ACME reads a
    /// resource: an unauthenticated GET would let anyone read an account's
    /// orders. A rejected nonce is retried, because a CA is entitled to
    /// reject any nonce and Let's Encrypt does from time to time.
    mutating func post(_ url: String, payload: String?,
                       accept: String = "application/json") -> Response? {
        for _ in 0..<3 {
            guard let nonce = self.nonce ?? nonceHeader(newNonceURL) else { return nil }
            self.nonce = nil
            var protected = "{\"alg\":\"ES256\","
            if let kid {
                protected += "\"kid\":" + acmeQuote(kid) + ","
            } else {
                protected += "\"jwk\":" + jwk + ","
            }
            protected += "\"nonce\":" + acmeQuote(nonce) + ",\"url\":" + acmeQuote(url) + "}"
            let protected64 = b64(protected)
            let payload64 = payload.map { b64($0) } ?? ""
            let signingInput = Array((protected64 + "." + payload64).utf8)
            var signature = [CChar](repeating: 0, count: 128)
            let signed = signingInput.withUnsafeBufferPointer {
                av_acme_sign(key, $0.baseAddress, $0.count, &signature, 128)
            }
            guard signed > 0 else {
                acmeLog(.error, "", "cannot sign a request")
                return nil
            }
            let body = "{\"protected\":\"" + protected64 + "\",\"payload\":\"" + payload64
                + "\",\"signature\":\"" + acmeText(signature) + "\"}"
            guard let response = requestKeepingNonce(url, Array(body.utf8), accept) else { return nil }
            if response.status == 400,
               response.json?["type"]?.string == "urn:ietf:params:acme:error:badNonce" {
                continue
            }
            return response
        }
        acmeLog(.error, "", "the CA rejected three nonces in a row")
        return nil
    }

    /// POST, keeping the nonce every ACME response carries for the next one.
    private mutating func requestKeepingNonce(_ url: String, _ body: [UInt8],
                                              _ accept: String) -> Response? {
        var error = [CChar](repeating: 0, count: 512)
        let resp: OpaquePointer? = url.withCString { u in
            accept.withCString { a in
                withOptionalCString(caFile) { ca in
                    error.withUnsafeMutableBufferPointer { e in
                        body.withUnsafeBufferPointer { b in
                            av_acme_https("POST", u, "application/jose+json", b.baseAddress,
                                          b.count, a, ca, e.baseAddress, 512)
                        }
                    }
                }
            }
        }
        guard let resp else {
            acmeLog(.error, "", acmeText(error))
            return nil
        }
        defer { av_acme_resp_free(resp) }
        nonce = header(resp, "replay-nonce")
        var length = 0
        let base = av_acme_resp_body(resp, &length)
        let bytes = base.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? []
        return Response(status: Int(av_acme_resp_status(resp)), body: bytes,
                        location: header(resp, "location"))
    }

    // MARK: Protocol

    mutating func loadDirectory() -> Bool {
        guard let response = request("GET", directoryURL), response.status == 200,
              let json = response.json,
              let newNonce = json["newNonce"]?.string,
              let newAccount = json["newAccount"]?.string,
              let newOrder = json["newOrder"]?.string else {
            acmeLog(.error, "cannot read the directory at ", directoryURL)
            return false
        }
        newNonceURL = newNonce
        newAccountURL = newAccount
        newOrderURL = newOrder
        return true
    }

    /// Registers the account key, or finds the account it already has -- the
    /// same request does both, so nothing about the account needs keeping.
    mutating func register(email: String?) -> Bool {
        var payload = "{\"termsOfServiceAgreed\":true"
        if let email { payload += ",\"contact\":[" + acmeQuote("mailto:" + email) + "]" }
        payload += "}"
        guard let response = post(newAccountURL, payload: payload),
              response.status == 200 || response.status == 201,
              let location = response.location else {
            acmeLog(.error, "account registration failed: ", describe(nil))
            return false
        }
        kid = location
        return true
    }

    func describe(_ response: Response?) -> String {
        guard let response else { return "no response" }
        if let json = response.json, let detail = json["detail"]?.string {
            return String(response.status) + " " + detail
        }
        return String(response.status) + " " + response.bodyText
    }

    /// Asks for a resource until its status leaves `pending`/`processing`.
    mutating func poll(_ url: String, until done: String, attempts: Int = 90) -> ACMEJSON? {
        for attempt in 0..<attempts {
            _ = usleep(attempt == 0 ? 250_000 : 1_000_000)
            guard let response = post(url, payload: nil), response.status == 200,
                  let json = response.json, let status = json["status"]?.string else {
                return nil
            }
            if status == done { return json }
            if status == "invalid" {
                var why = "invalid"
                if let challenges = json["challenges"]?.array {
                    for c in challenges {
                        if let detail = c["error"]?["detail"]?.string { why = detail }
                    }
                }
                if let detail = json["error"]?["detail"]?.string { why = detail }
                acmeLog(.error, "", why)
                return nil
            }
        }
        acmeLog(.error, "gave up waiting on ", url)
        return nil
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}

/// A DNS name as ACME will accept one, lower-cased, or nil.
func acmeValidDomain(_ name: String) -> String? {
    let lowered = String(name.unicodeScalars.map { u -> Character in
        (u.value >= 0x41 && u.value <= 0x5A) ? Character(Unicode.Scalar(u.value + 32)!) : Character(u)
    })
    if lowered.isEmpty || lowered.utf8.count > 253 { return nil }
    if lowered.hasPrefix(".") || lowered.hasSuffix(".") || lowered.hasPrefix("-") { return nil }
    for u in lowered.unicodeScalars {
        let ok = (u.value >= 0x61 && u.value <= 0x7A) || (u.value >= 0x30 && u.value <= 0x39)
            || u == "-" || u == "."
        if !ok { return nil }
    }
    return lowered
}

// MARK: - One issuance

enum ACME {

    /// Everything the helper needs, as plain values: it is forked from the
    /// supervisor and must not rely on anything but its own copy of these.
    struct Settings {
        var domains: [String]
        var email: String?
        var directory: String
        var cacheDir: String
        var caFile: String?

        var certPath: String { cacheDir + "/cert.pem" }
        var keyPath: String { cacheDir + "/key.pem" }
        var challengeDir: String { cacheDir + "/alpn" }
        var names: String { domains.joined(separator: ",") }
    }

    static func settings(_ config: ServerConfig) -> Settings {
        Settings(domains: config.acmeDomains.map {
                    let given = String(cString: $0)
                    return acmeValidDomain(given) ?? given
                 },
                 email: config.acmeEmail.map { String(cString: $0) },
                 directory: String(cString: config.acmeDirectory),
                 cacheDir: config.acmeCacheDir.map { String(cString: $0) } ?? "acme",
                 caFile: config.acmeCABundle.map { String(cString: $0) })
    }

    /// Obtains a certificate for every domain and installs it. True when the
    /// files on disk are new and the workers should be reloaded.
    static func obtain(_ settings: Settings) -> Bool {
        _ = av_acme_mkdirs(settings.challengeDir)
        guard var client = ACMEClient(directoryURL: settings.directory,
                                      caFile: settings.caFile,
                                      accountKeyPath: settings.cacheDir + "/account.key") else {
            return false
        }
        defer { client.destroy() }
        acmeLog(.info, "requesting a certificate for ", settings.names)

        guard client.loadDirectory(), client.register(email: settings.email) else { return false }

        let identifiers = settings.domains
            .map { "{\"type\":\"dns\",\"value\":" + acmeQuote($0) + "}" }
            .joined(separator: ",")
        guard let order = client.post(client.newOrderURL,
                                      payload: "{\"identifiers\":[" + identifiers + "]}"),
              order.status == 201, let orderURL = order.location, let orderJSON = order.json,
              let finalizeURL = orderJSON["finalize"]?.string else {
            acmeLog(.error, "the order was refused: ", client.describe(nil))
            return false
        }

        var written: [String] = []
        defer { for path in written { _ = av_unlink(path) } }

        for entry in orderJSON["authorizations"]?.array ?? [] {
            guard let authURL = entry.string,
                  let response = client.post(authURL, payload: nil), response.status == 200,
                  let authz = response.json else {
                acmeLog(.error, "", "cannot read an authorization")
                return false
            }
            if authz["status"]?.string == "valid" { continue }
            guard let asked = authz["identifier"]?["value"]?.string,
                  let domain = acmeValidDomain(asked) else {
                acmeLog(.error, "", "an authorization names something that is not a domain")
                return false
            }
            guard let challenge = (authz["challenges"]?.array ?? [])
                    .first(where: { $0["type"]?.string == "tls-alpn-01" }),
                  let token = challenge["token"]?.string,
                  let challengeURL = challenge["url"]?.string else {
                acmeLog(.error, "the CA offers no tls-alpn-01 challenge for ", domain)
                return false
            }

            let certPath = settings.challengeDir + "/" + domain + ".crt"
            let keyPath = settings.challengeDir + "/" + domain + ".key"
            var error = [CChar](repeating: 0, count: 256)
            let made = domain.withCString { d in
                (token + "." + client.thumbprint).withCString { ka in
                    certPath.withCString { c in
                        keyPath.withCString { k in
                            av_acme_alpn_cert(d, ka, c, k, &error, 256)
                        }
                    }
                }
            }
            guard made == 0 else {
                acmeLog(.error, "", acmeText(error))
                return false
            }
            written.append(certPath)
            written.append(keyPath)

            // The challenge is only answered once it is on disk for every
            // worker to find; telling the CA to look before that would fail it.
            guard let accepted = client.post(challengeURL, payload: "{}"),
                  accepted.status == 200 else {
                acmeLog(.error, "the challenge was refused: ", domain)
                return false
            }
            guard client.poll(authURL, until: "valid") != nil else {
                acmeLog(.error, "validation failed for ", domain)
                return false
            }
            acmeLog(.info, "validated ", domain)
        }

        // The key is written beside the live one and swapped in only with the
        // certificate that matches it: a worker restarted in between must find
        // a pair, not a new key and an old certificate.
        let newKey = settings.keyPath + ".new"
        let newCert = settings.certPath + ".new"
        var csr = [CChar](repeating: 0, count: 8192)
        var error = [CChar](repeating: 0, count: 256)
        let csrLength = settings.names.withCString { n in
            newKey.withCString { k in av_acme_csr(n, k, &csr, 8192, &error, 256) }
        }
        guard csrLength > 0 else {
            acmeLog(.error, "", acmeText(error))
            return false
        }
        guard let finalized = client.post(finalizeURL,
                                          payload: "{\"csr\":\"" + acmeText(csr) + "\"}"),
              finalized.status == 200 else {
            acmeLog(.error, "finalizing the order failed", "")
            return false
        }
        guard let done = client.poll(orderURL, until: "valid"),
              let certificateURL = done["certificate"]?.string else {
            acmeLog(.error, "the order never completed", "")
            return false
        }
        guard let certificate = client.post(certificateURL, payload: nil,
                                            accept: "application/pem-certificate-chain"),
              certificate.status == 200, !certificate.body.isEmpty else {
            acmeLog(.error, "cannot download the certificate", "")
            return false
        }

        let wroteCert = newCert.withCString { path in
            certificate.body.withUnsafeBufferPointer {
                av_acme_write_file(path, $0.baseAddress, $0.count, 0o644)
            }
        }
        guard wroteCert == 0,
              newKey.withCString({ n in settings.keyPath.withCString { av_acme_rename(n, $0) } }) == 0,
              newCert.withCString({ n in settings.certPath.withCString { av_acme_rename(n, $0) } }) == 0
        else {
            acmeLog(.error, "cannot install the certificate in ", settings.cacheDir)
            return false
        }
        acmeLog(.info, "certificate installed for ", settings.names)
        return true
    }
}

//===----------------------------------------------------------------------===//
// What the HTTP client does around one exchange: follow the redirects its
// policy allows, and decode the body the server compressed.
//
//     var client = request.client
//     client.redirects = .sameOrigin()
//     let answer = try await client.get("https://api.example.com/v1/report")
//     answer.url   // where it ended up
//
// A redirect is followed the way browsers do: 303 turns any method but HEAD
// into a GET without a body, and so do 301 and 302 after a POST; 307 and 308
// repeat the request as it was. Leaving the origin drops Authorization, Cookie
// and Proxy-Authorization, which were meant for the server that was asked. A
// redirect from https to http is never followed, whatever the policy. One the
// policy does not allow is returned as the response, for the caller to read;
// one too many is `tooManyRedirects`.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

/// Which redirects an `HTTPClient` follows.
public struct RedirectPolicy: Sendable {
    /// How many redirects in a row may be followed.
    public let limit: Int
    let allows: @Sendable (_ from: ClientOrigin, _ to: ClientOrigin, _ url: String) -> Bool

    /// Follows none: a 3xx is the response.
    public static let none = RedirectPolicy(limit: 0) { _, _, _ in false }

    /// Follows redirects that stay on the scheme, host and port asked for.
    public static func sameOrigin(limit: Int = 10) -> RedirectPolicy {
        RedirectPolicy(limit: limit) { from, to, _ in from == to }
    }

    /// Follows redirects anywhere over http or https.
    public static func any(limit: Int = 10) -> RedirectPolicy {
        RedirectPolicy(limit: limit) { _, _, _ in true }
    }

    /// Follows the redirects `allow` says yes to, given the absolute URL.
    public static func matching(limit: Int = 10,
                                _ allow: @escaping @Sendable (_ url: String) -> Bool) -> RedirectPolicy {
        RedirectPolicy(limit: limit) { _, _, url in allow(url) }
    }
}

/// The scheme, host and port of a URL.
public struct ClientOrigin: Sendable, Equatable {
    public let secure: Bool
    public let host: String
    public let port: UInt16

    init?(_ url: String) {
        var bytes = Array(url.utf8)
        guard !bytes.isEmpty else { return nil }
        let parsed: (Bool, String, UInt16)? = bytes.withUnsafeMutableBufferPointer { buffer in
            let base = UnsafePointer(buffer.baseAddress!)
            guard let url = try? HTTPURL.parse(base, buffer.count) else { return nil }
            let host = String(decoding: UnsafeBufferPointer(start: base + Int(url.host.offset),
                                                            count: url.host.count), as: UTF8.self)
            return (url.scheme.isSecure, host.lowercased(), url.port)
        }
        guard let (secure, host, port) = parsed else { return nil }
        self.secure = secure
        self.host = host
        self.port = port
    }
}

extension HTTPClient {
    /// One request: the exchange, the redirects `redirects` allows, and the
    /// body decoded when `decompress` asked for it.
    public func send(_ method: HTTPMethod, _ url: String,
                     headers: [(String, String)] = [],
                     body: [UInt8] = []) async throws(ClientError) -> ClientResponse {
        // The whole of it, redirects included, inside one budget if there is
        // one: the deadline is set once, here, and every wait below reads it.
        let client = startingExchange()
        var method = method
        var url = url
        var headers = headers
        var body = body
        var followed = 0
        while true {
            let response = try await client.exchange(method, url, headers: headers, body: body)
            guard let next = client.redirect(response.status, response.header("location"), from: url) else {
                var answer = try client.decoded(response)
                answer.url = url
                return answer
            }
            guard followed < redirects.limit else { throw .tooManyRedirects }
            followed += 1
            client.follow(response.status, to: next, from: url, &method, &headers, &body)
            url = next
        }
    }

    /// Sends a request and returns as soon as the response head is in, with
    /// the body still to be read from the result as it arrives.
    ///
    ///     let upstream = try await request.client.stream(.get, "https://api.example.com/events")
    ///     while let event = try await upstream.nextEvent() { ... }
    ///
    /// For what should not be held whole: a large file relayed on, an
    /// upstream's server-sent events, a model's tokens as they are produced.
    /// A body read this way is not held to `maxBodyBytes`, and waits on the
    /// connection rather than filling memory when the caller stops reading.
    ///
    /// The body comes as the server sent it: no compression is asked for,
    /// and a caller that sends its own `Accept-Encoding` gets what the server
    /// encoded, with its Content-Encoding, which is what a relay wants.
    /// Redirects are followed as `redirects` allows. `totalTimeoutMilliseconds`
    /// bounds everything up to the head.
    public func stream(_ method: HTTPMethod = .get, _ url: String,
                       headers: [(String, String)] = [],
                       body: [UInt8] = []) async throws(ClientError) -> ClientResponseStream {
        var client = startingExchange()
        client.decompress = false
        var method = method
        var url = url
        var headers = headers
        var body = body
        var followed = 0
        while true {
            let started = try await client.start(method, url, headers: headers, body: body, streaming: true)
            let response = ClientResponseStream(client, started, url: url)
            guard let next = client.redirect(response.status, response.header("location"), from: url) else {
                // The budget was for getting here. The body is read for as
                // long as the caller wants it, a wait at a time.
                response.startReading()
                return response
            }
            // A redirect's own body is short, and reading it keeps the
            // connection for the request it points at.
            if (try? await response.collect(limit: maxBodyBytes)) == nil { response.cancel() }
            guard followed < redirects.limit else { throw .tooManyRedirects }
            followed += 1
            client.follow(response.status, to: next, from: url, &method, &headers, &body)
            url = next
        }
    }

    /// What following a redirect does to the request: 303 turns any method
    /// but HEAD into a GET without a body, as 301 and 302 do after a POST, and
    /// leaving the origin drops the credentials meant for the one asked.
    func follow(_ status: Int, to next: String, from url: String,
                _ method: inout HTTPMethod, _ headers: inout [(String, String)], _ body: inout [UInt8]) {
        if (status == 303 && method != .head) || ((status == 301 || status == 302) && method == .post) {
            method = .get
            body = []
            headers.removeAll { named($0.0, "content-type") || named($0.0, "content-length") }
        }
        if ClientOrigin(next) != ClientOrigin(url) {
            headers.removeAll {
                named($0.0, "authorization") || named($0.0, "cookie") || named($0.0, "proxy-authorization")
            }
        }
    }

    /// Where `response` redirects to, when it is a redirect the policy allows.
    func redirect(_ response: ClientResponse, from url: String) -> String? {
        redirect(response.status, response.header("location"), from: url)
    }

    /// Where a response redirects to, when it is a redirect the policy allows.
    func redirect(_ status: Int, _ location: String?, from url: String) -> String? {
        guard redirects.limit > 0, [301, 302, 303, 307, 308].contains(status),
              let location,
              let next = resolveReference(location, against: url),
              let from = ClientOrigin(url), let to = ClientOrigin(next) else { return nil }
        if from.secure && !to.secure { return nil }
        return redirects.allows(from, to, next) ? next : nil
    }

    /// `response` with its body decoded, when this client asked for a coding
    /// and the server used one it can decode. A coding it cannot decode is
    /// left as it came, header and all.
    func decoded(_ response: ClientResponse) throws(ClientError) -> ClientResponse {
        guard decompress, !response.body.isEmpty,
              let coding = response.header("content-encoding"),
              ContentDecoder.canDecode(coding) else { return response }
        let body: [UInt8]
        do {
            body = try ContentDecoder.decode(response.body, contentEncoding: coding, limit: maxBodyBytes)
        } catch {
            throw error == .tooLarge ? .bodyTooLarge : .undecodableBody
        }
        let headers = response.headers.filter {
            !named($0.name, "content-encoding") && !named($0.name, "content-length")
        }
        return ClientResponse(status: response.status, reason: response.reason, headers: headers,
                              body: body, reusedConnection: response.reusedConnection)
    }
}

private func named(_ name: String, _ lowercase: String) -> Bool {
    name.utf8.count == lowercase.utf8.count && name.lowercased() == lowercase
}

/// `reference`, a Location value, made absolute against the http or https
/// URL `base` (RFC 3986 section 5.2). Nil for another scheme. The fragment is
/// dropped: it never goes to a server.
func resolveReference(_ reference: String, against base: String) -> String? {
    var reference = Substring(reference)
    while reference.first == " " || reference.first == "\t" { reference.removeFirst() }
    while reference.last == " " || reference.last == "\t" { reference.removeLast() }
    if let hash = reference.firstIndex(of: "#") { reference = reference[..<hash] }

    guard let colon = base.firstIndex(of: ":") else { return nil }
    let scheme = base[..<colon].lowercased()
    let afterColon = base[base.index(after: colon)...]
    guard afterColon.hasPrefix("//") else { return nil }
    let afterScheme = afterColon.dropFirst(2)
    let authorityEnd = afterScheme.firstIndex(where: isAuthorityEnd) ?? afterScheme.endIndex
    let authority = String(afterScheme[..<authorityEnd])
    var rest = String(afterScheme[authorityEnd...])
    if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
    let basePath = String(rest.prefix { $0 != "?" })
    let path = basePath.isEmpty ? "/" : basePath

    // A reference with a scheme of its own.
    if let colon = reference.firstIndex(of: ":"),
       let first = reference.first, first.isLetter,
       reference[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
        let own = reference[..<colon].lowercased()
        guard own == "http" || own == "https" else { return nil }
        let tail = reference[reference.index(after: colon)...]
        guard tail.hasPrefix("//") else { return nil }
        return own + ":" + tail
    }
    if reference.hasPrefix("//") { return scheme + ":" + reference }

    let origin: String = scheme + "://" + authority
    if reference.isEmpty { return origin + rest }
    if reference.hasPrefix("/") { return origin + normalized(String(reference)) }
    if reference.hasPrefix("?") { return origin + path + String(reference) }
    let slash = path.lastIndex(of: "/") ?? path.startIndex
    let directory = String(path[...slash])
    return origin + normalized(directory + String(reference))
}

private func isAuthorityEnd(_ c: Character) -> Bool {
    c == "/" || c == "?" || c == "#"
}

/// The path of `target` with `.` and `..` segments removed, its query kept.
private func normalized(_ target: String) -> String {
    let query = target.firstIndex(of: "?")
    let path = query.map { target[..<$0] } ?? target[...]
    var output: [Substring] = []
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    for (i, segment) in segments.enumerated() {
        let last = i == segments.count - 1
        switch segment {
        case ".":
            if last { output.append("") }
        case "..":
            if !output.isEmpty { output.removeLast() }
            if last { output.append("") }
        default:
            output.append(Substring(segment))
        }
    }
    return "/" + output.joined(separator: "/") + (query.map { String(target[$0...]) } ?? "")
}

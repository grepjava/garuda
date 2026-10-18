//===----------------------------------------------------------------------===//
// The HTTP client: one exchange over a connection it made or kept.
//
//     let answer = try await HTTPClient().get("https://example.com/status")
//
// The three pieces in GarudaWire -- the URL splitter, the request writer and
// the response parser -- each do one thing and none of them touches a socket.
// This is what puts them together: parse a URL, open or reuse a connection,
// write a request, read a response, and decide whether what is left is fit
// to hand to the next caller.
//
// That last decision is the one that matters. A connection goes back to the
// pool only when the response was read whole and both ends still mean to keep
// it; anything else is closed. A connection handed back with bytes still on it
// gives the next caller somebody else's response, and the failure surfaces as
// one request answering another -- far from here, and looking nothing like a
// pooling bug.
//
// Around the exchange (HTTPClientRedirects.swift):
//
//   * Redirects are followed only as `redirects` allows, and not at all by
//     default. A redirect chosen by the peer is a request to somewhere this
//     process did not choose, and following one by default is how a client
//     reaches 169.254.169.254 on somebody else's say-so.
//   * Accept-Encoding names what this process can decode, and the body is
//     decoded before it is returned, unless `decompress` is off.
//   * Over TLS, ALPN offers h2 and http/1.1, and an HTTP/2 connection is
//     shared by every request to the same origin (HTTP2Client.swift).
//
// A client is a value, made where it is needed; what it shares -- the kept
// connections -- belongs to the process (HTTPClientConnections.swift).
//===----------------------------------------------------------------------===//

import VegaWire
import GarudaWire
import Vega

/// Why an exchange did not finish.
public enum ClientError: Error, Equatable {
    /// The URL could not be read. Carries what was wrong with it.
    case url(HTTPURLError)
    /// The connection could not be made.
    case connect(OutboundError)
    /// A header this client owns, or one that could split the request. The
    /// writer refused it and nothing was sent.
    case refusedHeader
    /// The peer went away part way through. Distinct from `connect`: the
    /// connection was fine and then stopped, which usually means the far
    /// end decided something about this request.
    case closed
    /// What came back was not a response this can frame. Carries the parser's
    /// reason, which is the same set of reasons the server refuses a request
    /// for.
    case malformedResponse(HTTPParseError)
    /// The response head was larger than `maxHeadBytes`.
    case headTooLarge
    /// The response body was larger than `maxBodyBytes`. The connection is
    /// closed rather than kept: what is left on it is the rest of a body
    /// nobody is going to read.
    case bodyTooLarge
    /// It did not finish inside the time allowed.
    case timedOut
    /// The body was not what its Content-Encoding said: corrupt, or cut
    /// short.
    case undecodableBody
    /// More redirects in a row than `redirects` allows.
    case tooManyRedirects
    /// The task that made the request was cancelled.
    case cancelled
    /// The peer broke HTTP/2 framing: a frame longer than was agreed, a header
    /// block interleaved with another frame, a stream identifier for a stream
    /// this client never opened, a push it was told not to send.
    case protocolError
    /// The peer reset this stream, or went away without answering it. Carries
    /// its error code, which is the only thing it said about why.
    case streamReset(UInt32)

    /// A wait that failed: out of time, cancelled, or the connection gone.
    init(_ error: IOError) {
        if error == .timedOut { self = .timedOut }
        else if error == .cancelled { self = .cancelled }
        else { self = .closed }
    }

    /// The case alone, without what it carries: `error.type` on a span is
    /// meant to be one of a few values, not a message.
    var kind: String {
        String(String(describing: self).prefix { $0 != "(" })
    }
}

public struct ClientHeader: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A response, owned. Every byte is copied out of the connection's buffer
/// before this is returned, because the buffer is reused and the caller
/// keeps this.
public struct ClientResponse: Sendable {
    public let status: Int
    /// The reason phrase, which a server may legitimately leave empty, and
    /// HTTP/2 does not have.
    public let reason: String
    public let headers: [ClientHeader]
    public let body: [UInt8]
    /// Whether the connection was fit to keep. False says nothing about
    /// whether the response is good -- only that this one is not coming back.
    public let reusedConnection: Bool
    /// The URL this response answered: the one asked for, or where the
    /// redirects followed led.
    public internal(set) var url: String = ""

    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The first value of `name`, compared without regard to case.
    public func header(_ name: String) -> String? {
        headers.first { named($0.name, name) }?.value
    }
}

/// Makes HTTP requests, from a handler or anywhere else on a Vega runtime.
///
///     var client = HTTPClient()
///     client.timeout = .seconds(2)
///     let answer = try await client.get("https://api.example.com/v1/rates")
public struct HTTPClient: Sendable {
    /// How long any one wait may take: connecting, writing, or waiting for
    /// more of a response. A peer that answers slowly but steadily is never
    /// cut off by this; `totalTimeout` is what bounds the whole.
    public var timeout: Duration = .seconds(10)
    /// How long the whole exchange may take, redirects included: the lookup,
    /// connecting, writing the request and reading the response to its end.
    /// For `stream`, everything up to the response head, after which each
    /// read of the body is bounded by `timeout` alone -- a stream may rightly
    /// run for as long as the caller keeps reading it. Nil, the default,
    /// sets no budget beyond the per-wait one.
    ///
    /// A route's deadline (`app.deadline`) bounds a call made in its handler
    /// whatever this says.
    public var totalTimeout: Duration? = nil
    public var maxHeadBytes: Int = 32 * 1024
    public var maxBodyBytes: Int = 8 * 1024 * 1024
    public var maxHeaders: Int = 100
    /// A trust store for https, as a PEM file. Empty means the system's.
    public var caFile: String = ""
    /// What to offer over ALPN on an encrypted connection, most preferred
    /// first. The server chooses, and the client speaks whichever it chose.
    /// Plaintext is always HTTP/1.1 -- there is no ALPN without TLS, and
    /// sending the HTTP/2 preface to a server that never agreed to it reads
    /// there as a malformed request.
    var alpn: [String] = ["h2", "http/1.1"]
    /// Sent unless the caller sets its own.
    public var userAgent: String = "garuda"
    /// Asks for compressed responses with the codings this process can
    /// decode, and decodes the body before returning it, removing
    /// Content-Encoding and Content-Length. The decoded body is held to
    /// `maxBodyBytes` too. Off, the caller may send its own Accept-Encoding
    /// and gets the body as it came.
    public var decompress = true
    /// Which redirects to follow. None by default.
    public var redirects: RedirectPolicy = .none
    /// Speak HTTP/2 whatever ALPN said, including on a plaintext connection.
    ///
    /// Internal, and only for tests: without it every test of the frame loop
    /// would also be a test of TLS. This is not RFC 9113's prior-knowledge
    /// mode: nothing negotiates, and pointing it at an ordinary HTTP/1.1
    /// server sends a preface that server will read as a malformed request.
    var forceHTTP2 = false
    /// When the exchange under way must be over, or nil for no deadline
    /// beyond each wait's own. Set from `totalTimeout` when an exchange
    /// starts.
    var deadline: ContinuousClock.Instant? = nil

    public init() {}

    /// This client with the deadline for one exchange set, if it has a total.
    func startingExchange() -> HTTPClient {
        guard let totalTimeout else { return self }
        var started = self
        started.deadline = .now + max(totalTimeout, .milliseconds(1))
        return started
    }

    /// When the next wait gives up: `timeout` from now, or the exchange's
    /// deadline if that is sooner. `timedOut` once the deadline has passed.
    func waitDeadline() throws(ClientError) -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let own = now + timeout
        guard let deadline else { return own }
        guard now < deadline else { throw .timedOut }
        return min(own, deadline)
    }

    /// One wait on a connection, bounded as `waitDeadline` says.
    func waiting<T>(_ body: () async throws(IOError) -> T) async throws(ClientError) -> T {
        let until = try waitDeadline()
        do {
            return try await Runtime.withIOTimeout(until: until, body)
        } catch {
            throw ClientError(error)
        }
    }
}

extension HTTPClient {

    public func get(_ url: String,
                    headers: [(String, String)] = []) async throws(ClientError) -> ClientResponse {
        try await send(.get, url, headers: headers)
    }

    public func head(_ url: String,
                     headers: [(String, String)] = []) async throws(ClientError) -> ClientResponse {
        try await send(.head, url, headers: headers)
    }

    public func post(_ url: String, body: [UInt8], contentType: String,
                     headers: [(String, String)] = []) async throws(ClientError) -> ClientResponse {
        var all = headers
        all.append(("Content-Type", contentType))
        return try await send(.post, url, headers: all, body: body)
    }

    /// One exchange, as it goes over the wire: no redirect followed and no
    /// body decoded.
    func exchange(_ method: HTTPMethod, _ url: String,
                  headers: [(String, String)],
                  body: [UInt8]) async throws(ClientError) -> ClientResponse {
        switch try await start(method, url, headers: headers, body: body, streaming: false) {
        case .h1(let head, let rest):
            return try await readWhole(head, rest)
        case .h2(let shared, let stream):
            return try await finishShared(shared, stream)
        }
    }

    /// Where a response's body is to be read from, once its head is in.
    enum Started {
        case h1(ClientHead, H1Body)
        case h2(H2Shared, ClientH2Stream)
    }

    /// Writes the request and reads up to the final response's head.
    /// `streaming` is for a body the caller reads as it arrives: over HTTP/2
    /// its window is then opened only as the caller takes what came.
    ///
    /// A stream refused -- a shared connection that filled or was told to go
    /// away while this waited for it, or REFUSED_STREAM, which RFC 9113
    /// section 8.7 promises was never looked at -- is tried again, twice.
    func start(_ method: HTTPMethod, _ url: String,
               headers: [(String, String)],
               body: [UInt8], streaming: Bool) async throws(ClientError) -> Started {
        var tries = 0
        while true {
            do {
                return try await startOnce(method, url, headers: headers, body: body, streaming: streaming)
            } catch .streamReset(HTTP2ErrorCode.refusedStream.rawValue) where tries < 2 {
                tries += 1
            }
        }
    }

    private func startOnce(_ method: HTTPMethod, _ url: String,
                           headers: [(String, String)],
                           body: [UInt8], streaming: Bool) async throws(ClientError) -> Started {
        var request = ByteBuffer(capacity: 512)
        defer { request.destroy() }
        let plan = try buildHead(method, url, headers: headers, body: body, into: &request)

        let mayUseHTTP2 = forceHTTP2 || (plan.secure && alpn.contains("h2"))
        let key = OriginKey(host: plan.host, port: plan.port,
                            tls: plan.secure ? caFile + "\u{0}" + alpn.joined(separator: ",")
                                 : forceHTTP2 ? "\u{0}h2c" : "")
        // An HTTP/2 connection open to this place takes the request as one
        // more stream, before a lookup or a connect is paid for; one being
        // opened is waited for rather than opened twice.
        var connecting = false
        if mayUseHTTP2 {
            switch try await H2Registry.shared.find(key, client: self) {
            case .shared(let shared):
                let block = try encodeRequestBlock(plan, method: method, headers: headers, hasBody: !body.isEmpty)
                return .h2(shared, try await openShared(shared, block: block, method: method,
                                                        body: body, streaming: streaming))
            case .connect:
                // This request opens it, and the others to the same place
                // wait to see what it comes up as.
                connecting = true
            case .http1:
                break
            }
        }

        // A kept HTTP/1.1 connection, or a new one.
        let connection: ClientConnection
        if let kept = ClientConnections.shared.take(key) {
            if connecting { H2Registry.shared.speaksHTTP1(key) }
            connection = kept
        } else {
            let connected: Connected
            let until: ContinuousClock.Instant
            do {
                until = try waitDeadline()
            } catch {
                if connecting { H2Registry.shared.connectFailed(key) }
                throw error
            }
            do throws(OutboundError) {
                connected = try await ClientConnections.shared.connect(
                    host: plan.host, port: plan.port, secure: plan.secure, caFile: caFile,
                    alpn: alpn, forceHTTP2: forceHTTP2, key: key, deadline: until)
            } catch {
                if connecting { H2Registry.shared.connectFailed(key) }
                // The deadline passing during the connect is the exchange
                // timing out, not the connection failing.
                if let deadline, ContinuousClock.now >= deadline { throw .timedOut }
                throw .connect(error)
            }
            switch connected {
            case .http1(let made):
                // HTTP/1.1 after all: what ALPN said is remembered, and anyone
                // who waited connects for themselves.
                if connecting { H2Registry.shared.speaksHTTP1(key) }
                connection = made
            case .http2(let reader, let writer):
                // What was agreed, not what was asked for. Kept from here on,
                // for every request to the same place, before this request's
                // fields are checked: a field that cannot be sent is this
                // request's problem, not the connection's.
                let shared = try await startShared(reader, writer, key)
                let block = try encodeRequestBlock(plan, method: method, headers: headers, hasBody: !body.isEmpty)
                return .h2(shared, try await openShared(shared, block: block, method: method,
                                                        body: body, streaming: streaming))
            }
        }

        // The body goes behind the head, in one write. Dropped on failure:
        // nothing about a failed exchange says the connection is clean, and
        // one that is not must not be kept.
        if !body.isEmpty {
            body.withUnsafeBufferPointer { request.write($0.baseAddress!, $0.count) }
        }
        try await writeAll(connection, UnsafeRawBufferPointer(start: request.readPointer, count: request.readableBytes))
        let head = try await readHead(connection, method: method)
        return .h1(head.head, H1Body(connection, framing: head.framing, keepAlive: head.keepAlive))
    }

    /// What the head, once built, says about where it goes.
    struct Plan {
        var host: String
        var port: UInt16
        var secure: Bool
        /// host[:port] as it belongs in a Host field or an `:authority`.
        var authority: String
        /// The request-target, with its leading slash already supplied.
        var target: String
        /// How many bytes of body follow, for the `content-length` HTTP/2
        /// states in a field rather than in framing.
        var bodyLength: Int
    }

    // MARK: Building the head

    private func buildHead(_ method: HTTPMethod, _ url: String,
                           headers: [(String, String)], body: [UInt8],
                           into head: inout ByteBuffer) throws(ClientError) -> Plan {
        var urlBytes = Array(url.utf8)
        if urlBytes.isEmpty { throw .url(.scheme) }
        let count = urlBytes.count
        urlBytes.append(0)
        // Everything the parser produces is a slice into the URL's bytes, so
        // the head is built while they are held, and what is kept is copied.
        let outcome: Result<Plan, ClientError> = urlBytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let parsed: HTTPURL
            do throws(HTTPURLError) {
                parsed = try HTTPURL.parse(base, count)
            } catch {
                return .failure(.url(error))
            }

            // The request-target. A URL with no path asks for the root, and
            // that slash is not in the caller's bytes to point at.
            var target: [UInt8] = parsed.needsLeadingSlash ? [UInt8(ascii: "/")] : []
            target.append(contentsOf: UnsafeBufferPointer(
                start: base + Int(parsed.target.offset), count: parsed.target.count))

            let wrote = target.withUnsafeBufferPointer { t in
                HTTPRequestWriter.writeRequestLine(&head, method: method, target: ByteSpan(t.baseAddress!, t.count))
            }
            guard wrote else { return .failure(.refusedHeader) }
            guard HTTPRequestWriter.writeHost(&head, parsed.hostForField.span(in: base)) else {
                return .failure(.refusedHeader)
            }

            var sawUserAgent = false
            for (name, value) in headers {
                let nameBytes = Array(name.utf8)
                let valueBytes = Array(value.utf8)
                let allowed = nameBytes.withUnsafeBufferPointer { n -> Bool in
                    valueBytes.withUnsafeBufferPointer { v -> Bool in
                        guard let np = n.baseAddress else { return false }
                        let field = ByteSpan(np, n.count)
                        let kind = HTTPRequestWriter.classify(field)
                        // Two this client refuses beyond the ones the writer
                        // owns, and both because it would be promising
                        // something it does not do: with `decompress` on it
                        // names the codings itself and decodes only those, and
                        // it does not wait for a 100 before sending a body.
                        if (decompress && kind.contains(.acceptEncoding)) || kind.contains(.expect) {
                            return false
                        }
                        if kind.contains(.userAgent) { sawUserAgent = true }
                        let empty: StaticString = ""
                        let vp = v.baseAddress ?? empty.utf8Start
                        return HTTPRequestWriter.writeUserHeader(&head, name: field, value: ByteSpan(vp, v.count))
                    }
                }
                guard allowed else { return .failure(.refusedHeader) }
            }

            if decompress {
                guard writeField(&head, "Accept-Encoding", RequestDecoder.acceptEncoding) else {
                    return .failure(.refusedHeader)
                }
            }
            if !sawUserAgent, !userAgent.isEmpty {
                guard writeField(&head, "User-Agent", userAgent) else { return .failure(.refusedHeader) }
            }

            // Always stated, even at zero. A POST with no Content-Length and
            // no chunked framing is a request the peer has to guess the end
            // of, and some read it as running until close.
            if !body.isEmpty || method == .post || method == .put || method == .patch {
                HTTPRequestWriter.writeContentLength(&head, body.count)
            }
            HTTPRequestWriter.writeConnection(&head, keepAlive: true)
            HTTPRequestWriter.endHead(&head)

            let host = String(decoding: UnsafeBufferPointer(
                start: base + Int(parsed.host.offset), count: parsed.host.count), as: UTF8.self)
            let authority = String(decoding: UnsafeBufferPointer(
                start: base + Int(parsed.hostForField.offset), count: parsed.hostForField.count), as: UTF8.self)
            return .success(Plan(host: host, port: parsed.port, secure: parsed.scheme.isSecure,
                                 authority: authority, target: String(decoding: target, as: UTF8.self),
                                 bodyLength: body.count))
        }
        return try outcome.get()
    }

    private func writeField(_ head: inout ByteBuffer, _ name: StaticString, _ value: String) -> Bool {
        var value = value
        return value.withUTF8 { v in
            HTTPRequestWriter.writeHeader(&head, name: ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                          value: ByteSpan(v.baseAddress ?? name.utf8Start, v.count))
        }
    }

    // MARK: Writing and reading

    func writeAll(_ connection: ClientConnection, _ bytes: UnsafeRawBufferPointer) async throws(ClientError) {
        guard bytes.count > 0 else { return }
        try await waiting { () async throws(IOError) in try await connection.transport.write(bytes) }
    }

    /// Waits for more on `connection` and takes it. A peer that closes is
    /// `.closed`, which the close-delimited path treats as the end of the
    /// body and every other path as the peer giving up part way through.
    func readMore(_ connection: ClientConnection) async throws(ClientError) {
        let n = try await waiting { () async throws(IOError) -> Int in try await connection.readMore() }
        if n == 0 { throw .closed }
    }

    /// The rest of the response, read whole and held to `maxBodyBytes`.
    private func readWhole(_ head: ClientHead, _ body: H1Body) async throws(ClientError) -> ClientResponse {
        if case .length(let wanted) = body.framing, wanted > maxBodyBytes {
            body.close()
            throw .bodyTooLarge
        }
        var bytes: [UInt8] = []
        if case .length(let wanted) = body.framing { bytes.reserveCapacity(wanted) }
        while let piece = try await body.next(self) {
            if bytes.count + piece.count > maxBodyBytes {
                body.close()
                throw .bodyTooLarge
            }
            bytes.append(contentsOf: piece)
        }
        return ClientResponse(status: head.status, reason: head.reason, headers: head.headers,
                              body: bytes, reusedConnection: body.reused)
    }

    /// A final response's head, as `readHead` read it.
    struct ReadHead {
        var head: ClientHead
        var framing: HTTPBodyFraming
        var keepAlive: Bool
    }

    /// Reads up to the end of the final response's head, leaving whatever of
    /// the body came with it in the connection's input.
    func readHead(_ connection: ClientConnection, method: HTTPMethod) async throws(ClientError) -> ReadHead {
        let fields = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: max(1, maxHeaders))
        defer { fields.deallocate() }
        // An informational response is a response, and then the real one
        // follows on the same connection. Reading one as final would leave
        // its successor sitting in the buffer to be read as a body.
        while true {
            var head = HTTPResponseHead()
            let outcome = connection.input.withUnsafeBytes { raw -> HTTPParseResult in
                guard raw.count > 0 else { return .incomplete }
                return HTTPResponseParser.parse(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                                                maxHeadSize: maxHeadBytes, maxHeaders: maxHeaders,
                                                headers: fields, head: &head)
            }
            switch outcome {
            case .incomplete:
                // The parser takes a head that never ends to `maxHeadBytes`
                // and no further.
                try await readMore(connection)
                continue
            case .failure(let error):
                throw error == .headTooLarge ? .headTooLarge : .malformedResponse(error)
            case .complete:
                break
            }
            if head.status >= 100 && head.status < 200 && head.status != 101 {
                connection.input.consume(head.headEnd)
                continue
            }
            let read = connection.input.withUnsafeBytes { raw -> ClientHead in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                func text(_ slice: HTTPSlice) -> String {
                    String(decoding: UnsafeBufferPointer(start: base + Int(slice.offset), count: slice.count), as: UTF8.self)
                }
                var headers: [ClientHeader] = []
                headers.reserveCapacity(head.headerCount)
                for i in 0..<head.headerCount {
                    headers.append(ClientHeader(name: text(fields[i].name), value: text(fields[i].value)))
                }
                return ClientHead(status: head.status, reason: text(head.reason), headers: headers)
            }
            connection.input.consume(head.headEnd)
            return ReadHead(head: read, framing: head.framing(method: method), keepAlive: head.keepAlive)
        }
    }
}

/// A response's status line and fields, before its body.
struct ClientHead {
    var status: Int
    var reason: String
    var headers: [ClientHeader]
}

/// A response body on an HTTP/1.1 connection, read as it arrives.
///
/// The connection is this body's until it ends: once the last byte is read it
/// goes back to be kept if both ends mean to keep it and nothing is left on
/// it, and is closed otherwise. A body given up on part way is closed, since
/// what is left on the connection is the rest of it.
final class H1Body: @unchecked Sendable {
    private var connection: ClientConnection?
    let framing: HTTPBodyFraming
    private var remaining = 0
    private var decoder = ChunkedDecoder()
    private var keepAlive: Bool
    private var finished = false
    /// Whether the connection went back to be kept.
    private(set) var reused = false

    init(_ connection: ClientConnection, framing: HTTPBodyFraming, keepAlive: Bool) {
        self.connection = connection
        self.framing = framing
        self.keepAlive = keepAlive
        if case .length(let wanted) = framing { remaining = wanted }
    }

    /// The next piece of the body, never empty, or nil once it has ended.
    func next(_ client: HTTPClient) async throws(ClientError) -> [UInt8]? {
        do throws(ClientError) {
            return try await read(client)
        } catch {
            close()
            throw error
        }
    }

    private func read(_ client: HTTPClient) async throws(ClientError) -> [UInt8]? {
        guard let connection else { return nil }
        while !finished {
            switch framing {
            case .none:
                finished = true

            case .length:
                if remaining == 0 {
                    finished = true
                    continue
                }
                if connection.input.count == 0 { try await client.readMore(connection) }
                let take = min(remaining, connection.input.count)
                let piece = connection.input.withUnsafeBytes { Array($0[0..<take]) }
                connection.input.consume(take)
                remaining -= take
                // Settled as soon as the last byte is in, so the connection
                // is kept whether or not the caller asks again.
                if remaining == 0 {
                    finished = true
                    settle()
                }
                return piece

            case .chunked:
                if connection.input.count == 0 { try await client.readMore(connection) }
                var consumed = 0
                var piece: [UInt8] = []
                let outcome = connection.input.withUnsafeBytes { raw in
                    decoder.decode(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                                   consumed: &consumed) { p, n in
                        piece.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
                    }
                }
                connection.input.consume(consumed)
                switch outcome {
                case .needMore:
                    // A chunk's size line split across reads is left whole
                    // for the next one.
                    if consumed == 0 && piece.isEmpty { try await client.readMore(connection) }
                case .finished:
                    finished = true
                    settle()
                case .failure(let error):
                    throw .malformedResponse(error)
                }
                if !piece.isEmpty { return piece }

            case .untilClose:
                // The body ends when the connection does, so reading it to the
                // end is the same act as making the connection unusable.
                keepAlive = false
                if connection.input.count > 0 {
                    let piece = connection.input.withUnsafeBytes { Array($0) }
                    connection.input.consume(piece.count)
                    return piece
                }
                do {
                    try await client.readMore(connection)
                } catch .closed {
                    finished = true
                }
            }
        }
        settle()
        return nil
    }

    /// Keeps the connection, or closes it. Once.
    private func settle() {
        guard let connection else { return }
        self.connection = nil
        // Anything still in the buffer belongs to a message this exchange did
        // not ask for. Keeping the connection with that on it is what makes
        // the next caller read somebody else's answer.
        reused = finished && keepAlive && connection.input.count == 0
        if reused { ClientConnections.shared.give(connection) }
    }

    /// Gives up on the rest: the connection is closed, with the rest of the
    /// body on it.
    func close() {
        connection = nil
    }
}

/// Whether `name` is `wanted`, without regard to case.
func named(_ name: String, _ wanted: String) -> Bool {
    name.utf8.count == wanted.utf8.count && name.lowercased() == wanted.lowercased()
}

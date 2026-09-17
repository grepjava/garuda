//===----------------------------------------------------------------------===//
// One HTTP/1.1 exchange over a connection this worker made.
//
// The three pieces next door -- the URL splitter, the request writer and the
// response parser -- each do one thing and none of them touches a socket. This
// is what puts them together: parse a URL, open or reuse a connection, write a
// request, read a response, and decide whether what is left is fit to hand to
// the next caller.
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
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// Why an exchange did not finish.
public enum ClientError: Error, Equatable {
    /// The URL could not be read. Carries what was wrong with it.
    case url(HTTPURLError)
    /// The connection could not be made, or did not survive. Carries the
    /// reason from the layer that owns connections.
    case connect(OutboundError)
    /// A header this client owns, or one that could split the request. The
    /// writer refused it and nothing was sent.
    case refusedHeader
    /// The peer went away part way through. Distinct from `connect(.failed)`:
    /// the connection was fine and then stopped, which usually means the far
    /// end decided something about this request.
    case closed
    /// What came back was not a response this can frame. Carries the parser's
    /// reason, which is the same set of reasons the server refuses a request
    /// for.
    case malformedResponse(HTTPParseError)
    /// The response head was larger than `maxHeadBytes`.
    case headTooLarge
    /// The response body was larger than `maxBodyBytes`. The connection is
    /// closed rather than pooled: what is left on it is the rest of a body
    /// nobody is going to read.
    case bodyTooLarge
    /// It did not finish inside the time allowed.
    case timedOut
    /// The body was not what its Content-Encoding said: corrupt, or cut
    /// short.
    case undecodableBody
    /// More redirects in a row than `redirects` allows.
    case tooManyRedirects
    /// The request that wanted it ended, or the worker is shutting down.
    case cancelled
    /// The peer broke HTTP/2 framing: a frame longer than was agreed, a header
    /// block interleaved with another frame, a stream identifier for a stream
    /// this client never opened, a push it was told not to send.
    case protocolError
    /// The peer reset this stream, or went away without answering it. Carries
    /// its error code, which is the only thing it said about why.
    case streamReset(UInt32)
}

public struct ClientHeader: Sendable, Equatable {
    public let name: String
    public let value: String
}

/// A response, owned. Every byte is copied out of the connection buffer before
/// this is returned, because the buffer is reused and the caller keeps this.
public struct ClientResponse: Sendable {
    public let status: Int
    /// The reason phrase, which a server may legitimately leave empty.
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
        for field in headers where field.name.count == name.count {
            if field.name.lowercased() == name.lowercased() { return field.value }
        }
        return nil
    }
}

/// Makes requests on the worker that owns this handler.
///
/// Taken from a request *before* the first `await`: a `Request` is a view of a
/// connection slot and does not outlive a suspension, while the worker pointer
/// does.
///
///     let client = request.client
///     let answer = try await client.get("https://example.com/status")
public struct HTTPClient {
    let worker: UnsafeMutablePointer<Worker>

    /// How long any one wait may take: connecting, writing, or waiting for
    /// more of a response. Not a budget for the whole exchange -- the engine
    /// has no clock a handler can read, and a deadline set on the route is
    /// what bounds a request overall.
    public var timeoutMilliseconds: UInt64 = 10_000
    public var maxHeadBytes: Int = 32 * 1024
    public var maxBodyBytes: Int = 8 * 1024 * 1024
    public var maxHeaders: Int = 100
    /// A trust store for https. Empty means the system's.
    public var caFile: String = ""
    /// What to offer over ALPN on an encrypted connection, most preferred
    /// first. The server chooses, and the client speaks whichever it chose.
    ///
    /// HTTP/2 first now that a connection is kept and shared. Before that it
    /// would have been slower than HTTP/1.1, not faster: a pooled HTTP/1.1
    /// connection is reused, while an HTTP/2 one used once and closed costs a
    /// TLS handshake per request. Plaintext is always HTTP/1.1 -- there is no
    /// ALPN without TLS, and sending the HTTP/2 preface to a server that
    /// never agreed to it reads there as a malformed request.
    var alpn: String = "h2,http/1.1"
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
    /// Internal, and only for tests. ALPN is what chooses in production, and
    /// ALPN needs TLS -- so without this every test of the frame loop would
    /// also be a test of OpenSSL, and a framing bug would be indistinguishable
    /// from a handshake one. This is not RFC 9113's prior-knowledge mode:
    /// nothing negotiates, and pointing it at an ordinary HTTP/1.1 server
    /// sends a preface that server will read as a malformed request.
    var forceHTTP2 = false

    init(worker: UnsafeMutablePointer<Worker>) {
        self.worker = worker
    }
}

extension Request {
    /// A client on this request's worker. Read it before the first `await`.
    public var client: HTTPClient { HTTPClient(worker: worker) }
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

        // The head is built first and entirely, while the URL's bytes are
        // still alive: everything the parser produced is a slice into them.
        // Nothing here waits, so the borrow never crosses a suspension.
        var request = ByteBuffer(capacity: 512)
        let plan: Plan
        switch buildHead(method, url, headers: headers, body: body, into: &request) {
        case .failure(let error):
            request.destroy()
            throw error
        case .success(let made):
            plan = made
        }
        defer { request.destroy() }

        // An HTTP/2 connection already open to this place takes the request as
        // one more stream, before a lookup or a connect is paid for.
        let mayUseHTTP2 = forceHTTP2 || (plan.secure && offersHTTP2)
        let key = sharedKey(plan)
        var connecting = false
        if mayUseHTTP2 {
            while true {
                if let shared = reusableShared(key) {
                    let block = try encodeRequestBlock(plan, method: method, headers: headers,
                                                       hasBody: !body.isEmpty)
                    return try await exchangeShared(shared, block: block, method: method, body: body)
                }
                // Somebody is already opening one. Wait to see whether it comes
                // up as a connection this can join, rather than opening a second
                // alongside it.
                guard worker.pointee.outboundH2Connecting[key] != nil else { break }
                let worker = self.worker
                await withUnsafeContinuation { k in
                    worker.pointee.outboundH2Connecting[key]?.append(k)
                }
            }
            worker.pointee.outboundH2Connecting[key] = []
            connecting = true
        }
        // Lets the requests that waited on this connect try again. Called the
        // moment the outcome is known -- registered, failed, or HTTP/1.1 after
        // all -- and not when this request finishes, which could be long after.
        let worker = self.worker
        func doneConnecting() {
            guard connecting else { return }
            connecting = false
            let waiting = worker.pointee.outboundH2Connecting.removeValue(forKey: key) ?? []
            for k in waiting { k.resume() }
        }

        // Forced HTTP/2 knows its protocol before connecting, so a field it
        // cannot send is refused before anything is opened.
        var early: [UInt8]? = nil
        if forceHTTP2 {
            do {
                early = try encodeRequestBlock(plan, method: method, headers: headers,
                                               hasBody: !body.isEmpty)
            } catch {
                doneConnecting()
                throw error
            }
        }

        let socket: OutboundSocket
        do {
            if plan.secure {
                socket = try await Worker.connectTLS(worker, name: plan.host, port: plan.port,
                                                     caFile: caFile, alpn: alpn,
                                                     milliseconds: timeoutMilliseconds)
            } else {
                // A forced HTTP/2 connection is keyed apart from plaintext
                // HTTP/1.1, so the pool can never hand one to the other.
                socket = try await Worker.connect(worker, name: plan.host, port: plan.port,
                                                  tls: forceHTTP2 ? "\u{0}h2c" : "",
                                                  milliseconds: timeoutMilliseconds)
            }
        } catch {
            doneConnecting()
            throw .connect(error)
        }

        // What was agreed, not what was asked for. A request line written into
        // a connection the peer believes is carrying frames desynchronises it
        // immediately, so the agreement decides which of the two this is.
        if socket.isHTTP2 || forceHTTP2 {
            // Kept from here on, for every request to the same place. Kept
            // before this request's fields are checked, too: a field that
            // cannot be sent is this request's problem, not the connection's.
            let shared: H2Shared
            do {
                shared = try await startShared(socket, key)
            } catch {
                doneConnecting()
                throw error
            }
            doneConnecting()
            let block: [UInt8]
            if let early {
                block = early
            } else {
                block = try encodeRequestBlock(plan, method: method, headers: headers,
                                               hasBody: !body.isEmpty)
            }
            return try await exchangeShared(shared, block: block, method: method, body: body)
        }
        // HTTP/1.1 after all. Anyone who waited connects for themselves.
        doneConnecting()

        do {
            try await writeAll(socket, request.readPointer, request.readableBytes)
            if !body.isEmpty { try await writeAll(socket, body) }
            return try await readResponse(socket, method: method)
        } catch {
            // Nothing about a failed exchange says the connection is clean, and
            // a connection that is not clean must not be offered to anyone.
            socket.close()
            throw error
        }
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
                           into request: inout ByteBuffer) -> Result<Plan, ClientError> {
        let urlBytes = Array(url.utf8)
        let storage = urlBytes.isEmpty ? [UInt8(0)] : urlBytes
        let count = urlBytes.count

        // Built into locals and copied out: the closure may not escape the
        // borrow, and `inout` cannot cross it either.
        var head = ByteBuffer(capacity: 512)
        let outcome: Result<Plan, ClientError> = storage.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let parsed: HTTPURL
            do {
                parsed = try HTTPURL.parse(base, count)
            } catch {
                // withUnsafeBufferPointer erases the typed throw, so what
                // arrives here is `any Error` and has to be put back.
                return .failure(.url((error as? HTTPURLError) ?? .illegalByte))
            }

            // The request-target. A URL with no path asks for the root, and
            // that slash is not in the caller's bytes to point at.
            var target: [UInt8] = parsed.needsLeadingSlash ? [cSlash] : []
            target.append(contentsOf: UnsafeBufferPointer(
                start: base + Int(parsed.target.offset), count: parsed.target.count))

            let wrote = target.withUnsafeBufferPointer { t in
                HTTPRequestWriter.writeRequestLine(
                    &head, method: method, target: ByteSpan(t.baseAddress!, t.count))
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
                        guard let np = n.baseAddress, let vp = v.baseAddress else { return false }
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
                        return HTTPRequestWriter.writeUserHeader(&head, name: field,
                                                                 value: ByteSpan(vp, v.count))
                    }
                }
                guard allowed else { return .failure(.refusedHeader) }
            }

            if decompress {
                let offered = Array(ContentDecoder.acceptEncoding.utf8)
                let wrote = offered.withUnsafeBufferPointer { a -> Bool in
                    let name: StaticString = "Accept-Encoding"
                    return HTTPRequestWriter.writeHeader(
                        &head,
                        name: ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                        value: ByteSpan(a.baseAddress!, a.count))
                }
                guard wrote else { return .failure(.refusedHeader) }
            }

            if !sawUserAgent, !userAgent.isEmpty {
                let agent = Array(userAgent.utf8)
                let wrote = agent.withUnsafeBufferPointer { a -> Bool in
                    let name: StaticString = "User-Agent"
                    return HTTPRequestWriter.writeHeader(
                        &head,
                        name: ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                        value: ByteSpan(a.baseAddress!, a.count))
                }
                guard wrote else { return .failure(.refusedHeader) }
            }

            // Always stated, even at zero. A POST with no Content-Length and
            // no chunked framing is a request the peer has to guess the end
            // of, and some read it as running until close.
            if !body.isEmpty || method == .post || method == .put || method == .patch {
                HTTPRequestWriter.writeContentLength(&head, body.count)
            }
            HTTPRequestWriter.writeConnection(&head, keepAlive: true)
            HTTPRequestWriter.endHead(&head)

            // Copied out inside the borrow, while the URL's bytes are still
            // alive: everything the parser produced is a slice into them, and
            // HTTP/2 needs the same three values in a different shape.
            let host = String(decoding: UnsafeBufferPointer(
                start: base + Int(parsed.host.offset), count: parsed.host.count), as: UTF8.self)
            let authority = String(decoding: UnsafeBufferPointer(
                start: base + Int(parsed.hostForField.offset),
                count: parsed.hostForField.count), as: UTF8.self)
            return .success(Plan(host: host, port: parsed.port,
                                 secure: parsed.scheme.isSecure,
                                 authority: authority,
                                 target: String(decoding: target, as: UTF8.self),
                                 bodyLength: body.count))
        }

        switch outcome {
        case .failure(let error):
            head.destroy()
            return .failure(error)
        case .success(let plan):
            request.reserve(head.readableBytes)
            request.write(head.readPointer, head.readableBytes)
            head.destroy()
            return .success(plan)
        }
    }

    // MARK: Writing

    /// The same for bytes the caller owns.
    ///
    /// The pointer is taken afresh inside each attempt rather than once around
    /// the loop: a borrow of the array cannot cross the `await` that waits for
    /// the socket to drain, and an array is free to move while nothing holds
    /// it.
    func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8]) async throws(ClientError) {
        var sent = 0
        while sent < bytes.count {
            let n: Int
            do {
                n = try bytes.withUnsafeBufferPointer { buffer in
                    try socket.write(UnsafeRawBufferPointer(start: buffer.baseAddress! + sent,
                                                            count: buffer.count - sent))
                }
            } catch {
                // withUnsafeBufferPointer erases the typed throw, so what
                // arrives here is `any Error` and has to be put back.
                throw (error as? OutboundError) == .cancelled ? .cancelled : .closed
            }
            sent &+= n
            if sent < bytes.count {
                do {
                    try await socket.writable(milliseconds: timeoutMilliseconds)
                } catch {
                    throw error == .timedOut ? .timedOut
                        : error == .cancelled ? .cancelled : .closed
                }
            }
        }
    }

    func writeAll(_ socket: OutboundSocket,
                  _ base: UnsafePointer<UInt8>, _ count: Int) async throws(ClientError) {
        var sent = 0
        while sent < count {
            let n: Int
            do {
                n = try socket.write(UnsafeRawBufferPointer(start: base + sent, count: count - sent))
            } catch {
                throw error == .cancelled ? .cancelled : .closed
            }
            sent &+= n
            if sent < count {
                do {
                    try await socket.writable(milliseconds: timeoutMilliseconds)
                } catch {
                    throw error == .timedOut ? .timedOut
                        : error == .cancelled ? .cancelled : .closed
                }
            }
        }
    }

    // MARK: Reading

    private func readResponse(_ socket: OutboundSocket,
                              method: HTTPMethod) async throws(ClientError) -> ClientResponse {
        var buffer = ByteBuffer(capacity: 8192)
        defer { buffer.destroy() }
        let fields = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: max(1, maxHeaders))
        defer { fields.deallocate() }

        var head = HTTPResponseHead()
        var headers: [ClientHeader] = []
        var reason = ""

        // An informational response is a response, and then the real one
        // follows on the same connection. Reading one as final would leave its
        // successor sitting in the buffer to be read as a body.
        while true {
            let outcome = HTTPResponseParser.parse(buffer.readPointer, buffer.readableBytes,
                                                   maxHeadSize: maxHeadBytes,
                                                   maxHeaders: maxHeaders,
                                                   headers: fields, head: &head)
            switch outcome {
            case .incomplete:
                try await readMore(socket, into: &buffer)
                continue
            case .failure(let error):
                throw error == .headTooLarge ? .headTooLarge : .malformedResponse(error)
            case .complete:
                break
            }

            if head.status >= 100 && head.status < 200 && head.status != 101 {
                buffer.consume(head.headEnd)
                head = HTTPResponseHead()
                continue
            }

            let base = buffer.readPointer
            reason = String(decoding: UnsafeBufferPointer(start: base + Int(head.reason.offset),
                                                          count: head.reason.count), as: UTF8.self)
            headers.reserveCapacity(head.headerCount)
            for i in 0..<head.headerCount {
                headers.append(ClientHeader(
                    name: String(decoding: UnsafeBufferPointer(
                        start: base + Int(fields[i].name.offset),
                        count: fields[i].name.count), as: UTF8.self),
                    value: String(decoding: UnsafeBufferPointer(
                        start: base + Int(fields[i].value.offset),
                        count: fields[i].value.count), as: UTF8.self)))
            }
            buffer.consume(head.headEnd)
            break
        }

        let framing = head.framing(method: method)
        var body: [UInt8] = []
        var reusable = head.keepAlive

        switch framing {
        case .none:
            break

        case .length(let wanted):
            if wanted > maxBodyBytes { throw .bodyTooLarge }
            body.reserveCapacity(wanted)
            while body.count < wanted {
                if buffer.readableBytes == 0 { try await readMore(socket, into: &buffer) }
                let take = min(wanted - body.count, buffer.readableBytes)
                body.append(contentsOf: UnsafeBufferPointer(start: buffer.readPointer, count: take))
                buffer.consume(take)
            }

        case .chunked:
            var decoder = ChunkedDecoder()
            var finished = false
            while !finished {
                if buffer.readableBytes == 0 { try await readMore(socket, into: &buffer) }
                var consumed = 0
                var tooLarge = false
                let outcome = decoder.decode(buffer.readPointer, buffer.readableBytes,
                                             consumed: &consumed) { p, n in
                    if body.count + n > maxBodyBytes { tooLarge = true; return }
                    body.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
                }
                buffer.consume(consumed)
                if tooLarge { throw .bodyTooLarge }
                switch outcome {
                case .needMore: continue
                case .finished: finished = true
                case .failure(let error): throw .malformedResponse(error)
                }
            }

        case .untilClose:
            // The body ends when the connection does, so reading it to the end
            // is the same act as making the connection unusable.
            reusable = false
            while true {
                // Drained before waiting, not after. The start of the body
                // arrives in the same read as the head, and a peer that sent
                // everything and closed has no readability left to offer -- so
                // waiting first loses exactly the bytes that were already
                // here. The length and chunked paths are safe from this
                // because each has a reason to look at the buffer first; this
                // one, having no length, had none.
                if buffer.readableBytes > 0 {
                    if body.count + buffer.readableBytes > maxBodyBytes { throw .bodyTooLarge }
                    body.append(contentsOf: UnsafeBufferPointer(start: buffer.readPointer,
                                                                count: buffer.readableBytes))
                    buffer.consume(buffer.readableBytes)
                }
                do {
                    try await readMore(socket, into: &buffer)
                } catch ClientError.closed {
                    break
                }
            }
        }

        // Anything still in the buffer belongs to a message this exchange did
        // not ask for. Handing the connection on with that on it is what makes
        // the next caller read somebody else's answer.
        if buffer.readableBytes > 0 { reusable = false }

        if reusable { socket.release() } else { socket.close() }

        return ClientResponse(status: head.status, reason: reason, headers: headers,
                              body: body, reusedConnection: reusable)
    }

    /// Waits for more and takes it. A peer that closes is `.closed`, which the
    /// close-delimited path treats as the end of the body and every other path
    /// treats as the peer giving up part way through.
    func readMore(_ socket: OutboundSocket,
                  into buffer: inout ByteBuffer) async throws(ClientError) {
        while true {
            // OpenSSL may be holding decrypted bytes the socket has already
            // given up, and no poll will ever mention those again.
            if !socket.hasBufferedInput {
                do {
                    try await socket.readable(milliseconds: timeoutMilliseconds)
                } catch {
                    throw error == .timedOut ? .timedOut
                        : error == .cancelled ? .cancelled : .closed
                }
            }
            buffer.reserve(8192)
            let n: Int
            do {
                n = try socket.read(into: UnsafeMutableRawBufferPointer(
                    start: buffer.writePointer, count: buffer.writableBytes))
            } catch {
                // The peer closing arrives here, as `failed(0)`, and nowhere
                // else.
                throw error == .cancelled ? .cancelled : .closed
            }
            if n > 0 {
                buffer.advanceWriter(n)
                return
            }
            // Readable, and nothing to hand over. That is not the peer going
            // away -- the read above throws for that. Over TLS it is routine:
            // a TLS 1.3 server sends a session ticket straight after the
            // handshake, the socket wakes, OpenSSL consumes the ticket, and
            // there is no application data yet. This once read that as a
            // close, and every HTTPS/1.1 request to a server whose ticket
            // arrived first failed as `closed`; plaintext tests never showed
            // it, because a readable plaintext socket always has data or a
            // real end. The ticket is consumed now, so the next wait blocks.
        }
    }
}

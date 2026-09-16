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
// Not here yet, deliberately:
//
//   * Redirects are not followed. A redirect chosen by the peer is a request
//     to somewhere this process did not choose, and following one by default
//     is how a client reaches 169.254.169.254 on somebody else's say-so. A
//     caller that wants one reads Location and asks again.
//   * No Accept-Encoding goes out. The compression shim encodes and does not
//     decode, so asking for a coding would buy a body this cannot read.
//   * HTTP/2 is next. This API is the one it has to fit: ALPN still asks for
//     http/1.1 only, because a server that selected h2 would find a client
//     that cannot speak it.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

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
    /// The request that wanted it ended, or the worker is shutting down.
    case cancelled
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
    /// Sent unless the caller sets its own.
    public var userAgent: String = "garuda"

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

    /// One exchange.
    public func send(_ method: HTTPMethod, _ url: String,
                     headers: [(String, String)] = [],
                     body: [UInt8] = []) async throws(ClientError) -> ClientResponse {

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

        let socket: OutboundSocket
        do {
            if plan.secure {
                socket = try await Worker.connectTLS(worker, name: plan.host, port: plan.port,
                                                     caFile: caFile,
                                                     milliseconds: timeoutMilliseconds)
            } else {
                socket = try await Worker.connect(worker, name: plan.host, port: plan.port,
                                                  milliseconds: timeoutMilliseconds)
            }
        } catch {
            throw .connect(error)
        }

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
                        // something it does not do: it cannot decode a coding
                        // it asked for, and it does not wait for a 100 before
                        // sending a body.
                        if kind.contains(.acceptEncoding) || kind.contains(.expect) {
                            return false
                        }
                        if kind.contains(.userAgent) { sawUserAgent = true }
                        return HTTPRequestWriter.writeUserHeader(&head, name: field,
                                                                 value: ByteSpan(vp, v.count))
                    }
                }
                guard allowed else { return .failure(.refusedHeader) }
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

            let host = String(decoding: UnsafeBufferPointer(
                start: base + Int(parsed.host.offset), count: parsed.host.count), as: UTF8.self)
            return .success(Plan(host: host, port: parsed.port, secure: parsed.scheme.isSecure))
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
    private func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8]) async throws(ClientError) {
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

    private func writeAll(_ socket: OutboundSocket,
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
    private func readMore(_ socket: OutboundSocket,
                          into buffer: inout ByteBuffer) async throws(ClientError) {
        // OpenSSL may be holding decrypted bytes the socket has already given
        // up, and no poll will ever mention those again.
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
            throw error == .cancelled ? .cancelled : .closed
        }
        // A read that returns nothing on a readable socket is the peer having
        // spoken and stopped; treating it as more to come would spin.
        if n == 0 { throw .closed }
        buffer.advanceWriter(n)
    }
}

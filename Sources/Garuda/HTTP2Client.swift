//===----------------------------------------------------------------------===//
// One HTTP/2 exchange over a connection this worker made.
//
// A frame loop of its own rather than the server's. The framing primitives are
// shared -- H2FrameHeader, the flags, the settings, the preface, HPACK -- but
// every frame handler next door is `extension Worker` taking a connection-table
// slot, and an outbound connection is a different record entirely. More to the
// point, half of H2Connection is server state: a concurrency limit it imposes
// on a peer, the highest identifier a peer has opened, the reset budget that
// answers CVE-2023-44487. A client opens its own identifiers and cancels its
// own streams; none of that transfers. Refactoring working security code to
// share the half that does would be a poor trade.
//
// One request per connection here. An h2 connection is built to carry many at
// once, and this deliberately does not: the state that would have to persist
// between exchanges on one socket -- the HPACK dynamic table above all -- is
// what makes sharing subtle, and doing it properly means reference-counted
// connections and a reader handing off to the next waiter. So a connection
// used for one exchange is closed rather than pooled. Returning it would send
// a second preface down a live connection and desynchronise the dynamic table,
// which is a worse failure than not pooling at all.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

/// Per-connection HTTP/2 state for a connection this process opened.
///
/// A class for the same reason the server's is: allocated once per connection,
/// holding tables, touched once per frame rather than once per byte.
final class H2ClientConnection {
    var decoder: HPACKDecoder
    let encoder = HPACKEncoder()

    /// What the peer imposed on us, in its SETTINGS.
    var peerMaxFrameSize = H2FrameHeader.defaultMaxFrameSize
    var peerInitialWindowSize = H2FrameHeader.defaultInitialWindowSize
    var peerMaxHeaderListSize = Int.max

    /// What we advertised.
    let maxFrameSize: Int
    let initialWindowSize: Int

    /// Connection-level flow control, which is separate from every stream's.
    var sendWindow = H2FrameHeader.defaultInitialWindowSize
    var recvWindow: Int

    /// Client streams are odd, RFC 9113 section 5.1.1.
    var nextStreamID: UInt32 = 1

    /// Header block assembly across CONTINUATION frames.
    var headerBlock = ByteBuffer()
    var expectingContinuation = false

    var peerGoneAway = false

    init(maxFrameSize: Int = H2FrameHeader.defaultMaxFrameSize,
         initialWindowSize: Int = H2FrameHeader.defaultInitialWindowSize) {
        self.maxFrameSize = maxFrameSize
        self.initialWindowSize = initialWindowSize
        recvWindow = initialWindowSize
        decoder = HPACKDecoder(maxTableSize: 4096)
    }

    func destroy() {
        decoder.destroy()
        headerBlock.destroy()
    }
}

extension HTTPClient {

    /// Sends one request and reads its response, as HTTP/2.
    func exchangeHTTP2(_ socket: OutboundSocket, _ plan: Plan, method: HTTPMethod,
                       headers: [(String, String)],
                       body: [UInt8]) async throws(ClientError) -> ClientResponse {

        let h2 = H2ClientConnection(initialWindowSize: max(H2FrameHeader.defaultInitialWindowSize,
                                                           maxBodyBytes > 0 ? 65535 : 65535))
        defer { h2.destroy() }

        let stream = h2.nextStreamID
        h2.nextStreamID &+= 2

        // ---- the preface, our settings, and the request ----

        var out = ByteBuffer(capacity: 1024)
        defer { out.destroy() }

        HTTP2.preface.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
        writeSettings(&out, h2)

        var block = ByteBuffer(capacity: 512)
        defer { block.destroy() }
        switch encodeRequestBlock(h2, plan, method: method, headers: headers,
                                  hasBody: !body.isEmpty, into: &block) {
        case .failure(let error): throw error
        case .success: break
        }

        // A header block larger than one frame is split, and the parts may not
        // be interleaved with anything else -- which is what the peer checks
        // and what the reader below checks in the other direction.
        try writeHeaderBlock(&out, h2, stream: stream, block: block,
                             endStream: body.isEmpty)
        try await writeAll(socket, out.readPointer, out.readableBytes)
        out.clear()

        // ---- the body, inside both windows ----

        if !body.isEmpty {
            var streamSendWindow = h2.peerInitialWindowSize
            var buffer = ByteBuffer(capacity: 8192)
            defer { buffer.destroy() }
            var sent = 0
            while sent < body.count {
                // Both windows have to allow it. Waiting for one and spending
                // the other is how a peer's connection-level limit gets
                // ignored, and it answers with a flow-control error.
                while h2.sendWindow <= 0 || streamSendWindow <= 0 {
                    try await pumpUntilWindow(socket, h2, &buffer, stream: stream,
                                              streamSendWindow: &streamSendWindow)
                }
                var n = min(body.count - sent, h2.peerMaxFrameSize)
                n = min(n, h2.sendWindow)
                n = min(n, streamSendWindow)
                let last = sent + n == body.count
                out.clear()
                let header = H2FrameHeader(length: n, type: .data,
                                           flags: last ? .endStream : [], streamID: stream)
                header.write(into: &out)
                body.withUnsafeBufferPointer { out.write($0.baseAddress! + sent, n) }
                try await writeAll(socket, out.readPointer, out.readableBytes)
                h2.sendWindow -= n
                streamSendWindow -= n
                sent += n
            }
        }

        // ---- the response ----

        return try await readHTTP2Response(socket, h2, stream: stream, method: method)
    }

    // MARK: Writing

    private func writeSettings(_ out: inout ByteBuffer, _ h2: H2ClientConnection) {
        let entries: [(H2Setting, UInt32)] = [
            (.maxFrameSize, UInt32(h2.maxFrameSize)),
            (.initialWindowSize, UInt32(h2.initialWindowSize)),
            // Nothing here answers a promise, and saying so up front keeps a
            // server from reserving streams this client would only reset.
            (.enablePush, 0),
        ]
        let header = H2FrameHeader(length: entries.count * 6, type: .settings,
                                   flags: [], streamID: 0)
        header.write(into: &out)
        for (setting, value) in entries {
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue))
            HTTP2.writeUInt32(value, into: &out)
        }
    }

    /// The pseudo-headers and then the ordinary fields, into `block`.
    private func encodeRequestBlock(_ h2: H2ClientConnection, _ plan: Plan,
                                    method: HTTPMethod, headers: [(String, String)],
                                    hasBody: Bool,
                                    into block: inout ByteBuffer) -> Result<Void, ClientError> {
        guard let token = method.token else { return .failure(.refusedHeader) }
        let authority = Array(plan.authority.utf8)
        let path = Array(plan.target.utf8)
        let scheme = plan.secure ? "https" : "http"
        let schemeBytes = Array(scheme.utf8)

        UnsafeRawPointer(token.utf8Start).withMemoryRebound(
            to: UInt8.self, capacity: token.utf8CodeUnitCount) { m in
            schemeBytes.withUnsafeBufferPointer { s in
                authority.withUnsafeBufferPointer { a in
                    path.withUnsafeBufferPointer { p in
                        h2.encoder.encodeRequestPseudoHeaders(
                            method: ByteSpan(m, token.utf8CodeUnitCount),
                            scheme: ByteSpan(s.baseAddress!, s.count),
                            authority: ByteSpan(a.baseAddress!, a.count),
                            path: ByteSpan(p.baseAddress!, p.count),
                            into: &block)
                    }
                }
            }
        }

        var sawUserAgent = false
        for (name, value) in headers {
            let lowered = name.lowercased()
            let nameBytes = Array(lowered.utf8)
            let valueBytes = Array(value.utf8)
            let ok = nameBytes.withUnsafeBufferPointer { n -> Bool in
                valueBytes.withUnsafeBufferPointer { v -> Bool in
                    guard let np = n.baseAddress, let vp = v.baseAddress else { return false }
                    // Connection-specific fields have no meaning in HTTP/2 and
                    // their presence makes a message malformed, RFC 9113
                    // section 8.2.2. The h1 writer refuses the same names for
                    // its own reasons; this refuses them for the peer's.
                    if HTTP2.isConnectionSpecific(np, n.count) { return false }
                    if !HTTP2.validFieldName(np, n.count) { return false }
                    if !HTTP2.validFieldValue(vp, v.count) { return false }
                    let field = ByteSpan(np, n.count)
                    let kind = HTTPRequestWriter.classify(field)
                    if kind.contains(.acceptEncoding) || kind.contains(.expect) { return false }
                    if kind.contains(.host) { return false }
                    if kind.contains(.userAgent) { sawUserAgent = true }
                    h2.encoder.encode(name: np, nameLength: n.count,
                                      value: vp, valueLength: v.count, into: &block)
                    return true
                }
            }
            guard ok else { return .failure(.refusedHeader) }
        }

        if !sawUserAgent, !userAgent.isEmpty {
            let agent = Array(userAgent.utf8)
            let name: StaticString = "user-agent"
            agent.withUnsafeBufferPointer { a in
                UnsafeRawPointer(name.utf8Start).withMemoryRebound(
                    to: UInt8.self, capacity: name.utf8CodeUnitCount) { n in
                    h2.encoder.encode(name: n, nameLength: name.utf8CodeUnitCount,
                                      value: a.baseAddress!, valueLength: a.count, into: &block)
                }
            }
        }

        if hasBody {
            // Stated even though DATA framing already bounds it: a server that
            // buffers by declared length has nothing else to go on, and
            // HTTP/2 has no Transfer-Encoding to fall back to.
            let length = Array(String(plan.bodyLength).utf8)
            let name: StaticString = "content-length"
            length.withUnsafeBufferPointer { l in
                UnsafeRawPointer(name.utf8Start).withMemoryRebound(
                    to: UInt8.self, capacity: name.utf8CodeUnitCount) { n in
                    h2.encoder.encode(name: n, nameLength: name.utf8CodeUnitCount,
                                      value: l.baseAddress!, valueLength: l.count, into: &block)
                }
            }
        }
        return .success(())
    }

    /// HEADERS, then CONTINUATION for whatever did not fit.
    private func writeHeaderBlock(_ out: inout ByteBuffer, _ h2: H2ClientConnection,
                                 stream: UInt32, block: ByteBuffer,
                                 endStream: Bool) throws(ClientError) {
        let total = block.readableBytes
        let limit = h2.peerMaxFrameSize
        var at = 0
        var first = true
        repeat {
            let n = min(limit, total - at)
            let last = at + n == total
            var flags: H2Flags = []
            if last { flags.insert(.endHeaders) }
            if first && endStream { flags.insert(.endStream) }
            let header = H2FrameHeader(length: n, type: first ? .headers : .continuation,
                                       flags: flags, streamID: stream)
            header.write(into: &out)
            out.write(block.readPointer + at, n)
            at += n
            first = false
        } while at < total
    }

    // MARK: Reading

    /// Reads whole frames until this stream is done, and assembles the answer.
    private func readHTTP2Response(_ socket: OutboundSocket, _ h2: H2ClientConnection,
                                   stream: UInt32,
                                   method: HTTPMethod) async throws(ClientError) -> ClientResponse {
        var buffer = ByteBuffer(capacity: 8192)
        defer { buffer.destroy() }
        var status = 0
        var headers: [ClientHeader] = []
        var body: [UInt8] = []
        var sawHeaders = false
        var done = false

        while !done {
            let header = try await nextFrame(socket, h2, &buffer)
            let payload = buffer.readPointer + H2FrameHeader.size

            // A header block may not be interleaved with anything else, and
            // the peer is not to be trusted to keep to that: a CONTINUATION
            // that arrives after something else means the block this was
            // assembling is now of unknown provenance.
            if h2.expectingContinuation && header.type != H2FrameType.continuation.rawValue {
                throw .protocolError
            }

            switch H2FrameType(rawValue: header.type) {
            case .settings:
                if !header.flags.contains(.ack) {
                    try applyPeerSettings(h2, payload, header.length)
                    try await writeAck(socket, h2)
                }

            case .windowUpdate:
                guard header.length == 4 else { throw .protocolError }
                let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
                if increment == 0 { throw .protocolError }
                if header.streamID == 0 { h2.sendWindow += increment }

            case .ping:
                guard header.length == 8 else { throw .protocolError }
                if !header.flags.contains(.ack) {
                    var pong = ByteBuffer(capacity: 32)
                    defer { pong.destroy() }
                    H2FrameHeader(length: 8, type: .ping, flags: .ack, streamID: 0)
                        .write(into: &pong)
                    pong.write(payload, 8)
                    try await writeAll(socket, pong.readPointer, pong.readableBytes)
                }

            case .goaway:
                guard header.length >= 8 else { throw .protocolError }
                h2.peerGoneAway = true
                let code = HTTP2.readUInt32(payload + 4)
                // A GOAWAY naming a stream below this one means this request
                // was never processed, which is worth telling apart from one
                // that was refused on its merits.
                let lastStream = HTTP2.readUInt32(payload) & 0x7FFF_FFFF
                if code != 0 || lastStream < stream { throw .streamReset(code) }
                if !sawHeaders { throw .closed }
                done = true

            case .rstStream:
                guard header.length == 4 else { throw .protocolError }
                if header.streamID == stream { throw .streamReset(HTTP2.readUInt32(payload)) }

            case .headers, .continuation:
                if header.streamID != stream && header.streamID != 0 {
                    // Not ours, and with one stream in flight there is no such
                    // thing: a block for a stream this client never opened.
                    throw .protocolError
                }
                h2.headerBlock.reserve(header.length)
                h2.headerBlock.write(payload, header.length)
                h2.expectingContinuation = !header.flags.contains(.endHeaders)
                if !h2.expectingContinuation {
                    let outcome = decodeBlock(h2, into: &status, &headers)
                    h2.headerBlock.clear()
                    if let outcome { throw outcome }
                    // Informational responses are followed by the real one,
                    // exactly as in HTTP/1.1.
                    if status >= 100 && status < 200 {
                        status = 0
                        headers.removeAll(keepingCapacity: true)
                    } else {
                        sawHeaders = true
                        if header.flags.contains(.endStream) { done = true }
                    }
                }

            case .data:
                if header.streamID != stream { throw .protocolError }
                if body.count + header.length > maxBodyBytes { throw .bodyTooLarge }
                body.append(contentsOf: UnsafeBufferPointer(start: payload, count: header.length))
                // Every DATA byte is spent from our window whether or not the
                // handler wanted it, so the credit has to go back or a large
                // response stops half way.
                h2.recvWindow -= header.length
                if h2.recvWindow < h2.initialWindowSize / 2 {
                    let bump = h2.initialWindowSize - h2.recvWindow
                    try await writeWindowUpdate(socket, stream: stream, increment: bump)
                    h2.recvWindow = h2.initialWindowSize
                }
                if header.flags.contains(.endStream) { done = true }

            case .priority:
                break
            case .pushPromise:
                // Push was refused in our SETTINGS, so a promise is the peer
                // ignoring what it was told.
                throw .protocolError
            case .none:
                // Unknown types are ignorable by design, which is how
                // extensions are meant to work.
                break
            }

            buffer.consume(H2FrameHeader.size + header.length)
        }

        guard sawHeaders else { throw .closed }
        return ClientResponse(status: status, reason: "", headers: headers,
                              body: method == .head ? [] : body, reusedConnection: false)
    }

    /// Reads until a whole frame is in the buffer, and bounds it.
    private func nextFrame(_ socket: OutboundSocket, _ h2: H2ClientConnection,
                           _ buffer: inout ByteBuffer) async throws(ClientError) -> H2FrameHeader {
        while buffer.readableBytes < H2FrameHeader.size {
            try await readMore(socket, into: &buffer)
        }
        let header = H2FrameHeader.parse(buffer.readPointer)
        // Checked before a byte of it is waited for. A length beyond what we
        // advertised is a frame we never agreed to receive, and reading it to
        // find out would be doing what it asked.
        guard header.length <= h2.maxFrameSize else { throw .protocolError }
        while buffer.readableBytes < H2FrameHeader.size + header.length {
            try await readMore(socket, into: &buffer)
        }
        return header
    }

    private func applyPeerSettings(_ h2: H2ClientConnection,
                                   _ payload: UnsafePointer<UInt8>,
                                   _ length: Int) throws(ClientError) {
        guard length % 6 == 0 else { throw .protocolError }
        var at = 0
        while at < length {
            let id = UInt16(payload[at]) << 8 | UInt16(payload[at + 1])
            let value = HTTP2.readUInt32(payload + at + 2)
            switch H2Setting(rawValue: id) {
            case .maxFrameSize:
                guard value >= 16384 && value <= 16_777_215 else { throw .protocolError }
                h2.peerMaxFrameSize = Int(value)
            case .initialWindowSize:
                guard value <= UInt32(H2FrameHeader.maxWindowSize) else { throw .protocolError }
                h2.peerInitialWindowSize = Int(value)
            case .maxHeaderListSize:
                h2.peerMaxHeaderListSize = Int(value)
            case .headerTableSize:
                h2.decoder.setPermittedMaxSize(Int(value))
            default:
                break
            }
            at += 6
        }
    }

    private func writeAck(_ socket: OutboundSocket,
                          _ h2: H2ClientConnection) async throws(ClientError) {
        var out = ByteBuffer(capacity: 16)
        defer { out.destroy() }
        H2FrameHeader(length: 0, type: .settings, flags: .ack, streamID: 0).write(into: &out)
        try await writeAll(socket, out.readPointer, out.readableBytes)
    }

    private func writeWindowUpdate(_ socket: OutboundSocket, stream: UInt32,
                                   increment: Int) async throws(ClientError) {
        guard increment > 0 else { return }
        var out = ByteBuffer(capacity: 32)
        defer { out.destroy() }
        // Both levels: the connection's window and the stream's are spent
        // separately, and topping up only one leaves the other to run out.
        H2FrameHeader(length: 4, type: .windowUpdate, flags: [], streamID: 0).write(into: &out)
        HTTP2.writeUInt32(UInt32(increment), into: &out)
        H2FrameHeader(length: 4, type: .windowUpdate, flags: [], streamID: stream).write(into: &out)
        HTTP2.writeUInt32(UInt32(increment), into: &out)
        try await writeAll(socket, out.readPointer, out.readableBytes)
    }

    /// Reads frames until the send window opens, which is the only thing that
    /// can reopen it.
    private func pumpUntilWindow(_ socket: OutboundSocket, _ h2: H2ClientConnection,
                                 _ buffer: inout ByteBuffer, stream: UInt32,
                                 streamSendWindow: inout Int) async throws(ClientError) {
        let header = try await nextFrame(socket, h2, &buffer)
        let payload = buffer.readPointer + H2FrameHeader.size
        switch H2FrameType(rawValue: header.type) {
        case .windowUpdate:
            guard header.length == 4 else { throw .protocolError }
            let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
            if increment == 0 { throw .protocolError }
            if header.streamID == 0 {
                h2.sendWindow += increment
            } else if header.streamID == stream {
                streamSendWindow += increment
            }
        case .settings:
            if !header.flags.contains(.ack) {
                try applyPeerSettings(h2, payload, header.length)
                buffer.consume(H2FrameHeader.size + header.length)
                try await writeAck(socket, h2)
                return
            }
        case .goaway:
            guard header.length >= 8 else { throw .protocolError }
            throw .streamReset(header.length >= 8 ? HTTP2.readUInt32(payload + 4) : 0)
        case .rstStream:
            guard header.length == 4 else { throw .protocolError }
            if header.streamID == stream { throw .streamReset(HTTP2.readUInt32(payload)) }
        default:
            break
        }
        buffer.consume(H2FrameHeader.size + header.length)
    }

    /// Decodes an assembled header block into a status and fields.
    ///
    /// Returns the failure rather than throwing it: the decoder's throw is
    /// erased by the closure it is called through, and putting it back at the
    /// call site keeps the typed throw honest.
    private func decodeBlock(_ h2: H2ClientConnection, into status: inout Int,
                             _ headers: inout [ClientHeader]) -> ClientError? {
        var failure: ClientError? = nil
        var foundStatus = 0
        var collected: [ClientHeader] = []
        do {
            try h2.decoder.decode(h2.headerBlock.readPointer, h2.headerBlock.readableBytes) { span in
                if span.nameLength > 0 && span.name[0] == UInt8(ascii: ":") {
                    if equalsExact(span.name, span.nameLength, ":status") {
                        var value = 0
                        var i = 0
                        var digits = 0
                        while i < span.valueLength {
                            let c = span.value[i]
                            guard c >= cZero, c <= cNine else { return }
                            value = value * 10 + Int(c - cZero)
                            digits += 1
                            i += 1
                        }
                        if digits == 3 { foundStatus = value }
                    }
                    return
                }
                collected.append(ClientHeader(
                    name: String(decoding: UnsafeBufferPointer(start: span.name,
                                                               count: span.nameLength),
                                 as: UTF8.self),
                    value: String(decoding: UnsafeBufferPointer(start: span.value,
                                                                count: span.valueLength),
                                  as: UTF8.self)))
            }
        } catch {
            failure = .malformedResponse(.badHeader)
        }
        if failure == nil && foundStatus == 0 {
            // No :status, or one that was not three digits. A response
            // without it is malformed, RFC 9113 section 8.3.2, and guessing
            // 200 would hand the caller a success the peer never claimed.
            failure = .malformedResponse(.badStatusLine)
        }
        if failure == nil {
            status = foundStatus
            headers = collected
        }
        return failure
    }
}

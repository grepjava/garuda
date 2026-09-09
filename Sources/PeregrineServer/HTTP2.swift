//===----------------------------------------------------------------------===//
// HTTP/2 (RFC 9113).
//
// The structural problem with HTTP/2 in a server built around one request per
// connection is that it is no longer one request per connection. The approach
// here is to keep the connection slot as the transport -- socket, read buffer,
// poller interest, HPACK state -- and give every stream a slot of its own,
// borrowed from the same table, with `parentSlot` pointing back at the socket
// and `fd` set to -1.
//
// That is what makes the rest of the server keep working unchanged. A stream
// slot has a head, a body buffer, a write buffer, a task, a receive future and
// a Content-Length budget, so ASGI dispatch, request-body streaming, response
// framing, write backpressure and disconnect delivery all operate on a stream
// exactly as they operate on a connection. Only three operations have to know
// the difference: writing (bytes become DATA frames on the parent rather than
// going to a socket), read interest (a stream has no descriptor), and teardown.
//
// The request head is rebuilt as HTTP/1.1 text in the stream's `headStore` and
// handed to the ordinary parser. It costs one copy and one parse per request,
// and in exchange the scope builder, the trusted-proxy logic and the access log
// all keep working on the representation they were written for.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

/// Per-connection HTTP/2 state.
///
/// A class rather than a value in the slab: it is allocated once per HTTP/2
/// connection, holds two variable-sized tables, and is touched once per frame
/// rather than once per byte. The no-ARC rule earns nothing here.
public final class H2Connection {
    var decoder: HPACKDecoder
    let encoder = HPACKEncoder()

    /// Settings the peer imposed on us.
    var peerMaxFrameSize = H2FrameHeader.defaultMaxFrameSize
    var peerInitialWindowSize = H2FrameHeader.defaultInitialWindowSize
    var peerMaxHeaderListSize = Int.max

    /// Our own advertised settings.
    let initialWindowSize: Int
    let maxFrameSize: Int
    let maxConcurrentStreams: Int
    let maxHeaderListSize: Int

    /// Connection-level flow control.
    var sendWindow: Int = H2FrameHeader.defaultInitialWindowSize
    var recvWindow: Int
    var pendingRecvUpdate = 0

    /// Live streams, by identifier.
    var streams: [UInt32: Int32] = [:]
    /// The highest identifier the peer has opened, for GOAWAY and for spotting
    /// a stream identifier that goes backwards.
    var lastPeerStream: UInt32 = 0

    /// Header block assembly across CONTINUATION frames.
    var headerBlock = ByteBuffer()
    var headerStream: UInt32 = 0
    var headerFlags: H2Flags = []
    var expectingContinuation = false
    /// Trailers, which are decoded to keep HPACK in sync and then dropped.
    var headerIsTrailer = false

    var sentGoaway = false
    var peerGoneAway = false
    /// Set once the preface and our first SETTINGS have been exchanged.
    var settingsReceived = false

    init(config: ServerConfig) {
        initialWindowSize = max(H2FrameHeader.defaultInitialWindowSize,
                                config.bodyHighWaterMark)
        maxFrameSize = config.h2MaxFrameSize
        maxConcurrentStreams = config.h2MaxConcurrentStreams
        maxHeaderListSize = config.maxHeadSize
        recvWindow = initialWindowSize
        decoder = HPACKDecoder(maxTableSize: 4096)
    }

    func destroy() {
        decoder.destroy()
        headerBlock.destroy()
        streams.removeAll()
    }
}

extension Worker {

    // MARK: - Starting a connection

    /// True when the bytes buffered on a fresh connection are (or may still
    /// become) the HTTP/2 client preface.
    func looksLikeHTTP2(_ slot: Int) -> Bool {
        let c = table[slot]
        let n = c.pointee.read.readableBytes
        if n == 0 { return false }
        return HTTP2.prefaceMatches(UnsafePointer(c.pointee.read.readPointer), n)
    }

    /// Consumes the preface and puts the connection into HTTP/2 mode.
    mutating func beginHTTP2(_ slot: Int) {
        let c = table[slot]
        c.pointee.read.consume(HTTP2.preface.count)
        let h2 = H2Connection(config: config)
        c.pointee.h2 = h2
        c.pointee.state = .http2
        c.pointee.flags.remove(.keepAlive)

        // Our SETTINGS have to be the first thing we send.
        writeSettings(slot, h2)
        // A connection-level window larger than the default lets a single
        // upload use the link; the per-stream window is what bounds memory.
        let bump = h2.initialWindowSize - H2FrameHeader.defaultInitialWindowSize
        if bump > 0 {
            writeFrame(slot, length: 4, type: .windowUpdate, flags: [], streamID: 0) { out in
                HTTP2.writeUInt32(UInt32(bump), into: &out)
            }
            h2.recvWindow = h2.initialWindowSize
        }
        _ = flush(slot)
        if table[slot].pointee.state != .free { pumpHTTP2(slot) }
    }

    func writeSettings(_ slot: Int, _ h2: H2Connection) {
        let entries: [(H2Setting, UInt32)] = [
            (.maxConcurrentStreams, UInt32(h2.maxConcurrentStreams)),
            (.initialWindowSize, UInt32(h2.initialWindowSize)),
            (.maxFrameSize, UInt32(h2.maxFrameSize)),
            (.maxHeaderListSize, UInt32(h2.maxHeaderListSize)),
            // We never push, and saying so up front keeps a client from
            // reserving anything on our behalf.
            (.enablePush, 0),
        ]
        writeFrame(slot, length: entries.count * 6, type: .settings, flags: [], streamID: 0) { out in
            for (setting, value) in entries {
                out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
                out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue))
                HTTP2.writeUInt32(value, into: &out)
            }
        }
    }

    /// Writes one frame into the connection's write buffer.
    func writeFrame(_ slot: Int, length: Int, type: H2FrameType, flags: H2Flags,
                    streamID: UInt32, _ body: (inout ByteBuffer) -> Void) {
        let c = table[slot]
        let header = H2FrameHeader(length: length, type: type, flags: flags, streamID: streamID)
        header.write(into: &c.pointee.write)
        body(&c.pointee.write)
    }

    // MARK: - Frame loop

    mutating func pumpHTTP2(_ slot: Int) {
        let c = table[slot]
        guard let h2 = c.pointee.h2 else { return }

        while c.pointee.state == .http2 {
            let available = c.pointee.read.readableBytes
            if available < H2FrameHeader.size { break }
            let base = UnsafePointer(c.pointee.read.readPointer)
            let header = H2FrameHeader.parse(base)
            if header.length > h2.maxFrameSize {
                connectionError(slot, .frameSizeError)
                return
            }
            if available < H2FrameHeader.size + header.length { break }
            let payload = base + H2FrameHeader.size

            // A header block may not be interleaved with anything else.
            if h2.expectingContinuation && header.type != H2FrameType.continuation.rawValue {
                connectionError(slot, .protocolError)
                return
            }

            handleFrame(slot, h2, header, payload)
            let after = table[slot]
            if after.pointee.state != .http2 { return }
            after.pointee.read.consume(H2FrameHeader.size + header.length)
        }

        let c2 = table[slot]
        if c2.pointee.state == .http2 {
            if c2.pointee.flags.contains(.peerClosed) && c2.pointee.read.isEmpty {
                // The peer half-closed. Streams still running get to finish,
                // but nothing new can arrive.
                if h2.streams.isEmpty { closeConnection(slot) }
            }
            _ = flush(slot)
        }
    }

    mutating func handleFrame(_ slot: Int, _ h2: H2Connection,
                              _ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) {
        guard let type = H2FrameType(rawValue: header.type) else {
            // Unknown frame types are discarded, which is how extensions are
            // meant to be ignorable.
            return
        }
        switch type {
        case .data:         handleDataFrame(slot, h2, header, payload)
        case .headers:      handleHeadersFrame(slot, h2, header, payload)
        case .continuation: handleContinuationFrame(slot, h2, header, payload)
        case .priority:     handlePriorityFrame(slot, h2, header, payload)
        case .rstStream:    handleRstStreamFrame(slot, h2, header, payload)
        case .settings:     handleSettingsFrame(slot, h2, header, payload)
        case .ping:         handlePingFrame(slot, h2, header, payload)
        case .goaway:       handleGoawayFrame(slot, h2, header)
        case .windowUpdate: handleWindowUpdateFrame(slot, h2, header, payload)
        case .pushPromise:  connectionError(slot, .protocolError)
        }
    }

    // MARK: DATA

    mutating func handleDataFrame(_ slot: Int, _ h2: H2Connection,
                                  _ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) {
        if header.streamID == 0 { connectionError(slot, .protocolError); return }

        // Flow control is accounted before anything else can reject the frame:
        // the peer has spent the window whether or not we want the bytes.
        h2.recvWindow -= header.length
        if h2.recvWindow < 0 { connectionError(slot, .flowControlError); return }
        h2.pendingRecvUpdate += header.length

        var offset = 0
        var length = header.length
        if header.flags.contains(.padded) {
            if length < 1 { connectionError(slot, .protocolError); return }
            let pad = Int(payload[0])
            offset = 1
            length -= 1
            if pad > length { connectionError(slot, .protocolError); return }
            length -= pad
        }

        guard let streamSlot = h2.streams[header.streamID].map(Int.init) else {
            // A stream we have finished with. The connection window still has
            // to be given back or the peer stalls behind bytes nobody wanted.
            releaseConnectionWindow(slot, h2)
            if header.streamID <= h2.lastPeerStream {
                writeRstStream(slot, header.streamID, .streamClosed)
                _ = flush(slot)
            } else {
                connectionError(slot, .protocolError)
            }
            return
        }

        let s = table[streamSlot]
        s.pointee.recvWindow -= header.length
        if s.pointee.recvWindow < 0 {
            streamError(slot, h2, header.streamID, .flowControlError)
            return
        }
        if s.pointee.bodyRemaining == 0 {
            // Data after END_STREAM.
            streamError(slot, h2, header.streamID, .streamClosed)
            return
        }

        if length > 0 {
            if s.pointee.body.readableBytes + length > config.maxBodySize {
                streamError(slot, h2, header.streamID, .enhanceYourCalm)
                return
            }
            s.pointee.body.write(payload + offset, length)
            s.pointee.bodyReceived += length
        }

        if header.flags.contains(.endStream) {
            s.pointee.bodyRemaining = 0
            // RFC 9113 section 8.1.1: a declared length that does not match
            // what arrived is a malformed request.
            if s.pointee.head.flags.contains(.hasContentLength)
                && s.pointee.head.contentLength != s.pointee.bodyReceived {
                streamError(slot, h2, header.streamID, .protocolError)
                return
            }
        }
        onBodyProgress(streamSlot)
    }

    // MARK: HEADERS

    mutating func handleHeadersFrame(_ slot: Int, _ h2: H2Connection,
                                     _ header: H2FrameHeader,
                                     _ payload: UnsafePointer<UInt8>) {
        if header.streamID == 0 { connectionError(slot, .protocolError); return }
        if header.streamID % 2 == 0 { connectionError(slot, .protocolError); return }

        var offset = 0
        var length = header.length
        if header.flags.contains(.padded) {
            if length < 1 { connectionError(slot, .protocolError); return }
            let pad = Int(payload[0])
            offset = 1
            length -= 1
            if pad > length { connectionError(slot, .protocolError); return }
            length -= pad
        }
        if header.flags.contains(.priority) {
            // Priority information is deprecated in RFC 9113; it is parsed only
            // far enough to skip, and a stream that depends on itself is still
            // a protocol error.
            if length < 5 { connectionError(slot, .frameSizeError); return }
            let dependency = HTTP2.readUInt32(payload + offset) & 0x7FFF_FFFF
            if dependency == header.streamID { connectionError(slot, .protocolError); return }
            offset += 5
            length -= 5
        }

        let existing = h2.streams[header.streamID]
        if existing == nil {
            if header.streamID <= h2.lastPeerStream {
                // Reusing or going backwards through identifiers.
                connectionError(slot, .protocolError)
                return
            }
            h2.lastPeerStream = header.streamID
            h2.headerIsTrailer = false
        } else {
            let streamSlot = Int(existing!)
            if table[streamSlot].pointee.bodyRemaining == 0 {
                // Half-closed already: the request is over, whatever this is.
                streamError(slot, h2, header.streamID, .streamClosed)
                return
            }
            // A second HEADERS on a live stream is a trailer section, and a
            // trailer section is the end of the request by definition.
            if !header.flags.contains(.endStream) {
                connectionError(slot, .protocolError)
                return
            }
            h2.headerIsTrailer = true
        }

        h2.headerBlock.clear()
        h2.headerBlock.write(payload + offset, length)
        h2.headerStream = header.streamID
        h2.headerFlags = header.flags
        h2.expectingContinuation = !header.flags.contains(.endHeaders)
        if !h2.expectingContinuation { completeHeaderBlock(slot, h2) }
    }

    mutating func handleContinuationFrame(_ slot: Int, _ h2: H2Connection,
                                          _ header: H2FrameHeader,
                                          _ payload: UnsafePointer<UInt8>) {
        if !h2.expectingContinuation || header.streamID != h2.headerStream {
            connectionError(slot, .protocolError)
            return
        }
        if h2.headerBlock.readableBytes + header.length > h2.maxHeaderListSize * 2 {
            connectionError(slot, .enhanceYourCalm)
            return
        }
        h2.headerBlock.write(payload, header.length)
        if header.flags.contains(.endHeaders) {
            h2.expectingContinuation = false
            completeHeaderBlock(slot, h2)
        }
    }

    /// Decodes a finished header block and, unless it is a trailer section,
    /// starts a request.
    mutating func completeHeaderBlock(_ slot: Int, _ h2: H2Connection) {
        let streamID = h2.headerStream
        let endStream = h2.headerFlags.contains(.endStream)

        if h2.headerIsTrailer {
            // Decode and discard: HPACK is stateful, so a block that is not
            // wanted still has to be read or every later block is nonsense.
            var ok = true
            decodeBlock(h2) { _ in } onError: { ok = false }
            if !ok { connectionError(slot, .compressionError); return }
            if let streamSlot = h2.streams[streamID].map(Int.init) {
                table[streamSlot].pointee.bodyRemaining = 0
                onBodyProgress(streamSlot)
            }
            return
        }

        // Refuse rather than queue when the peer runs past what we advertised.
        if h2.streams.count >= h2.maxConcurrentStreams || h2.peerGoneAway {
            var ok = true
            decodeBlock(h2) { _ in } onError: { ok = false }
            if !ok { connectionError(slot, .compressionError); return }
            writeRstStream(slot, streamID, .refusedStream)
            _ = flush(slot)
            return
        }

        let streamSlot = openStream(parent: slot, h2, streamID: streamID)
        if streamSlot < 0 {
            var ok = true
            decodeBlock(h2) { _ in } onError: { ok = false }
            if !ok { connectionError(slot, .compressionError); return }
            writeRstStream(slot, streamID, .refusedStream)
            _ = flush(slot)
            return
        }

        switch buildRequestHead(streamSlot, h2) {
        case .compression:
            closeStream(streamSlot, resetWith: nil)
            connectionError(slot, .compressionError)
            return
        case .malformed:
            closeStream(streamSlot, resetWith: nil)
            writeRstStream(slot, streamID, .protocolError)
            _ = flush(slot)
            return
        case .ok:
            break
        }

        let s = table[streamSlot]
        if endStream {
            s.pointee.bodyRemaining = 0
            if s.pointee.head.flags.contains(.hasContentLength)
                && s.pointee.head.contentLength > 0 {
                closeStream(streamSlot, resetWith: nil)
                writeRstStream(slot, streamID, .protocolError)
                _ = flush(slot)
                return
            }
        } else {
            // Length is decided by END_STREAM, not by Content-Length.
            s.pointee.bodyRemaining = -1
        }

        s.pointee.state = .dispatching
        dispatch(streamSlot)
        if table[slot].pointee.state == .http2 { _ = flush(slot) }
    }

    /// Runs the HPACK decoder over the assembled block.
    func decodeBlock(_ h2: H2Connection, _ emit: (HPACKSpan) -> Void,
                     onError: () -> Void) {
        let n = h2.headerBlock.readableBytes
        guard n > 0 else { return }
        let p = UnsafePointer(h2.headerBlock.readPointer)
        do {
            try h2.decoder.decode(p, n, sizeLimit: h2.maxHeaderListSize, emit: emit)
        } catch {
            onError()
        }
    }

    enum HeaderOutcome { case ok, malformed, compression }

    /// Rebuilds the request as HTTP/1.1 text and parses it.
    ///
    /// Everything downstream -- the scope builder, the forwarded-header logic,
    /// the access log -- reads a parsed head with slices into a base pointer,
    /// so producing one here is what lets HTTP/2 reuse all of it.
    mutating func buildRequestHead(_ streamSlot: Int, _ h2: H2Connection) -> HeaderOutcome {
        let s = table[streamSlot]
        // A decoded field is only valid until the next one is decoded -- they
        // share one staging buffer -- so everything worth keeping is copied out
        // as it arrives: pseudo-header values by offset into `pseudo`, regular
        // fields straight into the header text.
        var pseudo = ByteBuffer()
        defer { pseudo.destroy() }
        var methodAt = (0, 0), pathAt = (0, 0), schemeAt = (0, 0), authorityAt = (0, 0)
        var sawMethod = false, sawPath = false, sawScheme = false, sawAuthority = false
        var malformed = false
        var sawRegular = false

        var fields = ByteBuffer()
        defer { fields.destroy() }

        func stash(_ span: HPACKSpan) -> (Int, Int) {
            let at = pseudo.readableBytes
            pseudo.write(span.value, span.valueLength)
            return (at, span.valueLength)
        }

        var failed = false
        decodeBlock(h2) { span in
            if malformed { return }
            if span.nameLength > 0 && span.name[0] == 0x3A {      // ':'
                if sawRegular { malformed = true; return }
                if !HTTP2.validFieldValue(span.value, span.valueLength) {
                    malformed = true; return
                }
                if equalsExact(span.name, span.nameLength, ":method") {
                    if sawMethod { malformed = true; return }
                    sawMethod = true; methodAt = stash(span)
                } else if equalsExact(span.name, span.nameLength, ":path") {
                    if sawPath { malformed = true; return }
                    sawPath = true; pathAt = stash(span)
                } else if equalsExact(span.name, span.nameLength, ":scheme") {
                    if sawScheme { malformed = true; return }
                    sawScheme = true; schemeAt = stash(span)
                } else if equalsExact(span.name, span.nameLength, ":authority") {
                    if sawAuthority { malformed = true; return }
                    sawAuthority = true; authorityAt = stash(span)
                } else {
                    malformed = true      // unknown pseudo-header
                }
                return
            }
            sawRegular = true
            if !HTTP2.validFieldName(span.name, span.nameLength)
                || !HTTP2.validFieldValue(span.value, span.valueLength) {
                malformed = true; return
            }
            if HTTP2.isConnectionSpecific(span.name, span.nameLength) {
                // "te: trailers" is the one connection-specific field HTTP/2
                // still allows.
                if !(span.nameLength == 2
                     && equalsLowercased(span.value, span.valueLength, "trailers")) {
                    malformed = true; return
                }
            }
            fields.write(span.name, span.nameLength)
            fields.write(": ")
            fields.write(span.value, span.valueLength)
            fields.writeCRLF()
        } onError: {
            failed = true
        }
        if failed { return .compression }
        if malformed { return .malformed }
        // CONNECT is only meaningful with the extended form, which arrives with
        // the rest of WebTransport; a plain one has no target here.
        if !sawMethod || !sawScheme || !sawPath { return .malformed }
        if pathAt.1 == 0 || methodAt.1 == 0 { return .malformed }

        let base0 = UnsafePointer(pseudo.pointer(at: 0))
        var head = ByteBuffer()
        defer { head.destroy() }
        head.write(base0 + methodAt.0, methodAt.1)
        head.writeByte(cSP)
        head.write(base0 + pathAt.0, pathAt.1)
        head.write(" HTTP/1.1\r\n")
        if sawAuthority && authorityAt.1 > 0 {
            head.write("host: ")
            head.write(base0 + authorityAt.0, authorityAt.1)
            head.writeCRLF()
        }
        if fields.readableBytes > 0 {
            head.write(UnsafePointer(fields.readPointer), fields.readableBytes)
        }
        head.writeCRLF()

        s.pointee.headStore.clear()
        s.pointee.headStore.write(UnsafePointer(head.readPointer), head.readableBytes)
        s.pointee.headInStore = true
        s.pointee.headOrigin = 0

        var parsed = HTTPRequestHead()
        let base = UnsafePointer(s.pointee.headStore.pointer(at: 0))
        let result = HTTPParser.parse(base, s.pointee.headStore.readableBytes,
                                      maxHeadSize: config.maxHeadSize,
                                      maxHeaders: config.maxHeaders,
                                      headers: headers,
                                      head: &parsed)
        guard case .complete = result else { return .malformed }
        parsed.httpMajor = 2
        // Chunked framing does not exist in HTTP/2, and a request that claims
        // it is malformed rather than merely odd.
        if parsed.flags.contains(.chunked) { return .malformed }
        s.pointee.head = parsed
        // The same rule as HTTP/1: a HEAD response carries the headers of the
        // GET and none of its body. `beginRequest` does this for HTTP/1, and
        // an HTTP/2 stream never goes through it.
        if parsed.method == .head { s.pointee.flags.insert(.suppressBody) }
        // The scheme the client asked for outranks the server default.
        s.pointee.h2Scheme = equalsLowercased(base0 + schemeAt.0, schemeAt.1, "https")
        return .ok
    }

    // MARK: Other frames

    mutating func handlePriorityFrame(_ slot: Int, _ h2: H2Connection,
                                      _ header: H2FrameHeader,
                                      _ payload: UnsafePointer<UInt8>) {
        if header.streamID == 0 { connectionError(slot, .protocolError); return }
        if header.length != 5 {
            streamError(slot, h2, header.streamID, .frameSizeError)
            return
        }
        // Prioritisation itself is deprecated by RFC 9113 and not implemented,
        // but a stream that depends on itself is still nonsense.
        let dependency = HTTP2.readUInt32(payload) & 0x7FFF_FFFF
        if dependency == header.streamID {
            streamError(slot, h2, header.streamID, .protocolError)
        }
    }

    mutating func handleRstStreamFrame(_ slot: Int, _ h2: H2Connection,
                                       _ header: H2FrameHeader,
                                       _ payload: UnsafePointer<UInt8>) {
        if header.streamID == 0 { connectionError(slot, .protocolError); return }
        if header.length != 4 { connectionError(slot, .frameSizeError); return }
        guard let streamSlot = h2.streams[header.streamID].map(Int.init) else {
            if header.streamID > h2.lastPeerStream { connectionError(slot, .protocolError) }
            return
        }
        // The application finds out the way it finds out about any hang-up.
        let s = table[streamSlot]
        s.pointee.flags.insert(.disconnected)
        closeStream(streamSlot, resetWith: nil)
    }

    mutating func handleSettingsFrame(_ slot: Int, _ h2: H2Connection,
                                      _ header: H2FrameHeader,
                                      _ payload: UnsafePointer<UInt8>) {
        if header.streamID != 0 { connectionError(slot, .protocolError); return }
        if header.flags.contains(.ack) {
            if header.length != 0 { connectionError(slot, .frameSizeError) }
            return
        }
        if header.length % 6 != 0 { connectionError(slot, .frameSizeError); return }

        var i = 0
        var windowDelta = 0
        var windowChanged = false
        while i < header.length {
            let id = (UInt16(payload[i]) << 8) | UInt16(payload[i + 1])
            let value = HTTP2.readUInt32(payload + i + 2)
            i += 6
            guard let setting = H2Setting(rawValue: id) else { continue }
            switch setting {
            case .headerTableSize:
                // Bounds what we may use when encoding; we never index, so
                // there is nothing to resize.
                break
            case .enablePush:
                if value > 1 { connectionError(slot, .protocolError); return }
            case .maxConcurrentStreams:
                break                                  // limits pushes only
            case .initialWindowSize:
                if value > UInt32(H2FrameHeader.maxWindowSize) {
                    connectionError(slot, .flowControlError); return
                }
                windowDelta = Int(value) - h2.peerInitialWindowSize
                windowChanged = true
                h2.peerInitialWindowSize = Int(value)
            case .maxFrameSize:
                if value < UInt32(H2FrameHeader.defaultMaxFrameSize) || value > 0xFF_FFFF {
                    connectionError(slot, .protocolError); return
                }
                h2.peerMaxFrameSize = Int(value)
            case .maxHeaderListSize:
                h2.peerMaxHeaderListSize = Int(value)
            case .enableConnectProtocol:
                if value > 1 { connectionError(slot, .protocolError); return }
            }
        }

        // A changed initial window applies to every stream already open.
        if windowChanged && windowDelta != 0 {
            for (_, raw) in h2.streams {
                let s = table[Int(raw)]
                s.pointee.sendWindow += windowDelta
                if s.pointee.sendWindow > H2FrameHeader.maxWindowSize {
                    connectionError(slot, .flowControlError)
                    return
                }
            }
        }

        h2.settingsReceived = true
        writeFrame(slot, length: 0, type: .settings, flags: .ack, streamID: 0) { _ in }
        _ = flush(slot)
        if windowChanged && table[slot].pointee.state == .http2 { pumpAllStreams(slot, h2) }
    }

    mutating func handlePingFrame(_ slot: Int, _ h2: H2Connection,
                                  _ header: H2FrameHeader,
                                  _ payload: UnsafePointer<UInt8>) {
        if header.streamID != 0 { connectionError(slot, .protocolError); return }
        if header.length != 8 { connectionError(slot, .frameSizeError); return }
        if header.flags.contains(.ack) { return }
        writeFrame(slot, length: 8, type: .ping, flags: .ack, streamID: 0) { out in
            out.write(payload, 8)
        }
        _ = flush(slot)
    }

    mutating func handleGoawayFrame(_ slot: Int, _ h2: H2Connection, _ header: H2FrameHeader) {
        if header.streamID != 0 { connectionError(slot, .protocolError); return }
        if header.length < 8 { connectionError(slot, .frameSizeError); return }
        h2.peerGoneAway = true
        if h2.streams.isEmpty { closeConnection(slot) }
    }

    mutating func handleWindowUpdateFrame(_ slot: Int, _ h2: H2Connection,
                                          _ header: H2FrameHeader,
                                          _ payload: UnsafePointer<UInt8>) {
        if header.length != 4 { connectionError(slot, .frameSizeError); return }
        let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
        if header.streamID == 0 {
            if increment == 0 { connectionError(slot, .protocolError); return }
            h2.sendWindow += increment
            if h2.sendWindow > H2FrameHeader.maxWindowSize {
                connectionError(slot, .flowControlError); return
            }
            pumpAllStreams(slot, h2)
            return
        }
        if increment == 0 {
            streamError(slot, h2, header.streamID, .protocolError)
            return
        }
        guard let streamSlot = h2.streams[header.streamID].map(Int.init) else {
            if header.streamID > h2.lastPeerStream { connectionError(slot, .protocolError) }
            return
        }
        let s = table[streamSlot]
        s.pointee.sendWindow += increment
        if s.pointee.sendWindow > H2FrameHeader.maxWindowSize {
            streamError(slot, h2, header.streamID, .flowControlError)
            return
        }
        _ = flushStream(streamSlot)
    }

    // MARK: - Errors

    mutating func connectionError(_ slot: Int, _ code: H2Error) {
        Log.debug { line in
            line.str("h2 connection error, code ")
            line.int(Int(code.rawValue))
        }
        let c = table[slot]
        guard let h2 = c.pointee.h2 else { closeConnection(slot); return }
        if !h2.sentGoaway {
            h2.sentGoaway = true
            writeFrame(slot, length: 8, type: .goaway, flags: [], streamID: 0) { out in
                HTTP2.writeUInt32(h2.lastPeerStream, into: &out)
                HTTP2.writeUInt32(code.rawValue, into: &out)
            }
        }
        // One last push at the socket so the peer learns why, then done.
        while c.pointee.write.readableBytes > 0 {
            let n = pg_write(c.pointee.fd, c.pointee.write.readPointer,
                             c.pointee.write.readableBytes)
            if n <= 0 { break }
            c.pointee.write.consume(n)
        }
        closeConnection(slot)
    }

    mutating func streamError(_ slot: Int, _ h2: H2Connection,
                              _ streamID: UInt32, _ code: H2Error) {
        if let streamSlot = h2.streams[streamID].map(Int.init) {
            closeStream(streamSlot, resetWith: nil)
        }
        writeRstStream(slot, streamID, code)
        _ = flush(slot)
    }

    func writeRstStream(_ slot: Int, _ streamID: UInt32, _ code: H2Error) {
        Log.debug { line in
            line.str("h2 stream ")
            line.int(Int(streamID))
            line.str(" reset, code ")
            line.int(Int(code.rawValue))
        }
        writeFrame(slot, length: 4, type: .rstStream, flags: [], streamID: streamID) { out in
            HTTP2.writeUInt32(code.rawValue, into: &out)
        }
    }

    // MARK: - Streams

    mutating func openStream(parent: Int, _ h2: H2Connection, streamID: UInt32) -> Int {
        let slot = table.allocate()
        if slot < 0 { return -1 }
        let p = table[parent]
        let s = table[slot]
        s.pointee.fd = -1
        s.pointee.parentSlot = Int32(parent)
        s.pointee.streamID = streamID
        s.pointee.state = .readingBody
        s.pointee.interest = 0
        // Trust is a property of the peer, so it is inherited whole.
        s.pointee.flags = p.pointee.flags.intersection([.trustEvaluated, .trustedPeer])
        s.pointee.flags.insert(.keepAlive)
        s.pointee.read = ByteBuffer()
        s.pointee.write = ByteBuffer()
        s.pointee.body = ByteBuffer()
        s.pointee.headStore.clear()
        s.pointee.head = HTTPRequestHead()
        s.pointee.headInStore = true
        s.pointee.headOrigin = 0
        s.pointee.chunked = ChunkedDecoder()
        s.pointee.bodyRemaining = -1
        s.pointee.bodyReceived = 0
        s.pointee.requestCount = 1
        s.pointee.lastActivity = pg_monotonic_ms()
        s.pointee.task = nil
        s.pointee.pendingReceive = nil
        s.pointee.sendCallable = nil
        s.pointee.receiveCallable = nil
        s.pointee.drainWaiter = nil
        s.pointee.poolJob = nil
        s.pointee.h2 = nil
        s.pointee.responseRemaining = -1
        s.pointee.sendWindow = h2.peerInitialWindowSize
        s.pointee.recvWindow = h2.initialWindowSize
        s.pointee.pendingRecvUpdate = 0
        s.pointee.clientTuple = nil
        if let a = p.pointee.remoteAddrObj { pg_incref(a); s.pointee.remoteAddrObj = a }
        if let port = p.pointee.remotePortObj { pg_incref(port); s.pointee.remotePortObj = port }
        h2.streams[streamID] = Int32(slot)
        return slot
    }

    /// Tears down one stream. `resetWith` sends RST_STREAM first, for the case
    /// where we are abandoning a stream the peer still believes in.
    mutating func closeStream(_ streamSlot: Int, resetWith code: H2Error?) {
        let s = table[streamSlot]
        if s.pointee.state == .free { return }
        let parent = Int(s.pointee.parentSlot)
        let streamID = s.pointee.streamID
        if parent >= 0, let h2 = table[parent].pointee.h2 {
            h2.streams.removeValue(forKey: streamID)
            if let code {
                writeRstStream(parent, streamID, code)
                _ = flush(parent)
            }
            // The last stream on a connection the peer has finished with.
            if h2.streams.isEmpty && (h2.peerGoneAway
                                      || table[parent].pointee.flags.contains(.peerClosed)) {
                closeConnection(streamSlot)
                closeConnection(parent)
                return
            }
        }
        closeConnection(streamSlot)
    }

    // MARK: - Writing

    /// Moves a stream's queued body into the connection as DATA frames, as far
    /// as flow control and the socket allow.
    mutating func flushStream(_ streamSlot: Int) -> Bool {
        let s = table[streamSlot]
        let parent = Int(s.pointee.parentSlot)
        if parent < 0 { return false }
        let p = table[parent]
        guard p.pointee.state == .http2, let h2 = p.pointee.h2 else {
            closeConnection(streamSlot)
            return false
        }

        while true {
            let pending = s.pointee.write.readableBytes
            if pending == 0 { break }
            // Never let one stream queue an unbounded amount on the socket:
            // the stream buffer is where a slow client applies its pressure,
            // and that is what parks the application in `await send()`.
            if p.pointee.write.readableBytes > config.writeHighWaterMark { break }
            var n = min(pending, h2.peerMaxFrameSize)
            n = min(n, max(0, s.pointee.sendWindow))
            n = min(n, max(0, h2.sendWindow))
            if n == 0 { break }
            writeFrame(parent, length: n, type: .data, flags: [], streamID: s.pointee.streamID) { out in
                out.write(UnsafePointer(s.pointee.write.readPointer), n)
            }
            s.pointee.write.consume(n)
            s.pointee.sendWindow -= n
            h2.sendWindow -= n
        }

        // The end of the response is a flag on a frame, so an empty DATA frame
        // is sometimes the only way to say it -- unless the response came up
        // short, where saying "that was all of it" would be a lie and the
        // stream is reset instead.
        let short = s.pointee.flags.contains(.responseComplete)
            && s.pointee.responseRemaining > 0
        if s.pointee.flags.contains(.responseComplete)
            && s.pointee.write.isEmpty
            && !short
            && !s.pointee.flags.contains(.endStreamSent) {
            s.pointee.flags.insert(.endStreamSent)
            writeFrame(parent, length: 0, type: .data, flags: .endStream,
                       streamID: s.pointee.streamID) { _ in }
        }

        if !flush(parent) { return false }
        resumeWriterIfDrained(streamSlot)

        if s.pointee.flags.contains(.endStreamSent) && s.pointee.write.isEmpty {
            if s.pointee.state == .writing {
                if appProtocol == .asgi && s.pointee.task != nil { return true }
                closeStream(streamSlot, resetWith: nil)
                return false
            }
        }
        return true
    }

    mutating func pumpAllStreams(_ slot: Int, _ h2: H2Connection) {
        for (_, raw) in h2.streams {
            let streamSlot = Int(raw)
            if table[streamSlot].pointee.state == .free { continue }
            if !flushStream(streamSlot) { continue }
            if table[slot].pointee.state != .http2 { return }
        }
    }

    // MARK: - Receive-side flow control

    /// Called when the application takes body bytes, which is what makes room
    /// for more. Doing it here rather than on arrival is what gives HTTP/2 the
    /// same backpressure as HTTP/1: an application that does not read stops the
    /// peer from sending.
    mutating func h2NoteConsumed(_ streamSlot: Int, _ n: Int) {
        if n <= 0 { return }
        table[streamSlot].pointee.pendingRecvUpdate += n
    }

    /// Emits whatever window the application has earned back.
    ///
    /// Separate from noting it because writing to the connection can fail, and
    /// that must not happen half way through building a message for a slot the
    /// caller is still holding.
    mutating func h2FlushWindowUpdates(_ streamSlot: Int) {
        let s = table[streamSlot]
        if !s.pointee.isStream { return }
        let parent = Int(s.pointee.parentSlot)
        guard let h2 = table[parent].pointee.h2 else { return }
        var wrote = false

        // Half the window is the usual compromise between a WINDOW_UPDATE per
        // frame and letting the peer run dry.
        if s.pointee.pendingRecvUpdate >= h2.initialWindowSize / 2
            && s.pointee.bodyRemaining != 0 {
            let bump = s.pointee.pendingRecvUpdate
            s.pointee.pendingRecvUpdate = 0
            s.pointee.recvWindow += bump
            writeFrame(parent, length: 4, type: .windowUpdate, flags: [],
                       streamID: s.pointee.streamID) { out in
                HTTP2.writeUInt32(UInt32(bump), into: &out)
            }
            wrote = true
        }
        let before = h2.pendingRecvUpdate
        releaseConnectionWindow(parent, h2)
        if wrote || h2.pendingRecvUpdate != before { _ = flush(parent) }
    }

    mutating func releaseConnectionWindow(_ slot: Int, _ h2: H2Connection) {
        if h2.pendingRecvUpdate < h2.initialWindowSize / 2 { return }
        let bump = h2.pendingRecvUpdate
        h2.pendingRecvUpdate = 0
        h2.recvWindow += bump
        writeFrame(slot, length: 4, type: .windowUpdate, flags: [], streamID: 0) { out in
            HTTP2.writeUInt32(UInt32(bump), into: &out)
        }
    }
}

/// A valid pointer for an empty span.
nonisolated(unsafe) let emptyH2Byte: UnsafePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    p[0] = 0
    return UnsafePointer(p)
}()

extension Worker {
    /// Whether a connection opened with something that cannot be the start of
    /// an HTTP/1 request line but could be an HTTP/2 frame.
    ///
    /// A request line begins with a method, and a method is a token, so a
    /// first byte outside the token set is not HTTP/1 by any reading. On a
    /// port that speaks HTTP/2 the likeliest explanation is a client that sent
    /// frames without the preface, and RFC 9113 section 3.4 says what to do
    /// about that. Answering in HTTP/1 would be talking past it.
    func looksLikeBareFrames(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.read.readableBytes == 0 { return false }
        let b = c.pointee.read.readPointer[0]
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return false
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return false
        default: return true
        }
    }

    /// A connection that began with the start of the HTTP/2 preface and then
    /// did not finish it, or with frames and no preface at all. RFC 9113
    /// section 3.4 asks for GOAWAY and a close.
    mutating func rejectBadPreface(_ slot: Int) {
        let c = table[slot]
        writeFrame(slot, length: 8, type: .goaway, flags: [], streamID: 0) { out in
            HTTP2.writeUInt32(0, into: &out)
            HTTP2.writeUInt32(H2Error.protocolError.rawValue, into: &out)
        }
        while c.pointee.write.readableBytes > 0 {
            let n = pg_write(c.pointee.fd, c.pointee.write.readPointer,
                             c.pointee.write.readableBytes)
            if n <= 0 { break }
            c.pointee.write.consume(n)
        }
        closeConnection(slot)
    }
}

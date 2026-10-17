//===----------------------------------------------------------------------===//
// The HTTP client over HTTP/2: one connection to a place, shared by every
// request going there.
//
// A frame loop of its own rather than the server's. The framing primitives are
// shared -- H2FrameHeader, the flags, the settings, the preface, HPACK -- but
// half of the server's connection is server state: a concurrency limit imposed
// on a peer, the highest identifier a peer opened, the reset budget that
// answers CVE-2023-44487. A client opens and cancels its own streams.
//
// ## Who reads
//
// Each connection has a reader task, from its preface until it goes: it reads
// frames, decodes header blocks -- HPACK is the connection's, and only it
// touches the decoder -- and hands each frame to the stream it belongs to,
// waking the request waiting there. A connection with no streams is read
// too, so a GOAWAY or a close is seen when it comes rather than when the
// next request writes into it; one left with no streams for the pool's idle
// time is closed.
//
// Garuda 1 had no task to spare for this -- a worker would not end one
// suspended on something other than its own loop -- and passed the read
// between the requests waiting, as a baton. Here a task is what a reader is.
//
// ## Who writes
//
// A frame must reach the wire whole, and a header block split across
// CONTINUATION must reach it with nothing in between, so writing is under a
// lock. Two rules keep that lock from deadlocking against the reader:
//
//   * DATA is written one frame per lock, and never while waiting for flow
//     control credit -- which only the reader can deliver.
//   * The reader never waits for the lock. Its replies -- SETTINGS and PING
//     acknowledgements, WINDOW_UPDATEs, RST_STREAMs -- go into a queue that
//     whoever holds the lock sends before letting it go; with the lock free,
//     the reader takes it and leaves a task to send them. A reader stuck
//     behind a full socket stops reading, and a peer stuck behind a full
//     socket of its own then never drains this one.
//
// Stream identifiers are allocated under the lock too. A new stream's id has
// to exceed every id opened before it, so an id taken before waiting for the
// lock could reach the wire after a larger one and be illegal on arrival.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega

// MARK: - State

/// One request's stream. Everything but `changed` is the connection's,
/// under its lock.
final class ClientH2Stream: @unchecked Sendable {
    var id: UInt32 = 0
    let method: HTTPMethod
    var sendWindow = 0
    var recvWindow: Int
    var status = 0
    var headers: [ClientHeader] = []
    var body: [UInt8] = []
    var sawFinalHeaders = false
    var done = false
    var error: ClientError? = nil
    /// The peer reset it, or a reset is already queued: nothing more is owed.
    var closedByPeer = false
    /// This request's own limits. A connection is shared, and the reader must
    /// not lend one stream's limits to another: that both fails responses
    /// inside their own limit and lets one past a tighter one.
    let maxHeadBytes: Int
    let maxBodyBytes: Int
    /// What Content-Length promised, or -1 where the head named no length or
    /// none is owed (HEAD, 204, 304). DATA payload bytes are counted against
    /// it so that a stream ended early is refused rather than handed over as
    /// a whole response: RFC 9113 8.1.1 makes that mismatch malformed.
    var declaredLength = -1
    var receivedLength = 0
    /// Read by the caller as it arrives, so its window is opened as the
    /// caller takes the bytes rather than as they come, and no body limit
    /// applies: the window is what bounds what waits here.
    var streaming = false
    /// Signalled whenever the reader changes anything above, or the
    /// connection fails.
    let changed = IOEvent()

    init(method: HTTPMethod, recvWindow: Int, maxHeadBytes: Int, maxBodyBytes: Int) {
        self.method = method
        self.recvWindow = recvWindow
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
    }
}

/// An HTTP/2 connection shared by every request to one place.
final class H2Shared: @unchecked Sendable {
    let key: OriginKey
    let reader: any ClientReader
    let writer: any ClientWriter
    /// Guards everything below the reader's own.
    let lock = Mutex(())
    /// Held by whoever writes.
    let writeLock = Semaphore(permits: 1)
    var readerTask: Task<Void, Never>? = nil

    // The reader's own.

    var decoder = HPACKDecoder(maxTableSize: 4096)
    var input = IOBuffer(capacity: 16 * 1024)
    /// Header block assembly across CONTINUATION, which is per connection:
    /// nothing may come between the parts, whatever stream they are for.
    var headerBlock: [UInt8] = []
    var headerStream: UInt32 = 0
    var headerEndsStream = false
    var expectingContinuation = false
    /// The head limit of the stream the block being assembled belongs to,
    /// taken when its HEADERS arrived.
    var headBudget = Int.max

    // Under the lock.

    /// What the peer imposed, in its SETTINGS.
    var peerMaxFrameSize = H2FrameHeader.defaultMaxFrameSize
    var peerInitialWindowSize = H2FrameHeader.defaultInitialWindowSize
    var peerMaxConcurrentStreams = Int.max
    /// What we advertised.
    let maxFrameSize = H2FrameHeader.defaultMaxFrameSize
    let initialWindowSize = H2FrameHeader.defaultInitialWindowSize
    /// Connection-level flow control, separate from every stream's.
    var sendWindow = H2FrameHeader.defaultInitialWindowSize
    var recvWindow = H2FrameHeader.defaultInitialWindowSize
    /// Client streams are odd, RFC 9113 section 5.1.1.
    var nextStreamID: UInt32 = 1
    var streams: [UInt32: ClientH2Stream] = [:]
    /// The largest head limit of any stream opened here: what a header block
    /// may come to, encoded, before the connection is ended over it.
    var headCap = 0
    /// Replies the reader owes, waiting for the write lock.
    var control = ByteBuffer(capacity: 64)
    var dead: ClientError? = nil
    var goaway = false

    init(key: OriginKey, reader: any ClientReader, writer: any ClientWriter) {
        self.key = key
        self.reader = reader
        self.writer = writer
    }

    deinit {
        decoder.destroy()
        control.destroy()
        ClientConnections.shared.closed()
    }

    /// Whether a new stream may be opened here. Under the lock.
    var acceptsStreamsLocked: Bool {
        dead == nil && !goaway && streams.count < peerMaxConcurrentStreams && nextStreamID < 0x7FFF_FFFF
    }

    var acceptsStreams: Bool { lock.withLock { _ in acceptsStreamsLocked } }

    /// Whether it is done with: failed, or told to go away with nothing left
    /// on it.
    var finished: Bool { lock.withLock { _ in dead != nil || (goaway && streams.isEmpty) } }

    /// The connection is gone: every stream is told, the reader stopped, and
    /// new requests sent elsewhere.
    func fail(_ error: ClientError) {
        let (waiting, task): ([ClientH2Stream], Task<Void, Never>?) = lock.withLock { _ in
            guard dead == nil else { return ([], nil) }
            dead = error
            return (Array(streams.values), readerTask)
        }
        for stream in waiting { stream.changed.signal() }
        task?.cancel()
        H2Registry.shared.remove(self)
    }

    /// Queues a reply for whoever next holds the write lock. Under the lock.
    func queueControl(_ type: H2FrameType, flags: H2Flags = [], stream: UInt32,
                      length: Int, _ payload: (inout ByteBuffer) -> Void) {
        H2FrameHeader(length: length, type: type, flags: flags, streamID: stream).write(into: &control)
        payload(&control)
    }

    func queueReset(_ id: UInt32, _ code: H2Error) {
        queueControl(.rstStream, stream: id, length: 4) { HTTP2.writeUInt32(code.rawValue, into: &$0) }
    }

    func queueWindowUpdate(_ id: UInt32, _ increment: Int) {
        guard increment > 0 else { return }
        queueControl(.windowUpdate, stream: id, length: 4) { HTTP2.writeUInt32(UInt32(increment), into: &$0) }
    }

    // MARK: Writing

    /// Takes the write lock.
    func lockWriting() async throws(ClientError) {
        do {
            try await writeLock.acquire()
        } catch {
            throw .cancelled
        }
        if let dead = lock.withLock({ _ in dead }) {
            await unlockWriting()
            throw dead
        }
    }

    /// Lets the write lock go, sending first the replies the reader queued
    /// while it was held -- and again after, for any queued between the last
    /// look and the release, which the reader could not take the lock for.
    func unlockWriting() async {
        while true {
            let pending: [UInt8] = lock.withLock { _ in
                guard dead == nil, control.readableBytes > 0 else { return [] }
                let bytes = Array(UnsafeBufferPointer(start: control.readPointer, count: control.readableBytes))
                control.clear()
                return bytes
            }
            if !pending.isEmpty {
                // Its own deadline: the replies are nobody's request's.
                do {
                    try await Runtime.withIODeadline(.seconds(10)) { () async throws(IOError) in
                        try await pending.withUnsafeBytesAsync { (bytes) async throws(IOError) in try await writer.write(bytes) }
                    }
                } catch {
                    fail(ClientError(error))
                }
            }
            writeLock.release()
            let more = lock.withLock { _ in dead == nil && control.readableBytes > 0 }
            guard more, writeLock.tryAcquire() else { return }
        }
    }

    /// Sends the queued replies now, if nobody is writing; whoever is sends
    /// them when done.
    func flushControl() {
        let pending = lock.withLock { _ in dead == nil && control.readableBytes > 0 }
        guard pending, writeLock.tryAcquire() else { return }
        Runtime.spawn { [self] in await unlockWriting() }
    }

    /// Writes all of `bytes`, holding the write lock, inside the request's
    /// wait. A failure is the connection's.
    func writeLocked(_ client: HTTPClient, _ bytes: [UInt8]) async throws(ClientError) {
        do {
            try await client.waiting { () async throws(IOError) in
                try await bytes.withUnsafeBytesAsync { (bytes) async throws(IOError) in try await writer.write(bytes) }
            }
        } catch {
            fail(error)
            throw error
        }
    }

    // MARK: Reading

    /// The reader task: frames to their streams, until the connection goes.
    func readLoop() async {
        while true {
            if let failure = dispatchBuffered() {
                // Told why before it goes, when it is a protocol error.
                if failure == .protocolError {
                    lock.withLock { _ in
                        queueControl(.goaway, stream: 0, length: 8) { out in
                            HTTP2.writeUInt32(0, into: &out)
                            HTTP2.writeUInt32(H2Error.protocolError.rawValue, into: &out)
                        }
                    }
                    flushControl()
                }
                fail(failure)
                return
            }
            flushControl()
            if input.capacity - input.count < 4096 { input.reserveCapacity(max(input.capacity * 2, 16 * 1024)) }
            let idle = lock.withLock { _ in streams.isEmpty }
            do {
                let n: Int
                if idle {
                    // Nobody is waiting on it: kept for the pool's idle time.
                    n = try await Runtime.withIODeadline(ClientConnections.shared.idleTime) { () async throws(IOError) -> Int in
                        try await reader.read(into: &input)
                    }
                } else {
                    n = try await reader.read(into: &input)
                }
                if n == 0 {
                    fail(.closed)
                    return
                }
            } catch {
                if error == .timedOut {
                    if lock.withLock({ _ in streams.isEmpty }) {
                        fail(.closed)
                        return
                    }
                    continue
                }
                fail(ClientError(error))
                return
            }
        }
    }

    /// Hands every whole frame read so far to its stream. A failure ends the
    /// connection.
    private func dispatchBuffered() -> ClientError? {
        var at = 0
        var failure: ClientError? = nil
        var woken: [ClientH2Stream] = []
        input.withUnsafeBytes { raw in
            guard raw.count >= H2FrameHeader.size else { return }
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            lock.withLock { _ in
                while raw.count - at >= H2FrameHeader.size {
                    let header = H2FrameHeader.parse(base + at)
                    // Bounded before a byte of the payload is waited for. A
                    // length beyond what we advertised is a frame we never
                    // agreed to take.
                    if header.length > maxFrameSize {
                        failure = .protocolError
                        return
                    }
                    guard raw.count - at >= H2FrameHeader.size + header.length else { return }
                    if let error = dispatch(header, base + at + H2FrameHeader.size, &woken) {
                        failure = error
                        return
                    }
                    at += H2FrameHeader.size + header.length
                }
            }
        }
        input.consume(at)
        for stream in woken { stream.changed.signal() }
        return failure
    }

    /// Handles one frame, under the lock. Returns an error only for what ends
    /// the connection; a stream's troubles are recorded on the stream.
    private func dispatch(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>,
                          _ woken: inout [ClientH2Stream]) -> ClientError? {
        // A header block may not be interleaved with anything, and a peer
        // that does it has left a block of unknown provenance half assembled.
        if expectingContinuation && header.type != H2FrameType.continuation.rawValue {
            return .protocolError
        }

        switch H2FrameType(rawValue: header.type) {
        case .settings:
            if header.streamID != 0 || header.length % 6 != 0 { return .protocolError }
            if header.flags.contains(.ack) { return nil }
            var at = 0
            while at < header.length {
                let id = UInt16(payload[at]) << 8 | UInt16(payload[at + 1])
                let value = HTTP2.readUInt32(payload + at + 2)
                switch H2Setting(rawValue: id) {
                case .maxFrameSize:
                    guard value >= 16384 && value <= 16_777_215 else { return .protocolError }
                    peerMaxFrameSize = Int(value)
                case .initialWindowSize:
                    guard value <= UInt32(H2FrameHeader.maxWindowSize) else { return .protocolError }
                    // Applies to every open stream, by the difference, and may
                    // leave a window negative: RFC 9113 section 6.9.2.
                    let delta = Int(value) - peerInitialWindowSize
                    peerInitialWindowSize = Int(value)
                    for stream in streams.values {
                        stream.sendWindow += delta
                        if stream.sendWindow > H2FrameHeader.maxWindowSize { return .protocolError }
                    }
                case .maxConcurrentStreams:
                    peerMaxConcurrentStreams = Int(value)
                default:
                    // SETTINGS_HEADER_TABLE_SIZE included, deliberately. It
                    // bounds the *peer's* decoder, which is to say our encoder,
                    // and our encoder never indexes.
                    break
                }
                at += 6
            }
            queueControl(.settings, flags: .ack, stream: 0, length: 0) { _ in }
            woken.append(contentsOf: streams.values)

        case .windowUpdate:
            guard header.length == 4 else { return .protocolError }
            let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
            if header.streamID == 0 {
                if increment == 0 { return .protocolError }
                sendWindow += increment
                if sendWindow > H2FrameHeader.maxWindowSize { return .protocolError }
                woken.append(contentsOf: streams.values)
            } else if let stream = streams[header.streamID] {
                if increment == 0 {
                    failStream(stream, .protocolError, reset: .protocolError, &woken)
                } else {
                    stream.sendWindow += increment
                    if stream.sendWindow > H2FrameHeader.maxWindowSize {
                        failStream(stream, .protocolError, reset: .flowControlError, &woken)
                    }
                    woken.append(stream)
                }
            }

        case .ping:
            guard header.length == 8, header.streamID == 0 else { return .protocolError }
            if !header.flags.contains(.ack) {
                queueControl(.ping, flags: .ack, stream: 0, length: 8) { $0.write(payload, 8) }
            }

        case .goaway:
            guard header.length >= 8, header.streamID == 0 else { return .protocolError }
            goaway = true
            let lastStream = HTTP2.readUInt32(payload) & 0x7FFF_FFFF
            let code = HTTP2.readUInt32(payload + 4)
            // Streams above the last one the peer processed were never looked
            // at, which is what makes them safe to send again elsewhere.
            for stream in streams.values where stream.id > lastStream {
                stream.closedByPeer = true
                stream.error = .streamReset(code == 0 ? H2Error.refusedStream.rawValue : code)
                woken.append(stream)
            }

        case .rstStream:
            guard header.length == 4, header.streamID != 0 else { return .protocolError }
            if let stream = streams[header.streamID], !stream.done {
                stream.closedByPeer = true
                stream.error = .streamReset(HTTP2.readUInt32(payload))
                woken.append(stream)
            }

        case .headers, .continuation:
            var start = 0
            var end = header.length
            if header.type == H2FrameType.headers.rawValue {
                if header.streamID == 0 || header.streamID % 2 == 0 { return .protocolError }
                if header.flags.contains(.padded) {
                    guard header.length >= 1 else { return .protocolError }
                    start = 1
                    end = header.length - Int(payload[0])
                }
                if header.flags.contains(.priority) { start += 5 }
                guard start <= end else { return .protocolError }
                headerStream = header.streamID
                headerEndsStream = header.flags.contains(.endStream)
                headerBlock.removeAll(keepingCapacity: true)
                // The stream's own limit, or the largest any stream here has
                // where the stream has already gone: the block is decoded
                // either way, to keep HPACK in step, so it is held to
                // something either way.
                headBudget = streams[header.streamID]?.maxHeadBytes ?? max(headCap, 32 * 1024)
            } else {
                guard expectingContinuation, header.streamID == headerStream else { return .protocolError }
            }
            // Encoded bytes are the cheap outer guard, and bound what is held.
            // This ends the connection, because a block assembled in part
            // cannot be decoded, and dropping it would leave the HPACK table
            // describing bytes nobody read -- so it is held to the connection's
            // cap, not to the stream's own limit. A block past the stream's
            // limit and within the cap is decoded, and fails that stream
            // alone: HPACK only expands, so it cannot decode to something
            // inside the limit.
            guard headerBlock.count + (end - start) <= max(headBudget, headCap) else { return .headTooLarge }
            headerBlock.append(contentsOf: UnsafeBufferPointer(start: payload + start, count: end - start))
            expectingContinuation = !header.flags.contains(.endHeaders)
            if expectingContinuation { return nil }

            // Decoded whether or not anyone still wants it. HPACK is stateful,
            // and skipping one block decodes every later one to nonsense.
            var status = 0
            var fields: [ClientHeader] = []
            var tooLarge = false
            guard decodeBlock(&status, &fields, &tooLarge) else { return .malformedResponse(.badHeader) }
            headerBlock.removeAll(keepingCapacity: true)
            guard let stream = streams[headerStream], !stream.done, stream.error == nil else { return nil }
            let endsStream = headerEndsStream

            if tooLarge {
                // Decoded to keep the table in step and then dropped, so this
                // ends the one stream and not the connection.
                failStream(stream, .headTooLarge, reset: .cancel, &woken)
                return nil
            }
            if status < 0 || (stream.sawFinalHeaders && status != 0) {
                // A pseudo-field out of place, or any in trailers.
                failStream(stream, .malformedResponse(.badHeader), reset: .protocolError, &woken)
                return nil
            }
            if stream.sawFinalHeaders {
                // Trailers. Read to keep HPACK in step, and not kept.
                if !endsStream {
                    failStream(stream, .protocolError, reset: .protocolError, &woken)
                } else {
                    endOfStream(stream, &woken)
                }
            } else if status == 0 {
                // No :status, or one that was not three digits. Guessing 200
                // would hand the caller a success the peer never claimed.
                failStream(stream, .malformedResponse(.badStatusLine), reset: .protocolError, &woken)
            } else if status >= 100 && status < 200 {
                // Informational: the real answer follows on the same stream.
                // Never 101, which RFC 9113 section 8.8 makes malformed.
                if endsStream || status == 101 {
                    failStream(stream, .malformedResponse(.badStatusLine), reset: .protocolError, &woken)
                }
            } else {
                let owed = owedLength(status: status, method: stream.method, fields: fields)
                if owed == badLength {
                    failStream(stream, .malformedResponse(.conflictingFraming), reset: .protocolError, &woken)
                } else {
                    stream.status = status
                    stream.headers = fields
                    stream.sawFinalHeaders = true
                    stream.declaredLength = owed
                    if endsStream { endOfStream(stream, &woken) }
                }
            }
            woken.append(stream)

        case .data:
            guard header.streamID != 0 else { return .protocolError }
            var start = 0
            var end = header.length
            if header.flags.contains(.padded) {
                guard header.length >= 1 else { return .protocolError }
                start = 1
                end = header.length - Int(payload[0])
                guard start <= end else { return .protocolError }
            }
            // Flow control counts the whole frame, padding included, and the
            // connection's share is spent whoever the stream belongs to: DATA
            // for a stream nobody wants any more still used the credit.
            recvWindow -= header.length
            if recvWindow < 0 { return .protocolError }
            if recvWindow < initialWindowSize / 2 {
                queueWindowUpdate(0, initialWindowSize - recvWindow)
                recvWindow = initialWindowSize
            }
            guard let stream = streams[header.streamID], !stream.done, stream.error == nil else { return nil }
            guard stream.sawFinalHeaders else {
                // A body before any answer to attach it to.
                failStream(stream, .protocolError, reset: .protocolError, &woken)
                return nil
            }
            stream.recvWindow -= header.length
            if stream.recvWindow < 0 {
                failStream(stream, .protocolError, reset: .flowControlError, &woken)
                return nil
            }
            let length = end - start
            if !stream.streaming && stream.body.count + length > stream.maxBodyBytes {
                failStream(stream, .bodyTooLarge, reset: .cancel, &woken)
                return nil
            }
            // Padding is framing, not content, so only the payload counts.
            stream.receivedLength += length
            if stream.declaredLength >= 0 && stream.receivedLength > stream.declaredLength {
                // Already past what was promised; no need for END_STREAM.
                failStream(stream, .protocolError, reset: .protocolError, &woken)
                return nil
            }
            stream.body.append(contentsOf: UnsafeBufferPointer(start: payload + start, count: length))
            if header.flags.contains(.endStream) {
                endOfStream(stream, &woken)
            } else if !stream.streaming && stream.recvWindow < initialWindowSize / 2 {
                // A streamed body's window opens as the caller takes it
                // (`nextShared`), so a caller that stops reading stops the
                // peer rather than growing this buffer.
                queueWindowUpdate(stream.id, initialWindowSize - stream.recvWindow)
                stream.recvWindow = initialWindowSize
            }
            woken.append(stream)

        case .priority:
            guard header.length == 5 else { return .protocolError }

        case .pushPromise:
            // Push was refused in our SETTINGS.
            return .protocolError

        case .none:
            // Unknown types are ignorable by design.
            break
        }
        return nil
    }

    /// Ends one stream, telling the peer why, without touching the others.
    private func failStream(_ stream: ClientH2Stream, _ error: ClientError, reset code: H2Error,
                            _ woken: inout [ClientH2Stream]) {
        stream.error = error
        queueReset(stream.id, code)
        stream.closedByPeer = true
        woken.append(stream)
    }

    /// Ends a stream the peer says is over, or refuses it where the body was
    /// not the length the head promised. A short body is the case that
    /// matters: without this a truncated download is handed back as a whole
    /// response, which HTTP/1.1 never does.
    private func endOfStream(_ stream: ClientH2Stream, _ woken: inout [ClientH2Stream]) {
        guard stream.declaredLength < 0 || stream.receivedLength == stream.declaredLength else {
            failStream(stream, .protocolError, reset: .protocolError, &woken)
            return
        }
        stream.done = true
    }

    /// What `owedLength` returns for a Content-Length that cannot be believed.
    private var badLength: Int { -2 }

    /// How many body bytes the head promised, `-1` for no promise, or
    /// `badLength`. A HEAD and a 204 or 304 carry a length describing what a
    /// GET would have sent and no body follows, so nothing is owed on those.
    private func owedLength(status: Int, method: HTTPMethod, fields: [ClientHeader]) -> Int {
        guard method != .head, status != 204, status != 304 else { return -1 }
        var found = -1
        for field in fields where named(field.name, "content-length") {
            let text = field.value.utf8
            // Bounded before it is read: 18 digits is past any body that could
            // arrive, and a hundred would overflow.
            guard !text.isEmpty, text.count <= 18 else { return badLength }
            var value = 0
            for c in text {
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return badLength }
                value = value * 10 + Int(c - UInt8(ascii: "0"))
            }
            // Two that disagree is a smuggling vector, and nothing here should
            // be guessing which one was meant.
            if found >= 0 && found != value { return badLength }
            found = value
        }
        return found
    }

    /// Decodes the assembled block. False when HPACK itself failed, which ends
    /// the connection: its table can no longer be trusted. A missing or
    /// malformed :status leaves `status` at 0 for the stream to refuse, and
    /// pseudo-fields out of place leave it at -1.
    private func decodeBlock(_ status: inout Int, _ fields: inout [ClientHeader], _ tooLarge: inout Bool) -> Bool {
        var found = 0
        var collected: [ClientHeader] = []
        // RFC 9113 counts a header list as the two lengths plus 32 for what
        // holding the field costs. HPACK turns one byte into a whole line, so
        // this, and not the frame size, is what bounds the memory a head takes.
        var listSize = 0
        var over = false
        // RFC 9113 section 8.3: pseudo-fields come before the rest, and a
        // response has one, :status, once. Anything else makes it malformed.
        var sawRegular = false, sawStatus = false, misplaced = false
        let budget = headBudget
        let statusName: [UInt8] = Array(":status".utf8)
        do {
            try headerBlock.withUnsafeBufferPointer { block in
                let empty: StaticString = ""
                try decoder.decode(block.baseAddress ?? empty.utf8Start, block.count) { span in
                    listSize += span.nameLength + span.valueLength + 32
                    if listSize > budget {
                        // Every later field is still decoded, because the
                        // table has to end where the peer thinks it does.
                        over = true
                        collected.removeAll(keepingCapacity: false)
                    }
                    if over { return }
                    if span.nameLength > 0 && span.name[0] == UInt8(ascii: ":") {
                        let isStatus = span.nameLength == statusName.count
                            && (0..<span.nameLength).allSatisfy { span.name[$0] == statusName[$0] }
                        guard !sawRegular, !sawStatus, isStatus else {
                            misplaced = true
                            return
                        }
                        sawStatus = true
                        // Three digits is the only length HTTP/2 allows, and
                        // counting first keeps a hundred of them from
                        // overflowing.
                        guard span.valueLength == 3 else { return }
                        var value = 0
                        for i in 0..<3 {
                            let c = span.value[i]
                            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return }
                            value = value * 10 + Int(c - UInt8(ascii: "0"))
                        }
                        // Below 100 is not a status, and 0 is what the stream
                        // refuses on.
                        if value >= 100 { found = value }
                        return
                    }
                    sawRegular = true
                    collected.append(ClientHeader(
                        name: String(decoding: UnsafeBufferPointer(start: span.name, count: span.nameLength), as: UTF8.self),
                        value: String(decoding: UnsafeBufferPointer(start: span.value, count: span.valueLength), as: UTF8.self)))
                }
            }
        } catch {
            return false
        }
        status = misplaced ? -1 : found
        fields = collected
        tooLarge = over
        return true
    }
}

// MARK: - The process's shared connections

/// The HTTP/2 connections the client shares, by where they go.
final class H2Registry: Sendable {
    static let shared = H2Registry()

    private enum Entry {
        /// Up, and where new requests go.
        case open(H2Shared)
        /// Being opened by one request; the others wait on these.
        case connecting([IOEvent])
        /// The server chose HTTP/1.1 over ALPN: requests there connect, or
        /// take a kept connection, without waiting on each other.
        case http1
    }

    enum Found {
        case shared(H2Shared)
        /// Nothing is open or opening: the caller opens one, and must say how
        /// it went (`register`, `speaksHTTP1`, `connectFailed`).
        case connect
        case http1
    }

    private let entries = Mutex<[OriginKey: Entry]>([:])

    /// The connection to use for `key`, or what the caller is to do instead.
    /// Waits, one of the client's waits at a time, while another request is
    /// opening one: a request given 30 milliseconds that sat out somebody
    /// else's 500 was never given 30 milliseconds.
    func find(_ key: OriginKey, client: HTTPClient) async throws(ClientError) -> Found {
        var event: IOEvent? = nil
        while true {
            let mine = event ?? IOEvent()
            event = mine
            let found: Found? = entries.withLock { entries in
                switch entries[key] {
                case .open(let shared)?:
                    if shared.acceptsStreams { return .shared(shared) }
                    // Full, failed or told to go away: a new one takes its
                    // place for new requests, and it finishes what it has.
                    entries[key] = .connecting([])
                    return .connect
                case .connecting(var waiting)?:
                    waiting.append(mine)
                    entries[key] = .connecting(waiting)
                    return nil
                case .http1?:
                    return .http1
                case nil:
                    entries[key] = .connecting([])
                    return .connect
                }
            }
            if let found { return found }
            try await client.waiting { () async throws(IOError) in try await mine.wait() }
        }
    }

    /// `shared` is up: where requests to its place go from now on.
    func register(_ shared: H2Shared) {
        settle(shared.key, .open(shared))
    }

    /// The server chose HTTP/1.1.
    func speaksHTTP1(_ key: OriginKey) {
        settle(key, .http1)
    }

    /// The connect failed: the next request tries its own.
    func connectFailed(_ key: OriginKey) {
        settle(key, nil)
    }

    private func settle(_ key: OriginKey, _ entry: Entry?) {
        let waiting: [IOEvent] = entries.withLock { entries in
            var waiting: [IOEvent] = []
            if case .connecting(let list)? = entries[key] { waiting = list }
            entries[key] = entry
            return waiting
        }
        for event in waiting { event.signal() }
    }

    /// `shared` is gone; if it is still where requests go, nothing is now.
    func remove(_ shared: H2Shared) {
        entries.withLock { entries in
            if case .open(let current)? = entries[shared.key], current === shared {
                entries[shared.key] = nil
            }
        }
    }

    /// Every shared connection, for tests.
    var openCount: Int {
        entries.withLock { $0.values.reduce(0) { if case .open = $1 { return $0 + 1 }; return $0 } }
    }
}

// MARK: - Exchanges

extension HTTPClient {

    /// Sends the preface and our settings on a fresh connection, starts its
    /// reader, and keeps it.
    func startShared(_ reader: any ClientReader, _ writer: any ClientWriter,
                     _ key: OriginKey) async throws(ClientError) -> H2Shared {
        let shared = H2Shared(key: key, reader: reader, writer: writer)
        var out = ByteBuffer(capacity: 128)
        HTTP2.preface.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
        let entries: [(H2Setting, UInt32)] = [
            (.maxFrameSize, UInt32(H2FrameHeader.defaultMaxFrameSize)),
            (.initialWindowSize, UInt32(H2FrameHeader.defaultInitialWindowSize)),
            // Nothing here answers a promise, and saying so up front keeps a
            // server from reserving streams this client would only reset.
            (.enablePush, 0),
        ]
        H2FrameHeader(length: entries.count * 6, type: .settings, flags: [], streamID: 0).write(into: &out)
        for (setting, value) in entries {
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue))
            HTTP2.writeUInt32(value, into: &out)
        }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        // Nobody else can reach it yet, so no lock.
        do {
            try await waiting { () async throws(IOError) in
                try await bytes.withUnsafeBytesAsync { (bytes) async throws(IOError) in try await writer.write(bytes) }
            }
        } catch {
            H2Registry.shared.connectFailed(key)
            throw error
        }
        let task = Runtime.spawn { await shared.readLoop() }
        shared.lock.withLock { _ in shared.readerTask = task }
        H2Registry.shared.register(shared)
        return shared
    }

    /// The request's header block, which does not depend on the connection:
    /// nothing is indexed, so it encodes the same wherever it goes.
    func encodeRequestBlock(_ plan: Plan, method: HTTPMethod, headers: [(String, String)],
                            hasBody: Bool) throws(ClientError) -> [UInt8] {
        let encoder = HPACKEncoder()
        var block = ByteBuffer(capacity: 512)
        defer { block.destroy() }
        var token = method.name
        var authority = plan.authority
        var path = plan.target
        var scheme = plan.secure ? "https" : "http"
        token.withUTF8 { m in
            scheme.withUTF8 { s in
                authority.withUTF8 { a in
                    path.withUTF8 { p in
                        encoder.encodeRequestPseudoHeaders(
                            method: ByteSpan(m.baseAddress!, m.count), scheme: ByteSpan(s.baseAddress!, s.count),
                            authority: ByteSpan(a.baseAddress!, a.count), path: ByteSpan(p.baseAddress!, p.count),
                            into: &block)
                    }
                }
            }
        }

        var sawUserAgent = false
        for (name, value) in headers {
            var lower = name.lowercased()
            var value = value
            let ok = lower.withUTF8 { n -> Bool in
                value.withUTF8 { v -> Bool in
                    guard let np = n.baseAddress else { return false }
                    let empty: StaticString = ""
                    let vp = v.baseAddress ?? empty.utf8Start
                    // Connection-specific fields have no meaning in HTTP/2 and
                    // make a message malformed, RFC 9113 section 8.2.2 -- all
                    // but "te: trailers", which gRPC, for one, sends.
                    if HTTP2.isConnectionSpecific(np, n.count),
                       !(n.count == 2 && String(decoding: v, as: UTF8.self).lowercased() == "trailers") { return false }
                    if !HTTP2.validFieldName(np, n.count) { return false }
                    if !HTTP2.validFieldValue(vp, v.count) { return false }
                    let kind = HTTPRequestWriter.classify(ByteSpan(np, n.count))
                    if (decompress && kind.contains(.acceptEncoding)) || kind.contains(.expect) { return false }
                    if kind.contains(.host) { return false }
                    if kind.contains(.userAgent) { sawUserAgent = true }
                    encoder.encode(name: np, nameLength: n.count, value: vp, valueLength: v.count, into: &block)
                    return true
                }
            }
            guard ok else { throw .refusedHeader }
        }

        func literal(_ name: StaticString, _ value: String) {
            var value = value
            value.withUTF8 { b in
                let empty: StaticString = ""
                encoder.encode(name: name.utf8Start, nameLength: name.utf8CodeUnitCount,
                               value: b.baseAddress ?? empty.utf8Start, valueLength: b.count, into: &block)
            }
        }
        if decompress { literal("accept-encoding", RequestDecoder.acceptEncoding) }
        if !sawUserAgent, !userAgent.isEmpty { literal("user-agent", userAgent) }
        // HTTP/2 has no Transfer-Encoding, so a server that buffers by declared
        // length has only this to go on.
        if hasBody { literal("content-length", String(plan.bodyLength)) }

        return Array(UnsafeBufferPointer(start: block.readPointer, count: block.readableBytes))
    }

    /// One request on a shared connection, up to its final response head.
    func openShared(_ shared: H2Shared, block: [UInt8], method: HTTPMethod,
                    body: [UInt8], streaming: Bool) async throws(ClientError) -> ClientH2Stream {
        let stream = ClientH2Stream(method: method, recvWindow: shared.initialWindowSize,
                              maxHeadBytes: maxHeadBytes, maxBodyBytes: maxBodyBytes)
        stream.streaming = streaming
        do {
            try await openStream(shared, stream, block: block, endStream: body.isEmpty)
            if !body.isEmpty { try await sendBody(shared, stream, body) }
            try await waitFor(shared, stream) { stream.sawFinalHeaders || stream.done }
        } catch {
            abandon(shared, stream)
            throw error
        }
        return stream
    }

    /// The rest of a response, read whole.
    func finishShared(_ shared: H2Shared, _ stream: ClientH2Stream) async throws(ClientError) -> ClientResponse {
        do {
            try await waitFor(shared, stream) { stream.done }
        } catch {
            abandon(shared, stream)
            throw error
        }
        let (body, keeps) = shared.lock.withLock { _ in (stream.body, shared.dead == nil && !shared.goaway) }
        finish(shared, stream)
        return ClientResponse(status: stream.status, reason: "", headers: stream.headers,
                              body: stream.method == .head ? [] : body, reusedConnection: keeps)
    }

    /// The next piece of a streamed response's body, never empty, or nil at
    /// its end. What was taken is given back to the peer as window, so a
    /// caller that reads slowly holds the peer to one window's worth here.
    func nextShared(_ shared: H2Shared, _ stream: ClientH2Stream) async throws(ClientError) -> [UInt8]? {
        do {
            try await waitFor(shared, stream) { !stream.body.isEmpty || stream.done }
        } catch {
            abandon(shared, stream)
            throw error
        }
        let (piece, ended): ([UInt8], Bool) = shared.lock.withLock { _ in
            var piece: [UInt8] = []
            swap(&piece, &stream.body)
            if stream.method == .head { piece = [] }
            if !stream.done {
                let grant = shared.initialWindowSize - stream.recvWindow
                if grant >= shared.initialWindowSize / 2 {
                    shared.queueWindowUpdate(stream.id, grant)
                    stream.recvWindow += grant
                }
            }
            return (piece, stream.done)
        }
        if ended && piece.isEmpty {
            finish(shared, stream)
            return nil
        }
        if ended {
            finish(shared, stream)
        } else {
            // Sent now if nobody is writing; whoever is sends it on the way
            // out. Left queued with nobody writing, the peer would wait for
            // credit while this waits for data.
            shared.flushControl()
        }
        return piece
    }

    /// Gives up on a streamed response: the peer is told to stop sending.
    func cancelShared(_ shared: H2Shared, _ stream: ClientH2Stream) {
        abandon(shared, stream)
    }

    /// Allocates the stream's id and writes its HEADERS, both under the lock.
    private func openStream(_ shared: H2Shared, _ stream: ClientH2Stream, block: [UInt8],
                            endStream: Bool) async throws(ClientError) {
        try await shared.lockWriting()
        let frames: [UInt8]? = shared.lock.withLock { _ in
            // Somebody else filled it, or it was told to go away, while this
            // waited for the lock. Nothing was sent, so this is safe to retry.
            guard shared.acceptsStreamsLocked else { return nil }
            stream.id = shared.nextStreamID
            shared.nextStreamID &+= 2
            stream.sendWindow = shared.peerInitialWindowSize
            shared.streams[stream.id] = stream
            shared.headCap = max(shared.headCap, stream.maxHeadBytes)

            var out = ByteBuffer(capacity: block.count + 32)
            defer { out.destroy() }
            let limit = shared.peerMaxFrameSize
            var at = 0
            var first = true
            repeat {
                let n = min(limit, block.count - at)
                var flags: H2Flags = []
                if at + n == block.count { flags.insert(.endHeaders) }
                if first && endStream { flags.insert(.endStream) }
                H2FrameHeader(length: n, type: first ? .headers : .continuation, flags: flags,
                              streamID: stream.id).write(into: &out)
                block.withUnsafeBufferPointer { out.write($0.baseAddress! + at, n) }
                at += n
                first = false
            } while at < block.count
            return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        }
        guard let frames else {
            let dead = shared.lock.withLock { _ in shared.dead }
            await shared.unlockWriting()
            throw dead ?? .streamReset(H2Error.refusedStream.rawValue)
        }
        do {
            try await shared.writeLocked(self, frames)
        } catch {
            await shared.unlockWriting()
            throw error
        }
        await shared.unlockWriting()
    }

    /// DATA, one frame per lock, inside both windows.
    private func sendBody(_ shared: H2Shared, _ stream: ClientH2Stream, _ body: [UInt8]) async throws(ClientError) {
        var sent = 0
        while sent < body.count {
            // Credit only the reader can deliver, so the lock is not held
            // while waiting for it.
            try await waitFor(shared, stream) {
                stream.done || (shared.sendWindow > 0 && stream.sendWindow > 0)
            }
            // The server answered before the body was finished -- a 413, say.
            // What it said is the answer; the rest of the body is not wanted.
            if shared.lock.withLock({ _ in stream.done }) { return }

            try await shared.lockWriting()
            // Measured and spent under the lock, with no suspension between,
            // so two streams cannot both spend the same connection credit.
            let frame: [UInt8]? = shared.lock.withLock { _ in
                var n = min(body.count - sent, shared.peerMaxFrameSize)
                n = min(n, shared.sendWindow)
                n = min(n, stream.sendWindow)
                guard n > 0, !stream.done, stream.error == nil, shared.dead == nil else { return nil }
                shared.sendWindow -= n
                stream.sendWindow -= n
                let last = sent + n == body.count
                var out = ByteBuffer(capacity: n + 16)
                defer { out.destroy() }
                H2FrameHeader(length: n, type: .data, flags: last ? .endStream : [], streamID: stream.id)
                    .write(into: &out)
                body.withUnsafeBufferPointer { out.write($0.baseAddress! + sent, n) }
                return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
            }
            guard let frame else {
                await shared.unlockWriting()
                if let error = shared.lock.withLock({ _ in stream.error ?? shared.dead }) { throw error }
                continue
            }
            do {
                try await shared.writeLocked(self, frame)
            } catch {
                await shared.unlockWriting()
                throw error
            }
            await shared.unlockWriting()
            sent += frame.count - H2FrameHeader.size
        }
    }

    /// Waits, a wait at a time, until `ready` holds -- asked under the lock --
    /// or the stream or the connection fails.
    private func waitFor(_ shared: H2Shared, _ stream: ClientH2Stream,
                         until ready: () -> Bool) async throws(ClientError) {
        while true {
            let outcome: ClientError?? = shared.lock.withLock { _ in
                if ready() { return .some(nil) }
                if let error = stream.error { return .some(error) }
                if let dead = shared.dead { return .some(dead) }
                return nil
            }
            if let outcome {
                if let error = outcome { throw error }
                return
            }
            try await waiting { () async throws(IOError) in try await stream.changed.wait() }
        }
    }

    // MARK: Leaving

    /// A stream that finished normally.
    private func finish(_ shared: H2Shared, _ stream: ClientH2Stream) {
        let close = shared.lock.withLock { _ in
            if shared.streams[stream.id] === stream { shared.streams.removeValue(forKey: stream.id) }
            return shared.streams.isEmpty && shared.goaway
        }
        if close { shared.fail(.closed) }
    }

    /// A stream this request is giving up on.
    ///
    /// The peer is told, unless it already knows. Otherwise it goes on sending
    /// DATA for a stream nobody will read, spending connection credit every
    /// other stream needs.
    private func abandon(_ shared: H2Shared, _ stream: ClientH2Stream) {
        let close = shared.lock.withLock { _ in
            if stream.id != 0, shared.streams[stream.id] === stream {
                shared.streams.removeValue(forKey: stream.id)
                if !stream.done && !stream.closedByPeer && shared.dead == nil {
                    shared.queueReset(stream.id, .cancel)
                }
            }
            return shared.streams.isEmpty && shared.goaway
        }
        shared.flushControl()
        if close { shared.fail(.closed) }
    }
}

extension Array where Element == UInt8 {
    /// The bytes, for an async body, copied to memory the call owns: an
    /// array's own may not be held across a suspension.
    func withUnsafeBytesAsync<R>(_ body: (UnsafeRawBufferPointer) async throws(IOError) -> R) async throws(IOError) -> R {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
        defer { raw.deallocate() }
        withUnsafeBytes { raw.copyMemory(from: $0) }
        return try await body(UnsafeRawBufferPointer(raw))
    }
}

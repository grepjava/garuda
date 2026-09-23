//===----------------------------------------------------------------------===//
// HTTP/2 over connections this worker made, shared by every request to the
// same place.
//
// A frame loop of its own rather than the server's. The framing primitives are
// shared -- H2FrameHeader, the flags, the settings, the preface, HPACK -- but
// every frame handler next door is `extension Worker` taking a connection-table
// slot, and half of H2Connection is server state: a concurrency limit imposed
// on a peer, the highest identifier a peer opened, the reset budget that
// answers CVE-2023-44487. A client opens and cancels its own streams.
//
// ## Who reads
//
// Many requests use one connection at once, and somebody has to read its
// frames and hand each to the stream it belongs to. Not a reader task of its
// own: handler tasks belong to requests from end to end, and a worker shutting
// down will not end a task suspended on something other than the engine, so a
// connection-lifetime reader would outlive a drain.
//
// So the read is a baton. Whichever request is waiting for something the
// connection has to deliver takes it if nobody holds it, waits on the socket,
// reads, dispatches every whole frame to its stream, and puts it down. Anyone
// else waiting parks on their own stream and is woken when that stream
// changes. A request that leaves wakes one parked request, which takes the
// baton if the connection still needs a reader -- so while any request is
// waiting, one of them is reading. A dropped baton parks everyone until they
// time out; two readers would hand the same bytes to two streams. Both are
// what the tests are for.
//
// The baton is also the only right to wait on the socket at all, in either
// direction. An outbound record holds exactly one waiter, so a writer whose
// socket is full cannot start a wait of its own: it widens the reader's wait
// to include writability and parks, and the reader wakes it.
//
// ## Who writes
//
// A frame must reach the wire whole, and a header block split across
// CONTINUATION must reach it with nothing in between, so writing is under a
// lock. Two rules keep that lock from deadlocking against the baton:
//
//   * DATA is written one frame per lock, and never while waiting for flow
//     control credit -- which only a reader can deliver, and a reader may
//     need the lock.
//   * A reader never takes the lock for its own replies. SETTINGS and PING
//     acknowledgements, WINDOW_UPDATEs and RST_STREAMs go into a control queue
//     that the lock's holder flushes on its way out, or the reader flushes
//     itself when the lock is free.
//
// Stream identifiers are allocated under the lock too. A new stream's id has
// to exceed every id opened before it, so an id taken before waiting for the
// lock could reach the wire after a larger one and be illegal on arrival.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

// MARK: - State

/// Settings, flow control and HPACK for one connection.
/// A request parked on a connect another request started, and when its own
/// patience runs out.
///
/// The deadline is the waiter's own. Joining a connect saves opening a second
/// one to the same place, but it must not lend whoever started it the right to
/// decide how long anybody else waits: a request given 30 milliseconds that sat
/// out somebody else's 500 was never given 30 milliseconds.
struct H2ConnectWaiter {
    let resume: UnsafeContinuation<Void, Never>
    let deadline: UInt64
}

final class H2ClientConnection {
    var decoder: HPACKDecoder

    /// What the peer imposed, in its SETTINGS.
    var peerMaxFrameSize = H2FrameHeader.defaultMaxFrameSize
    var peerInitialWindowSize = H2FrameHeader.defaultInitialWindowSize
    var peerMaxHeaderListSize = Int.max
    var peerMaxConcurrentStreams = Int.max

    /// What we advertised.
    let maxFrameSize = H2FrameHeader.defaultMaxFrameSize
    let initialWindowSize = H2FrameHeader.defaultInitialWindowSize

    /// Connection-level flow control, separate from every stream's.
    var sendWindow = H2FrameHeader.defaultInitialWindowSize
    var recvWindow = H2FrameHeader.defaultInitialWindowSize

    /// Client streams are odd, RFC 9113 section 5.1.1.
    var nextStreamID: UInt32 = 1

    /// Header block assembly across CONTINUATION, which is per connection:
    /// nothing may come between the parts, whatever stream they are for.
    var headerBlock = ByteBuffer()
    var headerStream: UInt32 = 0
    var headerEndsStream = false
    var expectingContinuation = false
    /// The head limit of the stream the block being assembled belongs to,
    /// taken when its HEADERS arrived. A block comes in as many CONTINUATION
    /// frames as the peer cares to send, so the per-frame cap bounds none of
    /// this and something has to.
    var headBudget = Int.max

    init() {
        decoder = HPACKDecoder(maxTableSize: 4096)
    }

    func destroy() {
        decoder.destroy()
        headerBlock.destroy()
    }
}

/// One request's stream.
final class H2Stream {
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
    /// The peer reset it, so nothing needs sending back.
    var closedByPeer = false
    /// When this request gives up if nothing happens. Pushed back by every
    /// frame for the stream, so it bounds silence rather than the exchange --
    /// up to `exchangeDeadline`, which it never passes.
    var deadline: UInt64
    /// How far each frame pushes `deadline`: the request's own
    /// `timeoutMilliseconds`, whoever happens to be reading the connection.
    let waitMilliseconds: UInt64
    /// This request's own limits. A connection is shared, and whoever happens
    /// to be reading it must not lend its limits to another stream: that both
    /// fails responses inside their own limit and lets one past a tighter one.
    let maxHeadBytes: Int
    let maxBodyBytes: Int
    /// What Content-Length promised, or -1 where the head named no length or
    /// none is owed (HEAD, 204, 304). DATA payload bytes are counted against
    /// it so that a stream ended early is refused rather than handed over as
    /// a whole response: RFC 9113 8.1.1 makes that mismatch malformed.
    var declaredLength = -1
    var receivedLength = 0
    /// When the whole exchange must be over, or 0 for no such bound. Cleared
    /// once a streamed response's head is in, after which only silence ends it.
    var exchangeDeadline: UInt64
    /// Read by the caller as it arrives, so its window is opened as the
    /// caller takes the bytes rather than as they come, and no body limit
    /// applies: the window is what bounds what waits here.
    var streaming = false
    /// The request's task, while it is parked waiting for this stream.
    var waiter: UnsafeContinuation<Void, Never>? = nil

    init(method: HTTPMethod, recvWindow: Int, waitMilliseconds: UInt64, exchangeDeadline: UInt64,
         maxHeadBytes: Int, maxBodyBytes: Int) {
        self.method = method
        self.recvWindow = recvWindow
        self.waitMilliseconds = waitMilliseconds
        self.exchangeDeadline = exchangeDeadline
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
        deadline = 0
        renew(at: av_monotonic_ms())
    }

    /// Something happened on the stream at `now`.
    func renew(at now: UInt64) {
        let own = now &+ waitMilliseconds
        deadline = exchangeDeadline == 0 ? own : min(own, exchangeDeadline)
    }
}

/// An HTTP/2 connection shared by every request to one place.
final class H2Shared {
    let key: OutboundKey
    let socket: OutboundSocket
    let conn = H2ClientConnection()
    var streams: [UInt32: H2Stream] = [:]
    /// The largest head limit of any stream opened here: what a header block
    /// may come to, encoded, before the connection is ended over it. One
    /// stream's own limit is not the connection's -- a block past it but
    /// within this is decoded and fails that stream alone.
    var headCap = 0

    /// Bytes read and not yet dispatched. Belongs to the connection, not to
    /// whoever read them: a reader that puts the baton down leaves a partial
    /// frame for the next one.
    var input = ByteBuffer(capacity: 16384)
    /// Control frames waiting for the write lock.
    var control = ByteBuffer(capacity: 64)

    var readerActive = false
    var writerActive = false
    var writeQueue: [UnsafeContinuation<Void, Never>] = []
    /// A lock holder whose socket is full, waiting for the reader to see it
    /// writable.
    var blockedWriter: H2Stream? = nil
    var writableSeen = false

    var dead: ClientError? = nil
    var goaway = false
    var idleSince: UInt64

    init(key: OutboundKey, socket: OutboundSocket) {
        self.key = key
        self.socket = socket
        idleSince = av_monotonic_ms()
    }

    deinit {
        conn.destroy()
        input.destroy()
        control.destroy()
    }

    /// Whether a new stream may be opened here.
    var acceptsStreams: Bool {
        dead == nil && !goaway && socket.isOpen
            && streams.count < conn.peerMaxConcurrentStreams
            && conn.nextStreamID < 0x7FFF_FFFF
    }

    /// Records that the connection is gone.
    ///
    /// Wakes nobody, and that is deliberate rather than an omission. A version
    /// that woke every parked request and every lock waiter here survived
    /// mutation testing with both removed, because nothing can reach them that
    /// the chain does not already: whoever notices the death is the reader or
    /// a writer, and it leaves through `abandon`, which wakes one parked
    /// request, which finds `dead` and leaves the same way, and so on; a lock
    /// holder always unlocks on its way out. A wake here that no input can make
    /// necessary reads as a safeguard while providing none.
    func markDead(_ error: ClientError) {
        guard dead == nil else { return }
        dead = error
    }

    func wake(_ stream: H2Stream) {
        stream.waiter.take()?.resume()
    }

    func wakeAll() {
        for stream in streams.values { stream.waiter.take()?.resume() }
    }

    /// Wakes one parked request, other than `except`, so that if the
    /// connection still needs a reader, somebody takes the baton.
    func wakeOne(except: H2Stream) {
        for stream in streams.values where stream !== except {
            if let k = stream.waiter.take() {
                k.resume()
                return
            }
        }
    }

    func queueControl(_ type: H2FrameType, flags: H2Flags = [], stream: UInt32,
                      _ payload: (inout ByteBuffer) -> Void, length: Int) {
        H2FrameHeader(length: length, type: type, flags: flags, streamID: stream)
            .write(into: &control)
        payload(&control)
    }

    func queueReset(_ id: UInt32, _ code: H2Error) {
        queueControl(.rstStream, stream: id, { HTTP2.writeUInt32(code.rawValue, into: &$0) },
                     length: 4)
    }

    func queueWindowUpdate(_ id: UInt32, _ increment: Int) {
        guard increment > 0 else { return }
        queueControl(.windowUpdate, stream: id,
                     { HTTP2.writeUInt32(UInt32(increment), into: &$0) }, length: 4)
    }
}

// MARK: - The worker's shared connections

extension Worker {

    /// Every shared connection is told it has gone. Sockets are not closed
    /// here: the caller is about to close every outbound record itself, and
    /// doing it through a handle would reach back into the worker mid-call.
    mutating func failAllSharedH2() {
        let all = Array(outboundH2.values)
        outboundH2.removeAll()
        // Closing each record is what wakes its reader, with `.cancelled`; the
        // reader leaving through `abandon` wakes the rest in turn.
        for shared in all { shared.markDead(.cancelled) }
        let waiting = outboundH2Connecting.values.flatMap { $0 }
        outboundH2Connecting.removeAll()
        for waiter in waiting { waiter.resume.resume() }
    }

    /// Wakes the requests whose wait on another request's connect has run out.
    ///
    /// The connect itself is left alone: the request that started it has its own
    /// patience, which may be longer, and cancelling it would punish it for
    /// somebody else's deadline. The woken requests find no connection and give
    /// up, which is what their own timeout asked for.
    mutating func expireConnectWaiters(now: UInt64) {
        var expired: [H2ConnectWaiter] = []
        for (key, waiters) in outboundH2Connecting {
            guard waiters.contains(where: { now >= $0.deadline }) else { continue }
            // The key stays whether or not anyone is left waiting on it: its
            // presence is what says a connect is under way.
            outboundH2Connecting[key] = waiters.filter { now < $0.deadline }
            expired.append(contentsOf: waiters.filter { now >= $0.deadline })
        }
        // Resumed once the table is settled, never while walking it.
        for waiter in expired { waiter.resume.resume() }
    }

    /// Closes shared connections nobody has used for a while, or that cannot
    /// be used again.
    mutating func sweepIdleH2(now: UInt64) {
        for (key, shared) in outboundH2 {
            guard shared.streams.isEmpty, !shared.readerActive, !shared.writerActive else {
                continue
            }
            let stale = now &- shared.idleSince >= outboundIdleMillis
            if stale || shared.dead != nil || shared.goaway || !shared.socket.isOpen {
                outboundH2.removeValue(forKey: key)
                shared.markDead(.closed)
                closeOutbound(shared.socket.index)
            }
        }
    }
}

// MARK: - Exchanges

extension HTTPClient {

    /// Whether the ALPN list offers HTTP/2 at all.
    var offersHTTP2: Bool {
        alpn.split(separator: ",").contains { $0.trimmingSpaces == "h2" }
    }

    /// Where a shared connection for `plan` is kept.
    ///
    /// Keyed on the name asked for, not the address it resolved to, so a
    /// request finds the connection before paying for a lookup. Plaintext
    /// HTTP/2 is only ever forced, and gets a marker no HTTP/1.1 key can spell.
    func sharedKey(_ plan: Plan) -> OutboundKey {
        if plan.secure {
            return OutboundKey(host: plan.host, port: plan.port,
                               tls: OutboundKey.tlsIdentity(hostname: plan.host,
                                                            caFile: caFile, alpn: alpn))
        }
        return OutboundKey(host: plan.host, port: plan.port, tls: "\u{0}h2c")
    }

    /// A shared connection that can take another stream, or nil.
    ///
    /// An idle one is read first, without waiting. Nobody reads a connection
    /// with no streams, so whatever the peer said meanwhile -- a GOAWAY, a
    /// close, settings -- is still sitting there, and a request written into a
    /// connection that has already been told to go away is a request that
    /// fails for no reason of its own.
    func reusableShared(_ key: OutboundKey) -> H2Shared? {
        guard let shared = worker.pointee.outboundH2[key] else { return nil }
        if shared.streams.isEmpty && !shared.readerActive && !shared.writerActive {
            if let failure = drainWithoutWaiting(shared) {
                retire(shared, failure)
                return nil
            }
        }
        if shared.dead != nil || shared.goaway || !shared.socket.isOpen {
            if shared.streams.isEmpty { retire(shared, shared.dead ?? .closed) }
            return nil
        }
        return shared.acceptsStreams ? shared : nil
    }

    /// Sends the preface and our settings on a fresh connection, and keeps it.
    func startShared(_ socket: OutboundSocket, _ key: OutboundKey) async throws(ClientError) -> H2Shared {
        var out = ByteBuffer(capacity: 128)
        defer { out.destroy() }
        HTTP2.preface.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
        let entries: [(H2Setting, UInt32)] = [
            (.maxFrameSize, UInt32(H2FrameHeader.defaultMaxFrameSize)),
            (.initialWindowSize, UInt32(H2FrameHeader.defaultInitialWindowSize)),
            // Nothing here answers a promise, and saying so up front keeps a
            // server from reserving streams this client would only reset.
            (.enablePush, 0),
        ]
        H2FrameHeader(length: entries.count * 6, type: .settings, flags: [], streamID: 0)
            .write(into: &out)
        for (setting, value) in entries {
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
            out.writeByte(UInt8(truncatingIfNeeded: setting.rawValue))
            HTTP2.writeUInt32(value, into: &out)
        }
        // Nobody else can reach it yet, so no lock.
        do {
            try await writeAll(socket, out.readPointer, out.readableBytes)
        } catch {
            socket.close()
            throw error
        }
        let shared = H2Shared(key: key, socket: socket)
        // A connection this replaces is left to finish its streams, and closes
        // when it has none: it is no longer where new requests are sent.
        worker.pointee.outboundH2[key] = shared
        return shared
    }

    /// The request's header block, which does not depend on the connection:
    /// nothing is indexed, so it encodes the same wherever it goes.
    func encodeRequestBlock(_ plan: Plan, method: HTTPMethod, headers: [(String, String)],
                            hasBody: Bool) throws(ClientError) -> [UInt8] {
        guard let token = method.token else { throw .refusedHeader }
        let encoder = HPACKEncoder()
        var block = ByteBuffer(capacity: 512)
        defer { block.destroy() }
        let authority = Array(plan.authority.utf8)
        let path = Array(plan.target.utf8)
        let scheme = Array((plan.secure ? "https" : "http").utf8)

        UnsafeRawPointer(token.utf8Start).withMemoryRebound(
            to: UInt8.self, capacity: token.utf8CodeUnitCount) { m in
            scheme.withUnsafeBufferPointer { s in
                authority.withUnsafeBufferPointer { a in
                    path.withUnsafeBufferPointer { p in
                        encoder.encodeRequestPseudoHeaders(
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
            let nameBytes = Array(name.lowercased().utf8)
            let valueBytes = Array(value.utf8)
            let ok = nameBytes.withUnsafeBufferPointer { n -> Bool in
                valueBytes.withUnsafeBufferPointer { v -> Bool in
                    guard let np = n.baseAddress else { return false }
                    let empty: StaticString = ""
                    let vp = v.baseAddress ?? empty.utf8Start
                    // Connection-specific fields have no meaning in HTTP/2 and
                    // make a message malformed, RFC 9113 section 8.2.2.
                    if HTTP2.isConnectionSpecific(np, n.count) { return false }
                    if !HTTP2.validFieldName(np, n.count) { return false }
                    if !HTTP2.validFieldValue(vp, v.count) { return false }
                    let kind = HTTPRequestWriter.classify(ByteSpan(np, n.count))
                    if (decompress && kind.contains(.acceptEncoding)) || kind.contains(.expect) { return false }
                    if kind.contains(.host) { return false }
                    if kind.contains(.userAgent) { sawUserAgent = true }
                    encoder.encode(name: np, nameLength: n.count,
                                   value: vp, valueLength: v.count, into: &block)
                    return true
                }
            }
            guard ok else { throw .refusedHeader }
        }

        func literal(_ name: StaticString, _ value: String) {
            let bytes = Array(value.utf8)
            bytes.withUnsafeBufferPointer { b in
                UnsafeRawPointer(name.utf8Start).withMemoryRebound(
                    to: UInt8.self, capacity: name.utf8CodeUnitCount) { n in
                    encoder.encode(name: n, nameLength: name.utf8CodeUnitCount,
                                   value: b.baseAddress!, valueLength: b.count, into: &block)
                }
            }
        }
        if decompress { literal("accept-encoding", ContentDecoder.acceptEncoding) }
        if !sawUserAgent, !userAgent.isEmpty { literal("user-agent", userAgent) }
        // HTTP/2 has no Transfer-Encoding, so a server that buffers by declared
        // length has only this to go on.
        if hasBody { literal("content-length", String(plan.bodyLength)) }

        return Array(UnsafeBufferPointer(start: block.readPointer, count: block.readableBytes))
    }

    /// One request on a shared connection, up to its final response head.
    func openShared(_ shared: H2Shared, block: [UInt8], method: HTTPMethod,
                    body: [UInt8], streaming: Bool) async throws(ClientError) -> H2Stream {
        let stream = H2Stream(method: method, recvWindow: shared.conn.initialWindowSize,
                              waitMilliseconds: timeoutMilliseconds, exchangeDeadline: deadline,
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
    func finishShared(_ shared: H2Shared, _ stream: H2Stream) async throws(ClientError) -> ClientResponse {
        do {
            try await waitFor(shared, stream) { stream.done }
        } catch {
            abandon(shared, stream)
            throw error
        }
        finish(shared, stream)
        let keeps = shared.dead == nil && !shared.goaway
        return ClientResponse(status: stream.status, reason: "", headers: stream.headers,
                              body: stream.method == .head ? [] : stream.body,
                              reusedConnection: keeps)
    }

    /// The next piece of a streamed response's body, never empty, or nil at
    /// its end. What was taken is given back to the peer as window, so a
    /// caller that reads slowly holds the peer to one window's worth here.
    func nextShared(_ shared: H2Shared, _ stream: H2Stream) async throws(ClientError) -> [UInt8]? {
        do {
            try await waitFor(shared, stream) { !stream.body.isEmpty || stream.done }
        } catch {
            abandon(shared, stream)
            throw error
        }
        guard !stream.body.isEmpty, stream.method != .head else {
            finish(shared, stream)
            return nil
        }
        var piece: [UInt8] = []
        swap(&piece, &stream.body)
        if !stream.done {
            let grant = shared.conn.initialWindowSize - stream.recvWindow
            if grant >= shared.conn.initialWindowSize / 2 {
                shared.queueWindowUpdate(stream.id, grant)
                stream.recvWindow += grant
                // Sent now if nobody holds the lock -- whoever does flushes it
                // on the way out. Left queued with nobody writing, the peer
                // would wait for credit while this waits for data.
                if !shared.writerActive, shared.dead == nil {
                    do {
                        try await lock(shared)
                    } catch {
                        abandon(shared, stream)
                        throw error
                    }
                    await unlock(shared, stream)
                }
            }
        } else {
            finish(shared, stream)
        }
        return piece
    }

    /// Gives up on a streamed response: the peer is told to stop sending.
    func cancelShared(_ shared: H2Shared, _ stream: H2Stream) {
        abandon(shared, stream)
    }

    /// Allocates the stream's id and writes its HEADERS, both under the lock.
    private func openStream(_ shared: H2Shared, _ stream: H2Stream, block: [UInt8],
                            endStream: Bool) async throws(ClientError) {
        try await lock(shared)
        guard shared.dead == nil, shared.acceptsStreams else {
            await unlock(shared, stream)
            // Somebody else filled it, or it was told to go away, while this
            // waited for the lock. Nothing was sent, so this is safe to retry.
            throw shared.dead ?? .streamReset(H2Error.refusedStream.rawValue)
        }
        stream.id = shared.conn.nextStreamID
        shared.conn.nextStreamID &+= 2
        stream.sendWindow = shared.conn.peerInitialWindowSize
        shared.streams[stream.id] = stream
        shared.headCap = max(shared.headCap, stream.maxHeadBytes)

        var out = ByteBuffer(capacity: block.count + 32)
        defer { out.destroy() }
        let limit = shared.conn.peerMaxFrameSize
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
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        do {
            try await writeLocked(shared, stream, bytes)
        } catch {
            await unlock(shared, stream)
            throw error
        }
        await unlock(shared, stream)
    }

    /// DATA, one frame per lock, inside both windows.
    private func sendBody(_ shared: H2Shared, _ stream: H2Stream,
                          _ body: [UInt8]) async throws(ClientError) {
        var sent = 0
        while sent < body.count {
            // Credit only a reader can deliver, so the lock is not held while
            // waiting for it: a reader may need the lock, and a writer holding
            // it until credit arrives would wait for itself.
            try await waitFor(shared, stream) {
                stream.done || stream.error != nil
                    || (shared.conn.sendWindow > 0 && stream.sendWindow > 0)
            }
            if let error = stream.error { throw error }
            // The server answered before the body was finished -- a 413, say.
            // What it said is the answer; the rest of the body is not wanted.
            if stream.done { return }

            try await lock(shared)
            // Measured and spent under the lock, with no suspension between,
            // so two streams cannot both spend the same connection credit.
            var n = min(body.count - sent, shared.conn.peerMaxFrameSize)
            n = min(n, shared.conn.sendWindow)
            n = min(n, stream.sendWindow)
            if n <= 0 || stream.done || shared.dead != nil {
                await unlock(shared, stream)
                if let dead = shared.dead { throw dead }
                continue
            }
            shared.conn.sendWindow -= n
            stream.sendWindow -= n
            let last = sent + n == body.count
            var out = ByteBuffer(capacity: n + 16)
            H2FrameHeader(length: n, type: .data, flags: last ? .endStream : [],
                          streamID: stream.id).write(into: &out)
            body.withUnsafeBufferPointer { out.write($0.baseAddress! + sent, n) }
            let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
            out.destroy()
            do {
                try await writeLocked(shared, stream, bytes)
            } catch {
                await unlock(shared, stream)
                throw error
            }
            await unlock(shared, stream)
            sent += n
            stream.renew(at: av_monotonic_ms())
        }
    }

    // MARK: Leaving

    /// A stream that finished normally.
    private func finish(_ shared: H2Shared, _ stream: H2Stream) {
        shared.streams.removeValue(forKey: stream.id)
        shared.wakeOne(except: stream)
        settleIfEmpty(shared)
    }

    /// A stream this request is giving up on.
    ///
    /// The peer is told, unless it already knows. Otherwise it goes on sending
    /// DATA for a stream nobody will read, spending connection credit every
    /// other stream needs.
    private func abandon(_ shared: H2Shared, _ stream: H2Stream) {
        if stream.id != 0, shared.streams[stream.id] === stream {
            shared.streams.removeValue(forKey: stream.id)
            if !stream.done && !stream.closedByPeer && shared.dead == nil {
                shared.queueReset(stream.id, .cancel)
            }
        }
        if shared.blockedWriter === stream { shared.blockedWriter = nil }
        shared.wakeOne(except: stream)
        settleIfEmpty(shared)
    }

    /// A connection with no streams is kept for the next request if it is
    /// still where requests go, and closed otherwise.
    private func settleIfEmpty(_ shared: H2Shared) {
        guard shared.streams.isEmpty else { return }
        shared.idleSince = av_monotonic_ms()
        let registered = worker.pointee.outboundH2[shared.key] === shared
        if !registered || shared.dead != nil || shared.goaway {
            retire(shared, shared.dead ?? .closed)
        }
    }

    /// Takes a connection out of use for good.
    func retire(_ shared: H2Shared, _ error: ClientError) {
        shared.markDead(error)
        if worker.pointee.outboundH2[shared.key] === shared {
            worker.pointee.outboundH2.removeValue(forKey: shared.key)
        }
        shared.socket.close()
    }

    // MARK: The write lock

    private func lock(_ shared: H2Shared) async throws(ClientError) {
        while shared.writerActive {
            if let dead = shared.dead { throw dead }
            await withUnsafeContinuation { shared.writeQueue.append($0) }
        }
        if let dead = shared.dead { throw dead }
        shared.writerActive = true
    }

    /// Releases the lock, flushing queued control frames first: whoever holds
    /// the lock is the only one who may write them, and a reader may have
    /// queued them while this held it.
    private func unlock(_ shared: H2Shared, _ stream: H2Stream) async {
        if shared.dead == nil, shared.control.readableBytes > 0 {
            let bytes = Array(UnsafeBufferPointer(start: shared.control.readPointer,
                                                  count: shared.control.readableBytes))
            shared.control.clear()
            // A failure here is the connection failing, which writeLocked
            // records; the stream that happened to be flushing is not at fault.
            try? await writeLocked(shared, stream, bytes)
        }
        shared.writerActive = false
        if !shared.writeQueue.isEmpty { shared.writeQueue.removeFirst().resume() }
    }

    /// Writes all of `bytes`, holding the lock.
    private func writeLocked(_ shared: H2Shared, _ stream: H2Stream,
                             _ bytes: [UInt8]) async throws(ClientError) {
        var sent = 0
        while sent < bytes.count {
            if let dead = shared.dead { throw dead }
            let n: Int
            do {
                n = try bytes.withUnsafeBufferPointer { buffer in
                    try shared.socket.write(UnsafeRawBufferPointer(
                        start: buffer.baseAddress! + sent, count: buffer.count - sent))
                }
            } catch {
                // withUnsafeBufferPointer erases the typed throw.
                let failure: ClientError = (error as? OutboundError) == .cancelled ? .cancelled : .closed
                retire(shared, failure)
                throw failure
            }
            sent += n
            guard sent < bytes.count else { break }
            // The socket is full. Only the baton's holder may wait on it, so
            // ask for writability through that wait rather than a second one.
            shared.blockedWriter = stream
            shared.writableSeen = false
            if shared.readerActive { shared.socket.watch([.read, .write]) }
            do {
                try await waitFor(shared, stream) { shared.writableSeen }
            } catch {
                if shared.blockedWriter === stream { shared.blockedWriter = nil }
                throw error
            }
            if shared.blockedWriter === stream { shared.blockedWriter = nil }
        }
    }

    // MARK: The read baton

    /// Makes the connection deliver until `ready` holds.
    ///
    /// Reads if nobody is reading, parks if somebody is.
    ///
    /// Returning does not hand the baton on; `finish` and `abandon` do. That
    /// is enough because every way out of here either comes back in -- a body
    /// waiting for credit, a writer waiting for the socket -- where it reads
    /// if nobody is, or reaches one of those two. An earlier version also
    /// woke a parked request on every return, and mutation testing showed it
    /// changed nothing but the number of spurious wakes: one per DATA frame
    /// sent.
    private func waitFor(_ shared: H2Shared, _ stream: H2Stream,
                         until ready: () -> Bool) async throws(ClientError) {
        while !ready() {
            if let dead = shared.dead { throw dead }
            if let error = stream.error { throw error }
            if av_monotonic_ms() >= stream.deadline { throw .timedOut }
            if shared.readerActive {
                await withUnsafeContinuation { stream.waiter = $0 }
                continue
            }
            shared.readerActive = true
            let failure = await readSome(shared)
            shared.readerActive = false
            if let failure {
                retire(shared, failure)
                throw failure
            }
            // Replies the reader owes go out now if nobody holds the lock --
            // after the baton is put down, so that a full socket here can be
            // waited on by the ordinary route.
            if !shared.writerActive, shared.control.readableBytes > 0, shared.dead == nil {
                try await lock(shared)
                await unlock(shared, stream)
            }
            let now = av_monotonic_ms()
            for other in shared.streams.values where other !== stream && now >= other.deadline {
                shared.wake(other)
            }
        }
    }

    /// Dispatches whatever whole frames are buffered, or waits on the socket
    /// for more and then dispatches. The caller holds the baton.
    private func readSome(_ shared: H2Shared) async -> ClientError? {
        switch dispatchBuffered(shared) {
        case .failed(let error): return error
        case .progressed: return nil
        case .nothing: break
        }

        if !shared.socket.hasBufferedInput {
            var mask: PollMask = .read
            if shared.blockedWriter != nil { mask.insert(.write) }
            // Woken at the earliest deadline of any stream, so a parked request
            // that has run out of time is told even while nothing arrives.
            let now = av_monotonic_ms()
            var earliest = UInt64.max
            for s in shared.streams.values { earliest = min(earliest, s.deadline) }
            let wait = earliest == .max ? timeoutMilliseconds
                : max(1, earliest > now ? earliest - now : 1)
            do {
                try await shared.socket.wait(mask, milliseconds: wait)
            } catch {
                // Silence is not the connection failing: each request checks
                // its own deadline.
                if error == .timedOut { return nil }
                return error == .cancelled ? .cancelled : .closed
            }
            if let writer = shared.blockedWriter {
                // Which of the two fired is not reported, so the writer is
                // told to try; a socket still full sends it back here.
                shared.writableSeen = true
                shared.wake(writer)
            }
        }

        shared.input.reserve(16384)
        do {
            let n = try shared.socket.read(into: UnsafeMutableRawBufferPointer(
                start: shared.input.writePointer, count: shared.input.writableBytes))
            shared.input.advanceWriter(n)
        } catch {
            return error == .cancelled ? .cancelled : .closed
        }

        if case .failed(let error) = dispatchBuffered(shared) { return error }
        return nil
    }

    /// Reads what an idle connection has without waiting, and dispatches it.
    private func drainWithoutWaiting(_ shared: H2Shared) -> ClientError? {
        while true {
            shared.input.reserve(16384)
            do {
                let n = try shared.socket.read(into: UnsafeMutableRawBufferPointer(
                    start: shared.input.writePointer, count: shared.input.writableBytes))
                if n == 0 { break }
                shared.input.advanceWriter(n)
            } catch {
                return error == .cancelled ? .cancelled : .closed
            }
            if shared.input.readableBytes > 1 << 20 { break }
        }
        if case .failed(let error) = dispatchBuffered(shared) { return error }
        return nil
    }

    private enum Dispatched {
        case nothing
        case progressed
        case failed(ClientError)
    }

    private func dispatchBuffered(_ shared: H2Shared) -> Dispatched {
        var any = false
        while shared.input.readableBytes >= H2FrameHeader.size {
            let header = H2FrameHeader.parse(shared.input.readPointer)
            // Bounded before a byte of the payload is waited for. A length
            // beyond what we advertised is a frame we never agreed to take.
            if header.length > shared.conn.maxFrameSize { return .failed(.protocolError) }
            guard shared.input.readableBytes >= H2FrameHeader.size + header.length else { break }
            if let error = dispatch(shared, header, shared.input.readPointer + H2FrameHeader.size) {
                return .failed(error)
            }
            shared.input.consume(H2FrameHeader.size + header.length)
            any = true
        }
        if shared.input.readableBytes == 0 { shared.input.clear() }
        return any ? .progressed : .nothing
    }

    // MARK: Frames

    /// Handles one frame. Returns an error only for what ends the connection;
    /// a stream's troubles are recorded on the stream.
    private func dispatch(_ shared: H2Shared, _ header: H2FrameHeader,
                          _ payload: UnsafePointer<UInt8>) -> ClientError? {
        let conn = shared.conn
        let now = av_monotonic_ms()

        // A header block may not be interleaved with anything, and a peer
        // that does it has left a block of unknown provenance half assembled.
        if conn.expectingContinuation && header.type != H2FrameType.continuation.rawValue {
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
                    conn.peerMaxFrameSize = Int(value)
                case .initialWindowSize:
                    guard value <= UInt32(H2FrameHeader.maxWindowSize) else { return .protocolError }
                    // Applies to every open stream, by the difference, and may
                    // leave a window negative: RFC 9113 section 6.9.2.
                    let delta = Int(value) - conn.peerInitialWindowSize
                    conn.peerInitialWindowSize = Int(value)
                    for stream in shared.streams.values {
                        stream.sendWindow += delta
                        if stream.sendWindow > H2FrameHeader.maxWindowSize { return .protocolError }
                    }
                case .maxConcurrentStreams:
                    conn.peerMaxConcurrentStreams = Int(value)
                case .maxHeaderListSize:
                    conn.peerMaxHeaderListSize = Int(value)
                default:
                    // SETTINGS_HEADER_TABLE_SIZE included, deliberately. It
                    // bounds the *peer's* decoder, which is to say our encoder,
                    // and our encoder never indexes. The first version handed
                    // it to our decoder, which shrinks the table we told the
                    // peer it could use -- a server advertising 0 would then
                    // have its valid responses refused.
                    break
                }
                at += 6
            }
            shared.queueControl(.settings, flags: .ack, stream: 0, { _ in }, length: 0)
            shared.wakeAll()

        case .windowUpdate:
            guard header.length == 4 else { return .protocolError }
            let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
            if header.streamID == 0 {
                if increment == 0 { return .protocolError }
                conn.sendWindow += increment
                if conn.sendWindow > H2FrameHeader.maxWindowSize { return .protocolError }
                shared.wakeAll()
            } else if let stream = shared.streams[header.streamID] {
                if increment == 0 {
                    failStream(shared, stream, .protocolError, reset: .protocolError)
                } else {
                    stream.sendWindow += increment
                    if stream.sendWindow > H2FrameHeader.maxWindowSize {
                        failStream(shared, stream, .protocolError, reset: .flowControlError)
                    }
                    stream.renew(at: now)
                    shared.wake(stream)
                }
            }

        case .ping:
            guard header.length == 8, header.streamID == 0 else { return .protocolError }
            if !header.flags.contains(.ack) {
                shared.queueControl(.ping, flags: .ack, stream: 0,
                                    { $0.write(payload, 8) }, length: 8)
            }

        case .goaway:
            guard header.length >= 8, header.streamID == 0 else { return .protocolError }
            shared.goaway = true
            let lastStream = HTTP2.readUInt32(payload) & 0x7FFF_FFFF
            let code = HTTP2.readUInt32(payload + 4)
            // Streams above the last one the peer processed were never looked
            // at, which is what makes them safe to send again elsewhere.
            for stream in shared.streams.values where stream.id > lastStream {
                stream.closedByPeer = true
                stream.error = .streamReset(code == 0 ? H2Error.refusedStream.rawValue : code)
                shared.wake(stream)
            }

        case .rstStream:
            guard header.length == 4, header.streamID != 0 else { return .protocolError }
            if let stream = shared.streams[header.streamID], !stream.done {
                stream.closedByPeer = true
                stream.error = .streamReset(HTTP2.readUInt32(payload))
                shared.wake(stream)
            }

        case .headers, .continuation:
            var start = 0
            var end = header.length
            if header.type == H2FrameType.headers.rawValue {
                if header.streamID == 0 || header.streamID % 2 == 0 { return .protocolError }
                if header.flags.contains(.padded) {
                    guard header.length >= 1 else { return .protocolError }
                    let pad = Int(payload[0])
                    start = 1
                    end = header.length - pad
                }
                if header.flags.contains(.priority) { start += 5 }
                guard start <= end else { return .protocolError }
                conn.headerStream = header.streamID
                conn.headerEndsStream = header.flags.contains(.endStream)
                conn.headerBlock.clear()
                // The stream's own limit, or this client's where the stream
                // has already gone: the block is decoded either way, to keep
                // HPACK in step, so it is held to something either way.
                conn.headBudget = shared.streams[header.streamID]?.maxHeadBytes ?? maxHeadBytes
            } else {
                guard conn.expectingContinuation, header.streamID == conn.headerStream else {
                    return .protocolError
                }
            }
            // Encoded bytes are the cheap outer guard, and bound what is held.
            // This ends the connection, because a block assembled in part
            // cannot be decoded, and dropping it would leave the HPACK table
            // describing bytes nobody read -- so it is held to the connection's
            // cap, not to the stream's own limit, which a tighter request on a
            // shared connection would otherwise impose on every other stream.
            // A block past the stream's limit and within the cap is decoded,
            // and fails that stream alone: HPACK only expands, so it cannot
            // decode to something inside the limit.
            guard conn.headerBlock.readableBytes + (end - start) <= max(conn.headBudget, shared.headCap) else {
                return .headTooLarge
            }
            conn.headerBlock.reserve(end - start)
            conn.headerBlock.write(payload + start, end - start)
            conn.expectingContinuation = !header.flags.contains(.endHeaders)
            if conn.expectingContinuation { return nil }

            // Decoded whether or not anyone still wants it. HPACK is stateful,
            // and skipping one block decodes every later one to nonsense.
            var status = 0
            var fields: [ClientHeader] = []
            var tooLarge = false
            guard decodeBlock(conn, &status, &fields, &tooLarge) else {
                return .malformedResponse(.badHeader)
            }
            conn.headerBlock.clear()
            guard let stream = shared.streams[conn.headerStream], !stream.done,
                  stream.error == nil else { return nil }
            stream.renew(at: now)
            let endsStream = conn.headerEndsStream

            if tooLarge {
                // Decoded to keep the table in step and then dropped, so this
                // ends the one stream and not the connection.
                failStream(shared, stream, .headTooLarge, reset: .cancel)
                return nil
            }
            if status < 0 || (stream.sawFinalHeaders && status != 0) {
                // A pseudo-field out of place, or any in trailers.
                failStream(shared, stream, .malformedResponse(.badHeader), reset: .protocolError)
                return nil
            }
            if stream.sawFinalHeaders {
                // Trailers. Read to keep HPACK in step, and not kept.
                if !endsStream {
                    failStream(shared, stream, .protocolError, reset: .protocolError)
                } else {
                    endOfStream(shared, stream)
                }
            } else if status == 0 {
                // No :status, or one that was not three digits. Guessing 200
                // would hand the caller a success the peer never claimed.
                failStream(shared, stream, .malformedResponse(.badStatusLine),
                           reset: .protocolError)
            } else if status >= 100 && status < 200 {
                // Informational: the real answer follows on the same stream.
                if endsStream {
                    failStream(shared, stream, .malformedResponse(.badStatusLine),
                               reset: .protocolError)
                }
            } else {
                let owed = owedLength(status: status, method: stream.method, fields: fields)
                if owed == badLength {
                    failStream(shared, stream, .malformedResponse(.conflictingFraming),
                               reset: .protocolError)
                } else {
                    stream.status = status
                    stream.headers = fields
                    stream.sawFinalHeaders = true
                    stream.declaredLength = owed
                    if endsStream { endOfStream(shared, stream) }
                }
            }
            shared.wake(stream)

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
            conn.recvWindow -= header.length
            if conn.recvWindow < 0 { return .protocolError }
            if conn.recvWindow < conn.initialWindowSize / 2 {
                shared.queueWindowUpdate(0, conn.initialWindowSize - conn.recvWindow)
                conn.recvWindow = conn.initialWindowSize
            }
            guard let stream = shared.streams[header.streamID], !stream.done,
                  stream.error == nil else { return nil }
            guard stream.sawFinalHeaders else {
                // A body before any answer to attach it to.
                failStream(shared, stream, .protocolError, reset: .protocolError)
                return nil
            }
            stream.recvWindow -= header.length
            if stream.recvWindow < 0 {
                failStream(shared, stream, .protocolError, reset: .flowControlError)
                return nil
            }
            let length = end - start
            if !stream.streaming && stream.body.count + length > stream.maxBodyBytes {
                failStream(shared, stream, .bodyTooLarge, reset: .cancel)
                return nil
            }
            // Padding is framing, not content, so only the payload counts.
            stream.receivedLength += length
            if stream.declaredLength >= 0 && stream.receivedLength > stream.declaredLength {
                // Already past what was promised; no need for END_STREAM.
                failStream(shared, stream, .protocolError, reset: .protocolError)
                return nil
            }
            stream.body.append(contentsOf: UnsafeBufferPointer(start: payload + start,
                                                               count: length))
            if header.flags.contains(.endStream) {
                endOfStream(shared, stream)
            } else if !stream.streaming && stream.recvWindow < conn.initialWindowSize / 2 {
                // A streamed body's window opens as the caller takes it
                // (`nextShared`), so a caller that stops reading stops the
                // peer rather than growing this buffer.
                shared.queueWindowUpdate(stream.id, conn.initialWindowSize - stream.recvWindow)
                stream.recvWindow = conn.initialWindowSize
            }
            stream.renew(at: now)
            shared.wake(stream)

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
    private func failStream(_ shared: H2Shared, _ stream: H2Stream, _ error: ClientError,
                            reset code: H2Error) {
        stream.error = error
        shared.queueReset(stream.id, code)
        stream.closedByPeer = true   // nothing further owed: the reset is queued
        shared.wake(stream)
    }

    /// Ends a stream the peer says is over, or refuses it where the body was
    /// not the length the head promised. A short body is the case that matters:
    /// without this a truncated download is handed back as a whole response,
    /// which HTTP/1.1 never does -- there the missing bytes end as `closed`.
    private func endOfStream(_ shared: H2Shared, _ stream: H2Stream) {
        guard stream.declaredLength < 0 || stream.receivedLength == stream.declaredLength else {
            failStream(shared, stream, .protocolError, reset: .protocolError)
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
        for field in fields {
            guard field.name.lowercased() == "content-length" else { continue }
            let text = field.value.utf8
            // Bounded before it is read. A peer is free to send a hundred
            // digits, and multiplying those into an Int traps and takes the
            // worker with it; 18 digits is past any body that could arrive.
            guard !text.isEmpty, text.count <= 18 else { return badLength }
            var value = 0
            for c in text {
                guard c >= cZero, c <= cNine else { return badLength }
                value = value * 10 + Int(c - cZero)
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
    private func decodeBlock(_ conn: H2ClientConnection, _ status: inout Int,
                             _ fields: inout [ClientHeader],
                             _ tooLarge: inout Bool) -> Bool {
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
        let budget = conn.headBudget
        do {
            try conn.decoder.decode(conn.headerBlock.readPointer,
                                    conn.headerBlock.readableBytes) { span in
                listSize += span.nameLength + span.valueLength + 32
                if listSize > budget {
                    // Every later field is still decoded, because the table
                    // has to end where the peer thinks it does. None is kept.
                    over = true
                    collected.removeAll(keepingCapacity: false)
                }
                if over { return }
                if span.nameLength > 0 && span.name[0] == UInt8(ascii: ":") {
                    guard !sawRegular, !sawStatus, equalsExact(span.name, span.nameLength, ":status") else {
                        misplaced = true
                        return
                    }
                    sawStatus = true
                    do {
                        // Length first. A peer is free to send ":status:
                        // 999...9" with as many digits as it likes, and
                        // accumulating those before counting them overflows
                        // `value` and traps -- taking the worker, and every
                        // other request on it, over one bad field. Three
                        // bytes is the only length HTTP/2 allows.
                        guard span.valueLength == 3 else { return }
                        var value = 0
                        var i = 0
                        while i < 3 {
                            let c = span.value[i]
                            guard c >= cZero, c <= cNine else { return }
                            value = value * 10 + Int(c - cZero)
                            i += 1
                        }
                        // Below 100 is not a status any more, and letting one
                        // through would hand the caller a final response the
                        // peer never named. 0 is what the stream refuses on.
                        if value >= 100 { found = value }
                    }
                    return
                }
                sawRegular = true
                collected.append(ClientHeader(
                    name: String(decoding: UnsafeBufferPointer(start: span.name,
                                                               count: span.nameLength),
                                 as: UTF8.self),
                    value: String(decoding: UnsafeBufferPointer(start: span.value,
                                                                count: span.valueLength),
                                  as: UTF8.self)))
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

private extension Substring {
    var trimmingSpaces: Substring {
        var s = self
        while s.first == " " { s = s.dropFirst() }
        while s.last == " " { s = s.dropLast() }
        return s
    }
}

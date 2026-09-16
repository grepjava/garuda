//===----------------------------------------------------------------------===//
// WebTransport handlers.
//
//     app.webTransport("/echo") { (session: WebTransportSession) async throws in
//         try await withThrowingTaskGroup(of: Void.self) { group in
//             group.addTask {
//                 while let datagram = try await session.receiveDatagram() {
//                     session.sendDatagram(datagram)
//                 }
//             }
//             while let stream = try await session.acceptStream() {
//                 group.addTask {
//                     while let bytes = try await stream.read() { try await stream.write(bytes) }
//                     stream.finish()
//                 }
//             }
//         }
//     }
//
// A session arrives as an HTTP/3 extended CONNECT, and is a route like any
// other until it is accepted: middleware runs in front of it, and extractors
// run before it, so a request refused by either is answered with an ordinary
// status and no session is ever made. Once every extractor has what it needs,
// the session is accepted and the handler runs for as long as it lasts. When
// the handler returns, a session it did not close is closed for it.
//
// Everything here runs on the worker's thread, as every handler does. A task
// group's child tasks inherit that; an unstructured `Task { }` does not, and
// touching a session from one stops the worker with a message saying so.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaQUIC
import GarudaHTTP

/// Why a WebTransport operation did not complete.
public enum WebTransportError: Error, Equatable, Sendable {
    /// The session has ended: closed by either side, or its connection lost.
    case closed
    /// The stream cannot be written to: the peer's unidirectional stream, or
    /// one already finished, reset, or stopped by the peer.
    case notWritable
    /// Another task is already waiting for the same thing. One reader per
    /// stream, one writer per stream, one task accepting streams and one
    /// receiving datagrams.
    case busy
    /// The peer will not accept another stream from us yet.
    case streamLimit
}

/// A WebTransport session, for as long as its handler runs.
public final class WebTransportSession: @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let state: WTSession

    init(worker: UnsafeMutablePointer<Worker>, slot: Int, state: WTSession) {
        self.worker = worker
        self.slot = slot
        self.state = state
    }

    /// The session's identifier: the QUIC stream its CONNECT arrived on.
    public var id: UInt64 { state.sessionID }

    /// Whether the session has ended, by either side.
    public var isClosed: Bool { state.gone }

    /// The code the session was closed with, by the peer or by `close`.
    public var closeCode: UInt32 { state.closeCode }

    public var closeReason: String { String(decoding: state.closeReason, as: UTF8.self) }

    /// The largest datagram the peer will take, or 0 when it takes none.
    public var maxDatagramSize: Int {
        guard let h3 else { return 0 }
        let quarter = state.sessionID / 4
        let prefix = quarter < 64 ? 1 : quarter < 16_384 ? 2 : quarter < 1 << 30 ? 4 : 8
        return max(0, h3.quic.maxDatagramPayload - prefix)
    }

    /// The next stream the peer opens, or nil once the session has ended.
    public func acceptStream() async throws -> WebTransportStream? {
        onWorker()
        while true {
            if !state.incoming.isEmpty {
                let id = state.incoming.removeFirst()
                guard let stream = state.streams[id] else { continue }
                return WebTransportStream(session: self, state: stream)
            }
            if state.gone { return nil }
            guard state.acceptWaiter == nil else { throw WebTransportError.busy }
            try await park(worker, { self.state.acceptWaiter = $0 }, { self.state.acceptWaiter.take() })
        }
    }

    /// Opens a stream to the peer. A unidirectional one can only be written.
    public func openStream(bidirectional: Bool = true) throws -> WebTransportStream {
        onWorker()
        guard !state.gone, let h3 else { throw WebTransportError.closed }
        guard let id = h3.quic.openStream(unidirectional: !bidirectional) else {
            throw WebTransportError.streamLimit
        }
        // Our streams carry the same prefix the peer's do: a unidirectional
        // stream is typed 0x54, a bidirectional one starts with the frame that
        // says it is not a request.
        var prefix = ByteBuffer(capacity: 16)
        defer { prefix.destroy() }
        prefix.writeVarint(bidirectional ? HTTP3FrameType.webTransportStream : HTTP3StreamType.webTransport)
        prefix.writeVarint(state.sessionID)
        h3.quic.send(id, UnsafePointer(prefix.readPointer), prefix.readableBytes, fin: false)

        let stream = WTStream(id: id, bidirectional: bidirectional, writable: true, readable: bidirectional)
        state.streams[id] = stream
        h3.wtStreams[id] = Int32(slot)
        flush()
        return WebTransportStream(session: self, state: stream)
    }

    /// The next datagram from the peer, or nil once the session has ended.
    /// Datagrams a handler is too slow to read are dropped, oldest first.
    public func receiveDatagram() async throws -> [UInt8]? {
        onWorker()
        while true {
            if !state.datagrams.isEmpty {
                let payload = state.datagrams.removeFirst()
                state.datagramBytes -= payload.count
                return payload
            }
            if state.gone { return nil }
            guard state.datagramWaiter == nil else { throw WebTransportError.busy }
            try await park(worker, { self.state.datagramWaiter = $0 }, { self.state.datagramWaiter.take() })
        }
    }

    /// Sends a datagram. Returns false, having sent nothing, when the session
    /// has ended or the datagram is larger than the peer will take: that is
    /// what unreliable means, and there is no waiting for room.
    @discardableResult
    public func sendDatagram(_ bytes: [UInt8]) -> Bool {
        onWorker()
        guard !state.gone, let h3 else { return false }
        var out = ByteBuffer(capacity: bytes.count + 8)
        defer { out.destroy() }
        out.writeVarint(state.sessionID / 4)
        bytes.withUnsafeBufferPointer { if let base = $0.baseAddress, $0.count > 0 { out.write(base, $0.count) } }
        let sent = h3.quic.sendDatagram(UnsafePointer(out.readPointer), out.readableBytes)
        flush()
        return sent
    }

    /// Ends the session with `code` and `reason`, which the peer receives.
    /// Every stream still open is abandoned. Closing twice does nothing.
    public func close(code: UInt32 = 0, reason: String = "") {
        onWorker()
        guard !state.gone else { return }
        state.closeCode = code
        state.closeReason = Array(reason.utf8.prefix(wtMaxCloseReason))
        worker.pointee.closeWebTransportSession(slot, state)
    }

    // MARK: Internals

    var h3: H3Connection? {
        guard !state.gone else { return nil }
        let parent = Int(worker.pointee.table[slot].pointee.parentSlot)
        return parent >= 0 ? worker.pointee.table[parent].pointee.h3 : nil
    }

    func flush() {
        let parent = Int(worker.pointee.table[slot].pointee.parentSlot)
        if !state.gone, parent >= 0 { worker.pointee.flushQUIC(parent) }
    }

    func onWorker() {
        precondition(pg_worker_current() == UnsafeMutableRawPointer(worker),
                     "a WebTransport session was used off its worker's thread; use a task group, not Task { }")
    }
}

/// One stream of a WebTransport session.
public final class WebTransportStream: @unchecked Sendable {
    public let session: WebTransportSession
    let state: WTStream

    init(session: WebTransportSession, state: WTStream) {
        self.session = session
        self.state = state
    }

    public var id: UInt64 { state.id }
    public var isBidirectional: Bool { state.bidirectional }
    /// Opened by this side rather than the peer.
    public var isLocal: Bool { state.id & 1 == 1 }
    /// The peer reset its side, or asked this side to stop sending.
    public var wasAborted: Bool { state.aborted }

    /// Up to `maxBytes` of what the peer sent, waiting for some when none has
    /// arrived. Nil once the stream has ended -- finished or reset by the
    /// peer, or its session gone -- and at once for a stream this side opened
    /// unidirectional. Bytes that arrived before a reset are still read.
    ///
    /// Bytes are held in the transport until read, and the peer is given no
    /// more room than that, so a stream nobody reads slows its sender and
    /// nothing else.
    public func read(maxBytes: Int = 64 * 1024) async throws -> [UInt8]? {
        session.onWorker()
        while true {
            if state.readEnded { return nil }
            guard let h3 = session.h3, let quic = h3.quic.stream(state.id) else {
                endRead()
                return nil
            }
            let available = quic.receive.ready.readableBytes
            if available > 0 {
                let take = min(available, max(1, maxBytes))
                let bytes = Array(UnsafeBufferPointer(start: UnsafePointer(quic.receive.ready.readPointer),
                                                      count: take))
                quic.receive.ready.consume(take)
                // Reading is what re-opens the window.
                h3.quic.extendStreamWindow(state.id,
                                           consumed: quic.receive.received - UInt64(quic.receive.ready.readableBytes))
                session.flush()
                return bytes
            }
            if quic.receive.finished || state.aborted {
                endRead()
                return nil
            }
            guard state.readWaiter == nil else { throw WebTransportError.busy }
            try await park(session.worker, { self.state.readWaiter = $0 }, { self.state.readWaiter.take() })
        }
    }

    /// Everything the peer sends until it finishes the stream, refusing more
    /// than `maxBytes`.
    public func readAll(maxBytes: Int = 1 << 20) async throws -> [UInt8] {
        var all: [UInt8] = []
        while let bytes = try await read() {
            all += bytes
            if all.count > maxBytes { throw WebTransportError.closed }
        }
        return all
    }

    /// Writes `bytes`, and waits while more than the server's write high-water
    /// mark is queued and unacknowledged on this stream.
    public func write(_ bytes: [UInt8]) async throws {
        session.onWorker()
        guard let h3 = session.h3 else { throw WebTransportError.closed }
        guard state.writable, !state.finSent else { throw WebTransportError.notWritable }
        bytes.withUnsafeBufferPointer {
            if let base = $0.baseAddress, $0.count > 0 { h3.quic.send(state.id, base, $0.count, fin: false) }
        }
        session.flush()
        let highWater = session.worker.pointee.config.writeHighWaterMark
        while true {
            guard let h3 = session.h3, let quic = h3.quic.stream(state.id) else { throw WebTransportError.closed }
            if quic.send.data.readableBytes <= highWater { return }
            guard state.writable else { throw WebTransportError.notWritable }
            guard state.writeWaiter == nil else { throw WebTransportError.busy }
            try await park(session.worker, { self.state.writeWaiter = $0 }, { self.state.writeWaiter.take() })
        }
    }

    /// Finishes this side of the stream: the peer reads to the end of what was
    /// written. Does nothing on a stream that cannot be written.
    public func finish() {
        session.onWorker()
        guard let h3 = session.h3, state.writable, !state.finSent else { return }
        h3.quic.send(state.id, emptyH3Byte, 0, fin: true)
        state.finSent = true
        state.writable = false
        retireIfDone(h3)
        session.flush()
    }

    /// Abandons the stream in both directions with an application error code.
    public func reset(code: UInt32 = 0) {
        session.onWorker()
        guard let h3 = session.h3 else { return }
        let wire = WebTransportStream.http3Code(code)
        if state.writable && !state.finSent { h3.quic.resetStream(state.id, code: wire) }
        if !state.readEnded { h3.quic.stopSending(state.id, code: wire) }
        state.writable = false
        state.readEnded = true
        retireIfDone(h3)
        session.flush()
    }

    private func endRead() {
        state.readEnded = true
        if let h3 = session.h3 { retireIfDone(h3) }
    }

    /// Lets the transport forget a stream once neither side can use it again.
    private func retireIfDone(_ h3: H3Connection) {
        guard state.readEnded, !state.writable else { return }
        session.state.streams.removeValue(forKey: state.id)
        h3.wtStreams.removeValue(forKey: state.id)
        h3.quic.releaseStream(state.id)
    }

    /// WebTransport's application codes live in a reserved stretch of the
    /// HTTP/3 error space, skipping every value HTTP/3 keeps for greasing
    /// (draft-ietf-webtrans-http3, section 4.3).
    static func http3Code(_ code: UInt32) -> UInt64 {
        0x52e4_a40f_a8db + UInt64(code) + UInt64(code) / 0x1e
    }
}

/// Waits for an engine event, or for the task to be cancelled.
///
/// The continuation is stored by `store` and taken back by whoever resumes it:
/// the engine when the event comes, or the cancellation handler. A cancel can
/// be requested from any thread, but the state it would touch is the worker's,
/// so only a cancel on the worker's own thread -- a task group cancelling its
/// children -- wakes the wait at once. One from elsewhere is noticed when the
/// wait next ends.
private func park(_ worker: UnsafeMutablePointer<Worker>,
                  _ store: (UnsafeContinuation<Void, Never>) -> Void,
                  _ take: @escaping @Sendable () -> UnsafeContinuation<Void, Never>?) async throws {
    try Task.checkCancellation()
    let raw = UnsafeMutableRawPointer(worker)
    nonisolated(unsafe) let workerAddress = raw
    await withTaskCancellationHandler {
        await withUnsafeContinuation { store($0) }
    } onCancel: {
        if pg_worker_current() == workerAddress { take()?.resume() }
    }
    try Task.checkCancellation()
}

// MARK: - Registration

/// A WebTransport handler over the raw request.
public typealias WebTransportHandler = (borrowing Request, WebTransportSession) async throws -> Void

extension Application {
    /// Serves WebTransport sessions on `pattern`: an HTTP/3 extended CONNECT
    /// with `:protocol: webtransport`. Middleware runs in front, as for any
    /// route; the session is accepted when the handler is called.
    public func onWebTransport(_ pattern: String, _ handler: sending @escaping WebTransportHandler) {
        onAsync(.connect, pattern) { request, _ in
            try WebTransportSession.refuseUnlessSession(request)
            try await WebTransportSession.serve(request) { session in try await handler(request, session) }
        }
    }

    /// Serves WebTransport sessions on `pattern`, with extractors. Every
    /// extractor runs before the session is accepted, so one that refuses the
    /// request refuses the session with an ordinary status.
    ///
    ///     app.webTransport("/room/:id") { (session: WebTransportSession, room: Path<Int>,
    ///                                      user: Context<User>) async throws in … }
    ///
    /// The session comes first: Swift will not pass further arguments after
    /// a variable number of extractors.
    public func webTransport<each E: RequestExtractor>(
        _ pattern: String,
        _ handler: sending @escaping (WebTransportSession, repeat each E) async throws -> Void
    ) {
        onAsync(.connect, pattern) { request, _ in
            try WebTransportSession.refuseUnlessSession(request)
            var parameter = 0
            try await WebTransportSession.serve(request, handler,
                                                repeat try (each E).extract(from: request, parameter: &parameter))
        }
    }
}

extension WebTransportSession {
    static func refuseUnlessSession(_ request: borrowing Request) throws {
        guard request.worker.pointee.isWebTransportRequest(request.slot) else {
            throw HTTPError(.badRequest, "a WebTransport session starts with an HTTP/3 extended CONNECT")
        }
    }

    /// Accepts the session and runs `handler` with the values already
    /// extracted -- they are arguments, so they were taken before this began.
    static func serve<each E>(_ request: borrowing Request,
                              _ handler: (WebTransportSession, repeat each E) async throws -> Void,
                              _ values: repeat each E) async {
        let worker = request.worker
        let slot = request.slot
        let c = worker.pointee.table[slot]
        let generation = c.pointee.generation
        let requestId = c.pointee.requestId
        guard let state = worker.pointee.acceptWebTransport(slot) else { return }
        let session = WebTransportSession(worker: worker, slot: slot, state: state)
        do {
            try await handler(session, repeat each values)
        } catch let error as WebTransportError where error == .closed {
            // The session ended under the handler; nothing went wrong.
        } catch is CancellationError {
        } catch {
            let description = String(describing: error)
            Log.error { line in
                line.str("webtransport handler threw: ")
                description.withCString { line.cstr($0) }
            }
        }
        worker.pointee.webTransportHandlerFinished(slot, generation: generation,
                                                   requestId: requestId, state)
    }
}

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
// the session is accepted, and once the route has returned, the handler runs
// for as long as the session lasts. When the handler returns, a session it
// did not close is closed for it.
//
// A session and its streams may be shared with child tasks, and with any
// other task: everything they share with the endpoint is under its lock
// (HTTP3WebTransport.swift).
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import Synchronization
import Vega

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
public final class WebTransportSession: Sendable {
    let state: WTSession

    init(state: WTSession) {
        self.state = state
    }

    /// `body` under the endpoint's lock.
    @inline(__always)
    private func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        try state.endpoint.lock.withLock { _ throws(E) -> R in try body() }
    }

    /// The session's identifier: the QUIC stream its CONNECT arrived on.
    public var id: UInt64 { state.sessionID }

    /// Whether the session has ended, by either side.
    public var isClosed: Bool { locked { state.gone } }

    /// The code the session was closed with, by the peer or by `close`.
    public var closeCode: UInt32 { locked { state.closeCode } }

    public var closeReason: String {
        String(decoding: locked { state.closeReason }, as: UTF8.self)
    }

    /// The largest datagram the peer will take, or 0 when it takes none.
    public var maxDatagramSize: Int { state.datagramLimit }

    /// The next stream the peer opens, or nil once the session has ended.
    public func acceptStream() async throws -> WebTransportStream? {
        while true {
            let next = try locked { () throws(WebTransportError) -> WTStream?? in
                if !state.incoming.isEmpty { return .some(state.incoming.removeFirst()) }
                if state.gone { return .some(nil) }
                guard !state.accepting else { throw .busy }
                state.accepting = true
                return .none
            }
            if let next {
                guard let next else { return nil }
                return WebTransportStream(session: self, state: next)
            }
            defer { locked { state.accepting = false } }
            try await waitFor(state.arrivals)
        }
    }

    /// Opens a stream to the peer. A unidirectional one can only be written.
    public func openStream(bidirectional: Bool = true) throws -> WebTransportStream {
        let opened = try locked { () throws(WebTransportError) -> WTStream in
            guard !state.gone else { throw .closed }
            let connection = state.connection
            let index = bidirectional ? connection.nextLocalBidi : connection.nextLocalUni
            let limit = bidirectional ? connection.localLimitBidi : connection.localLimitUni
            guard index < limit else { throw .streamLimit }
            if bidirectional { connection.nextLocalBidi &+= 1 } else { connection.nextLocalUni &+= 1 }
            let id = QUICStreamKind.id(index: index, serverInitiated: true, unidirectional: !bidirectional)
            let st = WTStream(id: id, bidirectional: bidirectional, local: true, session: state)
            // Our streams carry the same prefix the peer's do: a
            // unidirectional stream is typed 0x54, a bidirectional one starts
            // with the frame that says it is not a request.
            st.staged.writeVarint(bidirectional ? HTTP3FrameType.webTransportStream : HTTP3StreamType.webTransport)
            st.staged.writeVarint(state.sessionID)
            state.streams[id] = st
            connection.opening.append(st)
            state.mark(st)
            return st
        }
        return WebTransportStream(session: self, state: opened)
    }

    /// The next datagram from the peer, or nil once the session has ended.
    /// Datagrams a handler is too slow to read are dropped, oldest first.
    public func receiveDatagram() async throws -> [UInt8]? {
        while true {
            let next = try locked { () throws(WebTransportError) -> [UInt8]?? in
                if !state.datagrams.isEmpty {
                    let payload = state.datagrams.removeFirst()
                    state.datagramBytes &-= payload.count
                    return .some(payload)
                }
                if state.gone { return .some(nil) }
                guard !state.receiving else { throw .busy }
                state.receiving = true
                return .none
            }
            if let next { return next }
            defer { locked { state.receiving = false } }
            try await waitFor(state.datagramArrived)
        }
    }

    /// Sends a datagram. Returns false, having sent nothing, when the session
    /// has ended or the datagram is larger than the peer will take: that is
    /// what unreliable means, and there is no waiting for room.
    @discardableResult
    public func sendDatagram(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= state.datagramLimit else { return false }
        var out = ByteBuffer(capacity: bytes.count &+ 8)
        defer { out.destroy() }
        out.writeVarint(state.sessionID / 4)
        bytes.withUnsafeBufferPointer { if let base = $0.baseAddress, $0.count > 0 { out.write(base, $0.count) } }
        let datagram = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        return locked { () -> Bool in
            guard !state.gone else { return false }
            state.outgoing.append(datagram)
            state.endpoint.post(state.stream)
            return true
        }
    }

    /// Ends the session with `code` and `reason`, which the peer receives.
    /// Every stream still open is abandoned. Closing twice does nothing.
    public func close(code: UInt32 = 0, reason: String = "") {
        let reason = Array(reason.utf8.prefix(wtMaxCloseReason))
        locked { state.closeLocked(code: code, reason: reason) }
    }
}

/// One stream of a WebTransport session.
public final class WebTransportStream: Sendable {
    public let session: WebTransportSession
    let state: WTStream

    init(session: WebTransportSession, state: WTStream) {
        self.session = session
        self.state = state
    }

    /// `body` under the endpoint's lock.
    @inline(__always)
    private func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        try session.state.endpoint.lock.withLock { _ throws(E) -> R in try body() }
    }

    public var id: UInt64 { state.id }
    public var isBidirectional: Bool { state.bidirectional }
    /// Opened by this side rather than the peer.
    public var isLocal: Bool { state.local }
    /// The peer reset its side, or asked this side to stop sending.
    public var wasAborted: Bool { locked { state.aborted } }

    /// Up to `maxBytes` of what the peer sent, waiting for some when none has
    /// arrived. Nil once the stream has ended -- finished or reset by the
    /// peer, or its session gone -- and at once for a stream this side opened
    /// unidirectional. Bytes that arrived before a reset are still read.
    ///
    /// The peer is given no more room than the handler has read, so a stream
    /// nobody reads slows its sender and nothing else.
    public func read(maxBytes: Int = 64 * 1024) async throws -> [UInt8]? {
        let st = state
        let session = st.session
        let creditAt = max(1, session.connection.settings.streamWindow / 4)
        while true {
            let got = try locked { () throws(WebTransportError) -> [UInt8]?? in
                if st.readDone { return .some(nil) }
                let available = st.inbound.readableBytes
                if available > 0 {
                    let take = min(available, max(1, maxBytes))
                    let bytes = Array(UnsafeBufferPointer(start: st.inbound.readPointer, count: take))
                    st.inbound.consume(take)
                    st.taken &+= UInt64(take)
                    st.owed &+= take
                    // Reading is what opens the window again.
                    if st.owed >= creditAt && !session.gone {
                        st.owed = 0
                        session.mark(st)
                    }
                    return .some(bytes)
                }
                if st.peerEnded || session.gone {
                    st.readDone = true
                    st.inbound.clear()
                    if !session.gone { session.mark(st) }
                    return .some(nil)
                }
                guard !st.reading else { throw .busy }
                st.reading = true
                return .none
            }
            if let got { return got }
            defer { locked { st.reading = false } }
            try await waitFor(st.readable)
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
    /// mark is queued on this stream and not yet sent.
    public func write(_ bytes: [UInt8]) async throws {
        let st = state
        let session = st.session
        let high = session.connection.settings.high
        try locked { () throws(WebTransportError) in
            guard !session.gone else { throw .closed }
            guard st.writable, !st.finRequested else { throw .notWritable }
            bytes.withUnsafeBufferPointer { if let base = $0.baseAddress, $0.count > 0 { st.staged.write(base, $0.count) } }
            session.mark(st)
        }
        while true {
            let wait = try locked { () throws(WebTransportError) -> Bool in
                guard !session.gone else { throw .closed }
                if st.staged.readableBytes <= high { return false }
                guard st.writable else { throw .notWritable }
                guard !st.writing else { throw .busy }
                st.writing = true
                return true
            }
            if !wait { return }
            defer { locked { st.writing = false } }
            try await waitFor(st.drained)
        }
    }

    /// Finishes this side of the stream: the peer reads to the end of what was
    /// written. Does nothing on a stream that cannot be written.
    public func finish() {
        let st = state
        locked {
            guard !st.session.gone, st.writable, !st.finRequested else { return }
            st.finRequested = true
            st.writable = false
            st.session.mark(st)
        }
    }

    /// Abandons the stream in both directions with an application error code.
    public func reset(code: UInt32 = 0) {
        let st = state
        let wire = WebTransportStream.http3Code(code)
        locked {
            guard !st.session.gone else { return }
            if st.writable {
                st.resetCode = wire
                st.staged.clear()
            }
            if !st.readDone {
                st.stopCode = wire
                st.readDone = true
                st.inbound.clear()
            }
            st.writable = false
            st.wake()
            st.session.mark(st)
        }
    }

    /// WebTransport's application codes live in a reserved stretch of the
    /// HTTP/3 error space, skipping every value HTTP/3 keeps for greasing
    /// (draft-ietf-webtrans-http3, section 4.3).
    static func http3Code(_ code: UInt32) -> UInt64 {
        0x52e4_a40f_a8db + UInt64(code) + UInt64(code) / 0x1e
    }
}

/// Waits for the endpoint to signal `event`, which it does once what the
/// caller found missing under the lock may be there: the caller looks again.
/// A cancelled task's wait throws `CancellationError`; one under an I/O
/// deadline (`Runtime.withIODeadline`) throws `IOError.timedOut` when it
/// passes.
private func waitFor(_ event: IOEvent) async throws {
    do {
        try await event.wait()
    } catch {
        if error == .cancelled || Task.isCancelled { throw CancellationError() }
        throw error
    }
}

// MARK: - Registration

/// A WebTransport handler over the raw request.
public typealias WebTransportHandler = (borrowing Request, WebTransportSession) async throws -> Void

/// A handler, carried from its route to the stream's task, which runs it.
struct CarriedWebTransportHandler: @unchecked Sendable {
    let call: (borrowing Request, WebTransportSession) async throws -> Void

    /// Runs the handler, reporting what it threw unless it was the session
    /// ending under it.
    func run(_ request: borrowing Request, _ session: WebTransportSession) async {
        do {
            try await call(request, session)
        } catch let error as WebTransportError where error == .closed {
            // The session ended under the handler; nothing went wrong.
        } catch is CancellationError {
        } catch {
            Log.error("webtransport handler threw: \(error)")
        }
    }
}

/// A handler taking extracted values, in a struct: a function with a
/// parameter pack cannot be held as a generic value on its own.
struct VariadicWebTransportHandler<each E>: @unchecked Sendable {
    let call: (WebTransportSession, repeat each E) async throws -> Void
}

extension RouteBuilder {
    /// Serves WebTransport sessions on `pattern`: an HTTP/3 extended CONNECT
    /// with `:protocol: webtransport`. Middleware runs in front, as for any
    /// route; the session is accepted when the handler is called.
    public func onWebTransport(_ pattern: String, _ handler: sending @escaping WebTransportHandler) {
        let carried = CarriedWebTransportHandler(call: handler)
        on(.connect, pattern) { request, response in
            try refuseUnlessWebTransport(request)
            acceptWebTransport(request.exchange, run: carried)
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
        let handler = VariadicWebTransportHandler<repeat each E>(call: handler)
        on(.connect, pattern) { request, response in
            try refuseUnlessWebTransport(request)
            var parameter = 0
            let run = bindWebTransportHandler(handler,
                                              repeat try await (each E).extract(from: request, parameter: &parameter))
            acceptWebTransport(request.exchange, run: run)
        }
        var claims = 0
        var states: [Any.Type] = []
        repeat claims += pathClaims((each E).self)
        repeat states += requiredState((each E).self)
        noteRoute(.connect, pattern, pathParameters: claims, states: states)
    }
}

/// The handler with its extracted values applied. A closure rather than the
/// values themselves, because the task that runs it cannot capture a
/// parameter pack.
func bindWebTransportHandler<each E>(_ handler: VariadicWebTransportHandler<repeat each E>,
                                     _ values: repeat each E) -> CarriedWebTransportHandler {
    CarriedWebTransportHandler { _, session in try await handler.call(session, repeat each values) }
}

/// A CONNECT that is not a WebTransport session is a mistake at a session's
/// route.
func refuseUnlessWebTransport(_ request: borrowing Request) throws {
    let x = request.exchange
    var overHTTP3 = false
    if case .http3 = x.pointee.link { overHTTP3 = true }
    guard overHTTP3, x.pointee.connectProtocol == .webtransport else {
        throw HTTPError(.badRequest, "a WebTransport session starts with an HTTP/3 extended CONNECT")
    }
}

/// Accepts the session: the 200 is staged by the stream's task once the
/// route has returned, and the handler runs there (HTTP3WebTransport.swift).
func acceptWebTransport(_ x: UnsafeMutablePointer<Exchange>, run: CarriedWebTransportHandler) {
    guard case .http3(let link) = x.pointee.link else { return }
    let s = link.takeUnretainedValue()
    x.pointee.status = 200
    x.pointee.noCompress = true
    x.pointee.answered = true
    x.pointee.touchedStream = true
    x.pointee.webTransport = WTAcceptance(session: WTSession(stream: s), run: run)
}

//===----------------------------------------------------------------------===//
// WebSockets over HTTP/2 (RFC 8441).
//
// SETTINGS_ENABLE_CONNECT_PROTOCOL tells the client it may open a stream
// with an extended CONNECT, `:protocol: websocket`, which is routed as the
// GET it stands for. The route's handshake answers it 200 rather than 101,
// and the stream is the WebSocket's from then on: the frames the client
// sends are its DATA, and the frames sent back the 200's body.
//
// The stream's task runs the WebSocket as an HTTP/1 connection's task does
// (WebSocketSession.swift), reading from an `H2Inbound` -- the DATA the
// connection's reader hands over -- instead of a socket. The stream's
// window is given back as the session takes the bytes, not as they arrive,
// so a handler that stops reading stops the client, as TCP's window does
// over HTTP/1; the connection's window is given back at once, so one
// WebSocket that has stopped holds up no other stream.
//
// A WebSocket that ends with its close handshake ends the stream with
// END_STREAM, and the stream stays half-closed until the client ends its
// side too. One given up on -- no pong, or no answer to a close -- is reset
// with CANCEL.
//===----------------------------------------------------------------------===//

import VegaWire
@_spi(Garuda) import VegaHTTP2Core
import GarudaWire
import Synchronization
import Vega
import VegaIO

/// The DATA of a WebSocket's stream, from the connection's reader to the
/// session reading it.
final class H2Inbound: AsyncReader, @unchecked Sendable {
    unowned(unsafe) let stream: H2Stream
    private let arrived = IOEvent()
    private let lock = Mutex<Void>(())
    private var buffer = ByteBuffer()
    /// What the client may still send on the stream.
    private var window: Int
    /// Taken by the session and not yet given back.
    private var owed = 0
    private let creditAt: Int
    /// The client ended its side.
    private var ended = false
    /// The stream was reset, or the connection lost.
    private var failed = false
    /// Nobody reads any more: what arrives is dropped.
    private var closed = false

    init(stream: H2Stream, window: Int) {
        self.stream = stream
        self.window = window
        // Half the window, as for a request body.
        creditAt = max(1, window / 2)
    }

    deinit {
        buffer.destroy()
    }

    // MARK: The connection's reader

    /// A DATA frame: `count` bytes of payload, from a frame that spent
    /// `spent` of the stream's window. False when it overran the window.
    func deliver(_ p: UnsafePointer<UInt8>, _ count: Int, spent: Int, end: Bool) -> Bool {
        var credit = 0
        let ok = lock.withLock { _ -> Bool in
            window &-= spent
            if window < 0 { return false }
            if !closed && count > 0 { buffer.write(p, count) }
            // Padding is nobody's to read, and given back with the rest.
            if !closed { owed &+= spent &- count }
            if end { ended = true }
            if owed >= creditAt {
                credit = owed
                owed = 0
                window &+= credit
            }
            return true
        }
        if credit > 0 { stream.connection.creditStream(stream, credit) }
        arrived.signal()
        return ok
    }

    /// The client ended its side with a trailer section.
    func end() {
        lock.withLock { _ in ended = true }
        arrived.signal()
    }

    /// The stream is gone under the session.
    func fail() {
        lock.withLock { _ in failed = true }
        arrived.signal()
    }

    // MARK: The session

    /// The bytes that have arrived, waiting for them as a socket's read
    /// would, deadline and all.
    func read(into destination: inout IOBuffer) async throws(IOError) -> Int {
        while true {
            var credit = 0
            let got = lock.withLock { _ -> Int? in
                if failed { return -1 }
                let n = min(buffer.readableBytes, destination.spareCapacity)
                if n > 0 {
                    destination.append(UnsafeRawBufferPointer(start: buffer.readPointer, count: n))
                    buffer.consume(n)
                    owed &+= n
                    if owed >= creditAt {
                        credit = owed
                        owed = 0
                        window &+= credit
                    }
                    return n
                }
                return ended ? 0 : nil
            }
            if credit > 0 { stream.connection.creditStream(stream, credit) }
            if let got {
                if got < 0 { throw .connectionReset }
                return got
            }
            try await arrived.wait()
        }
    }

    /// The session is done: what arrives from now on is dropped.
    func close() {
        lock.withLock { _ in
            closed = true
            buffer.clear()
        }
    }
}

extension H2Connection {
    /// Gives `n` bytes of `s`'s window back to the client.
    func creditStream(_ s: H2Stream, _ n: Int) {
        lock.withLock { _ in
            guard !s.reset else { return }
            frame(&control, 4, .windowUpdate, [], s.id)
            HTTP2.writeUInt32(UInt32(n), into: &control)
            wake.notifyOne()
        }
    }

    /// Runs the WebSocket `s`'s route accepted, in `s`'s task, until it
    /// ends; then ends the stream, or resets it if the client was given up
    /// on.
    func runWebSocket(_ s: H2Stream, _ inbound: H2Inbound, _ upgrade: WebSocketUpgrade) async {
        // The 200, through the writer; the frames follow it as its body,
        // which is nothing for --cache-size to keep.
        s.x.pointee.capture = nil
        s.x.pointee.cacheInvalidates = 0
        let channel = startStream(s.x)
        lock.withLock { _ in webSocketStreams &+= 1 }
        let session = WebSocketSession(limits: upgrade.limits, channel: channel, deflate: upgrade.deflate,
                                       runtime: app.runtime)
        let handler = startWebSocketHandler(session, upgrade, app: app)
        let abandoned = await session.read(inbound, leftover: [])
        // As over HTTP/1: a handler with messages still to read reads them;
        // one with none is told by being cancelled.
        if !session.hasUnread { handler.cancel() }
        await handler.value
        // What is queued -- the last close -- goes before the stream ends.
        try? await channel.settle(.sent, flushing: true)
        app.webSockets.remove(session)
        inbound.close()
        lock.withLock { _ in
            s.task = nil
            if abandoned {
                s.failCode = .cancel
            } else {
                // Ended from our side; the client's may still be open.
                s.lingering = true
            }
            channel.closeH2Locked(s, failed: abandoned)
            release(s)
            tasks &-= 1
            if tasks == 0 { idle.notifyOne() }
            webSocketStreams &-= 1
            if webSocketStreams == 0 && goawayDeferred && !goawaySent { sendShutdownGoawayLocked() }
        }
    }
}

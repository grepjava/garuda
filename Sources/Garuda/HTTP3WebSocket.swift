//===----------------------------------------------------------------------===//
// WebSockets over HTTP/3 (RFC 9220).
//
// RFC 8441's extended CONNECT, carried over to HTTP/3: SETTINGS_ENABLE_
// CONNECT_PROTOCOL lets the client open a request stream with `:protocol:
// websocket`, which is routed as the GET it stands for. The route's handshake
// answers it 200, and from then on the frames the client sends are the
// stream's DATA, and the frames sent back the 200's body -- staged as DATA
// frames for the endpoint to send, as any streamed answer is
// (StreamingResponse.swift).
//
// The stream is dispatched on its HEADERS, since the request never ends, and
// its DATA is handed to the stream's task as it arrives, through an
// `H3Inbound`, rather than collected. The task runs the WebSocket as an
// HTTP/2 stream's does (HTTP2WebSocket.swift). The stream's window is given
// back as the session takes the bytes, not as they arrive, so a handler that
// stops reading stops the client and nothing else on the connection.
//
// A WebSocket that ends with its close handshake ends the stream with FIN;
// one given up on -- no pong, or no answer to a close -- is reset with
// H3_REQUEST_CANCELLED.
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import Synchronization
import Vega
import VegaIO

/// The DATA of a WebSocket's stream, from the endpoint to the session
/// reading it.
final class H3Inbound: AsyncReader, @unchecked Sendable {
    unowned(unsafe) let stream: H3Stream
    private let arrived = IOEvent()
    private let lock = Mutex<Void>(())
    private var buffer = ByteBuffer()
    /// Taken by the session since the endpoint was last asked to give the
    /// window back.
    private var owed = 0
    private let creditAt: Int
    /// The client ended its side.
    private var ended = false
    /// The stream was reset, or the connection lost.
    private var failed = false
    /// Nobody reads any more: what arrives is dropped.
    private var closed = false

    init(stream: H3Stream, window: Int) {
        self.stream = stream
        // A quarter of the window: the transport gives it back once half
        // has been taken.
        creditAt = max(1, window / 4)
    }

    deinit {
        buffer.destroy()
    }

    // MARK: The endpoint

    /// DATA payload as it arrives.
    func deliver(_ p: UnsafePointer<UInt8>, _ count: Int) {
        let kept = lock.withLock { _ -> Bool in
            if closed || count == 0 { return false }
            buffer.write(p, count)
            return true
        }
        if kept { arrived.signal() }
    }

    /// The client ended its side.
    func end() {
        lock.withLock { _ in ended = true }
        arrived.signal()
    }

    /// The stream is gone under the session.
    func fail() {
        lock.withLock { _ in failed = true }
        arrived.signal()
    }

    /// Bytes delivered and not yet taken: what the stream's window still
    /// holds back.
    var held: Int {
        lock.withLock { _ in buffer.readableBytes }
    }

    // MARK: The session

    /// The bytes that have arrived, waiting for them as a socket's read
    /// would, deadline and all.
    func read(into destination: inout IOBuffer) async throws(IOError) -> Int {
        while true {
            var credit = false
            let got = lock.withLock { _ -> Int? in
                if failed { return -1 }
                let n = min(buffer.readableBytes, destination.spareCapacity)
                if n > 0 {
                    destination.append(UnsafeRawBufferPointer(start: buffer.readPointer, count: n))
                    buffer.consume(n)
                    owed &+= n
                    if owed >= creditAt {
                        owed = 0
                        credit = true
                    }
                    return n
                }
                return ended ? 0 : nil
            }
            if credit {
                // The endpoint works the window out from what is still held.
                let endpoint = stream.endpoint
                endpoint.lock.withLock { _ in endpoint.post(stream) }
            }
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

extension QUICEndpoint {
    /// Runs the WebSocket `s`'s route accepted, in `s`'s task, until it
    /// ends; then ends the stream, or resets it if the client was given up
    /// on.
    func runWebSocket(_ s: H3Stream, _ inbound: H3Inbound, _ upgrade: WebSocketUpgrade) async {
        // The 200, staged; the frames follow it as its body, which is
        // nothing for --cache-size to keep.
        s.x.pointee.capture = nil
        s.x.pointee.cacheInvalidates = 0
        let channel = startStream(s.x)
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
            if abandoned { s.failCode = HTTP3Error.requestCancelled }
            channel.closeH3Locked(s, failed: abandoned)
            s.taskDone = true
            post(s)
        }
    }
}

extension H3Connection {
    /// Gives a WebSocket's stream its window back, as far as the session
    /// has taken what arrived.
    func extendTunnel(_ s: H3Stream, _ inbound: H3Inbound) {
        guard let stream = quic.stream(s.id), !stream.released else { return }
        let held = UInt64(stream.receive.ready.readableBytes &+ inbound.held)
        let received = stream.receive.received
        quic.extendStreamWindow(s.id, consumed: received > held ? received &- held : 0)
    }
}

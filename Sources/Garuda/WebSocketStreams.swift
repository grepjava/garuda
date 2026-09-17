//===----------------------------------------------------------------------===//
// WebSockets on one stream of an HTTP/2 or HTTP/3 connection.
//
// RFC 8441 (HTTP/2) and RFC 9220 (HTTP/3) carry a WebSocket over an extended
// CONNECT: a request with `:protocol: websocket` whose stream, once answered
// 200, holds the RFC 6455 frames in its DATA. Everything about the frames is
// what WebSocket.swift already does on an HTTP/1.1 connection -- masking,
// fragments, UTF-8, pings, closing, permessage-deflate, the handler's queue.
// This file is what differs when the frames arrive on a stream rather than a
// socket:
//
// - Bytes come from DATA frames into the stream slot's read buffer, and the
//   frame decoder takes them from there.
// - Backpressure is flow control. Bytes the decoder has not taken are not
//   credited back to the peer, so a handler that stops reading stops the
//   peer's stream and nothing else on the connection. HTTP/1.1 stops reading
//   the socket instead.
// - The peer's END_STREAM, or FIN on QUIC, is what a closed socket is on
//   HTTP/1.1. A WebSocket ends cleanly with END_STREAM or FIN of our own, and
//   is abandoned with a reset: RST_STREAM(CANCEL), or H3_REQUEST_CANCELLED.
//
// The stream is dispatched on its HEADERS, as the request never ends, and is
// routed as the GET it would be over HTTP/1.1, to the `app.webSocket` route.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import AvianQUIC

extension Worker {
    /// Whether SETTINGS_ENABLE_CONNECT_PROTOCOL goes out on HTTP/2
    /// connections, which is what lets a client ask for a WebSocket there.
    var http2WebSocketsAdvertised: Bool {
        config.websocketsEnabled && config.websocketOverHTTP2
    }

    /// Whether the request on `slot` is an extended CONNECT for a WebSocket.
    func isStreamWebSocketRequest(_ slot: Int) -> Bool {
        let c = table[slot]
        let p = c.pointee.connectProtocol
        return c.pointee.isStream && p.readableBytes == 9
            && equalsExact(UnsafePointer(p.readPointer), 9, "websocket")
    }

    /// Whether a WebSocket asked for on this stream is served here.
    func streamWebSocketAllowed(_ slot: Int) -> Bool {
        guard config.websocketsEnabled, isStreamWebSocketRequest(slot) else { return false }
        return table[slot].pointee.isH3Stream ? config.websocketOverHTTP3 : config.websocketOverHTTP2
    }

    /// DATA for a WebSocket stream, and whether the peer ended its side with
    /// it. Before the handler has accepted, bytes wait uncredited; the window
    /// is what bounds them. After a refusal or the end, they are counted and
    /// dropped.
    mutating func receiveStreamWebSocketData(_ streamSlot: Int, _ p: UnsafePointer<UInt8>?, _ n: Int,
                                             ended: Bool) {
        let s = table[streamSlot]
        s.pointee.lastActivity = av_monotonic_ms()
        if ended {
            s.pointee.bodyRemaining = 0
            s.pointee.flags.insert(.peerClosed)
        }
        switch s.pointee.state {
        case .websocket:
            if n > 0, let p {
                if !s.pointee.ws.closeReceived {
                    s.pointee.read.write(p, n)
                }
                // Credited as it arrives while the handler's queue has room:
                // a frame larger than the window must be able to arrive whole.
                // The frame decoder refuses one over the message limit, so the
                // buffer stays bounded. After a close the bytes are dropped,
                // and credited all the same.
                if websocketQueueFull(streamSlot) && !s.pointee.ws.closeReceived {
                    s.pointee.wsUncredited += n
                } else {
                    creditStreamWebSocket(streamSlot, n)
                }
            }
            pumpWebSocket(streamSlot)
            guard table[streamSlot].pointee.state == .websocket else { return }
            if ended { streamWebSocketPeerEnded(streamSlot) }
        case .dispatching:
            // Not accepted yet: held, and credited once it is.
            if n > 0, let p {
                s.pointee.read.write(p, n)
                s.pointee.wsUncredited += n
            }
        default:
            if n > 0 { creditStreamWebSocket(streamSlot, n) }
            // Finished on our side, and now on the peer's; unless our last
            // frames are still waiting for window, which the sweep bounds.
            if ended && s.pointee.state == .closing && s.pointee.write.isEmpty { releaseStream(streamSlot) }
        }
    }

    /// The peer ended its half without a close frame: to the handler that is
    /// 1006, as a socket closing is on HTTP/1.1.
    private mutating func streamWebSocketPeerEnded(_ streamSlot: Int) {
        let s = table[streamSlot]
        if let channel = s.pointee.ws.channel, !channel.ended {
            channel.ended = true
            channel.receiveWaiter.take()?.resume()
        }
        if s.pointee.write.isEmpty {
            closeWebSocketIfDone(streamSlot)
        } else {
            s.pointee.ws.closeReceived = true
        }
    }

    /// Credits what was held while the handler's queue was full, once it has
    /// room again. Called after the frame decoder has run.
    mutating func releaseStreamWebSocketCredit(_ streamSlot: Int) {
        let s = table[streamSlot]
        let held = s.pointee.wsUncredited
        guard held > 0, !websocketQueueFull(streamSlot) || s.pointee.ws.closeReceived else { return }
        s.pointee.wsUncredited = 0
        creditStreamWebSocket(streamSlot, held)
    }

    /// Gives the peer back `n` bytes of window, for bytes taken off the
    /// stream or dropped.
    mutating func creditStreamWebSocket(_ streamSlot: Int, _ n: Int) {
        let s = table[streamSlot]
        let parent = Int(s.pointee.parentSlot)
        guard parent >= 0 else { return }
        if s.pointee.isH3Stream {
            guard let h3 = table[parent].pointee.h3, let stream = h3.quic.stream(s.pointee.qstreamID) else { return }
            extendH3RequestWindow(streamSlot, h3, stream)
            flushQUIC(parent)
        } else if n > 0 {
            h2NoteConsumed(streamSlot, n)
            h2FlushWindowUpdates(streamSlot)
            if table[parent].pointee.state == .http2 { _ = flush(parent) }
        }
    }

    /// Answers the extended CONNECT on `slot` with 200 and switches the
    /// stream to frames. Nil when the request is no longer there to accept.
    mutating func acceptStreamWebSocket(_ slot: Int, _ offer: WebSocketOffer,
                                        subprotocol: String?) -> WSChannel? {
        let c = table[slot]
        guard c.pointee.state == .dispatching, !c.pointee.flags.contains(.responseStarted),
              !c.pointee.flags.contains(.timedOut) else { return nil }
        disarmDeadline(slot)

        c.pointee.ws = WebSocketState()
        if config.wsCompress && !offer.extensions.isEmpty {
            c.pointee.ws.deflate = WSDeflate.negotiate(offer.extensions)
        }
        if let subprotocol { addHeader(slot, "sec-websocket-protocol", subprotocol) }
        if let agreement = c.pointee.ws.deflate {
            var value = ByteBuffer()
            defer { value.destroy() }
            agreement.writeResponse(into: &value)
            addHeader(slot, "sec-websocket-extensions",
                      String(decoding: UnsafeBufferPointer(start: value.readPointer, count: value.readableBytes),
                             as: UTF8.self))
        }
        // The 200 goes out with the stream left open, through whatever
        // middleware added to the response, like any streamed response.
        respond(slot, status: 200, nil, 0, streaming: true)
        guard table[slot].pointee.state == .dispatching,
              table[slot].pointee.flags.contains(.responseStarted) else { return nil }
        // Frames follow, not a streamed body: the route returning while the
        // handler runs in its own task must not end the stream.
        c.pointee.flags.remove(.streamingResponse)

        let channel = WSChannel()
        c.pointee.ws.channel = channel
        c.pointee.ws.accepted = true
        c.pointee.state = .websocket
        c.pointee.flags.insert(.websocketMode)
        c.pointee.lastActivity = av_monotonic_ms()
        // Frames the client sent straight after its HEADERS are waiting.
        pumpWebSocket(slot)
        if table[slot].pointee.state == .websocket, table[slot].pointee.flags.contains(.peerClosed) {
            streamWebSocketPeerEnded(slot)
        }
        return channel
    }

    /// Ends a WebSocket's stream: with END_STREAM or FIN once the closes have
    /// been exchanged, or with a reset when it is abandoned.
    mutating func endStreamWebSocket(_ slot: Int, clean: Bool) {
        let s = table[slot]
        guard s.pointee.state == .websocket else { return }
        let parent = Int(s.pointee.parentSlot)
        // The handler hears of it now, whatever the stream still has to do.
        releaseWebSocket(slot)
        s.pointee.flags.remove(.websocketMode)

        if s.pointee.isH3Stream {
            guard parent >= 0, let h3 = table[parent].pointee.h3 else {
                closeConnection(slot)
                return
            }
            if clean {
                s.pointee.flags.insert(.responseComplete)
                s.pointee.state = .writing
                _ = flushH3Stream(slot)
                if table[slot].pointee.state != .free { closeH3Stream(slot) }
            } else {
                h3.quic.resetStream(s.pointee.qstreamID, code: HTTP3Error.requestCancelled)
                h3.quic.stopSending(s.pointee.qstreamID, code: HTTP3Error.requestCancelled)
                closeH3Stream(slot)
            }
            return
        }

        if clean {
            s.pointee.flags.insert(.responseComplete)
            // Waiting for the peer's END_STREAM, if it has not sent it, so that
            // it is not answered with a reset; the sweep gives up on it.
            // Either way the stream flush closes it once what is queued -- the
            // close frame among it -- has gone out under the peer's window.
            s.pointee.state = s.pointee.flags.contains(.peerClosed) ? .writing : .closing
            _ = flushStream(slot)
        } else {
            closeStream(slot, resetWith: .cancel)
        }
    }

    /// A stream in `.closing` that the peer has now finished.
    private mutating func releaseStream(_ streamSlot: Int) {
        if table[streamSlot].pointee.isH3Stream {
            closeH3Stream(streamSlot)
        } else {
            closeStream(streamSlot, resetWith: nil)
        }
    }
}

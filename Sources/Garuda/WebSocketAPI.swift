//===----------------------------------------------------------------------===//
// WebSocket handlers.
//
//     app.webSocket("/echo") { (ws: WebSocket) async throws in
//         for try await message in ws {
//             try await ws.send(message)
//         }
//     }
//
// A WebSocket arrives as an HTTP/1.1 GET with `Upgrade: websocket`, and is a
// route like any other until it is accepted: middleware runs in front of it
// and extractors run before it, so a request refused by either is answered
// with an ordinary status and never becomes a WebSocket. Once every extractor
// has what it needs, the upgrade is answered 101 and the handler runs for as
// long as the WebSocket lasts. When the handler returns, a WebSocket it did
// not close is closed for it: 1000, or 1011 if it threw.
//
// The handler sees whole messages. Fragments are joined, text is checked to
// be UTF-8, pings are answered and the server's own keepalive pings sent,
// all by the engine, whether or not the handler is reading. Messages the
// handler has not read yet queue up to `--ws-max-queue` and
// `--ws-max-queue-bytes`; past that the socket is not read, so a peer
// sending faster than the handler reads is slowed by TCP rather than held in
// memory. A send waits while more than `ServerConfig.writeHighWaterMark` is
// queued for a peer that is reading slowly.
//
// A handler runs on the worker's thread, on a task of its own rather than one
// of the pool's, so a server holding many WebSockets open leaves the pool to
// ordinary requests. A task group's child tasks run there too; an
// unstructured `Task { }` does not, and using a WebSocket from one stops the
// worker with a message saying so.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// One whole WebSocket message.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary([UInt8])
}

/// Why a WebSocket operation did not complete.
public enum WebSocketError: Error, Equatable, Sendable {
    /// The WebSocket has ended, or a close has been sent: nothing more can
    /// be sent on it.
    case closed
    /// Another task is already waiting to receive. A WebSocket has one
    /// reader at a time.
    case busy
}

/// A WebSocket, for as long as its handler runs.
public final class WebSocket: @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let channel: WSChannel
    /// The subprotocol agreed in the handshake: the first of the route's
    /// `subprotocols` that the client offered, or nil.
    public let subprotocol: String?
    /// The subprotocols the client offered, in its order.
    public let offeredSubprotocols: [String]

    init(worker: UnsafeMutablePointer<Worker>, slot: Int, channel: WSChannel,
         subprotocol: String?, offeredSubprotocols: [String]) {
        self.worker = worker
        self.slot = slot
        self.channel = channel
        self.subprotocol = subprotocol
        self.offeredSubprotocols = offeredSubprotocols
    }

    /// Whether nothing more can be sent: a close went out, by `close` or by
    /// the engine, or the connection has ended.
    public var isClosed: Bool {
        onWorker()
        return channel.gone || worker.pointee.table[slot].pointee.ws.closeSent
    }

    /// The code the peer closed with, 1005 when its close carried none, or
    /// 1006 when the connection ended without one. Nil until the peer's side
    /// has ended.
    public var closeCode: UInt16? {
        channel.ended ? channel.closeCode : nil
    }

    /// The reason the peer gave with its close, or empty.
    public var closeReason: String {
        String(decoding: channel.closeReason, as: UTF8.self)
    }

    /// Bytes sent and not yet taken by the peer. A send waits while this is
    /// above `ServerConfig.writeHighWaterMark`.
    public var queuedBytes: Int {
        onWorker()
        return channel.gone ? 0 : worker.pointee.websocketBacklog(slot)
    }

    /// The next message from the peer, waiting for one if none has arrived.
    /// Nil once the peer has closed or the connection has ended, after every
    /// message that arrived before that has been read.
    public func receive() async throws -> WebSocketMessage? {
        onWorker()
        while true {
            if !channel.queue.isEmpty {
                let message = channel.queue.removeFirst()
                switch message {
                case .text(let text): channel.queuedBytes -= text.utf8.count + 64
                case .binary(let bytes): channel.queuedBytes -= bytes.count + 64
                }
                // Room has been made: frames held in the socket may now be read.
                if !channel.gone { worker.pointee.pumpWebSocket(slot) }
                return message
            }
            if channel.ended { return nil }
            // A violation behind the messages just read: they have all been
            // read now, and the close goes out after whatever answered them.
            if !channel.gone && worker.pointee.table[slot].pointee.ws.pendingFailure != 0 {
                worker.pointee.applyPendingWebSocketFailure(slot)
                continue
            }
            guard channel.receiveWaiter == nil else { throw WebSocketError.busy }
            try await parkOnWorker(worker, { self.channel.receiveWaiter = $0 },
                                   { self.channel.receiveWaiter.take() })
        }
    }

    /// Sends a text message.
    public func send(_ text: String) async throws {
        var text = text
        let sent = text.withUTF8 { worker.pointee.sendWebSocketMessage(slot, opcode: .text, $0.baseAddress, $0.count) }
        try await settle(sent)
    }

    /// Sends a binary message.
    public func send(_ bytes: [UInt8]) async throws {
        let sent = bytes.withUnsafeBufferPointer {
            worker.pointee.sendWebSocketMessage(slot, opcode: .binary, $0.baseAddress, $0.count)
        }
        try await settle(sent)
    }

    /// Sends a message as the kind it is.
    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text): try await send(text)
        case .binary(let bytes): try await send(bytes)
        }
    }

    /// Starts the close handshake with `code` and `reason`, which the peer
    /// receives. Messages still arriving before the peer's close are read as
    /// usual; `receive` returns nil once it comes. Closing twice does nothing.
    ///
    /// `code` must be one an endpoint may send: 1000 to 1003, 1007 to 1014,
    /// or 3000 to 4999. The reason is cut to 123 bytes.
    public func close(code: UInt16 = WSCloseCode.normal, reason: String = "") {
        onWorker()
        precondition(WebSocketCodec.isSendableCloseCode(code), "\(code) is not a close code a server may send")
        guard !channel.gone else { return }
        var reason = reason
        reason.withUTF8 {
            worker.pointee.sendCloseFrame(slot, code: code, reason: $0.baseAddress,
                                          reasonLength: truncatedUTF8Length($0, 123))
        }
    }

    /// Waits `milliseconds` on the worker's timers, between sends. Throws
    /// `closed` if the connection ends first, at once rather than when the
    /// time is up. `Task.sleep` would resume the handler off its worker's
    /// thread; this does not.
    public func sleep(milliseconds: UInt64) async throws {
        onWorker()
        guard !channel.gone else { throw WebSocketError.closed }
        try Task.checkCancellation()
        let channel = self.channel
        var waitID: Int32 = -1
        let outcome = await Worker.waitTimed(worker, milliseconds: milliseconds) { id in
            waitID = id
            channel.sleeps.append(id)
        }
        channel.sleeps.removeAll { $0 == waitID }
        if outcome == .cancelled || channel.gone { throw WebSocketError.closed }
    }

    private func settle(_ sent: Bool) async throws {
        onWorker()
        guard sent, !channel.gone else { throw WebSocketError.closed }
        while !channel.gone, worker.pointee.websocketBacklog(slot) > worker.pointee.config.writeHighWaterMark {
            // Someone else is already waiting for this drain. Ours are queued
            // behind theirs, in order.
            if channel.writeWaiter != nil { return }
            try await parkOnWorker(worker, { self.channel.writeWaiter = $0 },
                                   { self.channel.writeWaiter.take() })
        }
        if channel.gone { throw WebSocketError.closed }
    }

    @inline(__always)
    func onWorker() {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a WebSocket was used off its worker's thread; use a task group, not Task { }")
    }
}

extension WebSocket: AsyncSequence {
    public typealias Element = WebSocketMessage

    public struct AsyncIterator: AsyncIteratorProtocol {
        let socket: WebSocket
        public mutating func next() async throws -> WebSocketMessage? {
            try await socket.receive()
        }
    }

    /// The messages from the peer, until it closes.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(socket: self)
    }
}

/// The length of the longest prefix of `bytes`, at most `limit`, that does not
/// end part-way through a UTF-8 character.
private func truncatedUTF8Length(_ bytes: UnsafeBufferPointer<UInt8>, _ limit: Int) -> Int {
    if bytes.count <= limit { return bytes.count }
    var n = limit
    // Back off continuation bytes, then the lead byte they belonged to.
    while n > 0 && bytes[n] & 0xC0 == 0x80 { n -= 1 }
    return n
}

/// A handler taking extracted values, in a struct: a function with a
/// parameter pack cannot be held as a generic value on its own.
struct VariadicHandler<each E>: @unchecked Sendable {
    let call: (WebSocket, repeat each E) async throws -> Void
}

/// Carries what a handler was given onto the task that runs it. Everything
/// in it is used on the worker's thread only.
private struct Carried<T>: @unchecked Sendable {
    let value: T
}

// MARK: - Registration

extension RouteBuilder {
    /// Serves WebSockets on `pattern`, with extractors. Every extractor runs
    /// before the upgrade is accepted, so one that refuses the request
    /// refuses the WebSocket with an ordinary status.
    ///
    ///     app.webSocket("/room/:id", subprotocols: ["chat.v2"]) {
    ///         (ws: WebSocket, room: Path<Int>, user: Context<User>) async throws in … }
    ///
    /// `subprotocols` are the ones this route speaks, most preferred first;
    /// the first one the client offered is agreed. A client that offered none
    /// of them is still accepted, with `ws.subprotocol` nil.
    ///
    /// The route serves an HTTP/1.1 upgrade, and on HTTP/2 and HTTP/3 an
    /// extended CONNECT with `:protocol: websocket`; the handler cannot tell
    /// them apart. A request to the route that is not a WebSocket upgrade is
    /// answered 426 with `Upgrade: websocket` (400 on HTTP/2 and HTTP/3), and
    /// one asking for another version 426 with `Sec-WebSocket-Version: 13`.
    @discardableResult
    public func webSocket<each E: RequestExtractor>(
        _ pattern: String,
        subprotocols: [String] = [],
        _ handler: sending @escaping (WebSocket, repeat each E) async throws -> Void
    ) -> OpenAPIOperation {
        let handler = VariadicHandler<repeat each E>(call: handler)
        onAsync(.get, pattern) { request, response in
            let offer: WebSocketOffer
            switch request.worker.pointee.websocketOffer(request.slot) {
            case .success(let found):
                offer = found
            case .failure(let problem):
                WebSocket.refuse(problem, response)
                return
            }
            var parameter = 0
            let run = Carried(value: WebSocket.bind(handler,
                                                    repeat try (each E).extract(from: request, parameter: &parameter)))
            let chosen = subprotocols.first { offer.subprotocols.contains($0) }
            let worker = request.worker
            let slot = request.slot
            guard let channel = worker.pointee.acceptWebSocket(slot, offer, subprotocol: chosen) else { return }
            let socket = WebSocket(worker: worker, slot: slot, channel: channel,
                                   subprotocol: chosen, offeredSubprotocols: offer.subprotocols)
            // A task of its own, preferring the worker's executor: the pool's
            // task this runs on goes back to the pool when this returns.
            Task(executorPreference: worker.pointee.handlerTasks!.executor) {
                var failure: (any Error)? = nil
                do {
                    try await run.value(socket)
                } catch is CancellationError {
                } catch let error as WebSocketError where error == .closed {
                    // The WebSocket ended under the handler; nothing went wrong.
                } catch {
                    failure = error
                }
                socket.worker.pointee.webSocketHandlerFinished(socket.slot, socket.channel, failure)
            }
        }
        let operation = OpenAPIOperation(.get, pattern)
        repeat operation.describeExtractor((each E).self)
        operation.response(.switchingProtocols, "The connection becomes a WebSocket")
        operation.response(HTTPStatus(426), "Not a WebSocket upgrade")
        document(operation)
        return operation
    }
}

extension WebSocket {
    /// The handler with its extracted values applied. A closure rather than
    /// the values themselves, because the task that runs it cannot capture a
    /// parameter pack.
    static func bind<each E>(_ handler: VariadicHandler<repeat each E>,
                             _ values: repeat each E) -> (WebSocket) async throws -> Void {
        { socket in try await handler.call(socket, repeat each values) }
    }

    static func refuse(_ problem: WebSocketOffer.Problem, _ response: borrowing Response) {
        switch problem {
        case .notUpgrade:
            response.addHeader("upgrade", "websocket")
            response.send(status: HTTPStatus(426), "this route speaks WebSocket\n")
        case .version:
            response.addHeader("sec-websocket-version", "13")
            response.send(status: HTTPStatus(426), "WebSocket version 13 is the one spoken here\n")
        case .malformed:
            response.send(status: .badRequest, "the WebSocket handshake is incomplete\n")
        case .multiplexed:
            response.send(status: .badRequest,
                          "a WebSocket over HTTP/2 or HTTP/3 starts with an extended CONNECT\n")
        }
    }
}

extension Worker {
    /// A WebSocket's handler returned or threw. One it left open is closed
    /// for it.
    mutating func webSocketHandlerFinished(_ slot: Int, _ channel: WSChannel, _ failure: (any Error)?) {
        if let failure {
            let description = String(describing: failure)
            Log.error { line in
                line.str("websocket handler threw: ")
                description.withCString { line.cstr($0) }
            }
        }
        guard !channel.gone, table[slot].pointee.ws.channel === channel else { return }
        if table[slot].pointee.ws.pendingFailure != 0 {
            applyPendingWebSocketFailure(slot)
            return
        }
        sendCloseFrame(slot, code: failure == nil ? WSCloseCode.normal : WSCloseCode.internalError,
                       reason: nil, reasonLength: 0)
    }
}

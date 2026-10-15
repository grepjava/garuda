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
// has what it needs, the upgrade is answered 101, and the handler runs in a
// task of its own for as long as the WebSocket lasts, while the connection's
// task reads its frames (WebSocketSession.swift). When the handler returns,
// a WebSocket it did not close is closed for it: 1000, or 1011 if it threw.
//
// The handler sees whole messages. Fragments are joined, text is checked to
// be UTF-8, pings are answered and the server's own keepalive pings sent,
// whether or not the handler is reading. Messages the handler has not read
// yet queue up to `--ws-max-queue` and `--ws-max-queue-bytes`; past that
// the socket is not read, so a peer sending faster than the handler reads is
// slowed by TCP rather than held in memory. A send waits while more than
// `ServerConfig.writeHighWaterMark` is queued for a peer that reads slowly.
//
// A WebSocket may be shared with child tasks: one receives while another
// sends. One task at a time receives.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega

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

/// The close codes a handler sends and reads most (RFC 6455 section 7.4.1).
public enum WebSocketCloseCode {
    public static let normal: UInt16 = 1000
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let unsupportedData: UInt16 = 1003
    /// Read only: the peer's close carried no code.
    public static let noStatus: UInt16 = 1005
    /// Read only: the connection ended without a close.
    public static let abnormal: UInt16 = 1006
    public static let invalidPayload: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    public static let messageTooBig: UInt16 = 1009
    public static let internalError: UInt16 = 1011
}

/// A WebSocket, for as long as its handler runs.
public final class WebSocket: Sendable {
    let session: WebSocketSession
    /// The subprotocol agreed in the handshake: the first of the route's
    /// `subprotocols` that the client offered, or nil.
    public let subprotocol: String?
    /// The subprotocols the client offered, in its order.
    public let offeredSubprotocols: [String]

    init(session: WebSocketSession, subprotocol: String?, offeredSubprotocols: [String]) {
        self.session = session
        self.subprotocol = subprotocol
        self.offeredSubprotocols = offeredSubprotocols
    }

    /// Whether nothing more can be sent: a close went out, or the connection
    /// has ended.
    public var isClosed: Bool { session.isClosed }

    /// The code the peer closed with, 1005 when its close carried none, or
    /// 1006 when the connection ended without one. Nil until the peer's side
    /// has ended.
    public var closeCode: UInt16? { session.peerClose?.code }

    /// The reason the peer gave with its close, or empty.
    public var closeReason: String { session.peerClose?.reason ?? "" }

    /// Bytes sent and not yet taken by the peer. A send waits while this is
    /// above `ServerConfig.writeHighWaterMark`.
    public var queuedBytes: Int { session.channel.backlog }

    /// The next message from the peer, waiting for one if none has arrived.
    /// Nil once the peer has closed or the connection has ended, after every
    /// message that arrived before that has been read.
    public func receive() async throws -> WebSocketMessage? {
        try await session.receive()
    }

    /// Sends a text message.
    public func send(_ text: String) async throws {
        var text = text
        let queued = text.withUTF8 { session.send(.text, $0) }
        try await session.settle(queued)
    }

    /// Sends a binary message.
    public func send(_ bytes: [UInt8]) async throws {
        let queued = bytes.withUnsafeBufferPointer { session.send(.binary, $0) }
        try await session.settle(queued)
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
    public func close(code: UInt16 = WebSocketCloseCode.normal, reason: String = "") {
        precondition(WebSocketCodec.isSendableCloseCode(code), "\(code) is not a close code a server may send")
        session.sendClose(code: code, reason: Array(reason.utf8))
    }

    /// Waits `milliseconds` between sends. Throws `closed` if the connection
    /// ends first, at once rather than when the time is up.
    public func sleep(milliseconds: UInt64) async throws {
        try await sleep(for: .milliseconds(Int64(clamping: milliseconds)))
    }

    /// Waits `duration` between sends. Throws `closed` if the connection
    /// ends first.
    public func sleep(for duration: Duration) async throws {
        if session.isOver { throw WebSocketError.closed }
        do {
            try await Runtime.sleep(for: duration)
        } catch {
            throw WebSocketError.closed
        }
        if session.isOver { throw WebSocketError.closed }
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

extension WebSocket {
    /// Subscribes the WebSocket to `topics`, until it ends (Broadcast.swift).
    /// With `after`, messages published since that one are delivered first.
    public func subscribe(_ topics: Topic..., after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        let session = self.session
        return try TopicBus.current().subscribe(topics, after: after) { !session.isGone }
    }
}

// MARK: - The handshake

/// What the handshake asked for, read from the request at dispatch.
struct WebSocketOffer {
    enum Problem: Error {
        /// Not an upgrade at all: answered 426 with `Upgrade: websocket`.
        case notUpgrade
        /// An upgrade to a version other than 13: 426 with the version.
        case version
        /// An upgrade missing what it needs: 400.
        case malformed
        /// Over HTTP/2, a request that is not an extended CONNECT.
        case multiplexed
        /// --no-websockets, or an extended CONNECT for another protocol:
        /// 501.
        case disabled
    }

    var key: [UInt8]
    var subprotocols: [String]
    var extensions: [[UInt8]]

    /// The offer `request` makes, or what is wrong with it.
    static func read(_ request: borrowing Request) -> Result<WebSocketOffer, Problem> {
        let x = request.exchange
        // Over HTTP/3 no extended CONNECT is offered yet (RFC 9220), so a
        // request there is never one.
        if case .http3 = x.pointee.link { return .failure(.multiplexed) }
        if case .http2 = x.pointee.link {
            switch x.pointee.connectProtocol {
            case .none: return .failure(.multiplexed)
            case .other: return .failure(.disabled)
            case .websocket: return readExtendedConnect(request)
            }
        }
        guard x.pointee.canUpgrade else {
            return .failure(x.pointee.websocketsRefused ? .disabled : .notUpgrade)
        }
        var key: [UInt8]? = nil
        var sawUpgrade = false
        var sawConnection = false
        var version = -1
        var subprotocols: [String] = []
        var extensions: [[UInt8]] = []
        request.forEachHeader { name, value in
            switch name.count {
            case 7 where lowercasedEquals(name, "upgrade"):
                sawUpgrade = sawUpgrade || containsToken(value, "websocket")
            case 10 where lowercasedEquals(name, "connection"):
                sawConnection = sawConnection || containsToken(value, "upgrade")
            case 17 where lowercasedEquals(name, "sec-websocket-key"):
                key = value.withUnsafeBufferPointer { Array($0) }
            case 21 where lowercasedEquals(name, "sec-websocket-version"):
                version = value.withUnsafeBufferPointer { b in
                    Int(String(decoding: b, as: UTF8.self).trimmingSpaces) ?? -1
                }
            case 22 where lowercasedEquals(name, "sec-websocket-protocol"):
                forEachItem(value) { subprotocols.append(String(decoding: $0, as: UTF8.self)) }
            case 24 where lowercasedEquals(name, "sec-websocket-extensions"):
                extensions.append(value.withUnsafeBufferPointer { Array($0) })
            default:
                break
            }
        }
        guard request.method == .get, sawUpgrade, sawConnection else { return .failure(.notUpgrade) }
        guard request.version == (1, 1) else { return .failure(.malformed) }
        guard version == 13 else { return .failure(.version) }
        // A key is 16 random bytes in base64: 24 characters.
        guard let key, key.count == 24 else { return .failure(.malformed) }
        return .success(WebSocketOffer(key: key, subprotocols: subprotocols, extensions: extensions))
    }

    /// RFC 8441's handshake: the extended CONNECT itself stands for the
    /// upgrade, and there is no key, so only the version, subprotocols and
    /// extensions are read.
    private static func readExtendedConnect(_ request: borrowing Request) -> Result<WebSocketOffer, Problem> {
        var version = -1
        var subprotocols: [String] = []
        var extensions: [[UInt8]] = []
        request.forEachHeader { name, value in
            switch name.count {
            case 21 where lowercasedEquals(name, "sec-websocket-version"):
                version = value.withUnsafeBufferPointer { b in
                    Int(String(decoding: b, as: UTF8.self).trimmingSpaces) ?? -1
                }
            case 22 where lowercasedEquals(name, "sec-websocket-protocol"):
                forEachItem(value) { subprotocols.append(String(decoding: $0, as: UTF8.self)) }
            case 24 where lowercasedEquals(name, "sec-websocket-extensions"):
                extensions.append(value.withUnsafeBufferPointer { Array($0) })
            default:
                break
            }
        }
        guard version == 13 else { return .failure(.version) }
        return .success(WebSocketOffer(key: [], subprotocols: subprotocols, extensions: extensions))
    }

    /// The 28-character Sec-WebSocket-Accept value.
    func acceptValue() -> String {
        let guid: [UInt8] = Array("258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8)
        return StandardBase64.encode(sha1(key + guid))
    }
}

private func lowercasedEquals(_ span: Span<UInt8>, _ name: StaticString) -> Bool {
    span.withUnsafeBufferPointer { b in
        let n = name.utf8Start
        for i in 0..<b.count where asciiLowercased(b[i]) != n[i] { return false }
        return true
    }
}

private func asciiLowercased(_ c: UInt8) -> UInt8 {
    c >= 0x41 && c <= 0x5A ? c | 0x20 : c
}

/// Calls `body` with each comma-separated item, trimmed of spaces and tabs;
/// empty ones are skipped.
private func forEachItem(_ value: Span<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
    value.withUnsafeBufferPointer { b in
        var start = 0
        while start <= b.count {
            var end = start
            while end < b.count, b[end] != 0x2C { end += 1 }
            var lo = start
            var hi = end
            while lo < hi, b[lo] == 0x20 || b[lo] == 0x09 { lo += 1 }
            while hi > lo, b[hi - 1] == 0x20 || b[hi - 1] == 0x09 { hi -= 1 }
            if hi > lo { body(UnsafeBufferPointer(rebasing: b[lo..<hi])) }
            start = end + 1
        }
    }
}

private func containsToken(_ value: Span<UInt8>, _ token: String) -> Bool {
    var found = false
    forEachItem(value) { item in
        if !found && item.count == token.utf8.count
            && zip(item, token.utf8).allSatisfy({ asciiLowercased($0) == $1 }) { found = true }
    }
    return found
}

extension String {
    var trimmingSpaces: Substring {
        var s = self[...]
        while s.first == " " || s.first == "\t" { s = s.dropFirst() }
        while s.last == " " || s.last == "\t" { s = s.dropLast() }
        return s
    }
}

/// SHA-1, which the handshake's accept value is made with (RFC 6455 section
/// 4.2.2) and nothing else here: it hashes 60 bytes per WebSocket.
func sha1(_ message: [UInt8]) -> [UInt8] {
    var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
    var data = message
    let bits = UInt64(message.count) &* 8
    data.append(0x80)
    while data.count % 64 != 56 { data.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
    var w = [UInt32](repeating: 0, count: 80)
    for chunk in stride(from: 0, to: data.count, by: 64) {
        for i in 0..<16 {
            let b = chunk + i * 4
            w[i] = UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
        }
        for i in 16..<80 {
            let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            w[i] = v << 1 | v >> 31
        }
        var (a, b, c, d, e) = h
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
            e = d
            d = c
            c = b << 30 | b >> 2
            b = a
            a = t
        }
        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
    }
    var out: [UInt8] = []
    for word in [h.0, h.1, h.2, h.3, h.4] {
        out += [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
    }
    return out
}

// MARK: - Registration

/// A handler taking extracted values, in a struct: a function with a
/// parameter pack cannot be held as a generic value on its own.
struct VariadicWebSocketHandler<each E>: @unchecked Sendable {
    let call: @concurrent (WebSocket, repeat each E) async throws -> Void
}

/// Carries what a handler was given onto the task that runs it.
struct CarriedHandler: @unchecked Sendable {
    let run: @concurrent (WebSocket) async throws -> Void
}

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
    /// A request to the route that is not a WebSocket upgrade is answered 426
    /// with `Upgrade: websocket`, and one asking for another version 426
    /// with `Sec-WebSocket-Version: 13`.
    @discardableResult
    public func webSocket<each E: RequestExtractor>(
        _ pattern: String,
        subprotocols: [String] = [],
        _ handler: sending @escaping @concurrent (WebSocket, repeat each E) async throws -> Void
    ) -> OpenAPIOperation {
        let handler = VariadicWebSocketHandler<repeat each E>(call: handler)
        on(.get, pattern) { request, response in
            let offer: WebSocketOffer
            switch WebSocketOffer.read(request) {
            case .success(let found):
                offer = found
            case .failure(let problem):
                refuseWebSocket(problem, response)
                return
            }
            var parameter = 0
            let run = bindWebSocketHandler(handler,
                                           repeat try await (each E).extract(from: request, parameter: &parameter))
            let chosen = subprotocols.first { offer.subprotocols.contains($0) }
            acceptWebSocket(request.exchange, offer, subprotocol: chosen, run: run)
        }
        var claims = 0
        var states: [Any.Type] = []
        repeat claims += pathClaims((each E).self)
        repeat states += requiredState((each E).self)
        noteRoute(.get, pattern, pathParameters: claims, states: states)
        let operation = OpenAPIOperation(.get, pattern)
        repeat operation.describeExtractor((each E).self)
        operation.response(.switchingProtocols, "The connection becomes a WebSocket")
        operation.response(HTTPStatus(426), "Not a WebSocket upgrade")
        document(operation)
        return operation
    }
}

/// The handler with its extracted values applied. A closure rather than the
/// values themselves, because the task that runs it cannot capture a
/// parameter pack.
func bindWebSocketHandler<each E>(_ handler: VariadicWebSocketHandler<repeat each E>,
                                  _ values: repeat each E) -> CarriedHandler {
    CarriedHandler { socket in try await handler.call(socket, repeat each values) }
}

func refuseWebSocket(_ problem: WebSocketOffer.Problem, _ response: borrowing Response) {
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
        response.send(status: .badRequest, "a WebSocket over HTTP/2 starts with an extended CONNECT\n")
    case .disabled:
        response.send(status: HTTPStatus(501), "WebSockets are turned off\n")
    }
}

/// Answers the upgrade: the 101 is written by the connection once the
/// handler has returned, and the connection becomes the WebSocket's; over
/// HTTP/2, the 200, and the stream becomes it.
func acceptWebSocket(_ x: UnsafeMutablePointer<Exchange>, _ offer: WebSocketOffer, subprotocol: String?,
                     run: CarriedHandler) {
    let limits = x.pointee.websocketLimits
    let deflate = limits.compress && !offer.extensions.isEmpty
        ? offer.extensions.withSpans { WSDeflate.negotiate($0) } : nil
    let response = Response(x)
    let multiplexed: Bool
    if case .http2 = x.pointee.link { multiplexed = true } else { multiplexed = false }
    if !multiplexed {
        response.addHeader("upgrade", "websocket")
        response.addHeader("sec-websocket-accept", offer.acceptValue())
    }
    if let subprotocol { response.addHeader("sec-websocket-protocol", subprotocol) }
    if let deflate {
        var value = ByteBuffer()
        defer { value.destroy() }
        deflate.writeResponse(into: &value)
        response.addHeader("sec-websocket-extensions", value.readableSpan.string)
    }
    // Over HTTP/2 a 200 opens the stream as the WebSocket's (RFC 8441),
    // its body the frames, which are not to be compressed twice.
    x.pointee.status = multiplexed ? 200 : 101
    if multiplexed { x.pointee.noCompress = true }
    x.pointee.answered = true
    x.pointee.touchedStream = true
    x.pointee.upgrade = WebSocketUpgrade(run: run, subprotocol: subprotocol,
                                         offered: offer.subprotocols, deflate: deflate, limits: limits)
}

extension Array where Element == [UInt8] {
    /// The values as `ByteSpan`s, for as long as `body` runs.
    func withSpans<R>(_ body: ([ByteSpan]) -> R) -> R {
        var spans: [ByteSpan] = []
        var pinned: [UnsafeMutableBufferPointer<UInt8>] = []
        for value in self {
            let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Swift.max(1, value.count))
            _ = copy.initialize(from: value)
            pinned.append(copy)
            spans.append(ByteSpan(UnsafePointer(copy.baseAddress!), value.count))
        }
        defer { for p in pinned { p.deallocate() } }
        return body(spans)
    }
}

/// An accepted upgrade, on its way from the route to the connection.
final class WebSocketUpgrade: @unchecked Sendable {
    let run: CarriedHandler
    let subprotocol: String?
    let offered: [String]
    let deflate: WSDeflateAgreement?
    let limits: WebSocketLimits
    /// What the client sent after the handshake: frames already.
    var leftover: [UInt8] = []

    init(run: CarriedHandler, subprotocol: String?, offered: [String], deflate: WSDeflateAgreement?,
         limits: WebSocketLimits) {
        self.run = run
        self.subprotocol = subprotocol
        self.offered = offered
        self.deflate = deflate
        self.limits = limits
    }
}

/// --ws-*: what every WebSocket is held to.
struct WebSocketLimits: Sendable {
    var enabled: Bool
    /// --websocket-protocols.
    var protocols: WebSocketProtocols
    var maxMessage: Int
    var pingInterval: Duration
    var pingTimeout: Duration
    var maxQueue: Int
    var maxQueueBytes: Int
    var compress: Bool

    /// ServerConfig's defaults.
    init() {
        enabled = true
        protocols = .all
        maxMessage = 16 * 1024 * 1024
        pingInterval = .seconds(20)
        pingTimeout = .seconds(20)
        maxQueue = 32
        maxQueueBytes = 4 * 1024 * 1024
        compress = false
    }

    init(_ config: ServerConfig) {
        enabled = config.websocketsEnabled
        protocols = config.websocketProtocols
        maxMessage = max(125, config.maxWebsocketMessageSize)
        pingInterval = config.websocketPingInterval
        pingTimeout = config.websocketPingTimeout
        maxQueue = max(1, config.maxWebsocketQueue)
        maxQueueBytes = max(1, config.maxWebsocketQueueBytes)
        compress = config.websocketCompress
    }
}

extension WebSocketLimits {
    /// WebSockets are served over HTTP/1.1's upgrade.
    var overHTTP1: Bool { enabled && protocols.contains(.http1) }
    /// And over HTTP/2's extended CONNECT, which is then offered.
    var overHTTP2: Bool { enabled && protocols.contains(.http2) }
}

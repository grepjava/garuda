//===----------------------------------------------------------------------===//
// HTTP2TestConnection: one HTTP/2 connection to an application, frame by
// frame.
//
//     let h2 = try app.test.http2()
//     #expect(try h2.get("/user/7").text == "user 7")
//
//     let slow = try h2.request("GET", "/delay/200")
//     let fast = try h2.request("GET", "/")
//     let answers = try h2.responses([slow, fast])
//
//     try h2.send(.rstStream, stream: slow, payload: h2.uint32(8))
//     #expect(try h2.goaway()?.code == H2Error.protocolError.rawValue)
//
// The connection is served exactly as a shard serves a cleartext socket that
// opens with the HTTP/2 preface (prior knowledge) -- the same detection, the
// same reader, writer and stream tasks -- over VegaTest's in-memory `duplex`,
// as `TestClient` serves HTTP/1. It stays open across calls, so streams can
// overlap and a test can send anything at all: raw bytes, raw frames,
// header blocks it encoded itself, frames that break the protocol.
//
// What arrives is decoded as it arrives: SETTINGS are acknowledged, header
// blocks are decoded in order (HPACK is stateful), and DATA is credited back
// with WINDOW_UPDATE unless `autoWindowUpdate` is off. Each frame is also
// kept, for a test that looks at frames rather than responses.
//===----------------------------------------------------------------------===//

@_spi(Testing) import Garuda
import GarudaWire
import Vega
import VegaIO
import VegaTest

/// A frame as it arrived.
public struct TestFrame: Sendable {
    public let type: UInt8
    public let flags: UInt8
    public let stream: UInt32
    public let payload: [UInt8]

    /// The frame's type, or nil for one the protocol does not define.
    public var kind: H2FrameType? { H2FrameType(rawValue: type) }

    public func has(_ flag: H2Flags) -> Bool { flags & flag.rawValue != 0 }
}

/// A stream's response as a test sees it.
public struct HTTP2TestResponse: Sendable {
    /// Nil when the stream was reset before a head arrived.
    public var status: HTTPStatus?
    /// The response fields in order, the `:status` pseudo-header left out.
    public var headers: [(name: String, value: String)] = []
    public var body: [UInt8] = []
    /// The error code of an RST_STREAM the server sent on the stream.
    public var reset: UInt32?
    /// The stream ended with END_STREAM.
    public var ended = false

    /// The body as text, with invalid UTF-8 repaired.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The first value of `name` (any case), or nil.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name == wanted }?.value
    }

    /// Every value of `name`, in order.
    public func headers(named name: String) -> [String] {
        let wanted = name.lowercased()
        return headers.filter { $0.name == wanted }.map { $0.value }
    }

    /// The body read as `type`, for an answer that is JSON.
    public func json<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONCoder.decode(type, from: body)
    }

    var done: Bool { ended || reset != nil }
}

extension TestClient {
    /// A new HTTP/2 connection, by prior knowledge. With `handshake` (the
    /// default) the preface and SETTINGS -- `settings` among them -- are
    /// sent and the server's SETTINGS read before this returns.
    public func http2(settings: [(H2Setting, UInt32)] = [], handshake: Bool = true) throws -> HTTP2TestConnection {
        try http2(on: TestClient.runtime, settings: settings, handshake: handshake)
    }

    /// The same, served on `runtime` rather than the one test clients
    /// share: for a test that shuts that runtime's HTTP/2 down.
    @_spi(Testing)
    public func http2(on runtime: Runtime, settings: [(H2Setting, UInt32)] = [],
                      handshake: Bool = true) throws -> HTTP2TestConnection {
        let connection = try HTTP2TestConnection(client: self, runtime: runtime)
        if handshake { try connection.handshake(settings: settings) }
        return connection
    }
}

/// One HTTP/2 connection to an application. See HTTP2TestClient.swift.
public final class HTTP2TestConnection: @unchecked Sendable {
    /// How long a wait for the server may take before it fails with
    /// `TestClientError.timedOut`.
    public var timeout: Duration
    /// Send WINDOW_UPDATE for every DATA frame that arrives.
    public var autoWindowUpdate = true
    /// The server's SETTINGS, by identifier.
    public private(set) var serverSettings: [UInt16: UInt32] = [:]
    /// Every frame received and not yet taken by `nextFrame`.
    public private(set) var frames: [TestFrame] = []
    /// The server has closed the connection.
    public private(set) var closedByServer = false
    /// The identifier the next `request` uses.
    public var nextStream: UInt32 = 1

    let runtime: Runtime
    let box: DuplexBox
    var pending: [UInt8] = []
    var decoder = HPACKDecoder()
    var streams: [UInt32: HTTP2TestResponse] = [:]
    /// A header block arriving in CONTINUATIONs.
    var block: [UInt8] = []
    var blockStream: UInt32 = 0
    var blockEndsStream = false
    /// What the server lets us send.
    var connectionWindow = 65535
    var streamWindows: [UInt32: Int] = [:]
    var initialWindow = 65535
    var maxFrameSize = 16384

    init(client: TestClient, runtime: Runtime) throws {
        self.runtime = runtime
        timeout = client.timeout
        let app = client.application, config = client.configuration
        let address = client.remoteAddress, port = client.remotePort
        let rt = runtime
        try app.startForTesting(on: rt)
        let pair = duplex(capacity: 1 << 20)
        box = DuplexBox(pair.first)
        rt.spawn(with: pair.second) { stream in
            await app.serveConnection(stream, halves: { $0.halves() }, config: config, runtime: rt,
                                      remoteAddress: address, remotePort: port)
        }
    }

    deinit {
        close()
        decoder.destroy()
    }

    // MARK: Requests

    /// Sends a request on a new stream and returns its identifier. With no
    /// body and `endStream`, HEADERS ends the stream; a body goes in DATA,
    /// the last of it ending the stream when `endStream` says so.
    @discardableResult
    public func request(_ method: String, _ path: String, headers: [(String, String)] = [],
                        body: [UInt8]? = nil, endStream: Bool = true, authority: String = "test",
                        scheme: String = "http") throws -> UInt32 {
        let id = nextStream
        nextStream += 2
        var fields = [(":method", method), (":scheme", scheme), (":authority", authority), (":path", path)]
        fields += headers.map { ($0.0.lowercased(), $0.1) }
        try sendHeaders(stream: id, fields, endStream: endStream && body == nil)
        if let body { try sendData(stream: id, body, endStream: endStream) }
        return id
    }

    public func get(_ path: String, headers: [(String, String)] = []) throws -> HTTP2TestResponse {
        try response(try request("GET", path, headers: headers))
    }

    public func head(_ path: String, headers: [(String, String)] = []) throws -> HTTP2TestResponse {
        try response(try request("HEAD", path, headers: headers))
    }

    public func post(_ path: String, body: [UInt8] = [], headers: [(String, String)] = []) throws -> HTTP2TestResponse {
        try response(try request("POST", path, headers: headers + [("content-length", "\(body.count)")],
                                 body: body))
    }

    public func post(_ path: String, body: String, headers: [(String, String)] = []) throws -> HTTP2TestResponse {
        try post(path, body: Array(body.utf8), headers: headers)
    }

    /// Waits for stream `id` to end or be reset.
    public func response(_ id: UInt32) throws -> HTTP2TestResponse {
        while !(streams[id]?.done ?? false) {
            guard try receive() else { throw TestClientError.closed(received: 0) }
        }
        return streams[id]!
    }

    /// Waits for every stream in `ids`, and returns their responses in order.
    public func responses(_ ids: [UInt32]) throws -> [HTTP2TestResponse] {
        try ids.map { try response($0) }
    }

    /// What has arrived on stream `id` so far, without waiting.
    public func received(_ id: UInt32) -> HTTP2TestResponse? { streams[id] }

    // MARK: Frames

    /// Writes `bytes` as they are.
    public func send(raw bytes: [UInt8]) throws {
        try io { stream in
            let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, bytes.count), alignment: 1)
            defer { raw.deallocate() }
            raw.copyBytes(from: bytes)
            try await stream.write(UnsafeRawBufferPointer(rebasing: raw[..<bytes.count]))
        }
    }

    /// Runs `operation` on the client's end of the connection, failing with
    /// `timedOut` if it takes longer than `timeout`. (An I/O deadline would
    /// not do: the in-memory duplex answers only cancellation.)
    func io<T: Sendable>(_ operation: @escaping @Sendable (borrowing DuplexStream) async throws -> T) throws -> T {
        let box = box
        let limit = timeout
        return try runtime.block { () async throws -> T in
            do {
                return try await Runtime.timeout(limit) { () async throws -> T in
                    guard let stream = box.stream.take() else { throw TestClientError.closed(received: 0) }
                    do {
                        let result = try await operation(stream)
                        box.stream = consume stream
                        return result
                    } catch {
                        box.stream = consume stream
                        throw error
                    }
                }
            } catch is TimeoutError {
                throw TestClientError.timedOut
            }
        }
    }

    /// A frame's bytes.
    public func frame(_ type: UInt8, flags: UInt8 = 0, stream: UInt32, payload: [UInt8] = []) -> [UInt8] {
        let n = payload.count
        return [UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n),
                type, flags] + uint32(stream & 0x7FFF_FFFF) + payload
    }

    /// Sends one frame of any type, valid or not.
    public func send(_ type: H2FrameType, flags: H2Flags = [], stream: UInt32, payload: [UInt8] = []) throws {
        try send(raw: frame(type.rawValue, flags: flags.rawValue, stream: stream, payload: payload))
    }

    /// Sends a frame of a type the protocol may not define.
    public func send(type: UInt8, flags: UInt8 = 0, stream: UInt32, payload: [UInt8] = []) throws {
        try send(raw: frame(type, flags: flags, stream: stream, payload: payload))
    }

    /// The preface and SETTINGS, then waits for the server's SETTINGS.
    public func handshake(settings: [(H2Setting, UInt32)] = []) throws {
        try send(raw: HTTP2.preface + frame(H2FrameType.settings.rawValue, stream: 0, payload: settingsPayload(settings)))
        while serverSettings.isEmpty {
            guard try receive() else { throw TestClientError.closed(received: 0) }
        }
    }

    public func settingsPayload(_ settings: [(H2Setting, UInt32)]) -> [UInt8] {
        settings.flatMap { [UInt8(truncatingIfNeeded: $0.0.rawValue >> 8), UInt8(truncatingIfNeeded: $0.0.rawValue)]
            + uint32($0.1) }
    }

    /// `fields` as an HPACK block: each a literal, never indexed.
    public func headerBlock(_ fields: [(String, String)]) -> [UInt8] {
        let encoder = HPACKEncoder()
        var out = ByteBuffer()
        defer { out.destroy() }
        for (name, value) in fields {
            let n = Array(name.utf8), v = Array(value.utf8)
            n.withUnsafeBufferPointer { np in
                v.withUnsafeBufferPointer { vp in
                    encoder.encode(name: np.baseAddress ?? emptyByte, nameLength: np.count,
                                   value: vp.baseAddress ?? emptyByte, valueLength: vp.count, into: &out)
                }
            }
        }
        return out.readableBytes == 0 ? [] : Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    /// HEADERS carrying `fields`, in CONTINUATIONs past the frame size.
    public func sendHeaders(stream id: UInt32, _ fields: [(String, String)], endStream: Bool = true,
                            frameSize: Int = 16384) throws {
        let encoded = headerBlock(fields)
        var bytes: [UInt8] = []
        var offset = 0
        repeat {
            let n = min(frameSize, encoded.count - offset)
            var flags: UInt8 = offset + n >= encoded.count ? H2Flags.endHeaders.rawValue : 0
            if offset == 0 && endStream { flags |= H2Flags.endStream.rawValue }
            bytes += frame(offset == 0 ? H2FrameType.headers.rawValue : H2FrameType.continuation.rawValue,
                           flags: flags, stream: id, payload: Array(encoded[offset..<offset + n]))
            offset += n
        } while offset < encoded.count
        if streamWindows[id] == nil { streamWindows[id] = initialWindow }
        try send(raw: bytes)
    }

    /// DATA, within the windows the server has given, waiting for more when
    /// they run out.
    public func sendData(stream id: UInt32, _ body: [UInt8], endStream: Bool = true) throws {
        var offset = 0
        if body.isEmpty {
            try send(.data, flags: endStream ? .endStream : [], stream: id)
            return
        }
        while offset < body.count {
            let window = min(connectionWindow, streamWindows[id] ?? initialWindow, maxFrameSize)
            if window <= 0 {
                guard try receive() else { throw TestClientError.closed(received: 0) }
                continue
            }
            let n = min(window, body.count - offset)
            let last = offset + n == body.count
            try send(.data, flags: last && endStream ? .endStream : [], stream: id,
                     payload: Array(body[offset..<offset + n]))
            connectionWindow -= n
            streamWindows[id, default: initialWindow] -= n
            offset += n
        }
    }

    /// RST_STREAM on `id`.
    public func reset(_ id: UInt32, code: H2Error = .cancel) throws {
        try send(.rstStream, stream: id, payload: uint32(code.rawValue))
    }

    /// The next frame received that `matches`, waiting for it; taken out of
    /// `frames`. Nil once the server has closed without sending one.
    public func nextFrame(where matches: (TestFrame) -> Bool = { _ in true }) throws -> TestFrame? {
        while true {
            if let i = frames.firstIndex(where: matches) { return frames.remove(at: i) }
            guard try receive() else { return nil }
        }
    }

    /// The server's GOAWAY, waiting for it: the last stream it took and the
    /// error code. Nil if it closed without one.
    public func goaway() throws -> (lastStream: UInt32, code: UInt32)? {
        guard let f = try nextFrame(where: { $0.kind == .goaway }), f.payload.count >= 8 else { return nil }
        return (HTTP2TestConnection.uint32(f.payload, 0) & 0x7FFF_FFFF, HTTP2TestConnection.uint32(f.payload, 4))
    }

    /// Waits for the server to close the connection. False if it is still
    /// open when the timeout passes.
    public func waitForClose() -> Bool {
        while !closedByServer {
            do {
                guard try receive() else { return true }
            } catch {
                return false
            }
        }
        return true
    }

    /// Every byte the server sends until it closes, as it sent them: for a
    /// connection that turned out not to be HTTP/2.
    public func readUntilClose() throws -> [UInt8] {
        let bytes = try io { stream -> [UInt8] in
            var buffer = IOBuffer(capacity: 64 * 1024)
            while true {
                if buffer.spareCapacity < 4096 { buffer.reserveCapacity(buffer.capacity * 2) }
                if try await stream.read(into: &buffer) == 0 { break }
            }
            return buffer.withUnsafeBytes { Array($0) }
        }
        closedByServer = true
        return pending + bytes
    }

    /// Ends the client's side; the server finishes what it has and closes.
    public func close() {
        let box = box
        runtime.block { () async -> Void in
            if let stream = box.stream.take() {
                stream.shutdownWrite()
                box.stream = consume stream
            }
        }
    }

    public func uint32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    static func uint32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    // MARK: Receiving

    /// Reads once and takes in every whole frame. False at end of stream.
    @discardableResult
    func receive() throws -> Bool {
        if closedByServer { return false }
        let bytes = try io { stream -> [UInt8]? in
            var buffer = IOBuffer(capacity: 64 * 1024)
            do {
                let n = try await stream.read(into: &buffer)
                return n == 0 ? nil : buffer.withUnsafeBytes { Array($0) }
            } catch {
                // The server reset the connection: as good as closed.
                if Task.isCancelled { throw error }
                return nil
            }
        }
        guard let bytes else {
            closedByServer = true
            return false
        }
        pending += bytes
        var at = 0
        var replies: [UInt8] = []
        while pending.count - at >= 9 {
            let n = Int(pending[at]) << 16 | Int(pending[at + 1]) << 8 | Int(pending[at + 2])
            guard pending.count - at - 9 >= n else { break }
            let f = TestFrame(type: pending[at + 3], flags: pending[at + 4],
                              stream: HTTP2TestConnection.uint32(pending, at + 5) & 0x7FFF_FFFF,
                              payload: Array(pending[(at + 9)..<(at + 9 + n)]))
            at += 9 + n
            frames.append(f)
            take(f, replies: &replies)
        }
        pending.removeFirst(at)
        if !replies.isEmpty { try send(raw: replies) }
        return true
    }

    func take(_ f: TestFrame, replies: inout [UInt8]) {
        switch f.kind {
        case .settings where !f.has(.ack):
            var i = 0
            while i + 6 <= f.payload.count {
                let id = UInt16(f.payload[i]) << 8 | UInt16(f.payload[i + 1])
                let value = HTTP2TestConnection.uint32(f.payload, i + 2)
                serverSettings[id] = value
                if id == H2Setting.initialWindowSize.rawValue {
                    let delta = Int(value) - initialWindow
                    initialWindow = Int(value)
                    for key in streamWindows.keys { streamWindows[key]! += delta }
                }
                if id == H2Setting.maxFrameSize.rawValue { maxFrameSize = Int(value) }
                i += 6
            }
            replies += frame(H2FrameType.settings.rawValue, flags: H2Flags.ack.rawValue, stream: 0)
        case .windowUpdate:
            let increment = Int(HTTP2TestConnection.uint32(f.payload, 0) & 0x7FFF_FFFF)
            if f.stream == 0 {
                connectionWindow += increment
            } else {
                streamWindows[f.stream, default: initialWindow] += increment
            }
        case .headers:
            var payload = f.payload[...]
            if f.has(.padded), let pad = payload.first {
                payload = payload.dropFirst().dropLast(Int(pad))
            }
            if f.has(.priority) { payload = payload.dropFirst(5) }
            block = Array(payload)
            blockStream = f.stream
            blockEndsStream = f.has(.endStream)
            if f.has(.endHeaders) { headerBlockDone() }
        case .continuation:
            block += f.payload
            if f.has(.endHeaders) { headerBlockDone() }
        case .data:
            var payload = f.payload[...]
            if f.has(.padded), let pad = payload.first {
                payload = payload.dropFirst().dropLast(Int(pad))
            }
            streams[f.stream, default: HTTP2TestResponse()].body += payload
            if f.has(.endStream) { streams[f.stream, default: HTTP2TestResponse()].ended = true }
            if autoWindowUpdate && !f.payload.isEmpty {
                replies += frame(H2FrameType.windowUpdate.rawValue, stream: 0, payload: uint32(UInt32(f.payload.count)))
                if !f.has(.endStream) {
                    replies += frame(H2FrameType.windowUpdate.rawValue, stream: f.stream,
                                     payload: uint32(UInt32(f.payload.count)))
                }
            }
        case .rstStream:
            if f.payload.count == 4 {
                streams[f.stream, default: HTTP2TestResponse()].reset = HTTP2TestConnection.uint32(f.payload, 0)
            }
        default:
            break
        }
    }

    /// Decodes a whole header block into its stream's response.
    func headerBlockDone() {
        var fields: [(name: String, value: String)] = []
        let bytes = block
        bytes.withUnsafeBufferPointer { p in
            try? decoder.decode(p.baseAddress ?? emptyByte, p.count) { span in
                let name = String(decoding: UnsafeBufferPointer(start: span.name, count: span.nameLength), as: UTF8.self)
                let value = String(decoding: UnsafeBufferPointer(start: span.value, count: span.valueLength),
                                   as: UTF8.self)
                fields.append((name, value))
            }
        }
        var response = streams[blockStream] ?? HTTP2TestResponse()
        if response.status == nil, let status = fields.first(where: { $0.name == ":status" }).flatMap({ Int($0.value) }) {
            response.status = HTTPStatus(status)
            response.headers = fields.filter { !$0.name.hasPrefix(":") }
        } else {
            // A trailer section.
            response.headers += fields
        }
        if blockEndsStream { response.ended = true }
        streams[blockStream] = response
        block = []
    }
}

/// Holds the client's end of the duplex between calls.
final class DuplexBox: @unchecked Sendable {
    var stream: DuplexStream?

    init(_ stream: consuming DuplexStream) {
        self.stream = consume stream
    }
}

nonisolated(unsafe) private let emptyByte: UnsafePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    p[0] = 0
    return UnsafePointer(p)
}()

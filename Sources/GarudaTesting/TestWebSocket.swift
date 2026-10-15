//===----------------------------------------------------------------------===//
// A WebSocket client for tests: `app.test.webSocket("/chat")` upgrades a
// connection served in memory, and then sends and receives whole messages
// in step with the test, which blocks on each.
//
//     let ws = try app.test.webSocket("/echo")
//     try ws.send("hello")
//     #expect(try ws.receive() == .text("hello"))
//     try ws.close()
//
// Frames are masked, as a client's must be, and the server's pings are
// answered as they arrive. An upgrade the route refused comes back as a
// socket whose `response` says why, and which cannot be used.
//===----------------------------------------------------------------------===//

import Garuda
@_spi(Testing) import Garuda
import GarudaWire
import Vega
import VegaIO
import VegaTest

public final class TestWebSocket: @unchecked Sendable {
    /// The answer to the upgrade: 101, or the refusal.
    public let response: TestResponse
    /// The code and reason of the close the server sent, once one came.
    public private(set) var closeCode: UInt16? = nil
    public private(set) var closeReason = ""

    private let runtime: Runtime
    private let stream: UnsafeMutablePointer<DuplexStream>
    private let timeout: Duration
    /// Bytes read and not yet made into frames.
    private var pending: [UInt8]
    private var ended = false

    init(runtime: Runtime, stream: consuming DuplexStream, response: TestResponse, rest: [UInt8], timeout: Duration) {
        self.runtime = runtime
        self.stream = .allocate(capacity: 1)
        self.stream.initialize(to: stream)
        self.response = response
        pending = rest
        self.timeout = timeout
    }

    deinit {
        stream.pointee.shutdownWrite()
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    public func send(_ text: String) throws {
        try sendFrame(opcode: WSOpcode.text.rawValue, Array(text.utf8))
    }

    public func send(_ bytes: [UInt8]) throws {
        try sendFrame(opcode: WSOpcode.binary.rawValue, bytes)
    }

    public func ping(_ payload: [UInt8] = []) throws {
        try sendFrame(opcode: WSOpcode.ping.rawValue, payload)
    }

    /// The next whole message, waiting for it. Nil once the server has
    /// closed: `closeCode` says how.
    public func receive() throws -> WebSocketMessage? {
        var assembling: (opcode: UInt8, payload: [UInt8])? = nil
        while true {
            guard let frame = try nextFrame() else { return nil }
            switch frame.opcode {
            case WSOpcode.ping.rawValue:
                try sendFrame(opcode: WSOpcode.pong.rawValue, frame.payload)
            case WSOpcode.pong.rawValue:
                break
            case WSOpcode.close.rawValue:
                if frame.payload.count >= 2 {
                    closeCode = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
                    closeReason = String(decoding: frame.payload[2...], as: UTF8.self)
                } else {
                    closeCode = 1005
                }
                return nil
            case WSOpcode.continuation.rawValue:
                guard var message = assembling else { throw TestClientError.malformed }
                message.payload += frame.payload
                assembling = message
                if frame.fin { return Self.message(message.opcode, message.payload) }
            default:
                if frame.fin { return Self.message(frame.opcode, frame.payload) }
                assembling = (frame.opcode, frame.payload)
            }
        }
    }

    /// Sends a close and waits for the server's.
    public func close(code: UInt16 = 1000, reason: String = "") throws {
        var payload = [UInt8(code >> 8), UInt8(truncatingIfNeeded: code)]
        payload += Array(reason.utf8)
        try sendFrame(opcode: WSOpcode.close.rawValue, payload)
        while closeCode == nil, try receive() != nil {}
    }

    private static func message(_ opcode: UInt8, _ payload: [UInt8]) -> WebSocketMessage {
        opcode == WSOpcode.text.rawValue ? .text(String(decoding: payload, as: UTF8.self)) : .binary(payload)
    }

    // MARK: Frames

    private func sendFrame(opcode: UInt8, _ payload: [UInt8]) throws {
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            frame += [0x80 | 126, UInt8(n >> 8), UInt8(truncatingIfNeeded: n)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        frame += mask
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i & 3]) }
        let stream = StreamRef(pointer: self.stream)
        let limit = timeout
        let bytes = frame
        do {
            try runtime.block { () async throws(IOError) -> Void in
                try await Runtime.withIODeadline(limit) { () async throws(IOError) -> Void in
                    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, bytes.count), alignment: 1)
                    defer { raw.deallocate() }
                    raw.copyBytes(from: bytes)
                    try await stream.pointer.pointee.write(UnsafeRawBufferPointer(rebasing: raw[0..<bytes.count]))
                }
            }
        } catch let error as IOError {
            throw error == .timedOut ? TestClientError.timedOut : TestClientError.closed(received: 0)
        }
    }

    private func nextFrame() throws -> (fin: Bool, opcode: UInt8, payload: [UInt8])? {
        while true {
            if let frame = takeFrame() { return frame }
            if ended { return nil }
            try read()
        }
    }

    private func takeFrame() -> (fin: Bool, opcode: UInt8, payload: [UInt8])? {
        guard pending.count >= 2 else { return nil }
        let fin = pending[0] & 0x80 != 0
        let opcode = pending[0] & 0x0F
        var length = Int(pending[1] & 0x7F)
        var at = 2
        if length == 126 {
            guard pending.count >= 4 else { return nil }
            length = Int(pending[2]) << 8 | Int(pending[3])
            at = 4
        } else if length == 127 {
            guard pending.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(pending[i]) }
            at = 10
        }
        guard pending.count >= at + length else { return nil }
        let payload = Array(pending[at..<(at + length)])
        pending.removeFirst(at + length)
        return (fin, opcode, payload)
    }

    private func read() throws {
        let stream = StreamRef(pointer: self.stream)
        let limit = timeout
        let got: [UInt8]
        do {
            got = try runtime.block { () async throws(IOError) -> [UInt8] in
                try await Runtime.withIODeadline(limit) { () async throws(IOError) -> [UInt8] in
                    var buffer = IOBuffer(capacity: 64 * 1024)
                    _ = try await stream.pointer.pointee.read(into: &buffer)
                    return buffer.withUnsafeBytes { Array($0) }
                }
            }
        } catch {
            if error == .timedOut { throw TestClientError.timedOut }
            ended = true
            return
        }
        if got.isEmpty { ended = true }
        pending += got
    }
}

extension TestClient {
    /// Upgrades a new connection to `path` to a WebSocket. The socket's
    /// `response` is the 101, or the answer that refused it.
    public func webSocket(_ path: String, headers: [(String, String)] = []) throws -> TestWebSocket {
        func given(_ name: String) -> Bool { headers.contains { $0.0.lowercased() == name } }
        var request = "GET \(path) HTTP/1.1\r\n"
        if !given("host") { request += "host: test\r\n" }
        request += "upgrade: websocket\r\nconnection: Upgrade\r\n"
        request += "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        let bytes = Array(request.utf8)

        let app = application, config = configuration
        let rt = TestClient.runtime
        let limit = timeout
        try app.startForTesting(on: rt)
        let pair = duplex(capacity: 1 << 20)
        rt.spawn(with: pair.second) { stream in
            await app.serveConnection(stream, halves: { $0.halves() }, config: config,
                                      remoteAddress: "127.0.0.1", remotePort: 40000)
        }
        let client = pair.first
        let socket = UnsafeMutablePointer<DuplexStream>.allocate(capacity: 1)
        socket.initialize(to: client)
        let ref = StreamRef(pointer: socket)
        defer { socket.deallocate() }
        var received: [UInt8] = []
        do {
            received = try rt.block { () async throws(IOError) -> [UInt8] in
                try await Runtime.withIODeadline(limit) { () async throws(IOError) -> [UInt8] in
                    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, bytes.count), alignment: 1)
                    defer { raw.deallocate() }
                    raw.copyBytes(from: bytes)
                    try await ref.pointer.pointee.write(UnsafeRawBufferPointer(rebasing: raw[0..<bytes.count]))
                    var got: [UInt8] = []
                    var buffer = IOBuffer(capacity: 64 * 1024)
                    while true {
                        buffer.clear()
                        let n = try await ref.pointer.pointee.read(into: &buffer)
                        if n == 0 { return got }
                        got += buffer.withUnsafeBytes { Array($0) }
                        if let end = headEnd(got) {
                            // A refusal has a body to wait for; the 101 has
                            // frames behind it, if anything.
                            if got.starts(with: Array("HTTP/1.1 101".utf8)) { return got }
                            if let length = contentLength(got, end), got.count >= end + 4 + length { return got }
                        }
                    }
                }
            }
        } catch let error as IOError {
            socket.deinitialize(count: 1)
            throw error == .timedOut ? TestClientError.timedOut : TestClientError.closed(received: 0)
        }
        guard let end = headEnd(received) else {
            socket.deinitialize(count: 1)
            throw TestClientError.closed(received: received.count)
        }
        let head = String(decoding: received[0..<end], as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        let status = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
        var fields: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields.append((String(line[..<colon]), String(line[line.index(after: colon)...].drop { $0 == " " })))
        }
        let rest = Array(received[(end + 4)...])
        let isUpgrade = status == 101
        let response = TestResponse(status: HTTPStatus(status), headers: fields, body: isUpgrade ? [] : rest)
        return TestWebSocket(runtime: rt, stream: socket.move(), response: response, rest: isUpgrade ? rest : [],
                             timeout: limit)
    }
}

private func headEnd(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
    return nil
}

private func contentLength(_ bytes: [UInt8], _ end: Int) -> Int? {
    let head = String(decoding: bytes[0..<end], as: UTF8.self).lowercased()
    for line in head.split(separator: "\r\n") where line.hasPrefix("content-length:") {
        return Int(line.dropFirst("content-length:".count).trimmingCharacters())
    }
    return 0
}

private extension Substring {
    func trimmingCharacters() -> Substring {
        var s = self
        while s.first == " " { s = s.dropFirst() }
        while s.last == " " { s = s.dropLast() }
        return s
    }
}

/// The client's end of the connection, carried into the runtime's tasks.
private struct StreamRef: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<DuplexStream>
}

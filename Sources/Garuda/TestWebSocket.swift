//===----------------------------------------------------------------------===//
// A WebSocket client for tests, over the test client's socket pair.
//
//     let ws = try app.test.webSocket("/echo")
//     #expect(ws.response.status == 101)
//     try ws.send("hello")
//     #expect(try ws.receive() == .text("hello"))
//     try ws.close()
//
// The worker's loop is turned by hand while the client waits, as for any
// test request, so the handler, the engine's framing and its close handshake
// all run as they do on a real connection. The client masks what it sends,
// answers pings, and reports how the server closed.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

public final class TestWebSocket {
    let client: TestClient
    let fd: Int32
    let slot: Int
    let generation: UInt32
    var buffer: [UInt8]
    var closeSent = false
    var ended = false
    var socketClosed = false

    /// The answer to the upgrade: 101, or the refusal with its body.
    public let response: TestResponse
    /// The code the server's close carried, once it has come.
    public private(set) var closeCode: UInt16? = nil
    public private(set) var closeReason = ""

    init(client: TestClient, fd: Int32, slot: Int, generation: UInt32,
         response: TestResponse, rest: [UInt8]) {
        self.client = client
        self.fd = fd
        self.slot = slot
        self.generation = generation
        self.response = response
        buffer = rest
        ended = response.status.code != 101
    }

    deinit {
        client.hangUp(fd, slot: slot, generation: generation)
    }

    /// Sends a text message.
    public func send(_ text: String) throws {
        try sendFrame(opcode: .text, Array(text.utf8))
    }

    /// Sends a binary message.
    public func send(_ bytes: [UInt8]) throws {
        try sendFrame(opcode: .binary, bytes)
    }

    /// Sends a ping, whose pong `receive` passes over.
    public func ping(_ payload: [UInt8] = []) throws {
        try sendFrame(opcode: .ping, payload)
    }

    /// The next message from the server, answering pings on the way. Nil
    /// once the server has closed, with `closeCode` and `closeReason` set.
    /// Throws `timedOut` when nothing comes within the client's timeout.
    public func receive() throws -> WebSocketMessage? {
        let deadline = av_monotonic_ms() + client.timeoutMillis
        var assembling: [UInt8] = []
        var opcode: UInt8 = 0
        while true {
            while let frame = takeFrame() {
                switch frame.opcode {
                case 0x9:
                    try sendFrame(opcode: .pong, frame.payload)
                case 0xA:
                    break
                case 0x8:
                    if frame.payload.count >= 2 {
                        closeCode = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
                        closeReason = String(decoding: frame.payload[2...], as: UTF8.self)
                    } else {
                        closeCode = WSCloseCode.noStatus
                    }
                    if !closeSent { try sendClose(code: closeCode == WSCloseCode.noStatus ? WSCloseCode.normal : closeCode!, reason: []) }
                    ended = true
                    return nil
                default:
                    if frame.opcode != 0 { opcode = frame.opcode }
                    assembling += frame.payload
                    if frame.fin {
                        return opcode == WSOpcode.text.rawValue
                            ? .text(String(decoding: assembling, as: UTF8.self))
                            : .binary(assembling)
                    }
                }
            }
            if ended { return nil }
            if socketClosed {
                // Everything that arrived before the end has been read.
                ended = true
                if closeCode == nil { closeCode = WSCloseCode.abnormal }
                return nil
            }
            client.turn()
            if !read() { socketClosed = true }
            if av_monotonic_ms() > deadline { throw TestClientError.timedOut }
        }
    }

    /// Sends a close and waits for the server's, which `closeCode` then holds.
    public func close(code: UInt16 = WSCloseCode.normal, reason: String = "") throws {
        if !closeSent && !ended { try sendClose(code: code, reason: Array(reason.utf8)) }
        while !ended {
            if try receive() == nil { break }
        }
    }

    // MARK: Frames

    private func sendClose(code: UInt16, reason: [UInt8]) throws {
        closeSent = true
        try sendFrame(opcode: .close, [UInt8(code >> 8), UInt8(code & 0xFF)] + reason)
    }

    private func sendFrame(opcode: WSOpcode, _ payload: [UInt8]) throws {
        guard response.status.code == 101 else { throw TestClientError.closed(received: 0) }
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            frame += [UInt8(0x80 | 126), UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
        }
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        frame += mask
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i & 3]) }
        var written = 0
        let deadline = av_monotonic_ms() + client.timeoutMillis
        while written < frame.count {
            let n = frame.withUnsafeBufferPointer { av_write(fd, $0.baseAddress! + written, frame.count - written) }
            if n > 0 {
                written += n
            } else {
                client.turn()
                if av_monotonic_ms() > deadline { throw TestClientError.timedOut }
            }
        }
        client.turn()
    }

    /// Reads what the socket has. False once the server has closed it.
    private func read() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { av_read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            return n != 0
        }
    }

    /// The next whole frame in the buffer, which a server sends unmasked.
    private func takeFrame() -> (fin: Bool, opcode: UInt8, payload: [UInt8])? {
        guard buffer.count >= 2 else { return nil }
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(buffer[i]) }
            offset = 10
        }
        guard buffer.count >= offset + length else { return nil }
        let frame = (fin: buffer[0] & 0x80 != 0, opcode: buffer[0] & 0x0F,
                     payload: Array(buffer[offset..<(offset + length)]))
        buffer.removeFirst(offset + length)
        return frame
    }
}

extension TestClient {
    /// Opens a WebSocket to `path`. The answer to the upgrade is in
    /// `response`: 101, or the status and body the route refused it with.
    public func webSocket(_ path: String, headers: [(String, String)] = []) throws -> TestWebSocket {
        func given(_ name: String) -> Bool { headers.contains { $0.0.lowercased() == name } }
        var request = "GET \(path) HTTP/1.1\r\n"
        if !given("host") { request += "host: test\r\n" }
        request += "upgrade: websocket\r\nconnection: Upgrade\r\n"
        request += "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        let bytes = Array(request.utf8)

        let (fd, slot, generation) = try connect()
        let deadline = av_monotonic_ms() + timeoutMillis
        var written = 0
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if written < bytes.count {
                let n = bytes.withUnsafeBufferPointer { av_write(fd, $0.baseAddress! + written, bytes.count - written) }
                if n > 0 { written += n }
            }
            turn()
            var closed = false
            while true {
                let n = chunk.withUnsafeMutableBufferPointer { av_read(fd, $0.baseAddress!, $0.count) }
                if n > 0 {
                    received.append(contentsOf: chunk[0..<n])
                    continue
                }
                if n == 0 { closed = true }
                break
            }
            if let end = TestResponse.headEnd(received, from: 0),
               received.starts(with: Array("HTTP/1.1 101".utf8)) {
                let head = String(decoding: received[0..<end], as: UTF8.self)
                var headers: [(name: String, value: String)] = []
                for line in head.split(separator: "\r\n").dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers.append((String(line[..<colon]),
                                    String(line[line.index(after: colon)...].drop { $0 == " " })))
                }
                return TestWebSocket(client: self, fd: fd, slot: slot, generation: generation,
                                     response: TestResponse(status: 101, headers: headers, body: []),
                                     rest: Array(received[(end + 4)...]))
            }
            if let response = try TestResponse.parse(received, bodyless: false, closed: closed) {
                return TestWebSocket(client: self, fd: fd, slot: slot, generation: generation,
                                     response: response, rest: [])
            }
            if closed {
                hangUp(fd, slot: slot, generation: generation)
                throw TestClientError.closed(received: received.count)
            }
            if av_monotonic_ms() > deadline {
                hangUp(fd, slot: slot, generation: generation)
                throw TestClientError.timedOut
            }
        }
    }
}

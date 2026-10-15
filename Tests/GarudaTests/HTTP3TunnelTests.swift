import Synchronization
import Testing
@_spi(Testing) @testable import Garuda
import GarudaQUIC
import GarudaWire
import QUICTestPeer
import Vega

// Extended CONNECT over HTTP/3, over a real UDP socket in process, to the
// tests' own QUIC client (HTTP3Tests.swift): WebSockets (RFC 9220).
// scripts/websocket-streams-test.py checks the same against aioquic.

/// `fields` for an extended CONNECT for `protocol` to `path`.
private func extendedConnect(_ path: String, _ proto: String, _ more: [(String, String)] = []) -> [(String, String)] {
    [(":method", "CONNECT"), (":protocol", proto), (":scheme", "https"), (":authority", "localhost"),
     (":path", path)] + more
}

/// The server's SETTINGS, from its control stream.
private func serverSettings(_ client: H3Client) throws -> [UInt64: UInt64] {
    let control = try h3Frames(Array((client.peer.streams[3] ?? []).dropFirst()))
    let payload = try #require(control.first { $0.0 == 0x04 }).1
    var settings: [UInt64: UInt64] = [:]
    try payload.withUnsafeBufferPointer { b in
        var r = QUICReader(b.baseAddress!, b.count)
        while !r.isEmpty {
            guard let id = r.varint(), let value = r.varint() else { throw QUICTestPeerError("a setting cut short") }
            settings[id] = value
        }
    }
    return settings
}

/// A client's WebSocket frame: masked, as a client's must be, in a DATA
/// frame.
private func clientFrame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
    precondition(payload.count < 126)
    let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
    let frame = [0x80 | opcode, 0x80 | UInt8(payload.count)] + mask
        + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    return hsVarint(0) + hsVarint(UInt64(frame.count)) + frame
}

/// The server's WebSocket frames on a stream, from its DATA frames: opcode
/// and payload.
private func serverFrames(_ bytes: [UInt8]) throws -> [(UInt8, [UInt8])] {
    var data: [UInt8] = []
    for (type, payload) in try h3Frames(bytes) where type == 0x00 { data += payload }
    var out: [(UInt8, [UInt8])] = []
    var at = 0
    while at + 2 <= data.count {
        let opcode = data[at] & 0x0F
        let length = Int(data[at + 1] & 0x7F)
        precondition(length < 126)
        guard at + 2 + length <= data.count else { break }
        out.append((opcode, Array(data[(at + 2)..<(at + 2 + length)])))
        at += 2 + length
    }
    return out
}

private func webSocketApp() -> Application {
    let app = h3App()
    app.webSocket("/ws/echo") { (ws: WebSocket) async throws in
        for try await message in ws { try await ws.send(message) }
    }
    return app
}

@Suite("WebSockets over HTTP/3")
struct HTTP3WebSocketTests {

    @Test func anExtendedConnectBecomesAWebSocket() throws {
        try withServer(webSocketApp()) { client, _ in
            try await client.connect()
            #expect(try serverSettings(client)[0x08] == 1)
            try await client.request(0, extendedConnect("/ws/echo", "websocket", [("sec-websocket-version", "13")]),
                                     fin: false)
            try await client.pump { (try? h3Frames(client.peer.streams[0] ?? []).isEmpty) == false }
            let head = try H3Answer(client.peer.streams[0] ?? [], reset: nil)
            // RFC 9220: 200, and no key to answer.
            #expect(head.status == 200)
            #expect(head.header("sec-websocket-accept") == nil)

            try await client.write(0, clientFrame(0x1, Array("over h3".utf8)))
            try await client.pump { (try? serverFrames(client.peer.streams[0] ?? []).count) == 1 }
            #expect(try serverFrames(client.peer.streams[0] ?? []).first?.1 == Array("over h3".utf8))

            // The close handshake, and the stream ends with FIN.
            try await client.write(0, clientFrame(0x8, [0x03, 0xE8]))
            let answer = try await client.answer(0)
            #expect(answer.reset == nil)
            let frames = try serverFrames(client.peer.streams[0] ?? [])
            #expect(frames.last?.0 == 0x8)
            #expect(frames.last?.1 == [0x03, 0xE8])
            // The connection goes on.
            #expect(try await client.get(4, "/user/after").text == "after")
        }
    }

    @Test func anUnknownProtocolIsRefusedAt501() throws {
        try withServer(webSocketApp()) { client, _ in
            try await client.connect()
            try await client.request(0, extendedConnect("/ws/echo", "flying-carpet"), fin: false)
            #expect(try await client.answer(0).status == 501)
            // A GET to the route is no WebSocket here.
            #expect(try await client.get(4, "/ws/echo").status == 400)
        }
    }

    @Test func websocketProtocolsCanLeaveHTTP3Out() throws {
        let config = h3Config { $0.websocketProtocols = [.http1, .http2] }
        try withServer(webSocketApp(), config) { client, _ in
            try await client.connect()
            // Still offered, for WebTransport, but a WebSocket is refused.
            #expect(try serverSettings(client)[0x08] == 1)
            try await client.request(0, extendedConnect("/ws/echo", "websocket", [("sec-websocket-version", "13")]),
                                     fin: false)
            #expect(try await client.answer(0).status == 501)
        }
    }

    @Test func aWebSocketGivenUpOnIsReset() throws {
        let config = h3Config {
            $0.websocketPingInterval = .milliseconds(100)
            $0.websocketPingTimeout = .milliseconds(200)
        }
        try withServer(webSocketApp(), config) { client, _ in
            try await client.connect()
            try await client.request(0, extendedConnect("/ws/echo", "websocket", [("sec-websocket-version", "13")]),
                                     fin: false)
            // No pong ever comes.
            let answer = try await client.answer(0)
            #expect(answer.reset == HTTP3Error.requestCancelled)
            #expect(try serverFrames(client.peer.streams[0] ?? []).contains { $0.0 == 0x9 })
        }
    }
}

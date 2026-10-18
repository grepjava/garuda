@_spi(Garuda) import VegaQUICCore
import Synchronization
import Testing
@_spi(Testing) @testable import Garuda
import GarudaWire
import QUICTestPeer
import Vega

// Extended CONNECT over HTTP/3, over a real UDP socket in process, to the
// tests' own QUIC client (HTTP3Tests.swift): WebSockets (RFC 9220) and
// WebTransport. scripts/websocket-streams-test.py and webtransport-test.py
// check the same against aioquic.

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
            #expect(answer.reset == HTTP3ErrorCode.requestCancelled.rawValue)
            #expect(try serverFrames(client.peer.streams[0] ?? []).contains { $0.0 == 0x9 })
        }
    }
}

// MARK: - WebTransport

/// How the last /wt-report session ended, as "<code> <reason>".
private let lastSessionClose = Mutex("")

/// Echoes every stream and datagram, as scripts/webtransport-test.py's /wt.
private func echoSession(_ session: WebTransportSession) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while let datagram = try await session.receiveDatagram() {
                session.sendDatagram(Array("echo:".utf8) + datagram)
            }
        }
        while let stream = try await session.acceptStream() {
            group.addTask {
                let body = try await stream.readAll()
                let out = stream.isBidirectional ? stream : try session.openStream(bidirectional: false)
                try await out.write(Array("echo:".utf8) + body)
                out.finish()
            }
        }
        try await group.waitForAll()
    }
}

private func webTransportApp() -> Application {
    let app = h3App()
    app.onWebTransport("/wt") { _, session in try await echoSession(session) }
    app.onWebTransport("/wt-close") { _, session in session.close(code: 7, reason: "asked to") }
    app.onWebTransport("/wt-report") { _, session in
        while try await session.acceptStream() != nil {}
        lastSessionClose.withLock { $0 = "\(session.closeCode) \(session.closeReason)" }
    }
    app.group("/wt-reject") {
        app.use { _, response, _ in response.send(status: .forbidden) }
        app.onWebTransport("/") { _, session in try await echoSession(session) }
    }
    app.webTransport("/wt-room/:name") { (session: WebTransportSession, name: Path<String>) async throws in
        let out = try session.openStream(bidirectional: false)
        try await out.write(Array("welcome to \(name.value)".utf8))
        out.finish()
        while try await session.acceptStream() != nil {}
    }
    return app
}

/// A CLOSE_WEBTRANSPORT_SESSION capsule.
private func closeCapsule(_ code: UInt32, _ reason: String) -> [UInt8] {
    let payload = [UInt8(code >> 24), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        + Array(reason.utf8)
    return hsVarint(0x2843) + hsVarint(UInt64(payload.count)) + payload
}

/// The length of the HEADERS frame at the start of `bytes`, or 0 while it
/// has not all arrived.
private func headLength(_ bytes: [UInt8]) -> Int {
    bytes.withUnsafeBufferPointer { b -> Int in
        guard let base = b.baseAddress else { return 0 }
        var r = QUICReader(base, b.count)
        guard r.varint() == 0x01, let length = r.varintAsInt(), r.skip(length) else { return 0 }
        return r.offset
    }
}

/// What follows the HEADERS frame on a session's CONNECT stream: capsules.
private func afterHead(_ bytes: [UInt8]) -> [UInt8] {
    Array(bytes[headLength(bytes)...])
}

extension H3Client {
    /// Opens a WebTransport session on stream `id`, and waits for its answer.
    func session(_ id: UInt64, _ path: String) async throws -> H3Answer {
        try await request(id, extendedConnect(path, "webtransport"), fin: false)
        try await pump { headLength(peer.streams[id] ?? []) > 0 || peer.resets[id] != nil }
        let bytes = peer.streams[id] ?? []
        return try H3Answer(Array(bytes.prefix(headLength(bytes))), reset: peer.resets[id])
    }
}

@Suite("WebTransport over HTTP/3")
struct HTTP3WebTransportTests {

    @Test func aSessionEchoesItsStreamsAndDatagrams() throws {
        try withServer(webTransportApp(), datagrams: 1200) { client, _ in
            try await client.connect()
            let settings = try serverSettings(client)
            #expect(settings[0x08] == 1)
            #expect(settings[0x33] == 1)
            #expect(settings[0xC671_706A] == 16)
            #expect(try await client.session(0, "/wt").status == 200)

            // A bidirectional stream, answered on itself.
            try await client.write(4, hsVarint(0x41) + hsVarint(0) + Array("hello".utf8), fin: true)
            try await client.pump { client.peer.finished.contains(4) }
            #expect(client.peer.streams[4] == Array("echo:hello".utf8))

            // A unidirectional one, answered on one of ours: the first after
            // the control and QPACK streams.
            try await client.write(2, hsVarint(0x54) + hsVarint(0) + Array("uni".utf8), fin: true)
            try await client.pump { client.peer.finished.contains(15) }
            #expect(client.peer.streams[15] == hsVarint(0x54) + hsVarint(0) + Array("echo:uni".utf8))

            // A datagram, by the session's quarter stream ID.
            try await client.datagram([0] + Array("ping".utf8))
            try await client.pump { !client.peer.datagrams.isEmpty }
            #expect(client.peer.datagrams.first == [0] + Array("echo:ping".utf8))

            // The connection still serves requests.
            #expect(try await client.get(8, "/user/alongside").text == "alongside")
        }
    }

    @Test func eitherSideMayClose() throws {
        lastSessionClose.withLock { $0 = "" }
        try withServer(webTransportApp(), datagrams: 1200) { client, _ in
            try await client.connect()
            // The handler closes: its code and reason, then FIN.
            #expect(try await client.session(0, "/wt-close").status == 200)
            try await client.pump { client.peer.finished.contains(0) }
            #expect(afterHead(client.peer.streams[0] ?? []) == closeCapsule(7, "asked to"))

            // The client closes: the handler's wait ends, and it sees why.
            #expect(try await client.session(4, "/wt-report").status == 200)
            try await client.write(4, closeCapsule(9, "bye now"), fin: true)
            try await client.pump { client.peer.finished.contains(4) }
            for _ in 0..<100 where lastSessionClose.withLock({ $0.isEmpty }) {
                try await Runtime.sleep(for: .milliseconds(10))
            }
            #expect(lastSessionClose.withLock { $0 } == "9 bye now")
        }
    }

    @Test func aSessionIsARouteUntilAccepted() throws {
        try withServer(webTransportApp(), datagrams: 1200) { client, _ in
            try await client.connect()
            #expect(try await client.session(0, "/wt-reject").status == 403)
            #expect(try await client.session(4, "/wt-nowhere").status == 404)
            let get = try await client.get(8, "/wt")
            #expect(get.status == 405)
            #expect(get.header("allow") == "CONNECT")
            // A typed route: the path parameter reaches the handler.
            #expect(try await client.session(12, "/wt-room/lobby").status == 200)
            try await client.pump { client.peer.finished.contains(15) }
            #expect(client.peer.streams[15] == hsVarint(0x54) + hsVarint(12) + Array("welcome to lobby".utf8))
        }
    }

    @Test func withoutDatagramsNoSessionsAreOffered() throws {
        try withServer(webTransportApp()) { client, _ in
            try await client.connect()
            let settings = try serverSettings(client)
            #expect(settings[0x08] == 1)
            #expect(settings[0x33] == nil)
            #expect(settings[0xC671_706A] == nil)
        }
    }

    @Test func shutdownClosesSessionsCleanly() throws {
        try withServer(webTransportApp(), datagrams: 1200) { client, service in
            try await client.connect()
            #expect(try await client.session(0, "/wt").status == 200)
            service.shutdown(grace: .seconds(5))
            // The session is closed with a capsule and FIN, and then the
            // connection with H3_NO_ERROR, well inside the grace period.
            try await client.pump(timeout: .seconds(3)) { client.peer.closeCode != nil }
            #expect(client.peer.finished.contains(0))
            #expect(afterHead(client.peer.streams[0] ?? []) == closeCapsule(0, ""))
            #expect(client.peer.closeCode == HTTP3ErrorCode.noError.rawValue)
        }
    }
}

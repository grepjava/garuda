import Synchronization
import Testing
@_spi(Garuda) import VegaHTTP2Core
@_spi(Testing) import GarudaTesting
import GarudaWire
import Vega
@testable import Garuda

// WebSockets over HTTP/2 (RFC 8441) through the frame-level client: the
// setting, the extended CONNECT, frames both ways on the stream, and how
// the stream ends. scripts/websocket-streams-test.py covers the rest from
// outside, with Python's h2.

/// A client's frame: masked, as it must be.
private func clientFrame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
    precondition(payload.count < 126)
    let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
    var frame: [UInt8] = [0x80 | opcode, 0x80 | UInt8(payload.count)] + mask
    for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i & 3]) }
    return frame
}

private func echoApp() -> Application {
    let app = Application()
    app.webSocket("/echo") { (ws: WebSocket) async throws in
        for try await message in ws { try await ws.send(message) }
    }
    app.get("/plain") { _, response in response.send("plain") }
    return app
}

/// A RST_STREAM's error code.
private func errorCode(_ f: TestFrame) -> UInt32 {
    f.payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

private let extendedConnect = [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "http"),
                               (":authority", "test"), (":path", "/echo"), ("sec-websocket-version", "13")]

extension HTTP2TestConnection {
    /// The next DATA on `id`, or nil once the stream or connection ends.
    fileprivate func data(on id: UInt32) throws -> TestFrame? {
        try nextFrame { $0.stream == id && ($0.kind == .data || $0.kind == .rstStream) }
    }
}

@Suite("WebSockets over HTTP/2")
struct HTTP2WebSocketTests {
    @Test func theServerOffersExtendedConnect() throws {
        let h2 = try echoApp().test.http2()
        #expect(h2.serverSettings[HTTP2Setting.enableConnectProtocol.rawValue] == 1)

        var config = ServerConfig()
        config.websocketProtocols = [.http1]
        let without = try echoApp().testClient(configuration: config).http2()
        #expect(without.serverSettings[HTTP2Setting.enableConnectProtocol.rawValue] == nil)
        // Not offered: :protocol is malformed.
        try without.sendHeaders(stream: 1, extendedConnect, endStream: false)
        let reset = try without.nextFrame { $0.stream == 1 && $0.kind == .rstStream }
        #expect(reset.map(errorCode) == HTTP2ErrorCode.protocolError.rawValue)
    }

    @Test func messagesRoundTripOnTheStream() throws {
        let h2 = try echoApp().test.http2()
        try h2.sendHeaders(stream: 1, extendedConnect, endStream: false)
        h2.nextStream = 3
        let head = try h2.nextFrame { $0.stream == 1 && $0.kind == .headers }
        #expect(head != nil)
        #expect(h2.received(1)?.status == .ok)
        #expect(h2.received(1)?.header("sec-websocket-accept") == nil)

        try h2.sendData(stream: 1, clientFrame(0x1, Array("hello".utf8)), endStream: false)
        let echoed = try h2.data(on: 1)
        #expect(echoed?.payload == [0x81, 5] + Array("hello".utf8))

        // A ping between messages is answered, the stream left open.
        try h2.sendData(stream: 1, clientFrame(0x9, [1, 2]), endStream: false)
        #expect(try h2.data(on: 1)?.payload == [0x8A, 2, 1, 2])

        // A close is answered, and the stream ended.
        try h2.sendData(stream: 1, clientFrame(0x8, [0x03, 0xE8]), endStream: false)
        let close = try h2.data(on: 1)
        #expect(close.map { Array($0.payload.prefix(4)) } == [0x88, 2, 0x03, 0xE8])
        var ended = close?.has(.endStream) ?? false
        while !ended, let f = try h2.data(on: 1) {
            #expect(f.kind == .data)
            ended = f.has(.endStream)
        }
        #expect(ended)
        // Our side, ended after theirs, is no error.
        try h2.sendData(stream: 1, [], endStream: true)
        #expect(try h2.get("/plain").text == "plain")
        #expect(!h2.frames.contains { $0.stream == 1 && $0.kind == .rstStream })
    }

    @Test func aPlainGetOrAnotherProtocolIsRefused() throws {
        let h2 = try echoApp().test.http2()
        #expect(try h2.get("/echo").status == .badRequest)
        var other = extendedConnect
        other[1] = (":protocol", "something-else")
        try h2.sendHeaders(stream: h2.nextStream, other, endStream: false)
        #expect(try h2.response(h2.nextStream).status == HTTPStatus(501))
        h2.nextStream += 2
        var version = extendedConnect
        version[5] = ("sec-websocket-version", "8")
        try h2.sendHeaders(stream: h2.nextStream, version, endStream: false)
        let refused = try h2.response(h2.nextStream)
        #expect(refused.status == HTTPStatus(426))
        #expect(refused.header("sec-websocket-version") == "13")
    }

    @Test func malformedExtendedConnectsAreReset() throws {
        let h2 = try echoApp().test.http2()
        func resetCode(_ fields: [(String, String)], endStream: Bool = false) throws -> UInt32? {
            let id = h2.nextStream
            h2.nextStream += 2
            try h2.sendHeaders(stream: id, fields, endStream: endStream)
            return try h2.nextFrame { $0.stream == id && $0.kind == .rstStream }
                .map(errorCode)
        }
        let protocolError = HTTP2ErrorCode.protocolError.rawValue
        #expect(try resetCode(extendedConnect.filter { $0.0 != ":authority" }) == protocolError)
        #expect(try resetCode(extendedConnect, endStream: true) == protocolError)
        var get = extendedConnect
        get[0] = (":method", "GET")
        #expect(try resetCode(get) == protocolError)
    }

    @Test func aClientResetEndsTheHandlersReceive() throws {
        let app = Application()
        let seen = Mutex("")
        app.webSocket("/echo") { (ws: WebSocket) async throws in
            do {
                while try await ws.receive() != nil {}
            } catch {}
            let code = ws.closeCode.map { "\($0)" } ?? "none"
            seen.withLock { $0 = code }
        }
        app.get("/seen") { _, response in response.send(seen.withLock { $0 }) }
        let h2 = try app.test.http2()
        try h2.sendHeaders(stream: 1, extendedConnect, endStream: false)
        h2.nextStream = 3
        _ = try h2.nextFrame { $0.stream == 1 && $0.kind == .headers }
        try h2.reset(1)
        // The connection carries on, and the handler hears of it.
        var got = ""
        for _ in 0..<2000 where got.isEmpty { got = try h2.get("/seen").text }
        #expect(got == "1006")
    }
}

import Synchronization
import Testing
@_spi(Testing) @testable import Garuda
@_spi(Testing) import GarudaTesting
import GarudaQUIC
import GarudaWire
import QUICTestPeer
import Vega
import VegaCrypto
import VegaIO
import VegaTLS

// HTTP/3: the endpoint's handling of datagrams before any connection exists,
// and requests answered over a real UDP socket in process, to the tests' own
// QUIC client (Tests/QUICTestPeer). Garuda 1 tested its HTTP/3 only from
// outside, as scripts/http3-test.py still does against aioquic.

private let h3Runtime = Runtime(workers: 2)

private func h3App() -> Application {
    let app = Application()
    app.get("/") { _, response in response.send(status: .ok) }
    app.get("/user/:id") { request, response in response.send(request.parameter(0)) }
    app.post("/echo") { request, response in response.send(request.body) }
    app.get("/version") { request, response in
        let v = request.version
        response.send("\(v.major).\(v.minor) \(request.arrivedOverHTTPS) \(request.authority ?? "-")")
    }
    app.get("/lines") { _, response in
        let body = response.stream(contentType: "text/plain")
        for i in 1...3 { try await body.write("line \(i)\n") }
    }
    app.get("/delay/:ms") { request, response in
        try await Runtime.sleep(for: .milliseconds(Int(request.parameter(0)) ?? 1))
        response.send(status: .ok)
    }
    return app
}

private let certificate: CertificateKey = {
    let identity = try! TLSIdentity.selfSigned(names: ["localhost"])
    return try! CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
}()

private func h3Config(_ change: (inout ServerConfig) -> Void = { _ in }) -> ServerConfig {
    var config = ServerConfig()
    config.http3Enabled = true
    change(&config)
    return config
}

/// An endpoint that has no socket, for the datagram handling alone.
private func bareEndpoint() throws -> QUICEndpoint {
    let app = h3App()
    let config = h3Config()
    app.prepareForTesting(config, threads: h3Runtime.workerCount)
    let compiled = try #require(app.compiledApplication)
    return QUICEndpoint(app: compiled, limits: ConnectionLimits(config),
                        pool: StreamPool(runtime: h3Runtime, maxTasks: 4), certificates: { [certificate] })
}

private let somewhere = SocketAddress(numericHost: "127.0.0.1", port: 50_000)!

private func deliver(_ endpoint: QUICEndpoint, _ datagram: [UInt8]) {
    var datagram = datagram
    datagram.withUnsafeMutableBufferPointer {
        endpoint.handleDatagram($0.baseAddress!, $0.count, from: somewhere, to: nil, ecn: 0, nowMs: quicNowMs())
    }
}

/// A long header for `version`, padded to `size`.
private func longHeader(version: UInt32, dcid: [UInt8], scid: [UInt8], size: Int) -> [UInt8] {
    var out: [UInt8] = [0xC0, UInt8(version >> 24), UInt8(version >> 16 & 0xFF), UInt8(version >> 8 & 0xFF),
                        UInt8(version & 0xFF)]
    out.append(UInt8(dcid.count))
    out += dcid
    out.append(UInt8(scid.count))
    out += scid
    out += [UInt8](repeating: 0, count: max(0, size - out.count))
    return out
}

// MARK: - A client over a real socket

/// The tests' QUIC client on a UDP socket connected to the endpoint, with
/// an HTTP/3 request's worth of framing.
private final class H3Client: @unchecked Sendable {
    let peer: QUICTestPeer
    let socket: UnsafeMutablePointer<UDPSocket>

    init(port: Int) throws {
        peer = try QUICTestPeer()
        socket = .allocate(capacity: 1)
        socket.initialize(to: try UDPSocket.connect(to: SocketAddress(numericHost: "127.0.0.1", port: port)!))
    }

    deinit {
        socket.deinitialize(count: 1)
        socket.deallocate()
    }

    func send(_ bytes: [UInt8]) async throws {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
        defer { raw.deallocate() }
        raw.copyBytes(from: bytes)
        _ = try await socket.pointee.send(UnsafeRawBufferPointer(raw))
    }

    /// One datagram, or nil once `timeout` has passed.
    func receiveOne(timeout: Duration) async throws -> [UInt8]? {
        try await receiveDatagram(socket.pointee, timeout: timeout)
    }

    /// Takes datagrams until `done`, acknowledging them as they come, as a
    /// client does.
    func pump(timeout: Duration = .seconds(5), until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero, let datagram = try await receiveOne(timeout: left) else {
                throw QUICTestPeerError("timed out waiting for the server")
            }
            let before = peer.largestReceived[2]
            try peer.receive(datagram)
            if peer.closeCode == nil && peer.largestReceived[2] > before
                && peer.keys[QUICLevel.application.rawValue].send.isValid {
                try await send(try peer.packet(.application, peer.ack(.application)))
            }
        }
    }

    /// The handshake, through the server's control stream and SETTINGS.
    func connect() async throws {
        let hello = peer.clientHello(serverName: "localhost", alpn: ["h3"])
        try await send(try peer.packet(.initial, cryptoFrame(offset: 0, hello)))
        try await pump { peer.handshakeReceived }
        try await send(try peer.finishedPacket())
        try await pump { peer.handshakeDone && (peer.streams[3]?.count ?? 0) > 2 }
    }

    /// `fields` as a HEADERS frame, then `body` as DATA frames of at most
    /// `chunk` bytes, on stream `id`.
    func request(_ id: UInt64, _ fields: [(String, String)], body: [UInt8]? = nil, chunk: Int = 1 << 20,
                 fin: Bool = true) async throws {
        var frames = headersFrame(fields)
        if let body {
            var at = 0
            repeat {
                let n = min(chunk, body.count - at)
                frames += hsVarint(0) + hsVarint(UInt64(n)) + body[at..<(at + n)]
                at += n
            } while at < body.count
        }
        // In packets that fit a datagram, as a client's must.
        var at = 0
        repeat {
            let n = min(1000, frames.count - at)
            let last = at + n == frames.count
            try await send(try peer.packet(.application, peer.ack(.application)
                + streamFrame(id, offset: at, Array(frames[at..<(at + n)]), fin: fin && last)))
            at += n
        } while at < frames.count
    }

    func get(_ id: UInt64, _ path: String, headers: [(String, String)] = []) async throws -> H3Answer {
        try await request(id, [(":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
                               (":path", path)] + headers)
        return try await answer(id)
    }

    /// Waits for stream `id` to end or be reset, and reads it.
    func answer(_ id: UInt64) async throws -> H3Answer {
        try await pump { peer.finished.contains(id) || peer.resets[id] != nil }
        return try H3Answer(peer.streams[id] ?? [], reset: peer.resets[id])
    }
}

/// One datagram from `socket`, or nil once `timeout` has passed.
private func receiveDatagram(_ socket: borrowing UDPSocket, timeout: Duration) async throws(IOError) -> [UInt8]? {
    var buffer = IOBuffer(capacity: 2048)
    do {
        _ = try await Runtime.withIODeadline(timeout) { () async throws(IOError) -> Int in
            try await socket.receive(into: &buffer)
        }
    } catch {
        if error == .timedOut { return nil }
        throw error
    }
    return buffer.withUnsafeBytes { Array($0) }
}

private func headersFrame(_ fields: [(String, String)]) -> [UInt8] {
    var block = ByteBuffer()
    defer { block.destroy() }
    let encoder = QPACKEncoder()
    encoder.begin(into: &block)
    for (name, value) in fields {
        let n = Array(name.utf8), v = Array(value.utf8)
        n.withUnsafeBufferPointer { np in
            v.withUnsafeBufferPointer { vp in
                encoder.encode(name: np.baseAddress!, nameLength: n.count,
                               value: vp.baseAddress ?? np.baseAddress!, valueLength: v.count, into: &block)
            }
        }
    }
    let bytes = hsBytes(block.readPointer, block.readableBytes)
    return hsVarint(1) + hsVarint(UInt64(bytes.count)) + bytes
}

/// An HTTP/3 response as it arrived on its stream.
private struct H3Answer {
    var status = 0
    var headers: [(name: String, value: String)] = []
    var body: [UInt8] = []
    var reset: UInt64?
    /// HEADERS frames, an interim head's among them.
    var heads = 0

    init(_ bytes: [UInt8], reset: UInt64?) throws {
        self.reset = reset
        for (type, payload) in try h3Frames(bytes) {
            switch type {
            case 0x01:
                heads += 1
                let fields = try decodeFields(payload)
                headers = fields.filter { $0.name != ":status" }
                status = Int(fields.first { $0.name == ":status" }?.value ?? "") ?? 0
            case 0x00:
                body += payload
            default:
                break
            }
        }
    }

    func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// A QPACK field section's fields.
private func decodeFields(_ payload: [UInt8]) throws -> [(name: String, value: String)] {
    final class Fields { var list: [(name: String, value: String)] = [] }
    let fields = Fields()
    var decoder = QPACKDecoder()
    defer { decoder.destroy() }
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, payload.count))
    defer { p.deallocate() }
    for (i, b) in payload.enumerated() { p[i] = b }
    try decoder.decode(p, payload.count) { span in
        let name = String(decoding: UnsafeBufferPointer(start: span.name, count: span.nameLength), as: UTF8.self)
        let value = String(decoding: UnsafeBufferPointer(start: span.value, count: span.valueLength), as: UTF8.self)
        fields.list.append((name, value))
    }
    return fields.list
}

/// The frames in `bytes`: type and payload.
private func h3Frames(_ bytes: [UInt8]) throws -> [(UInt64, [UInt8])] {
    var out: [(UInt64, [UInt8])] = []
    try bytes.withUnsafeBufferPointer { b in
        guard let base = b.baseAddress else { return }
        var r = QUICReader(base, b.count)
        while !r.isEmpty {
            guard let type = r.varint(), let length = r.varintAsInt(), let payload = r.take(length) else {
                throw QUICTestPeerError("a frame cut short")
            }
            out.append((type, hsBytes(payload, length)))
        }
    }
    return out
}

/// Serves `app` on a socket of its own on the test runtime, runs `body`
/// with a client connected to it, and shuts the endpoint down.
private func withServer(_ app: Application, _ config: ServerConfig = h3Config(),
                        _ body: @escaping @Sendable (H3Client, HTTP3Service) async throws -> Void) throws {
    app.prepareForTesting(config, threads: h3Runtime.workerCount)
    try app.startForTesting(on: h3Runtime)
    let compiled = try #require(app.compiledApplication)
    let service = HTTP3Service(runtime: h3Runtime, app: compiled, limits: ConnectionLimits(config),
                               certificates: { [certificate] })
    try h3Runtime.block { () async throws -> Void in
        let port = try service.start(host: "127.0.0.1", port: 0, count: 1)
        let client = try H3Client(port: port)
        do {
            try await body(client, service)
        } catch {
            service.shutdown(grace: .zero)
            await service.wait()
            throw error
        }
        service.shutdown(grace: .zero)
        await service.wait()
    }
}

@Suite("HTTP/3")
struct HTTP3Tests {

    // MARK: Datagrams before a connection

    @Test func anUnsupportedVersionIsAnsweredWithTheOnesServed() throws {
        let endpoint = try bareEndpoint()
        let dcid: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let scid: [UInt8] = [10, 11, 12]
        deliver(endpoint, longHeader(version: 0x1A2A_3A4A, dcid: dcid, scid: scid, size: 1200))
        try #require(endpoint.replies.count == 1)
        let reply = endpoint.replies[0].bytes
        #expect(reply[0] & 0x80 != 0)
        #expect(Array(reply[1..<5]) == [0, 0, 0, 0])
        // The identifiers come back swapped.
        #expect(Int(reply[5]) == scid.count)
        #expect(Array(reply[6..<(6 + scid.count)]) == scid)
        let at = 6 + scid.count
        #expect(Int(reply[at]) == dcid.count)
        #expect(Array(reply[(at + 1)..<(at + 1 + dcid.count)]) == dcid)
        let versions = Array(reply[(at + 1 + dcid.count)...])
        #expect(versions == [0, 0, 0, 1, 0x6B, 0x33, 0x43, 0xCF])
        #expect(endpoint.live.isEmpty)
    }

    @Test func aDatagramTooSmallToStartAConnectionIsNotNegotiated() throws {
        let endpoint = try bareEndpoint()
        deliver(endpoint, longHeader(version: 0x1A2A_3A4A, dcid: [1, 2, 3, 4, 5, 6, 7, 8], scid: [9], size: 1199))
        #expect(endpoint.replies.isEmpty)
        // Nor is a version negotiation packet answered.
        deliver(endpoint, longHeader(version: 0, dcid: [1, 2, 3, 4, 5, 6, 7, 8], scid: [9], size: 1200))
        #expect(endpoint.replies.isEmpty)
    }

    @Test func aFullSizeInitialMakesAConnectionAndAShortOneDoesNot() throws {
        let endpoint = try bareEndpoint()
        let short = try QUICTestPeer()
        let shortHello = short.clientHello(serverName: "localhost", alpn: ["h3"])
        let small = try short.packet(.initial, cryptoFrame(offset: 0, shortHello), padded: false)
        #expect(small.count < QUICPacket.minimumInitialSize)
        deliver(endpoint, small)
        #expect(endpoint.live.isEmpty)
        #expect(endpoint.replies.isEmpty)

        let peer = try QUICTestPeer()
        let hello = peer.clientHello(serverName: "localhost", alpn: ["h3"])
        deliver(endpoint, try peer.packet(.initial, cryptoFrame(offset: 0, hello)))
        try #require(endpoint.live.count == 1)
        #expect(endpoint.live[0].quic.hasOutput)
        // Both identifiers reach it: ours, and the one the client invented.
        #expect(endpoint.connections[peer.originalDCID] === endpoint.live[0])
        #expect(endpoint.connections[endpoint.live[0].localCID] === endpoint.live[0])
    }

    @Test func aPacketForNoKnownConnectionIsDropped() throws {
        let endpoint = try bareEndpoint()
        // A short header with a connection ID nobody issued.
        deliver(endpoint, [0x40] + [UInt8](repeating: 0x5A, count: 8) + [UInt8](repeating: 1, count: 40))
        // A Handshake packet, which cannot start a connection.
        let handshake = longHeader(version: QUICVersion.v1, dcid: [1, 2, 3, 4, 5, 6, 7, 8], scid: [9], size: 0)
        deliver(endpoint, [0xE0] + handshake[1...] + hsVarint(1200) + [UInt8](repeating: 0, count: 1200))
        #expect(endpoint.live.isEmpty)
        #expect(endpoint.replies.isEmpty)
    }

    @Test func aClientIdentifierShorterThanEightBytesIsRefused() throws {
        let endpoint = try bareEndpoint()
        let peer = try QUICTestPeer(dcidLength: 7)
        let hello = peer.clientHello(serverName: "localhost", alpn: ["h3"])
        deliver(endpoint, try peer.packet(.initial, cryptoFrame(offset: 0, hello)))
        #expect(endpoint.live.isEmpty)
    }

    // MARK: Requests

    @Test func aGetIsAnsweredAsHTTP1AndHTTP2Are() throws {
        let app = h3App()
        let seen = Mutex<[CompletedRequest]>([])
        app.onResponse { completed in seen.withLock { $0.append(completed) } }
        try withServer(app) { client, _ in
            try await client.connect()
            // The control stream: its type, then SETTINGS first.
            let control = client.peer.streams[3] ?? []
            #expect(control.first == 0x00)
            let settings = try h3Frames(Array(control.dropFirst()))
            #expect(settings.first?.0 == 0x04)

            let answer = try await client.get(0, "/user/42")
            #expect(answer.status == 200)
            #expect(answer.text == "42")
            #expect(answer.header("content-length") == "2")
            #expect(answer.header("server") == "garuda")
            #expect(answer.header("date") != nil)

            let version = try await client.get(4, "/version")
            #expect(version.text == "3.0 true localhost")
            let missing = try await client.get(8, "/nowhere")
            #expect(missing.status == 404)
        }
        // What observers and the access log are told.
        let completed = seen.withLock { $0 }
        #expect(completed.count == 3)
        #expect(completed.allSatisfy { $0.protocolName == "HTTP/3" })
        #expect(completed.first?.status == 200)
    }

    @Test func aRouteThatNeverWaitsIsAnsweredByTheEndpointAsWell() throws {
        let app = h3App()
        try withServer(app) { client, service in
            try await client.connect()
            // Past the runs it takes to be answered without a task of its
            // own, one at a time and then many at once.
            var id: UInt64 = 0
            for i in 0..<24 {
                #expect(try await client.get(id, "/user/\(i)").text == "\(i)")
                id += 4
            }
            let route = try #require(app.routes.firstIndex { $0.method == .get && $0.pattern == "/user/:id" })
            #expect(service.app.costs.neverSuspends(route))
            let first = id
            for i in 0..<20 {
                try await client.request(id, [(":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
                                              (":path", "/user/many\(i)")])
                id += 4
            }
            for i in 0..<20 {
                #expect(try await client.answer(first + UInt64(i) * 4).text == "many\(i)")
            }
        }
    }

    @Test func aBodyArrivesWholeAcrossDataFrames() throws {
        try withServer(h3App()) { client, _ in
            try await client.connect()
            let body = (0..<3000).map { UInt8($0 % 251) }
            try await client.request(0, [(":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                                         (":path", "/echo"), ("content-length", "3000")], body: body, chunk: 700)
            let answer = try await client.answer(0)
            #expect(answer.status == 200)
            #expect(answer.body == body)
        }
    }

    @Test func aBodyPastTheLimitIsAnswered413() throws {
        let config = h3Config { $0.maxBodySize = 10 }
        try withServer(h3App(), config) { client, _ in
            try await client.connect()
            try await client.request(0, [(":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                                         (":path", "/echo"), ("content-length", "100")],
                                     body: [UInt8](repeating: 1, count: 100))
            let answer = try await client.answer(0)
            #expect(answer.status == 413)
            // With no length declared, the body is counted as it comes, in
            // DATA frames, and refused once past the limit.
            try await client.request(4, [(":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                                         (":path", "/echo")], body: [UInt8](repeating: 2, count: 100), chunk: 8)
            #expect(try await client.answer(4).status == 413)
            // The connection goes on.
            #expect(try await client.get(8, "/user/after").text == "after")
        }
    }

    @Test func aBodyThatDisagreesWithItsLengthIsMalformed() throws {
        try withServer(h3App()) { client, _ in
            try await client.connect()
            try await client.request(0, [(":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                                         (":path", "/echo"), ("content-length", "5")], body: [1, 2, 3])
            let answer = try await client.answer(0)
            #expect(answer.reset == HTTP3Error.messageError)
        }
    }

    @Test func aMalformedRequestIsResetAndTheConnectionGoesOn() throws {
        try withServer(h3App()) { client, _ in
            try await client.connect()
            // No :scheme.
            try await client.request(0, [(":method", "GET"), (":authority", "localhost"), (":path", "/")])
            let answer = try await client.answer(0)
            #expect(answer.reset == HTTP3Error.messageError)
            // A Host that differs from :authority (RFC 9114 section 4.3.1).
            let differs = try await client.get(4, "/", headers: [("host", "elsewhere")])
            #expect(differs.reset == HTTP3Error.messageError)
            #expect(try await client.get(8, "/user/still").text == "still")
        }
    }

    @Test func aStreamedAnswerEndsWithTheStream() throws {
        try withServer(h3App()) { client, _ in
            try await client.connect()
            let answer = try await client.get(0, "/lines")
            #expect(answer.status == 200)
            #expect(answer.text == "line 1\nline 2\nline 3\n")
            #expect(answer.header("content-length") == nil)
            #expect(answer.header("content-type") == "text/plain")
        }
    }

    @Test func aCancelledRequestIsNotAnswered() throws {
        try withServer(h3App()) { client, _ in
            try await client.connect()
            try await client.request(0, [(":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
                                         (":path", "/delay/2000")])
            // The request is whole; its handler is waiting. Cancelled:
            let request = try headersFrame([(":method", "GET"), (":scheme", "https"),
                                             (":authority", "localhost"), (":path", "/delay/2000")]).count
            try await client.send(try client.peer.packet(.application, client.peer.ack(.application)
                + resetStreamFrame(0, code: HTTP3Error.requestCancelled, finalSize: request)))
            let answer = try await client.answer(0)
            #expect(answer.reset == HTTP3Error.requestCancelled)
            #expect(answer.status == 0)
            #expect(try await client.get(4, "/user/next").text == "next")
        }
    }

    @Test func shutdownSendsGoawayAndClosesOnceAnswered() throws {
        try withServer(h3App()) { client, service in
            try await client.connect()
            #expect(try await client.get(0, "/").status == 200)
            service.shutdown(grace: .seconds(5))
            // GOAWAY on the control stream, naming the first request it
            // will not serve, then CONNECTION_CLOSE with H3_NO_ERROR.
            try await client.pump { client.peer.closeCode != nil }
            let control = try h3Frames(Array((client.peer.streams[3] ?? []).dropFirst()))
            let goaway = try #require(control.first { $0.0 == 0x07 })
            #expect(goaway.1 == hsVarint(4))
            #expect(client.peer.closeCode == HTTP3Error.noError)
        }
    }
}

@Suite struct HTTP3CommandLineTests {
    func parse(_ args: String...) -> ServerConfig? {
        if case .run(let config) = ServerConfig.parse(["garuda"] + args) { return config }
        return nil
    }

    @Test func http3TakesItsPortAndHSTSItsAge() throws {
        let config = try #require(parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--port", "8443",
                                        "--http3", "--quic-port", "9443", "--hsts", "600"))
        #expect(config.http3Enabled)
        #expect(config.quicPort == 9443)
        #expect(config.hstsMaxAge == 600)
    }

    @Test func mistakesAreRefused() {
        // QUIC has no cleartext form.
        #expect(parse("--http3") == nil)
        #expect(parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--quic-port", "9443") == nil)
        #expect(parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--http3", "--quic-port", "0") == nil)
        // Strict-Transport-Security means nothing over plain HTTP.
        #expect(parse("--hsts", "600") == nil)
        #expect(parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--hsts", "soon") == nil)
    }

    @Test func altSvcNamesTheQUICPortOnTCPOnly() throws {
        var config = ServerConfig()
        config.port = 8443
        config.http3Enabled = true
        var limits = ConnectionLimits(config)
        #expect(limits.plainFields?.altSvc == Array("h3=\":8443\"; ma=86400".utf8))
        #expect(limits.secureFields?.altSvc == Array("h3=\":8443\"; ma=86400".utf8))
        #expect(limits.quicFields == nil)
        config.quicPort = 9443
        config.hstsMaxAge = 60
        limits = ConnectionLimits(config)
        #expect(limits.secureFields?.altSvc == Array("h3=\":9443\"; ma=86400".utf8))
        #expect(limits.secureFields?.hsts == Array("max-age=60".utf8))
        // HSTS is only for TLS, and Alt-Svc never over HTTP/3 itself.
        #expect(limits.plainFields?.hsts == nil)
        #expect(limits.quicFields?.hsts == Array("max-age=60".utf8))
        #expect(limits.quicFields?.altSvc == nil)
        // Nothing to add without HTTP/3 or --hsts.
        #expect(ConnectionLimits(ServerConfig()).secureFields == nil)
    }

    @Test func anHTTP1AnswerAdvertisesHTTP3OnceAndKeepsAHandlersOwn() throws {
        let app = Application()
        app.get("/") { _, response in response.send(status: .ok) }
        app.get("/own") { _, response in
            response.addHeader("alt-svc", "h3=\":9999\"")
            response.send(status: .ok)
        }
        var config = ServerConfig()
        config.port = 8443
        config.http3Enabled = true
        let client = app.testClient(configuration: config)
        let plain = try client.get("/")
        #expect(plain.headers(named: "alt-svc") == ["h3=\":8443\"; ma=86400"])
        #expect(plain.header("strict-transport-security") == nil)
        #expect(try client.get("/own").headers(named: "alt-svc") == ["h3=\":9999\""])
    }
}

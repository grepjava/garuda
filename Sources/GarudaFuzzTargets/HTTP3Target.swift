//===----------------------------------------------------------------------===//
// HTTP/3, a whole connection at a time, over a real UDP socket.
//
// HTTP/3's frames are read inside the connection, stream by stream, so like
// `h2` this target serves a connection and puts the input where a client's
// bytes go. The first byte of the input says where:
//
//   0  the rest is request stream 0, ended
//   1  the rest follows SETTINGS on the client's control stream
//   2  the rest is a whole unidirectional stream, its type included, ended
//
// After it, a plain GET on stream 4. The checks:
//
//   * the GET is answered, or the connection is closed -- whatever the input
//     did to one stream, it must not leave the others waiting, which is the
//     difference between a refused request and a connection anyone can stall;
//   * a request stream the client ended is answered or refused, however
//     little of a request it held: one the server neither answers nor resets
//     holds one of the client's stream slots for as long as the connection
//     lasts;
//   * everything the server sends opens and parses at the client, and every
//     stream it ends holds frames that parse and field sections that decode.
//
// The server is one for the whole process, on loopback, as a shard serves
// HTTP/3; each input gets a connection of its own.
//===----------------------------------------------------------------------===//

@_spi(Testing) import Garuda
import VegaQUIC
import GarudaWire
import QUICTestPeer
import Vega
import VegaIO

enum HTTP3Fixture {
    static let runtime = Runtime(workers: 2)

    /// The port, or why there is none.
    nonisolated(unsafe) static let server: Result<HTTP3TestServer, any Error> = {
        let app = Application()
        app.get("/") { _, response in response.send(status: .ok) }
        app.post("/echo") { request, response in response.send(request.body) }
        app.get("/big") { _, response in response.send([UInt8](repeating: 0x61, count: 100_000)) }
        var config = ServerConfig()
        config.http3Enabled = true
        app.prepareForTesting(config, threads: runtime.workerCount)
        return Result {
            try HTTP3TestServer(app, config: config, on: runtime, certificate: QUICFixture.certificate)
        }
    }()
}

/// The tests' QUIC client on a UDP socket connected to the server.
private final class H3FuzzClient {
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

    /// Takes datagrams until `done`, acknowledging them as a client does.
    /// False if the time ran out first; throws only for what the client
    /// could not read.
    func pump(_ timeout: Duration, until done: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return false }
            var buffer = IOBuffer(capacity: 2048)
            do {
                _ = try await Runtime.withIODeadline(left) { () async throws(IOError) -> Int in
                    try await socket.pointee.receive(into: &buffer)
                }
            } catch {
                if error == .timedOut { return false }
                throw error
            }
            let before = peer.largestReceived[2]
            try peer.receive(buffer.withUnsafeBytes { Array($0) })
            if peer.closeCode == nil && peer.largestReceived[2] > before
                && peer.keys[QUICLevel.application.rawValue].send.isValid {
                try await send(try peer.packet(.application, peer.ack(.application)))
            }
        }
        return true
    }

    func connect() async throws {
        let hello = peer.clientHello(serverName: "localhost", alpn: ["h3"])
        try await send(try peer.packet(.initial, cryptoFrame(offset: 0, hello)))
        guard try await pump(.seconds(5), until: { peer.handshakeReceived }) else {
            throw QUICTestPeerError("no handshake")
        }
        try await send(try peer.finishedPacket())
        guard try await pump(.seconds(5), until: { peer.handshakeDone && (peer.streams[3]?.count ?? 0) > 2 }) else {
            throw QUICTestPeerError("no SETTINGS")
        }
    }

    /// `bytes` on stream `id`, in packets that fit a datagram.
    func stream(_ id: UInt64, _ bytes: [UInt8], fin: Bool) async throws {
        var at = 0
        repeat {
            let n = min(1000, bytes.count - at)
            let last = at + n == bytes.count
            try await send(try peer.packet(.application, peer.ack(.application)
                + streamFrame(id, offset: at, Array(bytes[at..<(at + n)]), fin: fin && last)))
            at += n
        } while at < bytes.count
    }
}

extension Fuzz {

    static func h3(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let server: HTTP3TestServer
        switch HTTP3Fixture.server {
        case .success(let s): server = s
        case .failure(let error): return "no server to fuzz: \(error)"
        }
        let input = Array(UnsafeBufferPointer(start: base, count: n))
        do {
            return try HTTP3Fixture.runtime.block { () async throws -> String? in
                try await h3Connection(port: server.port, input)
            }
        } catch {
            return "\(error)"
        }
    }

    private static func h3Connection(port: Int, _ input: [UInt8]) async throws -> String? {
        let client = try H3FuzzClient(port: port)
        try await client.connect()
        let found = try await h3Exchange(client, input)
        // Closed from this end, so the server, which lives as long as the
        // fuzzer, does not hold every connection a run made until it idles.
        if client.peer.closeCode == nil {
            try? await client.send(try client.peer.packet(.application, [0x1d, 0x00, 0x00]))
        }
        return found
    }

    private static func h3Exchange(_ client: H3FuzzClient, _ input: [UInt8]) async throws -> String? {
        let peer = client.peer
        let rest = Array(input.dropFirst())
        let mode = (input.first ?? 0) % 3
        do {
            switch mode {
            case 0:
                try await client.stream(0, rest, fin: true)
            case 1:
                // The control stream's type, and an empty SETTINGS frame,
                // which must come first.
                try await client.stream(2, [0x00, 0x04, 0x00] + rest, fin: false)
            default:
                try await client.stream(6, rest, fin: true)
            }
            try await client.stream(4, headersFrame([(":method", "GET"), (":scheme", "https"),
                                                     (":authority", "localhost"), (":path", "/")]), fin: true)
            let ended = try await client.pump(.seconds(5)) {
                peer.closeCode != nil || peer.finished.contains(4) || peer.resets[4] != nil
            }
            if !ended { return "the request after the input was neither answered nor refused, and the connection stayed open" }
            if mode == 0 {
                let answered = try await client.pump(.seconds(5)) {
                    peer.closeCode != nil || peer.finished.contains(0) || peer.resets[0] != nil
                }
                if !answered { return "request stream 0 ended and was neither answered nor refused" }
            }
        } catch let error as QUICTestPeerError {
            return "the server sent what its client cannot read: \(error)"
        }
        // Every stream the server ended, ours and its own, holds whole
        // frames, and every HEADERS in one decodes.
        for id in peer.finished.sorted() {
            guard let bytes = peer.streams[id] else { continue }
            // A unidirectional stream opens with its type.
            var frames = bytes[...]
            if id & 0x2 != 0 {
                guard let (_, n) = h3Varint(frames) else { return "server stream \(id) ended before its type" }
                frames = frames.dropFirst(n)
            }
            while !frames.isEmpty {
                guard let (type, a) = h3Varint(frames), let (length, b) = h3Varint(frames.dropFirst(a)),
                      length <= UInt64(frames.count - a - b) else {
                    return "stream \(id) ended inside a frame"
                }
                let payload = Array(frames.dropFirst(a + b).prefix(Int(length)))
                if type == HTTP3FrameType.headers, !qpackDecodes(payload) {
                    return "stream \(id) carries a field section that does not decode"
                }
                frames = frames.dropFirst(a + b + Int(length))
            }
        }
        if peer.closeCode == nil, peer.finished.contains(4) {
            // Nothing in the input touched stream 4, so its answer is the
            // route's.
            guard let head = peer.streams[4], head.first == UInt8(HTTP3FrameType.headers) else {
                return "the request after the input was answered without a head"
            }
        }
        return nil
    }

    private static func h3Varint(_ bytes: ArraySlice<UInt8>) -> (UInt64, Int)? {
        guard let first = bytes.first else { return nil }
        let length = 1 << Int(first >> 6)
        guard bytes.count >= length else { return nil }
        var value = UInt64(first & 0x3F)
        for byte in bytes.dropFirst().prefix(length - 1) { value = value << 8 | UInt64(byte) }
        return (value, length)
    }

    private static func qpackDecodes(_ payload: [UInt8]) -> Bool {
        var decoder = QPACKDecoder()
        defer { decoder.destroy() }
        var bytes = payload
        let count = bytes.count
        if bytes.isEmpty { bytes = [0] }
        return bytes.withUnsafeBufferPointer { p in
            (try? decoder.decode(p.baseAddress!, count) { _ in }) != nil
        }
    }

    /// `fields` as one HEADERS frame.
    private static func headersFrame(_ fields: [(String, String)]) -> [UInt8] {
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
}

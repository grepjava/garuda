import Synchronization
import Testing
@testable import Garuda
import GarudaWire
import Vega
import VegaIO

// The HTTP/2 client against a scripted peer: each connection it makes is
// answered by a script of frames, the ones a server should never send
// included. Garuda's own server only ever sends good ones (HTTPClientTests).

/// One connection of a scripted peer, from the server's side.
final class PeerConnection: @unchecked Sendable {
    let stream: TCPStream
    var input = IOBuffer(capacity: 64 * 1024)
    var decoder = HPACKDecoder(maxTableSize: 4096)
    /// Every frame read, by type, for a script to look at afterwards.
    var seen: [H2FrameHeader] = []

    init(_ stream: consuming TCPStream) { self.stream = stream }

    deinit { decoder.destroy() }

    struct Frame {
        var header: H2FrameHeader
        var payload: [UInt8]
        var type: H2FrameType? { H2FrameType(rawValue: header.type) }
    }

    struct Request {
        var stream: UInt32
        var fields: [(String, String)]
        var endStream: Bool
        func field(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }
    }

    private func fill(_ count: Int) async throws {
        while input.count < count {
            if input.capacity - input.count < 16384 { input.reserveCapacity(input.capacity * 2) }
            guard try await stream.read(into: &input) > 0 else { throw IOError.connectionReset }
        }
    }

    /// The client's preface.
    func readPreface() async throws -> Bool {
        try await fill(HTTP2.preface.count)
        let matches = input.withUnsafeBytes { Array($0[0..<HTTP2.preface.count]) } == HTTP2.preface
        input.consume(HTTP2.preface.count)
        return matches
    }

    func readFrame() async throws -> Frame {
        try await fill(H2FrameHeader.size)
        let header = input.withUnsafeBytes { H2FrameHeader.parse($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        try await fill(H2FrameHeader.size + header.length)
        let payload = input.withUnsafeBytes { Array($0[H2FrameHeader.size..<(H2FrameHeader.size + header.length)]) }
        input.consume(H2FrameHeader.size + header.length)
        seen.append(header)
        return Frame(header: header, payload: payload)
    }

    /// Reads to the next request's whole header block, answering nothing
    /// and skipping the rest.
    func readRequest() async throws -> Request {
        var block: [UInt8] = []
        var id: UInt32 = 0
        var ends = false
        while true {
            let frame = try await readFrame()
            switch frame.type {
            case .headers:
                id = frame.header.streamID
                ends = frame.header.flags.contains(.endStream)
                block = frame.payload
                if frame.header.flags.contains(.endHeaders) { return try decode(id, block, ends) }
            case .continuation:
                block += frame.payload
                if frame.header.flags.contains(.endHeaders) { return try decode(id, block, ends) }
            default:
                continue
            }
        }
    }

    /// The body of stream `id`, to its end, giving window back as it comes.
    func readBody(_ id: UInt32) async throws -> [UInt8] {
        var body: [UInt8] = []
        while true {
            let frame = try await readFrame()
            guard frame.type == .data, frame.header.streamID == id else { continue }
            body += frame.payload
            if frame.payload.count > 0 {
                try await windowUpdate(0, frame.payload.count)
                try await windowUpdate(id, frame.payload.count)
            }
            if frame.header.flags.contains(.endStream) { return body }
        }
    }

    private func decode(_ id: UInt32, _ block: [UInt8], _ ends: Bool) throws -> Request {
        var fields: [(String, String)] = []
        try block.withUnsafeBufferPointer { b in
            try decoder.decode(b.baseAddress!, b.count) { span in
                fields.append((String(decoding: UnsafeBufferPointer(start: span.name, count: span.nameLength), as: UTF8.self),
                               String(decoding: UnsafeBufferPointer(start: span.value, count: span.valueLength), as: UTF8.self)))
            }
        }
        return Request(stream: id, fields: fields, endStream: ends)
    }

    func send(_ type: H2FrameType, flags: H2Flags = [], stream id: UInt32, _ payload: [UInt8] = []) async throws {
        try await sendRaw(type.rawValue, flags: flags, stream: id, payload)
    }

    func sendRaw(_ type: UInt8, flags: H2Flags = [], stream id: UInt32, _ payload: [UInt8]) async throws {
        var out = ByteBuffer(capacity: payload.count + 16)
        H2FrameHeader(length: payload.count, rawType: type, flags: flags, streamID: id).write(into: &out)
        if !payload.isEmpty { payload.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) } }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        try await bytes.withUnsafeBytesAsync { (b) async throws(IOError) in try await stream.write(b) }
    }

    func settings(_ entries: [(H2Setting, UInt32)] = [], ack: Bool = false) async throws {
        var payload: [UInt8] = []
        for (setting, value) in entries {
            payload += [UInt8(setting.rawValue >> 8), UInt8(setting.rawValue & 0xFF)] + be32(value)
        }
        try await send(.settings, flags: ack ? .ack : [], stream: 0, payload)
    }

    func windowUpdate(_ id: UInt32, _ increment: Int) async throws {
        try await send(.windowUpdate, stream: id, be32(UInt32(increment)))
    }

    /// Answers the opening: our settings, and an ack of the client's.
    func handshake(_ entries: [(H2Setting, UInt32)] = []) async throws {
        #expect(try await readPreface())
        try await settings(entries)
        try await settings(ack: true)
    }

    /// A header block for `status` and `fields`, nothing indexed.
    func block(status: Int?, _ fields: [(String, String)] = []) -> [UInt8] {
        var out = ByteBuffer(capacity: 256)
        let encoder = HPACKEncoder()
        if let status { encoder.encodeStatus(status, into: &out) }
        for (name, value) in fields {
            var n = name, v = value
            n.withUTF8 { nb in v.withUTF8 { vb in
                let empty: StaticString = ""
                encoder.encode(name: nb.baseAddress!, nameLength: nb.count, value: vb.baseAddress ?? empty.utf8Start,
                               valueLength: vb.count, into: &out)
            } }
        }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        return bytes
    }

    /// A whole answer: HEADERS, and DATA when there is a body.
    func respond(_ id: UInt32, status: Int = 200, _ fields: [(String, String)] = [], body: String? = nil) async throws {
        let ends = body == nil
        try await send(.headers, flags: ends ? [.endHeaders, .endStream] : [.endHeaders], stream: id,
                       block(status: status, fields))
        if let body { try await send(.data, flags: .endStream, stream: id, Array(body.utf8)) }
    }

    /// Waits for the client to close, reading and dropping what it sends.
    func drain() async {
        while (try? await readFrame()) != nil {}
    }
}

func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

/// A peer that answers its Nth connection with the Nth script.
struct ScriptedPeer: Sendable {
    let port: Int
    let log: OriginLog
    let server: TCPServer

    var url: String { "http://127.0.0.1:\(port)" }

    static func start(_ scripts: [@Sendable (PeerConnection) async throws -> Void]) throws -> ScriptedPeer {
        let log = OriginLog()
        let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
        let port = listener.localPort
        let server = try TCPServer.serve(listener) { stream in
            let index = log.state.withLock { state in
                state.accepted += 1
                return state.accepted - 1
            }
            let connection = PeerConnection(stream)
            guard index < scripts.count else { return }
            do {
                try await scripts[index](connection)
            } catch {
                log.state.withLock { $0.requests.append("script threw: \(error)") }
            }
        }
        return ScriptedPeer(port: port, log: log, server: server)
    }

    func stop() async { await server.shutdown(gracePeriod: .milliseconds(100)) }
}

private var h2: HTTPClient {
    var client = HTTPClient()
    client.forceHTTP2 = true
    client.decompress = false
    client.timeout = .seconds(2)
    return client
}

/// The answer, or the error, for one GET.
private func outcome(_ client: HTTPClient, _ url: String) async -> Result<ClientResponse, ClientError> {
    do {
        return .success(try await client.get(url))
    } catch {
        return .failure(error)
    }
}

private func failure(_ result: Result<ClientResponse, ClientError>) -> ClientError? {
    if case .failure(let error) = result { return error }
    return nil
}

/// One GET against one scripted connection.
private func against(_ client: HTTPClient = h2, path: String = "/x",
                     _ script: @escaping @Sendable (PeerConnection) async throws -> Void)
    throws -> (Result<ClientResponse, ClientError>, OriginLog) {
    try onRuntime {
        let peer = try ScriptedPeer.start([script])
        defer { Task { await peer.stop() } }
        let result = await outcome(client, peer.url + path)
        return (result, peer.log)
    }
}

@Suite("HTTP/2 client against a scripted peer")
struct HTTP2ClientPeerTests {

    @Test func theRequestOpensAnOddStreamWithThePseudoHeadersAServerNeeds() throws {
        let seen = Mutex<PeerConnection.Request?>(nil)
        let (result, _) = try against(path: "/a?b=c") { peer in
            try await peer.handshake()
            let request = try await peer.readRequest()
            seen.withLock { $0 = request }
            try await peer.respond(request.stream, [("x-answer", "yes")], body: "hello")
            await peer.drain()
        }
        let response = try result.get()
        #expect(response.text == "hello")
        #expect(response.header("x-answer") == "yes")
        let request = try #require(seen.withLock { $0 })
        #expect(request.stream % 2 == 1)
        #expect(request.endStream)
        #expect(request.field(":method") == "GET")
        #expect(request.field(":scheme") == "http")
        #expect(request.field(":path") == "/a?b=c")
        #expect(request.field(":authority")?.hasPrefix("127.0.0.1:") == true)
        #expect(request.field("user-agent") == "garuda")
    }

    @Test func paddedFramesAndABodyInPiecesAreReassembled() throws {
        let (result, _) = try against { peer in
            try await peer.handshake()
            let id = try await peer.readRequest().stream
            // HEADERS padded by 3, then DATA padded by 2, then plain DATA.
            let block = peer.block(status: 200)
            try await peer.send(.headers, flags: [.endHeaders, .padded], stream: id, [3] + block + [0, 0, 0])
            try await peer.send(.data, flags: .padded, stream: id, [2] + Array("abc".utf8) + [0, 0])
            try await peer.send(.data, flags: .endStream, stream: id, Array("def".utf8))
            await peer.drain()
        }
        #expect(try result.get().text == "abcdef")
    }

    @Test func aHeaderBlockSplitAcrossContinuationIsReassembledAndAnInformationalSkipped() throws {
        let (result, _) = try against { peer in
            try await peer.handshake()
            let id = try await peer.readRequest().stream
            try await peer.send(.headers, flags: .endHeaders, stream: id, peer.block(status: 103, [("link", "</a>")]))
            let block = peer.block(status: 200, [("x-one", "1"), ("x-two", "2")])
            try await peer.send(.headers, stream: id, Array(block[0..<3]))
            try await peer.send(.continuation, flags: .endHeaders, stream: id, Array(block[3...]))
            try await peer.send(.data, flags: .endStream, stream: id, Array("ok".utf8))
            await peer.drain()
        }
        let response = try result.get()
        #expect(response.status == 200)
        #expect(response.header("x-two") == "2")
        #expect(response.text == "ok")
    }

    @Test func framingAPeerShouldNeverSendEndsTheConnection() throws {
        // A frame longer than was agreed; a block interleaved with another
        // frame; a push, which was declined.
        let scripts: [@Sendable (PeerConnection, UInt32) async throws -> Void] = [
            { peer, id in try await peer.send(.data, stream: id, [UInt8](repeating: 0, count: 16385)) },
            { peer, id in
                try await peer.send(.headers, stream: id, peer.block(status: 200))
                try await peer.send(.ping, stream: 0, [UInt8](repeating: 0, count: 8))
            },
            { peer, id in try await peer.send(.pushPromise, flags: .endHeaders, stream: id, be32(2) + peer.block(status: nil)) },
        ]
        for script in scripts {
            let (result, _) = try against { peer in
                try await peer.handshake()
                let id = try await peer.readRequest().stream
                try await script(peer, id)
                await peer.drain()
            }
            #expect(failure(result) == .protocolError)
        }
    }

    @Test func aHeadThatIsNotAnAnswerIsRefused() throws {
        let heads: [[UInt8]] = [
            // No :status at all.
            PeerConnection.blockOnly([("content-type", "text/plain")]),
            // Not three digits.
            PeerConnection.blockOnly([(":status", "20")]),
            // 101, which HTTP/2 has no use for.
            PeerConnection.blockOnly([(":status", "101")]),
        ]
        for head in heads {
            let (result, _) = try against { peer in
                try await peer.handshake()
                let id = try await peer.readRequest().stream
                try await peer.send(.headers, flags: [.endHeaders, .endStream], stream: id, head)
                await peer.drain()
            }
            if case .malformedResponse = failure(result) {} else { Issue.record("\(result)") }
        }
    }

    @Test func aBodyThatIsNotTheLengthItsHeadPromisedIsRefused() throws {
        let cases: [(fields: [(String, String)], body: String, expected: ClientError?)] = [
            ([("content-length", "5")], "abc", .protocolError),
            ([("content-length", "2")], "abc", .protocolError),
            ([("content-length", "3")], "abc", nil),
            ([("content-length", "3"), ("content-length", "4")], "abc", .malformedResponse(.conflictingFraming)),
            ([("content-length", String(repeating: "9", count: 40))], "abc", .malformedResponse(.conflictingFraming)),
        ]
        for (fields, body, expected) in cases {
            let (result, _) = try against { peer in
                try await peer.handshake()
                let id = try await peer.readRequest().stream
                try await peer.respond(id, fields, body: body)
                await peer.drain()
            }
            #expect(failure(result) == expected, "\(fields)")
        }
    }

    @Test func aResetStreamIsReported() throws {
        let (result, _) = try against { peer in
            try await peer.handshake()
            let id = try await peer.readRequest().stream
            try await peer.send(.rstStream, stream: id, be32(H2Error.internalError.rawValue))
            await peer.drain()
        }
        #expect(failure(result) == .streamReset(H2Error.internalError.rawValue))
    }

    @Test func aPingIsAnsweredAndSettingsAcknowledged() throws {
        let acks = Mutex<(ping: [UInt8]?, settings: Bool)>((nil, false))
        let (result, _) = try against { peer in
            #expect(try await peer.readPreface())
            try await peer.settings([(.headerTableSize, 0)])
            let id = try await peer.readRequest().stream
            try await peer.send(.ping, stream: 0, [1, 2, 3, 4, 5, 6, 7, 8])
            while true {
                let frame = try await peer.readFrame()
                if frame.type == .settings && frame.header.flags.contains(.ack) { acks.withLock { $0.settings = true } }
                if frame.type == .ping && frame.header.flags.contains(.ack) {
                    acks.withLock { $0.ping = frame.payload }
                    break
                }
            }
            try await peer.respond(id, body: "ok")
            await peer.drain()
        }
        #expect(try result.get().text == "ok")
        #expect(acks.withLock { $0.ping } == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(acks.withLock { $0.settings })
    }

    @Test func aDecodedHeadLargerThanTheLimitEndsTheStreamOnly() throws {
        var client = h2
        client.maxHeadBytes = 200
        let (result, log) = try against(client) { peer in
            try await peer.handshake()
            let first = try await peer.readRequest().stream
            try await peer.respond(first, [("x-big", String(repeating: "x", count: 150)), ("x-more", String(repeating: "y", count: 150))],
                                   body: "too big")
            await peer.drain()
        }
        #expect(failure(result) == .headTooLarge)
        #expect(log.accepted == 1)
    }

    @Test func aBodyLargerThanTheWindowsAndFramesIsSentAsCreditArrives() throws {
        let received = Mutex<(body: Int, largest: Int)>((0, 0))
        let payload = [UInt8]((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
        let result: Result<ClientResponse, ClientError> = try onRuntime {
            let peer = try ScriptedPeer.start([{ peer in
                // A small stream window, and frames up to 20000 bytes.
                try await peer.handshake([(.initialWindowSize, 1000), (.maxFrameSize, 20_000)])
                let id = try await peer.readRequest().stream
                var total = 0
                var largest = 0
                while true {
                    let frame = try await peer.readFrame()
                    guard frame.type == .data else { continue }
                    total += frame.payload.count
                    largest = max(largest, frame.payload.count)
                    if frame.header.flags.contains(.endStream) { break }
                    try await peer.windowUpdate(0, frame.payload.count)
                    try await peer.windowUpdate(id, 30_000)
                }
                received.withLock { $0 = (total, largest) }
                try await peer.respond(id, body: "got it")
                await peer.drain()
            }])
            defer { Task { await peer.stop() } }
            do throws(ClientError) {
                return .success(try await h2.post(peer.url + "/up", body: payload, contentType: "application/octet-stream"))
            } catch {
                return .failure(error)
            }
        }
        #expect(try result.get().text == "got it")
        #expect(received.withLock { $0.body } == 150_000)
        #expect(received.withLock { $0.largest } > 16_384)
        #expect(received.withLock { $0.largest } <= 20_000)
    }

    @Test func aResetStreamFailsOnlyItsOwnRequest() throws {
        let (first, second) = try onRuntime {
            let peer = try ScriptedPeer.start([{ peer in
                try await peer.handshake()
                let a = try await peer.readRequest()
                let b = try await peer.readRequest()
                let reset = a.field(":path") == "/reset" ? a : b
                let answered = a.field(":path") == "/reset" ? b : a
                try await peer.send(.rstStream, stream: reset.stream, be32(H2Error.refusedStream.rawValue + 1))
                try await peer.respond(answered.stream, body: "fine")
                await peer.drain()
            }])
            defer { Task { await peer.stop() } }
            let client = h2
            async let one = outcome(client, peer.url + "/reset")
            try await Runtime.sleep(for: .milliseconds(20))
            async let two = outcome(client, peer.url + "/fine")
            return await (one, two)
        }
        #expect(failure(first) == .streamReset(H2Error.refusedStream.rawValue + 1))
        #expect((try? second.get().text) == "fine")
    }

    @Test func aConnectionThatDiesFailsEveryRequestOnIt() throws {
        let (first, second) = try onRuntime {
            let peer = try ScriptedPeer.start([{ peer in
                try await peer.handshake()
                _ = try await peer.readRequest()
                _ = try await peer.readRequest()
                // Gone, answering neither.
            }])
            defer { Task { await peer.stop() } }
            let client = h2
            async let one = outcome(client, peer.url + "/1")
            try await Runtime.sleep(for: .milliseconds(20))
            async let two = outcome(client, peer.url + "/2")
            return await (one, two)
        }
        #expect(failure(first) == .closed)
        #expect(failure(second) == .closed)
    }

    @Test func aGoawayRefusesOnlyTheStreamsThePeerNeverProcessedAndThoseAreSentAgain() throws {
        let (first, second, log) = try onRuntime {
            let peer = try ScriptedPeer.start([
                { peer in
                    try await peer.handshake()
                    let a = try await peer.readRequest()
                    _ = try await peer.readRequest()
                    // Only the first was looked at.
                    try await peer.send(.goaway, stream: 0, be32(a.stream) + be32(0))
                    try await peer.respond(a.stream, body: "first")
                    await peer.drain()
                },
                { peer in
                    try await peer.handshake()
                    let b = try await peer.readRequest()
                    try await peer.respond(b.stream, body: "again")
                    await peer.drain()
                },
            ])
            defer { Task { await peer.stop() } }
            let client = h2
            async let one = outcome(client, peer.url + "/1")
            try await Runtime.sleep(for: .milliseconds(20))
            async let two = outcome(client, peer.url + "/2")
            let both = await (one, two)
            return (both.0, both.1, peer.log)
        }
        #expect((try? first.get().text) == "first")
        #expect((try? second.get().text) == "again")
        #expect(log.accepted == 2)
    }

    @Test func anIdleConnectionToldToGoAwayIsNotUsedAgain() throws {
        let (first, second, log) = try onRuntime {
            let peer = try ScriptedPeer.start([
                { peer in
                    try await peer.handshake()
                    let a = try await peer.readRequest()
                    try await peer.respond(a.stream, body: "one")
                    try await peer.send(.goaway, stream: 0, be32(a.stream) + be32(0))
                    await peer.drain()
                },
                { peer in
                    try await peer.handshake()
                    let b = try await peer.readRequest()
                    try await peer.respond(b.stream, body: "two")
                    await peer.drain()
                },
            ])
            defer { Task { await peer.stop() } }
            let client = h2
            let one = await outcome(client, peer.url + "/1")
            try await Runtime.sleep(for: .milliseconds(50))
            let two = await outcome(client, peer.url + "/2")
            return (one, two, peer.log)
        }
        #expect((try? first.get().text) == "one")
        #expect((try? second.get().text) == "two")
        #expect(log.accepted == 2)
    }

    @Test func aFullConnectionSendsTheNextRequestToAnother() throws {
        let (first, second, log) = try onRuntime {
            // One stream at a time; the first connection answers /warm, then
            // whichever request it is given next.
            func script(answering count: Int) -> @Sendable (PeerConnection) async throws -> Void {
                { peer in
                    try await peer.handshake([(.maxConcurrentStreams, 1)])
                    for _ in 0..<count {
                        let a = try await peer.readRequest()
                        try await Runtime.sleep(for: .milliseconds(100))
                        try await peer.respond(a.stream, body: a.field(":path") ?? "?")
                    }
                    await peer.drain()
                }
            }
            let peer = try ScriptedPeer.start([script(answering: 2), script(answering: 1)])
            defer { Task { await peer.stop() } }
            let client = h2
            // The first connection's settings are in before the second asks.
            _ = await outcome(client, peer.url + "/warm")
            async let one = outcome(client, peer.url + "/1")
            try await Runtime.sleep(for: .milliseconds(20))
            async let two = outcome(client, peer.url + "/2")
            let both = await (one, two)
            return (both.0, both.1, peer.log)
        }
        #expect((try? first.get().text) == "/1")
        #expect((try? second.get().text) == "/2")
        #expect(log.accepted == 2)
    }

    @Test func oneRequestTimingOutDoesNotStopTheOthers() throws {
        var patientClient = h2
        patientClient.timeout = .seconds(2)
        var impatientClient = h2
        impatientClient.timeout = .milliseconds(100)
        let patient = patientClient, impatient = impatientClient
        let (slow, fast) = try onRuntime {
            let peer = try ScriptedPeer.start([{ peer in
                try await peer.handshake()
                let a = try await peer.readRequest()
                let b = try await peer.readRequest()
                let late = a.field(":path") == "/late" ? a : b
                try await Runtime.sleep(for: .milliseconds(300))
                try await peer.respond(late.stream, body: "late")
                await peer.drain()
            }])
            defer { Task { await peer.stop() } }
            async let one = outcome(patient, peer.url + "/late")
            try await Runtime.sleep(for: .milliseconds(20))
            async let two = outcome(impatient, peer.url + "/never")
            return await (one, two)
        }
        #expect(failure(fast) == .timedOut)
        #expect((try? slow.get().text) == "late")
    }
}

extension PeerConnection {
    /// A header block of exactly these fields, pseudo-fields included as
    /// given, nothing indexed.
    static func blockOnly(_ fields: [(String, String)]) -> [UInt8] {
        var out = ByteBuffer(capacity: 256)
        let encoder = HPACKEncoder()
        for (name, value) in fields {
            var n = name, v = value
            n.withUTF8 { nb in v.withUTF8 { vb in
                encoder.encode(name: nb.baseAddress!, nameLength: nb.count, value: vb.baseAddress!, valueLength: vb.count,
                               into: &out)
            } }
        }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        return bytes
    }
}

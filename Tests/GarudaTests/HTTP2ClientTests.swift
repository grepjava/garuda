import Testing
import CGaruda
import GarudaCore
import GarudaHTTP
@testable import Garuda

// Tests for one HTTP/2 exchange over a connection the worker made.
//
// The origin here speaks frames rather than text: it reads the client preface,
// takes the SETTINGS that follow it, decodes the request's header block with a
// real HPACK decoder, and answers with an encoded block of its own. A fake
// that matched bytes would prove nothing about whether a server can read what
// this client writes -- which is the only question worth asking of a protocol
// implementation.
//
// Both ends are on this thread, so the origin is pumped once per turn of the
// worker and never blocks.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var urlWanted = ""
nonisolated(unsafe) private var headersWanted: [(String, String)] = []
nonisolated(unsafe) private var bodyWanted: [UInt8] = []
nonisolated(unsafe) private var bodyLimitWanted = 8 * 1024 * 1024
/// How long the client under test should wait on any one read or write. Short
/// for the tests that prove something never arrives: the default ten seconds
/// is the right answer in production and a tax on a suite that runs in
/// tenths of a second.
nonisolated(unsafe) private var timeoutWanted: UInt64 = 10_000

/// One frame, as the origin saw it.
private struct SeenFrame {
    var type: UInt8
    var flags: UInt8
    var streamID: UInt32
    var payload: [UInt8]
}

/// An HTTP/2 origin the test owns, on a port the kernel chose.
private final class FakeH2Origin {
    let fd: Int32
    let port: UInt16
    /// Frames received, in order, after the preface.
    private(set) var frames: [SeenFrame] = []
    /// The request's decoded header fields, once its HEADERS block arrived.
    private(set) var requestFields: [(String, String)] = []
    /// Request DATA, reassembled.
    private(set) var requestBody: [UInt8] = []
    private(set) var accepted = 0
    private(set) var sawPreface = false
    /// Replies to send once the request's headers have arrived, in order.
    var script: [[UInt8]] = []
    /// Sends the scripted reply one frame per pump rather than all at once, so
    /// the client has to come back for the rest.
    var dribble = false
    /// Returns flow-control credit as upload DATA arrives, which is what lets
    /// a body larger than the initial window finish.
    var credit = false
    /// Returns stream credit but never connection credit, which tells a client
    /// that debits both windows from one counter apart from one that does not.
    var creditStreamOnly = false
    /// Grants one large lump of credit on the first DATA frame instead of
    /// matching each frame's size.
    ///
    /// Crediting in lockstep with consumption -- what `credit` does -- keeps
    /// the window as the binding constraint forever, so the frame size never
    /// gets to be the limit and an applied SETTINGS_MAX_FRAME_SIZE cannot show
    /// itself. Real servers grant in lumps. This is the only arrangement in
    /// which that setting is observable at all.
    var creditInLump = 0
    /// Sends SETTINGS before anything else and waits for the ack, so a setting
    /// is in force before the client starts sending a body.
    var settingsFirst = false
    /// The frame size to advertise when `settingsFirst` is on.
    var peerMaxFrameSize: UInt32 = 16384
    private var announced = false
    private var open: [Int32] = []
    private var inbox: [Int32: [UInt8]] = [:]
    private var answered = false
    private var pending: [[UInt8]] = []
    private var decoder = HPACKDecoder()
    private var block: [UInt8] = []

    init?() {
        let opened = "127.0.0.1".withCString { pg_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = pg_local_port(opened)
        guard got != 0 else { _ = pg_close(opened); return nil }
        fd = opened
        port = got
    }

    deinit {
        decoder.destroy()
        for peer in open { _ = pg_close(peer) }
        _ = pg_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func pump() {
        // Whatever was owed from last time goes first.
        if !pending.isEmpty, let peer = open.first {
            let next = pending.removeFirst()
            _ = next.withUnsafeBytes { pg_write(peer, $0.baseAddress, $0.count) }
        }

        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = pg_accept(fd, &address, 64, &peerPort)
        if peer >= 0 {
            open.append(peer)
            accepted += 1
        }

        // Announced the moment a peer arrives, not in reply to anything. A
        // setting only binds what has not been sent yet, so one that arrives
        // after the client has begun its body proves nothing about whether it
        // was honoured.
        if settingsFirst, !announced, let peer = open.first {
            announced = true
            var out = ByteBuffer(capacity: 32)
            defer { out.destroy() }
            H2FrameHeader(length: 6, type: .settings, flags: [], streamID: 0)
                .write(into: &out)
            out.writeByte(0x00)
            out.writeByte(UInt8(H2Setting.maxFrameSize.rawValue))
            HTTP2.writeUInt32(peerMaxFrameSize, into: &out)
            write(peer, out)
        }

        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { raw in
                pg_read(peer, raw.baseAddress, raw.count)
            }
            if got > 0 {
                inbox[peer, default: []].append(contentsOf: buffer.prefix(got))
            }
            consume(peer)
        }
    }

    /// Takes the preface and then whole frames out of what has arrived.
    private func consume(_ peer: Int32) {
        var have = inbox[peer] ?? []
        if !sawPreface {
            guard have.count >= HTTP2.preface.count else { inbox[peer] = have; return }
            sawPreface = Array(have.prefix(HTTP2.preface.count)) == HTTP2.preface
            have.removeFirst(HTTP2.preface.count)
        }
        while have.count >= H2FrameHeader.size {
            let header = have.withUnsafeBufferPointer { H2FrameHeader.parse($0.baseAddress!) }
            guard have.count >= H2FrameHeader.size + header.length else { break }
            let payload = Array(have[H2FrameHeader.size..<(H2FrameHeader.size + header.length)])
            have.removeFirst(H2FrameHeader.size + header.length)
            frames.append(SeenFrame(type: header.type, flags: header.flags.rawValue,
                                    streamID: header.streamID, payload: payload))
            handle(peer, header, payload)
        }
        inbox[peer] = have
    }

    private func handle(_ peer: Int32, _ header: H2FrameHeader, _ payload: [UInt8]) {
        switch H2FrameType(rawValue: header.type) {
        case .settings:
            if header.flags.rawValue & H2Flags.ack.rawValue == 0 {
                // Ack it, as a server must.
                var out = ByteBuffer(capacity: 16)
                defer { out.destroy() }
                H2FrameHeader(length: 0, type: .settings, flags: .ack, streamID: 0)
                    .write(into: &out)
                write(peer, out)
            }
        case .headers, .continuation:
            block.append(contentsOf: payload)
            if header.flags.rawValue & H2Flags.endHeaders.rawValue != 0 {
                decodeBlock()
                block.removeAll()
                if header.flags.rawValue & H2Flags.endStream.rawValue != 0 { answer(peer) }
            }
        case .data:
            requestBody.append(contentsOf: payload)
            if header.flags.rawValue & H2Flags.endStream.rawValue != 0 {
                answer(peer)
            } else if credit {
                // What a real server does as it consumes an upload: give the
                // window back, at both levels, or the client stops at 65535
                // bytes and waits for something that is never coming.
                var out = ByteBuffer(capacity: 64)
                defer { out.destroy() }
                H2FrameHeader(length: 4, type: .windowUpdate, flags: [], streamID: 0)
                    .write(into: &out)
                HTTP2.writeUInt32(UInt32(payload.count), into: &out)
                H2FrameHeader(length: 4, type: .windowUpdate, flags: [],
                              streamID: header.streamID).write(into: &out)
                HTTP2.writeUInt32(UInt32(payload.count), into: &out)
                write(peer, out)
            } else if creditInLump > 0 {
                // Once, and generously, so that after the stall the window is
                // wide and the agreed frame size is what caps a frame.
                let lump = creditInLump
                creditInLump = 0
                var out = ByteBuffer(capacity: 64)
                defer { out.destroy() }
                H2FrameHeader(length: 4, type: .windowUpdate, flags: [], streamID: 0)
                    .write(into: &out)
                HTTP2.writeUInt32(UInt32(lump), into: &out)
                H2FrameHeader(length: 4, type: .windowUpdate, flags: [],
                              streamID: header.streamID).write(into: &out)
                HTTP2.writeUInt32(UInt32(lump), into: &out)
                write(peer, out)
            } else if creditStreamOnly {
                // Stream credit only. A client that keeps one counter for both
                // windows reads this as permission to carry on, and overruns
                // the connection allowance it was never given.
                var out = ByteBuffer(capacity: 32)
                defer { out.destroy() }
                H2FrameHeader(length: 4, type: .windowUpdate, flags: [],
                              streamID: header.streamID).write(into: &out)
                HTTP2.writeUInt32(UInt32(payload.count), into: &out)
                write(peer, out)
            }
        default:
            break
        }
    }

    private func decodeBlock() {
        let bytes = block
        try? bytes.withUnsafeBufferPointer { buf in
            try decoder.decode(buf.baseAddress!, buf.count) { span in
                let name = String(decoding: UnsafeBufferPointer(start: span.name,
                                                                count: span.nameLength),
                                  as: UTF8.self)
                let value = String(decoding: UnsafeBufferPointer(start: span.value,
                                                                 count: span.valueLength),
                                   as: UTF8.self)
                self.requestFields.append((name, value))
            }
        }
    }

    private func answer(_ peer: Int32) {
        guard !answered else { return }
        answered = true
        guard !script.isEmpty else { return }
        if dribble {
            pending = script
        } else {
            for reply in script {
                _ = reply.withUnsafeBytes { pg_write(peer, $0.baseAddress, $0.count) }
            }
        }
    }

    private func write(_ peer: Int32, _ buffer: ByteBuffer) {
        _ = pg_write(peer, buffer.readPointer, buffer.readableBytes)
    }

    /// The field a request carried, compared without case.
    func requestField(_ name: String) -> String? {
        for (n, v) in requestFields where n == name { return v }
        return nil
    }

    func frames(ofType type: H2FrameType) -> [SeenFrame] {
        frames.filter { $0.type == type.rawValue }
    }
}

// MARK: Building reply frames

/// A HEADERS frame carrying `:status` and `fields`, HPACK-encoded.
private func responseHeaders(status: Int, fields: [(String, String)] = [],
                             stream: UInt32 = 1, endStream: Bool = false,
                             endHeaders: Bool = true) -> [UInt8] {
    var block = ByteBuffer(capacity: 256)
    defer { block.destroy() }
    let encoder = HPACKEncoder()
    encoder.encodeStatus(status, into: &block)
    for (name, value) in fields {
        let n = Array(name.utf8), v = Array(value.utf8)
        n.withUnsafeBufferPointer { np in
            v.withUnsafeBufferPointer { vp in
                encoder.encode(name: np.baseAddress!, nameLength: np.count,
                               value: vp.baseAddress!, valueLength: vp.count, into: &block)
            }
        }
    }
    var flags: H2Flags = []
    if endHeaders { flags.insert(.endHeaders) }
    if endStream { flags.insert(.endStream) }
    var out = ByteBuffer(capacity: 512)
    defer { out.destroy() }
    H2FrameHeader(length: block.readableBytes, type: .headers, flags: flags,
                  streamID: stream).write(into: &out)
    out.write(block.readPointer, block.readableBytes)
    return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
}

private func dataFrame(_ text: String, stream: UInt32 = 1, endStream: Bool = true) -> [UInt8] {
    let payload = Array(text.utf8)
    var out = ByteBuffer(capacity: payload.count + 16)
    defer { out.destroy() }
    H2FrameHeader(length: payload.count, type: .data,
                  flags: endStream ? .endStream : [], streamID: stream).write(into: &out)
    payload.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
    return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
}

private func rawFrame(type: H2FrameType, flags: H2Flags = [], stream: UInt32 = 1,
                      payload: [UInt8] = []) -> [UInt8] {
    var out = ByteBuffer(capacity: payload.count + 16)
    defer { out.destroy() }
    H2FrameHeader(length: payload.count, type: type, flags: flags,
                  streamID: stream).write(into: &out)
    if !payload.isEmpty { payload.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) } }
    return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
}

private func u32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

// MARK: The application under test

private func h2ClientApp() -> Application {
    let app = Application()
    // Plaintext, with the h2 path forced. ALPN is what chooses in production
    // and needs TLS; this exercises the frame loop without one, which is the
    // only way to test framing without also testing OpenSSL.
    app.onAsync(.get, "/fetch") { request, response in
        var client = request.client
        client.maxBodyBytes = bodyLimitWanted
        client.forceHTTP2 = true
        do {
            let answer = try await client.get(urlWanted, headers: headersWanted)
            outcome = "\(answer.status)|\(answer.text)|\(answer.reusedConnection)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/post") { request, response in
        var client = request.client
        client.forceHTTP2 = true
        client.timeoutMilliseconds = timeoutWanted
        do {
            let answer = try await client.post(urlWanted, body: bodyWanted,
                                               contentType: "text/plain")
            outcome = "\(answer.status)|\(answer.text)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/header") { request, response in
        var client = request.client
        client.forceHTTP2 = true
        do {
            let answer = try await client.get(urlWanted, headers: headersWanted)
            outcome = answer.header("x-thing") ?? "absent"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/head") { request, response in
        var client = request.client
        client.forceHTTP2 = true
        do {
            let answer = try await client.head(urlWanted)
            outcome = "\(answer.status)|\(answer.body.count)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    return app
}

@Suite("HTTP/2 client", .serialized)
struct HTTP2ClientTests {

    private func run(_ route: String, _ origin: FakeH2Origin,
                     path: String = "/x", turns: Int = 20_000) throws -> String {
        outcome = ""
        urlWanted = origin.url + path
        let client = h2ClientApp().test
        let wire = try TestWire(client)
        wire.send("GET \(route) HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            origin.pump()
            return !outcome.isEmpty
        }, turns: turns)
        _ = wire.receive()
        return outcome
    }

    private func reset() {
        outcome = ""
        headersWanted = []
        bodyWanted = []
        bodyLimitWanted = 8 * 1024 * 1024
    }

    // MARK: An ordinary exchange

    @Test func anOrdinaryResponseComesBack() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200), dataFrame("hello")]
        // Never pooled: one exchange per connection while the dynamic table
        // cannot be carried between them.
        #expect(try run("/fetch", origin) == "200|hello|false")
    }

    @Test func anHTTP2ConnectionIsClosedRatherThanPooled() throws {
        // reusedConnection being false is what the client *reports*; this is
        // what actually happened to the socket. Pooling one would send a
        // second preface down a live connection and desynchronise the HPACK
        // dynamic table -- and the report alone cannot tell the two apart,
        // which is why the flag is not enough.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200), dataFrame("hello")]
        outcome = ""
        urlWanted = origin.url + "/x"
        let client = h2ClientApp().test
        let wire = try TestWire(client)
        wire.send("GET /fetch HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 20_000)
        _ = wire.receive()
        #expect(outcome == "200|hello|false")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    @Test func theConnectionOpensWithThePrefaceAndSettings() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, endStream: true)]
        _ = try run("/fetch", origin)
        #expect(origin.sawPreface)
        // SETTINGS must be the first frame after it.
        #expect(origin.frames.first?.type == H2FrameType.settings.rawValue)
    }

    @Test func theRequestCarriesThePseudoHeadersAServerNeeds() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, endStream: true)]
        _ = try run("/fetch", origin, path: "/a/b?c=d")
        #expect(origin.requestField(":method") == "GET")
        #expect(origin.requestField(":scheme") == "http")
        #expect(origin.requestField(":path") == "/a/b?c=d")
        #expect(origin.requestField(":authority") == "127.0.0.1:\(origin.port)")
    }

    @Test func theRequestOpensAnOddStream() throws {
        // RFC 9113 section 5.1.1: a client's streams are odd, and the first is
        // 1. An even one would be a stream the server is entitled to own.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, endStream: true)]
        _ = try run("/fetch", origin)
        let headers = origin.frames(ofType: .headers)
        #expect(headers.count == 1)
        #expect(headers.first?.streamID == 1)
    }

    @Test func aUserAgentIsSentLowercased() throws {
        // HTTP/2 field names must be lowercase, and an uppercase one makes the
        // message malformed rather than merely unusual.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, endStream: true)]
        _ = try run("/fetch", origin)
        #expect(origin.requestField("user-agent") == "garuda")
    }

    @Test func aResponseHeaderIsReadOut() throws {
        // Asserting the value, not just the status: a decoder that dropped
        // every ordinary field would have satisfied the status check, and the
        // pseudo-header filter is one `:` away from discarding everything.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("x-thing", "here")],
                                         endStream: true)]
        #expect(try run("/header", origin) == "here")
    }

    @Test func aPostSendsItsBodyAsData() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        bodyWanted = Array("name=value".utf8)
        origin.script = [responseHeaders(status: 201), dataFrame("ok")]
        #expect(try run("/post", origin) == "201|ok")
        #expect(origin.requestField(":method") == "POST")
        #expect(String(decoding: origin.requestBody, as: UTF8.self) == "name=value")
        // HTTP/2 has no Transfer-Encoding, so a length is stated as a field.
        #expect(origin.requestField("content-length") == "10")
    }

    @Test func aHeadResponseCarriesNoBody() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "1024")],
                                         endStream: true)]
        #expect(try run("/head", origin) == "200|0")
    }

    @Test func aBodyArrivingInSeveralFramesIsReassembled() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [responseHeaders(status: 200),
                         dataFrame("hello ", endStream: false),
                         dataFrame("world")]
        #expect(try run("/fetch", origin) == "200|hello world|false")
    }

    @Test func anInformationalResponseIsNotMistakenForTheAnswer() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [responseHeaders(status: 103),
                         responseHeaders(status: 200),
                         dataFrame("done")]
        #expect(try run("/fetch", origin) == "200|done|false")
    }

    @Test func anInformationalResponseIsNotAnAnswerEvenWhenNoneFollows() throws {
        // The test above cannot see the 1xx skip being removed, and two
        // attempts at this missed it too. The reason is that a decoded block
        // replaces the fields and the status wholesale, so whenever a real
        // response follows, it repairs the damage the missing skip did --
        // every assertion about the answer holds either way.
        //
        // So the case has to be one where nothing final follows. A 103 and
        // then a body is a malformed response, and the two readings of it
        // differ visibly: skipping the 103 leaves no status at all, which is
        // `closed`, while treating it as the answer returns 103 and the body.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [responseHeaders(status: 103), dataFrame("x")]
        #expect(try run("/fetch", origin) == "closed")
    }

    // MARK: Framing the peer gets wrong

    @Test func aFrameLongerThanWasAgreedIsRefused() throws {
        // Bounded before a byte of it is waited for: reading it to find out
        // would be doing what it asked.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        var frame = rawFrame(type: .data, stream: 1)
        // Claim a length past the 16384 this client advertised.
        frame[0] = 0x01; frame[1] = 0x00; frame[2] = 0x00
        origin.script = [responseHeaders(status: 200), frame]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aHeaderBlockInterleavedWithAnotherFrameIsRefused() throws {
        // A block split across CONTINUATION may not have anything between its
        // parts, RFC 9113 section 6.10. A client that allowed it would be
        // assembling a block whose provenance it cannot vouch for: the bytes
        // either side of the intruder need not have come from the same
        // response at all.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        // HEADERS without END_HEADERS, then DATA where CONTINUATION belongs.
        origin.script = [responseHeaders(status: 200, endHeaders: false),
                         dataFrame("intruder", endStream: false),
                         rawFrame(type: .continuation, flags: .endHeaders, stream: 1)]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aStatusThatIsNotThreeDigitsIsRefused() throws {
        // :status is exactly three digits. Two would parse as a plausible
        // number and four would parse as a different one, and either way the
        // caller would be handed a status the peer never sent.
        reset()
        for text in ["20", "2000", "", "abc"] {
            guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
            var block = ByteBuffer(capacity: 64)
            defer { block.destroy() }
            let encoder = HPACKEncoder()
            let name = Array(":status".utf8), value = Array(text.utf8)
            name.withUnsafeBufferPointer { n in
                value.withUnsafeBufferPointer { v in
                    encoder.encode(name: n.baseAddress!, nameLength: n.count,
                                   value: value.isEmpty ? n.baseAddress! : v.baseAddress!,
                                   valueLength: value.count, into: &block)
                }
            }
            var out = ByteBuffer(capacity: 128)
            defer { out.destroy() }
            H2FrameHeader(length: block.readableBytes, type: .headers,
                          flags: [.endHeaders, .endStream], streamID: 1).write(into: &out)
            out.write(block.readPointer, block.readableBytes)
            origin.script = [Array(UnsafeBufferPointer(start: out.readPointer,
                                                       count: out.readableBytes))]
            #expect(try run("/fetch", origin).hasPrefix("malformedResponse"),
                    "a :status of \"\(text)\" should be refused")
        }
    }

    @Test func aPushPromiseIsRefusedBecausePushWasDeclined() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [rawFrame(type: .pushPromise, stream: 1, payload: u32(2))]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aResetStreamIsReported() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [rawFrame(type: .rstStream, stream: 1,
                                  payload: u32(H2Error.refusedStream.rawValue))]
        #expect(try run("/fetch", origin).hasPrefix("streamReset"))
    }

    @Test func aResponseWithoutAStatusIsMalformed() throws {
        // RFC 9113 section 8.3.2. Guessing 200 would hand the caller a success
        // the peer never claimed.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        var block = ByteBuffer(capacity: 64)
        defer { block.destroy() }
        let encoder = HPACKEncoder()
        let name = Array("x-thing".utf8), value = Array("here".utf8)
        name.withUnsafeBufferPointer { n in
            value.withUnsafeBufferPointer { v in
                encoder.encode(name: n.baseAddress!, nameLength: n.count,
                               value: v.baseAddress!, valueLength: v.count, into: &block)
            }
        }
        var out = ByteBuffer(capacity: 128)
        defer { out.destroy() }
        H2FrameHeader(length: block.readableBytes, type: .headers,
                      flags: [.endHeaders, .endStream], streamID: 1).write(into: &out)
        out.write(block.readPointer, block.readableBytes)
        origin.script = [Array(UnsafeBufferPointer(start: out.readPointer,
                                                   count: out.readableBytes))]
        #expect(try run("/fetch", origin).hasPrefix("malformedResponse"))
    }

    @Test func aPingIsAnswered() throws {
        // A server that pings and gets nothing back is entitled to conclude
        // the connection is dead and close it.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [rawFrame(type: .ping, stream: 0, payload: [1, 2, 3, 4, 5, 6, 7, 8]),
                         responseHeaders(status: 200, endStream: true)]
        #expect(try run("/fetch", origin) == "200||false")
        let pongs = origin.frames(ofType: .ping).filter {
            $0.flags & H2Flags.ack.rawValue != 0
        }
        #expect(pongs.count == 1)
        #expect(pongs.first?.payload == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func peerSettingsAreAcknowledged() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        var settings = u32(0)
        settings.removeAll()
        settings.append(contentsOf: [0x00, 0x05])          // maxFrameSize
        settings.append(contentsOf: u32(32768))
        origin.script = [rawFrame(type: .settings, stream: 0, payload: settings),
                         responseHeaders(status: 200, endStream: true)]
        #expect(try run("/fetch", origin) == "200||false")
        let acks = origin.frames(ofType: .settings).filter {
            $0.flags & H2Flags.ack.rawValue != 0
        }
        #expect(acks.count == 1)
    }

    @Test func aBodyLargerThanTheLimitIsRefused() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        bodyLimitWanted = 4
        origin.script = [responseHeaders(status: 200), dataFrame("far too much")]
        #expect(try run("/fetch", origin) == "bodyTooLarge")
    }

    @Test func aConnectionSpecificHeaderIsRefused() throws {
        // RFC 9113 section 8.2.2: these describe a connection rather than a
        // message and have no meaning in HTTP/2. Sending one makes the request
        // malformed at the far end.
        //
        // `upgrade` rather than `Connection`, deliberately. The h1 writer
        // already owns Connection, Host, Content-Length and Transfer-Encoding
        // and refuses them while the head is built -- which is before this
        // branches to HTTP/2 at all. So a test using one of those would pass
        // without the h2 check existing, and would be testing the wrong
        // refusal. These four names are the ones only HTTP/2 objects to.
        reset()
        for name in ["Upgrade", "TE", "Proxy-Connection", "Keep-Alive"] {
            guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
            headersWanted = [(name, "x")]
            origin.script = [responseHeaders(status: 200, endStream: true)]
            #expect(try run("/fetch", origin) == "refusedHeader", "\(name) should be refused")
        }
    }

    // MARK: Flow control

    /// A body larger than the initial window, which is the only way to reach
    /// the path that waits for credit.
    ///
    /// The client sends its preface, settings, headers and first DATA before
    /// reading anything, so the peer's initial window is still the default
    /// 65535 when the body starts. Under that, nothing ever blocks and this
    /// whole path is dead code; over it, the request stops halfway unless the
    /// credit a server returns is read and spent correctly.
    @Test func aBodyLargerThanTheWindowFinishesAsCreditArrives() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.credit = true
        bodyWanted = Array(repeating: UInt8(ascii: "x"), count: 70_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        #expect(try run("/post", origin, turns: 200_000) == "200|ok")
        #expect(origin.requestBody.count == 70_000)
    }

    @Test func aPeerFrameSizeSettingIsAppliedAndNotMerelyAcknowledged() throws {
        // Acknowledging a setting and honouring it are different things, and
        // the ack test cannot tell them apart: a peer that asks for 1024-byte
        // frames and gets 16384-byte ones is entitled to kill the connection.
        //
        // The timing is the whole difficulty. A client may send as soon as it
        // has written the preface, so it cannot honour a setting it has not
        // read -- the first frames going out at 16384 is correct, not a bug.
        // The setting only binds what comes after it is read, and the one
        // moment this client reads anything mid-send is when the window shuts.
        // So the body has to be larger than the initial window, and the
        // frames after the stall are the ones that must have shrunk.
        // It has to grow rather than shrink, which took a failing test to
        // notice: RFC 9113 puts SETTINGS_MAX_FRAME_SIZE between 16384 and
        // 16777215, and 16384 is also the default -- so no legal value is
        // smaller than what this already uses, and a frame getting smaller
        // could never be the evidence. A frame larger than the default is
        // something only an applied setting can produce.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        // Credit in one lump rather than per frame. It took a frame-by-frame
        // census to see why that matters: crediting exactly what each frame
        // spent keeps the window as the binding constraint for the whole
        // upload, so `min(n, sendWindow)` caps every frame at what was just
        // returned and the frame size never gets to be the limit. Three
        // stalls, an applied setting, and still every frame at 16384.
        origin.creditInLump = 300_000
        origin.settingsFirst = true
        origin.peerMaxFrameSize = 32768
        bodyWanted = Array(repeating: UInt8(ascii: "z"), count: 200_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        #expect(try run("/post", origin, turns: 400_000) == "200|ok")
        #expect(origin.requestBody.count == 200_000)
        let data = origin.frames(ofType: .data)
        // The first frames go at the 16384 default, correctly: a client may
        // send before it has read anything. The ones after the window stalled
        // are where the setting can show.
        #expect(data.contains { $0.payload.count > 16384 },
                "no frame exceeded the default, so the setting was not applied")
        #expect(data.allSatisfy { $0.payload.count <= 32768 })
    }

    @Test func aFrameSizeSettingBelowWhatRFC9113AllowsIsRefused() throws {
        // 16384 is the floor every implementation must accept. A peer
        // advertising less has broken the protocol, and honouring it would
        // mean sending frames it then has every right to reject.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.settingsFirst = true
        origin.peerMaxFrameSize = 1024
        origin.script = [responseHeaders(status: 200, endStream: true)]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aConnectionWindowIsSpentSeparatelyFromTheStreams() throws {
        // The two windows are debited separately, and a client that spent only
        // the stream's would keep sending past the connection's allowance --
        // which the peer answers with a connection-level flow-control error,
        // killing every stream on it rather than this one.
        //
        // The peer grants stream credit generously and connection credit not
        // at all, so a client crediting both from one counter runs past what
        // it was given.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.creditStreamOnly = true
        // Proving something never arrives means waiting for it, so this waits
        // briefly rather than the production ten seconds.
        timeoutWanted = 300
        defer { timeoutWanted = 10_000 }
        bodyWanted = Array(repeating: UInt8(ascii: "w"), count: 70_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        // It cannot finish: the connection window is never topped up, so the
        // upload stops at 65535 bytes and the request times out rather than
        // overrunning what the peer allowed.
        let text = try run("/post", origin, turns: 40_000)
        #expect(text == "timedOut" || text.isEmpty, "got \(text)")
        #expect(origin.requestBody.count <= 65_535)
    }

    @Test func aLargeBodyIsSplitToTheAgreedFrameSize() throws {
        // 16384 is what every implementation must accept and what this
        // advertises. A frame past it is one the peer never agreed to read.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.credit = true
        bodyWanted = Array(repeating: UInt8(ascii: "y"), count: 70_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        #expect(try run("/post", origin, turns: 200_000) == "200|ok")
        let data = origin.frames(ofType: .data)
        #expect(data.count >= 5)
        #expect(data.allSatisfy { $0.payload.count <= 16384 })
    }
}

import Testing
import CAvian
import AvianCore
import AvianHTTP
@testable import Garuda

// Tests for HTTP/2 over connections the worker made.
//
// The origin here speaks frames rather than text: it reads the client preface,
// takes the SETTINGS that follow it, decodes each request's header block with a
// real HPACK decoder -- one per connection, since HPACK is per connection --
// and answers with encoded blocks of its own. A fake that matched bytes would
// prove nothing about whether a server can read what this client writes, which
// is the only question worth asking of a protocol implementation.
//
// Both ends are on this thread, so the origin is pumped once per turn of the
// worker and never blocks.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var urlWanted = ""
nonisolated(unsafe) private var headersWanted: [(String, String)] = []
nonisolated(unsafe) private var bodyWanted: [UInt8] = []
nonisolated(unsafe) private var bodyLimitWanted = 8 * 1024 * 1024
nonisolated(unsafe) private var headLimitWanted = 32 * 1024
/// A body limit per concurrent route, where the test needs two requests in
/// flight whose limits differ.
nonisolated(unsafe) private var bodyLimitsWanted: [String: Int] = [:]
/// How long the client under test should wait on any one read or write. Short
/// for the tests that prove something never arrives: the default ten seconds
/// is the right answer in production and a tax on a suite that runs in
/// tenths of a second.
nonisolated(unsafe) private var timeoutWanted: UInt64 = 10_000
/// Holds `/stream-gated` from reading until the test sets it.
nonisolated(unsafe) private var gateOpen = false
/// What each of several concurrent requests saw, by the name of its route.
nonisolated(unsafe) private var outcomes: [String: String] = [:]
nonisolated(unsafe) private var originURL = ""
/// A timeout for one of the concurrent routes, where the test needs requests
/// with different patience in flight at once.
nonisolated(unsafe) private var timeoutsWanted: [String: UInt64] = [:]

/// One frame, as the origin saw it.
private struct SeenFrame {
    var peer: Int
    var type: UInt8
    var flags: UInt8
    var streamID: UInt32
    var payload: [UInt8]
}

/// A request the origin has read in full.
private struct OriginRequest {
    var peer: Int
    var stream: UInt32
    var fields: [(String, String)]
    var body: [UInt8]

    func field(_ name: String) -> String? {
        for (n, v) in fields where n == name { return v }
        return nil
    }

    var path: String { field(":path") ?? "" }
}

/// One connection the origin accepted, and the state HTTP/2 keeps for it.
private final class OriginPeer {
    let fd: Int32
    var inbox: [UInt8] = []
    var sawPreface = false
    var decoder = HPACKDecoder()
    var block: [UInt8] = []
    var headerStream: UInt32 = 0
    var headerEndsStream = false
    var fields: [UInt32: [(String, String)]] = [:]
    var bodies: [UInt32: [UInt8]] = [:]
    var pending: [[UInt8]] = []
    var closed = false

    init(_ fd: Int32) { self.fd = fd }

    deinit {
        decoder.destroy()
        if !closed { _ = av_close(fd) }
    }
}

/// An HTTP/2 origin the test owns, on a port the kernel chose.
private final class FakeH2Origin {
    let fd: Int32
    let port: UInt16
    private(set) var peers: [OriginPeer] = []
    /// Frames received from every connection, in order, after each preface.
    private(set) var frames: [SeenFrame] = []
    /// Requests read in full, in the order they finished arriving.
    private(set) var requests: [OriginRequest] = []
    /// Every DATA byte received, whether or not its request ever finished.
    private(set) var requestBody: [UInt8] = []
    private(set) var accepted = 0
    /// Requests read and deliberately not answered, while `hold` is on.
    private(set) var held: [OriginRequest] = []

    /// Frames for the first request, when nothing more specific is set.
    var script: [[UInt8]] = []
    private var scriptUsed = false
    /// Frames for every request, built for it.
    var respond: ((OriginRequest) -> [[UInt8]])? = nil
    /// Keeps finished requests unanswered until the test says, so a test can
    /// arrange what is in flight at once and answer it in any order.
    var hold = false
    /// Sends replies one frame per pump rather than all at once, so the client
    /// has to come back for the rest.
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
    /// On the first upload DATA, raises SETTINGS_INITIAL_WINDOW_SIZE to this
    /// and grants connection credit only -- so the one thing that can let the
    /// stream carry on is the new initial window being applied to a stream
    /// that is already open.
    var raiseInitialWindowTo: UInt32 = 0
    /// Settings announced to every connection the moment it is accepted, not
    /// in reply to anything. A setting only binds what has not been sent yet,
    /// so one that arrives late proves nothing about whether it was honoured.
    var announce: [(H2Setting, UInt32)] = []
    /// Shorthand for announcing SETTINGS_MAX_FRAME_SIZE, kept for the tests
    /// written before `announce`.
    var settingsFirst = false
    var peerMaxFrameSize: UInt32 = 16384

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = av_local_port(opened)
        guard got != 0 else { _ = av_close(opened); return nil }
        fd = opened
        port = got
    }

    deinit {
        peers.removeAll()
        _ = av_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }
    var sawPreface: Bool { peers.contains { $0.sawPreface } }
    /// The most recent request's fields, for the tests about one request.
    var requestFields: [(String, String)] { requests.last?.fields ?? [] }

    func pump() {
        // Whatever was owed from last time goes first, one frame per
        // connection per pump.
        for peer in peers where !peer.closed && !peer.pending.isEmpty {
            let next = peer.pending.removeFirst()
            _ = next.withUnsafeBytes { av_write(peer.fd, $0.baseAddress, $0.count) }
        }

        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let accepted = av_accept(fd, &address, 64, &peerPort)
        if accepted >= 0 {
            let peer = OriginPeer(accepted)
            peers.append(peer)
            self.accepted += 1
            var settings = announce
            if settingsFirst { settings.append((.maxFrameSize, peerMaxFrameSize)) }
            if !settings.isEmpty {
                var payload: [UInt8] = []
                for (setting, value) in settings {
                    payload.append(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
                    payload.append(UInt8(truncatingIfNeeded: setting.rawValue))
                    payload.append(contentsOf: u32(value))
                }
                let frame = rawFrame(type: .settings, stream: 0, payload: payload)
                _ = frame.withUnsafeBytes { av_write(peer.fd, $0.baseAddress, $0.count) }
            }
        }

        for index in peers.indices where !peers[index].closed {
            let peer = peers[index]
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { raw in
                av_read(peer.fd, raw.baseAddress, raw.count)
            }
            if got > 0 { peer.inbox.append(contentsOf: buffer.prefix(got)) }
            consume(index)
        }
    }

    /// Takes the preface and then whole frames out of what has arrived.
    private func consume(_ index: Int) {
        let peer = peers[index]
        if !peer.sawPreface {
            guard peer.inbox.count >= HTTP2.preface.count else { return }
            peer.sawPreface = Array(peer.inbox.prefix(HTTP2.preface.count)) == HTTP2.preface
            peer.inbox.removeFirst(HTTP2.preface.count)
        }
        while peer.inbox.count >= H2FrameHeader.size {
            let header = peer.inbox.withUnsafeBufferPointer { H2FrameHeader.parse($0.baseAddress!) }
            guard peer.inbox.count >= H2FrameHeader.size + header.length else { break }
            let payload = Array(peer.inbox[H2FrameHeader.size..<(H2FrameHeader.size + header.length)])
            peer.inbox.removeFirst(H2FrameHeader.size + header.length)
            frames.append(SeenFrame(peer: index, type: header.type, flags: header.flags.rawValue,
                                    streamID: header.streamID, payload: payload))
            handle(index, header, payload)
        }
    }

    private func handle(_ index: Int, _ header: H2FrameHeader, _ payload: [UInt8]) {
        let peer = peers[index]
        switch H2FrameType(rawValue: header.type) {
        case .settings:
            if header.flags.rawValue & H2Flags.ack.rawValue == 0 {
                write(peer, rawFrame(type: .settings, flags: .ack, stream: 0))
            }
        case .headers, .continuation:
            if header.type == H2FrameType.headers.rawValue {
                peer.headerStream = header.streamID
                peer.headerEndsStream = header.flags.rawValue & H2Flags.endStream.rawValue != 0
                peer.block = payload
            } else {
                peer.block.append(contentsOf: payload)
            }
            if header.flags.rawValue & H2Flags.endHeaders.rawValue != 0 {
                peer.fields[peer.headerStream] = decode(peer)
                peer.block.removeAll()
                if peer.headerEndsStream { complete(index, peer.headerStream) }
            }
        case .data:
            requestBody.append(contentsOf: payload)
            peer.bodies[header.streamID, default: []].append(contentsOf: payload)
            if header.flags.rawValue & H2Flags.endStream.rawValue != 0 {
                complete(index, header.streamID)
            } else if credit {
                // What a real server does as it consumes an upload: give the
                // window back, at both levels, or the client stops at 65535
                // bytes and waits for something that is never coming.
                write(peer, windowUpdate(0, payload.count) + windowUpdate(header.streamID,
                                                                          payload.count))
            } else if creditInLump > 0 {
                // Once, and generously, so that after the stall the window is
                // wide and the agreed frame size is what caps a frame.
                let lump = creditInLump
                creditInLump = 0
                write(peer, windowUpdate(0, lump) + windowUpdate(header.streamID, lump))
            } else if raiseInitialWindowTo > 0 {
                let raised = raiseInitialWindowTo
                raiseInitialWindowTo = 0
                let settings: [UInt8] = [0x00, UInt8(H2Setting.initialWindowSize.rawValue)]
                    + u32(raised)
                write(peer, rawFrame(type: .settings, stream: 0, payload: settings)
                    + windowUpdate(0, 1_000_000))
            } else if creditStreamOnly {
                // Stream credit only. A client that keeps one counter for both
                // windows reads this as permission to carry on, and overruns
                // the connection allowance it was never given.
                write(peer, windowUpdate(header.streamID, payload.count))
            }
        default:
            break
        }
    }

    private func decode(_ peer: OriginPeer) -> [(String, String)] {
        var fields: [(String, String)] = []
        let bytes = peer.block
        try? bytes.withUnsafeBufferPointer { buf in
            try peer.decoder.decode(buf.baseAddress!, buf.count) { span in
                fields.append((
                    String(decoding: UnsafeBufferPointer(start: span.name,
                                                         count: span.nameLength), as: UTF8.self),
                    String(decoding: UnsafeBufferPointer(start: span.value,
                                                         count: span.valueLength), as: UTF8.self)))
            }
        }
        return fields
    }

    private func complete(_ index: Int, _ stream: UInt32) {
        let peer = peers[index]
        let request = OriginRequest(peer: index, stream: stream,
                                    fields: peer.fields[stream] ?? [],
                                    body: peer.bodies[stream] ?? [])
        requests.append(request)
        if hold {
            held.append(request)
            return
        }
        if let respond {
            queue(index, respond(request))
        } else if !scriptUsed, !script.isEmpty {
            scriptUsed = true
            queue(index, script)
        }
    }

    /// Sends frames to one connection, honouring `dribble`.
    func queue(_ peer: Int, _ frames: [[UInt8]]) {
        guard peer < peers.count, !peers[peer].closed else { return }
        if dribble {
            peers[peer].pending.append(contentsOf: frames)
        } else {
            for frame in frames { write(peers[peer], frame) }
        }
    }

    /// Answers the held requests `pick` chooses, in the order they arrived.
    func answerHeld(_ pick: (OriginRequest) -> Bool,
                    _ frames: (OriginRequest) -> [[UInt8]]) {
        let chosen = held.filter(pick)
        held.removeAll(where: pick)
        for request in chosen { queue(request.peer, frames(request)) }
    }

    func forgetHeld() { held.removeAll() }

    /// Hangs up on one connection without a word.
    func closePeer(_ index: Int) {
        guard index < peers.count, !peers[index].closed else { return }
        peers[index].closed = true
        _ = av_close(peers[index].fd)
    }

    private func write(_ peer: OriginPeer, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { av_write(peer.fd, $0.baseAddress, $0.count) }
    }

    /// The field the most recent request carried.
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
    return rawFrame(type: .headers, flags: flags, stream: stream,
                    payload: Array(UnsafeBufferPointer(start: block.readPointer,
                                                       count: block.readableBytes)))
}

private func dataFrame(_ text: String, stream: UInt32 = 1, endStream: Bool = true) -> [UInt8] {
    rawFrame(type: .data, flags: endStream ? .endStream : [], stream: stream,
             payload: Array(text.utf8))
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

/// A header block as a HEADERS frame and as many CONTINUATION frames as it
/// needs, none larger than the default maximum frame size. One oversized frame
/// is a protocol error on its own, which would prove nothing about a head limit.
private func splitHeaders(_ whole: [UInt8], stream: UInt32 = 1,
                          endStream: Bool = false, chunk: Int = 16_384) -> [[UInt8]] {
    let block = Array(whole[H2FrameHeader.size...])
    var frames: [[UInt8]] = []
    var offset = 0
    while offset < block.count {
        let take = min(chunk, block.count - offset)
        let piece = Array(block[offset..<(offset + take)])
        var flags: H2Flags = []
        if offset + take == block.count { flags.insert(.endHeaders) }
        if frames.isEmpty {
            if endStream { flags.insert(.endStream) }
            frames.append(rawFrame(type: .headers, flags: flags, stream: stream, payload: piece))
        } else {
            frames.append(rawFrame(type: .continuation, flags: flags,
                                   stream: stream, payload: piece))
        }
        offset += take
    }
    return frames
}

private func windowUpdate(_ stream: UInt32, _ increment: Int) -> [UInt8] {
    rawFrame(type: .windowUpdate, stream: stream, payload: u32(UInt32(increment)))
}

private func goaway(lastStream: UInt32, code: UInt32 = 0) -> [UInt8] {
    rawFrame(type: .goaway, stream: 0, payload: u32(lastStream) + u32(code))
}

private func u32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

/// A response whose `x-thing: kept` field goes into the HPACK dynamic table
/// (`adding`) or is named only by its index there (not `adding`).
///
/// The second form decodes to anything at all only for a client whose table
/// still holds what the first put in -- which is to say, one that kept the
/// connection's HPACK state from one request to the next.
private func indexingResponse(stream: UInt32, adding: Bool, alsoRefer: Bool = false) -> [UInt8] {
    var block = ByteBuffer(capacity: 128)
    defer { block.destroy() }
    let encoder = HPACKEncoder()
    encoder.encodeStatus(200, into: &block)
    if adding {
        // Literal with incremental indexing, new name.
        hpackWriteInteger(0, prefixBits: 6, flags: 0x40, into: &block)
        let name = Array("x-thing".utf8), value = Array("kept".utf8)
        name.withUnsafeBufferPointer { encoder.encodeString($0.baseAddress!, $0.count, into: &block) }
        value.withUnsafeBufferPointer { encoder.encodeString($0.baseAddress!, $0.count, into: &block) }
    }
    if !adding || alsoRefer {
        // Indexed: 62 is the newest dynamic entry.
        hpackWriteInteger(62, prefixBits: 7, flags: 0x80, into: &block)
    }
    return rawFrame(type: .headers, flags: [.endHeaders, .endStream], stream: stream,
                    payload: Array(UnsafeBufferPointer(start: block.readPointer,
                                                       count: block.readableBytes)))
}

/// A frame of `type` with the PADDED flag, `padding` zero bytes after the
/// content, and the pad length in front of it.
private func padded(_ type: H2FrameType, flags: H2Flags, stream: UInt32,
                    content: [UInt8], padding: Int) -> [UInt8] {
    var payload: [UInt8] = [UInt8(padding)]
    payload.append(contentsOf: content)
    payload.append(contentsOf: [UInt8](repeating: 0, count: padding))
    return rawFrame(type: type, flags: flags.union(.padded), stream: stream, payload: payload)
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
        client.maxHeadBytes = headLimitWanted
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
    // Opens a stream and leaves it unread until the test opens the gate, then
    // reads it to the end: what a caller that is slower than its peer does.
    app.onAsync(.get, "/stream-gated") { request, response in
        var client = request.client
        client.forceHTTP2 = true
        do {
            let stream = try await client.stream(.get, urlWanted)
            while !gateOpen { try await response.sleep(milliseconds: 2) }
            var count = 0
            while let piece = try await stream.next() { count += piece.count }
            outcome = "\(stream.status)|\(count)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // Several routes that differ only in what they ask for, so a test can have
    // them in flight at once on one worker and tell their answers apart.
    // Reports the size of what came back rather than the body itself, for
    // bodies large enough to bury any failure message in.
    app.onAsync(.get, "/count") { request, response in
        var client = request.client
        client.forceHTTP2 = true
        client.timeoutMilliseconds = timeoutWanted
        do {
            let answer = try await client.get(urlWanted)
            outcome = "\(answer.status)|\(answer.body.count)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    for name in ["a", "b", "c"] {
        app.onAsync(.get, "/multi/\(name)") { request, response in
            var client = request.client
            client.forceHTTP2 = true
            client.timeoutMilliseconds = timeoutsWanted[name] ?? timeoutWanted
            if let limit = bodyLimitsWanted[name] { client.maxBodyBytes = limit }
            let result: String
            do {
                let answer = try await client.get(originURL + "/" + name)
                let thing = answer.header("x-thing").map { "|" + $0 } ?? ""
                result = "\(answer.status)|\(answer.text)\(thing)"
            } catch {
                result = "\(error)"
            }
            outcomes[name] = result
            response.send(result)
        }
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
        outcomes = [:]
        timeoutsWanted = [:]
        headersWanted = []
        bodyWanted = []
        bodyLimitWanted = 8 * 1024 * 1024
        headLimitWanted = 32 * 1024
        bodyLimitsWanted = [:]
        timeoutWanted = 10_000
    }

    /// Starts one request per route on `client`'s worker, which is what makes
    /// them share its connections.
    private func start(_ client: TestClient, _ routes: [String]) throws -> [TestWire] {
        try routes.map { route in
            let wire = try TestWire(client)
            wire.send("GET \(route) HTTP/1.1\r\nHost: test\r\n\r\n")
            return wire
        }
    }

    /// Turns the worker and pumps the origin until `ready`, or the turns run out.
    @discardableResult
    private func turn(_ client: TestClient, _ origin: FakeH2Origin, turns: Int = 20_000,
                      until ready: () -> Bool) -> Bool {
        for _ in 0..<turns {
            if ready() { return true }
            origin.pump()
            client.turn()
        }
        return ready()
    }

    private func answer(_ body: String) -> (OriginRequest) -> [[UInt8]] {
        { request in
            [responseHeaders(status: 200, stream: request.stream),
             dataFrame(body, stream: request.stream)]
        }
    }

    // MARK: An ordinary exchange

    @Test func anOrdinaryResponseComesBack() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200), dataFrame("hello")]
        // Kept: the connection is still good for the next request.
        #expect(try run("/fetch", origin) == "200|hello|true")
    }

    @Test func aConnectionIsKeptForTheNextRequest() throws {
        // The socket, not the flag. reusedConnection is what the client
        // reports; the live count is what actually happened -- and an earlier
        // version that closed only on failure reported `false` correctly while
        // leaking every connection that worked.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200), dataFrame("hello")]
        urlWanted = origin.url + "/x"
        let client = h2ClientApp().test
        let wire = try TestWire(client)
        wire.send("GET /fetch HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 20_000)
        _ = wire.receive()
        #expect(outcome == "200|hello|true")
        #expect(client.worker.pointee.outbound?.liveCount == 1)
        #expect(client.worker.pointee.outboundH2.count == 1)
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
        #expect(try run("/fetch", origin) == "200|hello world|true")
    }

    @Test func paddedFramesAreReadWithoutTheirPadding() throws {
        // PADDED puts a length byte in front and zeros behind, on HEADERS and
        // DATA alike. A reader that ignored the flag would decode the length
        // byte as HPACK and hand the zeros over as body.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        let headers = responseHeaders(status: 200, fields: [("x-thing", "padded")])
        let block = Array(headers[H2FrameHeader.size...])
        origin.script = [
            padded(.headers, flags: .endHeaders, stream: 1, content: block, padding: 7),
            padded(.data, flags: .endStream, stream: 1, content: Array("hello".utf8), padding: 3),
        ]
        #expect(try run("/fetch", origin) == "200|hello|true")
    }

    @Test func anInformationalResponseIsNotMistakenForTheAnswer() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [responseHeaders(status: 103),
                         responseHeaders(status: 200),
                         dataFrame("done")]
        #expect(try run("/fetch", origin) == "200|done|true")
    }

    @Test func anInformationalResponseIsNotAnAnswerEvenWhenNoneFollows() throws {
        // The test above cannot see the 1xx skip being removed, and two
        // attempts at this missed it too. The reason is that a decoded block
        // replaces the fields and the status wholesale, so whenever a real
        // response follows, it repairs the damage the missing skip did --
        // every assertion about the answer holds either way.
        //
        // So the case has to be one where nothing final follows. A 103 and
        // then a body is a body with no answer to belong to: skipping the 103
        // makes that a protocol error, while treating it as the answer
        // returns 103 and the body.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        origin.script = [responseHeaders(status: 103), dataFrame("x")]
        #expect(try run("/fetch", origin) == "protocolError")
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
        //
        // The intruder is a PING, which is harmless in itself. An earlier
        // version used DATA and could not see this guard at all: DATA before
        // any answer is refused on its own account, so the outcome was the
        // same with the interleave check deleted. A frame that would be
        // accepted anywhere else is the only kind that shows the check.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        let whole = responseHeaders(status: 200, fields: [("x-thing", "split")])
        let block = Array(whole[H2FrameHeader.size...])
        origin.script = [rawFrame(type: .headers, flags: .endStream, stream: 1,
                                  payload: Array(block.prefix(1))),
                         rawFrame(type: .ping, stream: 0, payload: [0, 0, 0, 0, 0, 0, 0, 1]),
                         rawFrame(type: .continuation, flags: .endHeaders, stream: 1,
                                  payload: Array(block.dropFirst(1)))]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aHeaderBlockSplitAcrossContinuationIsReassembled() throws {
        // The same split without the intruder is an ordinary response, which
        // is what makes the refusal above about the PING and not the split.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.dribble = true
        let whole = responseHeaders(status: 200, fields: [("x-thing", "split")])
        let block = Array(whole[H2FrameHeader.size...])
        origin.script = [rawFrame(type: .headers, flags: .endStream, stream: 1,
                                  payload: Array(block.prefix(1))),
                         rawFrame(type: .continuation, flags: .endHeaders, stream: 1,
                                  payload: Array(block.dropFirst(1)))]
        #expect(try run("/header", origin) == "split")
    }

    @Test func aStatusThatIsNotThreeDigitsIsRefused() throws {
        // :status is exactly three digits. Two would parse as a plausible
        // number and four would parse as a different one, and either way the
        // caller would be handed a status the peer never sent.
        reset()
        // The long one is not merely wrong: accumulating those digits into an
        // Int before counting them overflows and traps, which took the worker
        // and every other request on it over one field a peer chose.
        for text in ["20", "2000", "", "abc", String(repeating: "9", count: 24), "099"] {
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
            origin.script = [rawFrame(type: .headers, flags: [.endHeaders, .endStream], stream: 1,
                                      payload: Array(UnsafeBufferPointer(
                                        start: block.readPointer, count: block.readableBytes)))]
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
        origin.script = [Array(responseHeaders(status: 200, fields: [("x-thing", "here")],
                                               endStream: true))]
        // Rebuilt without :status: the static entry for 200 is the one byte
        // after the frame header.
        var frame = origin.script[0]
        frame.remove(at: H2FrameHeader.size)
        let length = frame.count - H2FrameHeader.size
        frame[0] = UInt8(truncatingIfNeeded: length >> 16)
        frame[1] = UInt8(truncatingIfNeeded: length >> 8)
        frame[2] = UInt8(truncatingIfNeeded: length)
        origin.script = [frame]
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
        #expect(try run("/fetch", origin) == "200||true")
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
        let settings: [UInt8] = [0x00, 0x05] + u32(32768)   // maxFrameSize
        origin.script = [rawFrame(type: .settings, stream: 0, payload: settings),
                         responseHeaders(status: 200, endStream: true)]
        #expect(try run("/fetch", origin) == "200||true")
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

    @Test func aDecodedHeadLargerThanTheLimitEndsTheStreamOnly() throws {
        // The gap this closes: a list whose *encoded* form is well inside the
        // limit and whose decoded form is nowhere near it. Each field costs the
        // two lengths plus 32 once decoded, so many tiny fields expand several
        // times over -- and the frame size bounds none of it.
        //
        // The block was decoded to keep the HPACK table in step and then
        // thrown away, so this ends the one stream and keeps the connection.
        // Ending the connection would punish every other request on it.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        headLimitWanted = 4096
        let whole = responseHeaders(status: 200,
                                    fields: Array(repeating: ("a", "b"), count: 500),
                                    endStream: true)
        let frames = splitHeaders(whole, endStream: true)
        // Stated, not assumed: were the block itself over the budget, the
        // assembly guard would answer first and this would prove nothing.
        let encoded = frames.reduce(0) { $0 + $1.count - H2FrameHeader.size }
        #expect(encoded < headLimitWanted)
        origin.script = frames
        urlWanted = origin.url + "/x"
        let client = h2ClientApp().test
        let wire = try TestWire(client)
        wire.send("GET /fetch HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 20_000)
        _ = wire.receive()
        #expect(outcome == "headTooLarge")
        #expect(origin.frames(ofType: .rstStream).count == 1)
        #expect(client.worker.pointee.outboundH2.count == 1)
    }

    @Test func aHeadBlockThatKeepsGoingIsRefused() throws {
        // CONTINUATION may repeat as long as the peer likes, and until the last
        // one arrives nothing has been decoded. Assembling it without a bound
        // lets the peer choose how much memory a worker spends, and the
        // per-frame cap bounds one frame rather than the sequence.
        //
        // A block assembled only in part cannot be decoded, so the HPACK table
        // would no longer describe what was read: this one ends the connection.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        headLimitWanted = 4096
        // Distinct fields, so HPACK cannot fold them and the encoded block
        // itself passes the budget.
        let fields = (0..<2000).map { ("x-\($0)", "value-\($0)") }
        let frames = splitHeaders(responseHeaders(status: 200, fields: fields,
                                                 endStream: true), endStream: true)
        #expect(frames.reduce(0) { $0 + $1.count - H2FrameHeader.size } > headLimitWanted)
        origin.script = frames
        #expect(try run("/fetch", origin) == "headTooLarge")
    }

    @Test func eachStreamKeepsItsOwnBodyLimit() throws {
        // One connection, two requests, different limits. Whoever happens to be
        // reading the connection must not lend its limit to the other stream:
        // before this, an eight-byte body inside its own request's limit failed
        // because the request reading at that moment allowed four.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        bodyLimitsWanted = ["a": 4, "b": 1000]
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        origin.answerHeld({ $0.path == "/b" }, answer("12345678"))
        origin.answerHeld({ $0.path == "/a" }, answer("ok"))
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["b"] == "200|12345678")
        #expect(outcomes["a"] == "200|ok")
        withExtendedLifetime(wires) {}
    }

    // MARK: What the head promised

    @Test func aBodyShorterThanContentLengthIsRefused() throws {
        // RFC 9113 8.1.1. END_STREAM is the peer saying the response is whole;
        // three bytes where ten were promised is a truncated download, and
        // handing it back as a 200 is how a relay corrupts what it copies.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "10")]),
                         dataFrame("abc")]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aBodyLongerThanContentLengthIsRefused() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "2")]),
                         dataFrame("far more than two")]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func aBodyMatchingContentLengthIsAccepted() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "5")]),
                         dataFrame("hello")]
        #expect(try run("/fetch", origin) == "200|hello|true")
    }

    @Test func aContentLengthWithNoBodyAtAllIsRefused() throws {
        // The head ends the stream while promising ten bytes.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "10")],
                                        endStream: true)]
        #expect(try run("/fetch", origin) == "protocolError")
    }

    @Test func twoContentLengthsThatDisagreeAreRefused() throws {
        // A smuggling vector, and nothing here should be guessing which was
        // meant.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "3"),
                                                              ("content-length", "5")]),
                         dataFrame("abc")]
        #expect(try run("/fetch", origin).hasPrefix("malformedResponse"))
    }

    @Test func aContentLengthTooLongToBeANumberIsRefused() throws {
        // A hundred digits multiplied into an Int traps, which is the worker
        // gone; it is refused before it is read.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        let huge = String(repeating: "9", count: 100)
        origin.script = [responseHeaders(status: 200, fields: [("content-length", huge)]),
                         dataFrame("abc")]
        #expect(try run("/fetch", origin).hasPrefix("malformedResponse"))
    }

    @Test func aHeadResponseKeepsItsContentLengthWithoutABody() throws {
        // The length describes what a GET would have sent. No body follows, and
        // nothing is owed on this one.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 200, fields: [("content-length", "1234")],
                                        endStream: true)]
        #expect(try run("/head", origin) == "200|0")
    }

    @Test func aBodylessStatusKeepsItsContentLength() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.script = [responseHeaders(status: 304, fields: [("content-length", "1234")],
                                        endStream: true)]
        #expect(try run("/fetch", origin) == "304||true")
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

    @Test func thePeersHeaderTableSizeDoesNotShrinkOurDecoder() throws {
        // SETTINGS_HEADER_TABLE_SIZE bounds the table of whoever *receives*
        // the setting's sender's blocks -- here, the server's own decoder,
        // which this client's encoder never touches, since it never indexes.
        // The first version handed the value to this client's decoder, so a
        // server advertising 0 had its perfectly valid responses refused:
        // the entry it added was not stored, and its next reference to it
        // named nothing.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.announce = [(.headerTableSize, 0)]
        origin.respond = { request in
            [indexingResponse(stream: request.stream, adding: true, alsoRefer: true)]
        }
        originURL = origin.url
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a"])
        #expect(turn(client, origin) { outcomes["a"] != nil })
        #expect(outcomes["a"] == "200||kept")
        withExtendedLifetime(wires) {}
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
        // the ack test cannot tell them apart.
        //
        // The timing is the whole difficulty. A client may send as soon as it
        // has written the preface, so it cannot honour a setting it has not
        // read -- the first frames going out at 16384 is correct, not a bug.
        // The setting only binds what comes after it is read, and the one
        // moment this client reads anything mid-send is when the window shuts.
        //
        // It has to grow rather than shrink, which took a failing test to
        // notice: RFC 9113 puts SETTINGS_MAX_FRAME_SIZE between 16384 and
        // 16777215, and 16384 is also the default, so no legal value is
        // smaller than what this already uses.
        //
        // And credit has to come in one lump. It took a frame-by-frame census
        // to see why: crediting exactly what each frame spent keeps the window
        // as the binding constraint for the whole upload, so every frame is
        // capped at what was just returned and the frame size never gets to be
        // the limit. Three stalls, an applied setting, and still every frame
        // at 16384.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.creditInLump = 300_000
        origin.settingsFirst = true
        origin.peerMaxFrameSize = 32768
        bodyWanted = Array(repeating: UInt8(ascii: "z"), count: 200_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        #expect(try run("/post", origin, turns: 400_000) == "200|ok")
        #expect(origin.requestBody.count == 200_000)
        let data = origin.frames(ofType: .data)
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
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.creditStreamOnly = true
        // Proving something never arrives means waiting for it, so this waits
        // briefly rather than the production ten seconds.
        timeoutWanted = 300
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

    // MARK: Sharing a connection

    @Test func twoRequestsAtOnceShareOneConnection() throws {
        // Answered in the opposite order to the one they were asked in, so a
        // reader that handed each frame to the stream that opened first, or
        // to whoever happened to be reading, gives each request the other's
        // body.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        origin.answerHeld({ $0.path == "/b" }, answer("body-b"))
        origin.answerHeld({ $0.path == "/a" }, answer("body-a"))
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["a"] == "200|body-a")
        #expect(outcomes["b"] == "200|body-b")
        #expect(origin.accepted == 1)
        // Opened on the wire in increasing order, as RFC 9113 requires of a
        // new stream: an id allocated before waiting for the write lock could
        // reach the wire after a larger one.
        #expect(origin.frames(ofType: .headers).map(\.streamID) == [1, 3])
        withExtendedLifetime(wires) {}
    }

    /// One request finishes while another is still waiting, and nothing more
    /// arrives until after the first has gone.
    ///
    /// If the first was the one reading, it has to hand the baton on as it
    /// leaves: otherwise the second is parked on its own stream with nobody
    /// reading the connection, and its answer arrives into a socket nobody
    /// looks at. Which of the two is reading depends on which waited first, so
    /// the test runs both ways round -- one of them is always the hand-off.
    ///
    /// And it is run with the first request leaving both ways a request can:
    /// finishing, which hands the baton on in `finish`, and being reset, which
    /// hands it on in `abandon`. Those are the two places the hand-off lives,
    /// so each needs a leaving that goes through it.
    private func handOff(first: String, second: String, byReset: Bool = false) throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        timeoutWanted = 3_000
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })

        if byReset {
            origin.answerHeld({ $0.path == "/" + first }) { request in
                [rawFrame(type: .rstStream, stream: request.stream,
                          payload: u32(H2Error.cancel.rawValue))]
            }
        } else {
            origin.answerHeld({ $0.path == "/" + first }, answer("body-" + first))
        }
        #expect(turn(client, origin) { outcomes[first] != nil })
        #expect(outcomes[first] == (byReset ? "streamReset(8)" : "200|body-" + first))

        // Quiet turns, so the leaving request has well and truly gone before
        // anything for the other one exists to be read.
        turn(client, origin, turns: 200) { false }

        origin.answerHeld({ $0.path == "/" + second }, answer("body-" + second))
        #expect(turn(client, origin, turns: 60_000) { outcomes[second] != nil })
        #expect(outcomes[second] == "200|body-" + second)
        withExtendedLifetime(wires) {}
    }

    @Test func aReaderThatLeavesHandsTheBatonOnWhenTheFirstFinishes() throws {
        try handOff(first: "a", second: "b")
    }

    @Test func aReaderThatLeavesHandsTheBatonOnWhenTheSecondFinishes() throws {
        try handOff(first: "b", second: "a")
    }

    @Test func aReaderThatIsResetHandsTheBatonOnWhenTheFirstIs() throws {
        try handOff(first: "a", second: "b", byReset: true)
    }

    @Test func aReaderThatIsResetHandsTheBatonOnWhenTheSecondIs() throws {
        try handOff(first: "b", second: "a", byReset: true)
    }

    /// A request with little patience parked behind a reader with a lot.
    ///
    /// Nothing arrives for either. The reader waits on the socket until the
    /// *earliest* deadline among everyone waiting, then wakes whoever has run
    /// out -- without that, the impatient request would sleep until the
    /// patient one gave up, seconds past its own limit. Which of the two reads
    /// depends on which waited first, so both orders are run; when the
    /// impatient one happens to be reading it times itself out, and the order
    /// that matters is the other.
    private func impatientBehindPatient(startingWith first: String) throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        timeoutsWanted = ["a": 300, "b": 8_000]
        let client = h2ClientApp().test
        let routes = first == "a" ? ["/multi/a", "/multi/b"] : ["/multi/b", "/multi/a"]
        let wires = try start(client, routes)
        #expect(turn(client, origin) { origin.held.count == 2 })

        let began = av_monotonic_ms()
        while outcomes["a"] == nil && av_monotonic_ms() &- began < 4_000 {
            origin.pump()
            client.turn()
        }
        let waited = av_monotonic_ms() &- began
        #expect(outcomes["a"] == "timedOut")
        #expect(waited < 4_000, "the impatient request waited \(waited) ms for a 300 ms limit")
        #expect(outcomes["b"] == nil, "the patient request should still be waiting")

        origin.answerHeld({ $0.path == "/b" }, answer("body-b"))
        #expect(turn(client, origin) { outcomes["b"] != nil })
        #expect(outcomes["b"] == "200|body-b")
        withExtendedLifetime(wires) {}
    }

    @Test func anImpatientRequestTimesOutBehindAPatientReaderStartedFirst() throws {
        try impatientBehindPatient(startingWith: "b")
    }

    @Test func anImpatientRequestTimesOutBehindAPatientReaderStartedSecond() throws {
        try impatientBehindPatient(startingWith: "a")
    }

    @Test func aResponseLargerThanTheWindowIsCreditedAsItArrives() throws {
        // Receive credit, the other direction from the upload tests. Every
        // DATA byte spends both this client's connection window and the
        // stream's, and each has to be returned separately -- a response
        // past 65535 bytes that returns neither stops dead, and one that
        // resets its own count without sending the frame leaves the peer
        // waiting for credit it was never given.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        let chunk = String(repeating: "r", count: 16_384)
        origin.respond = { request in
            var frames = [responseHeaders(status: 200, stream: request.stream)]
            for i in 0..<6 {
                frames.append(dataFrame(chunk, stream: request.stream, endStream: i == 5))
            }
            return frames
        }
        urlWanted = origin.url + "/big"
        let client = h2ClientApp().test
        let wire = try TestWire(client)
        wire.send("GET /count HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 60_000)
        #expect(outcome == "200|\(16_384 * 6)")
        let updates = origin.frames(ofType: .windowUpdate)
        #expect(updates.contains { $0.streamID == 0 }, "no connection credit returned")
        #expect(updates.contains { $0.streamID == 1 }, "no stream credit returned")
    }

    @Test func aStreamedResponseOpensItsWindowOnlyAsTheCallerReads() throws {
        // A caller reading a stream more slowly than the peer sends must hold
        // the peer back, not let the client buffer without bound. So the
        // stream's window is returned as the caller takes the bytes, never as
        // they arrive: while the caller holds off, no WINDOW_UPDATE goes out
        // for the stream, and the peer, out of credit, has to stop.
        //
        // A second request waits on the same connection for an answer that
        // does not come, so the connection is being read -- and the stream's
        // frames delivered -- the whole time the first caller is not reading.
        // With nobody reading, the frames would sit in the kernel whatever
        // the client did, and the test would prove nothing.
        reset()
        gateOpen = false
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        let chunk = String(repeating: "s", count: 16_384)
        origin.respond = { request in
            guard request.path == "/big" else { return [] }
            return [responseHeaders(status: 200, stream: request.stream)]
                + (0..<3).map { _ in dataFrame(chunk, stream: request.stream, endStream: false) }
        }
        urlWanted = origin.url + "/big"
        originURL = origin.url
        let client = h2ClientApp().test
        let wires = try start(client, ["/stream-gated"])
        #expect(turn(client, origin) { origin.requests.contains { $0.path == "/big" } })
        let stream = origin.requests.first { $0.path == "/big" }?.stream ?? 0
        let readers = try start(client, ["/multi/a"])
        #expect(turn(client, origin) { origin.requests.contains { $0.path == "/a" } })
        // Long enough for the reader to have taken in all three frames.
        turn(client, origin, turns: 500) { false }
        let early = origin.frames(ofType: .windowUpdate).filter { $0.streamID == stream }
        #expect(early.isEmpty, "stream credit returned before the caller read anything")

        gateOpen = true
        #expect(turn(client, origin, turns: 40_000) {
            origin.frames(ofType: .windowUpdate).contains { $0.streamID == stream }
        }, "reading gives the credit back")
        // The rest, which a peer holding to its window could only send now.
        origin.queue(0, (0..<3).map { i in dataFrame(chunk, stream: stream, endStream: i == 2) })
        #expect(turn(client, origin, turns: 60_000) { !outcome.isEmpty })
        #expect(outcome == "200|\(16_384 * 6)")
        withExtendedLifetime(wires + readers) {}
    }

    @Test func aRaisedInitialWindowAppliesToAStreamAlreadyOpen() throws {
        // SETTINGS_INITIAL_WINDOW_SIZE changes the window of every open stream
        // by the difference, RFC 9113 section 6.9.2 -- not only streams opened
        // afterwards. The peer here grants connection credit and raises the
        // initial window, and never sends the stream a WINDOW_UPDATE, so the
        // upload finishes only if the raise reached the stream in flight.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.raiseInitialWindowTo = 131_072
        timeoutWanted = 2_000
        bodyWanted = Array(repeating: UInt8(ascii: "v"), count: 70_000)
        origin.script = [responseHeaders(status: 200), dataFrame("ok")]
        #expect(try run("/post", origin, turns: 200_000) == "200|ok")
        #expect(origin.requestBody.count == 70_000)
    }

    @Test func dataForTwoStreamsInterleavedIsKeptApart() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        origin.dribble = true
        originURL = origin.url
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        guard let a = origin.held.first(where: { $0.path == "/a" }),
              let b = origin.held.first(where: { $0.path == "/b" }) else {
            Issue.record("both requests should have arrived")
            return
        }
        origin.forgetHeld()
        origin.queue(0, [responseHeaders(status: 200, stream: a.stream),
                         responseHeaders(status: 200, stream: b.stream),
                         dataFrame("a1", stream: a.stream, endStream: false),
                         dataFrame("b1", stream: b.stream, endStream: false),
                         dataFrame("a2", stream: a.stream),
                         dataFrame("b2", stream: b.stream)])
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["a"] == "200|a1a2")
        #expect(outcomes["b"] == "200|b1b2")
        withExtendedLifetime(wires) {}
    }

    @Test func aKeptConnectionCarriesItsHPACKStateToTheNextRequest() throws {
        // The first response adds `x-thing: kept` to the dynamic table and the
        // second refers to it by index alone. That second one decodes only for
        // a client that kept the table -- which is the whole difficulty of
        // reusing an HTTP/2 connection, and why the first version would not.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.respond = { request in
            [indexingResponse(stream: request.stream, adding: request.stream == 1)]
        }
        originURL = origin.url
        let client = h2ClientApp().test
        var wires = try start(client, ["/multi/a"])
        #expect(turn(client, origin) { outcomes["a"] != nil })
        wires += try start(client, ["/multi/b"])
        #expect(turn(client, origin) { outcomes["b"] != nil })
        #expect(outcomes["a"] == "200||kept")
        #expect(outcomes["b"] == "200||kept")
        #expect(origin.accepted == 1)
        #expect(origin.frames(ofType: .headers).map(\.streamID) == [1, 3])
        withExtendedLifetime(wires) {}
    }

    @Test func aResetStreamFailsOnlyItsOwnRequest() throws {
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        let client = h2ClientApp().test
        var wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        origin.answerHeld({ $0.path == "/a" }) { request in
            [rawFrame(type: .rstStream, stream: request.stream,
                      payload: u32(H2Error.refusedStream.rawValue))]
        }
        origin.answerHeld({ $0.path == "/b" }, answer("body-b"))
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["a"]?.hasPrefix("streamReset") == true)
        #expect(outcomes["b"] == "200|body-b")

        // And the connection is still good: the next request goes down it.
        origin.hold = false
        origin.respond = answer("body-c")
        wires += try start(client, ["/multi/c"])
        #expect(turn(client, origin) { outcomes["c"] != nil })
        #expect(outcomes["c"] == "200|body-c")
        #expect(origin.accepted == 1)
        withExtendedLifetime(wires) {}
    }

    @Test func aConnectionThatDiesFailsEveryRequestOnIt() throws {
        // None of them may be left parked. A request waiting on its own
        // stream is woken only by something happening to that stream, so a
        // connection that goes away has to wake all of them itself.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        origin.closePeer(0)
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["a"] == "closed")
        #expect(outcomes["b"] == "closed")
        #expect(client.worker.pointee.outboundH2.isEmpty)
        #expect(client.worker.pointee.outbound?.liveCount == 0)
        withExtendedLifetime(wires) {}
    }

    @Test func aGoawayRefusesOnlyTheStreamsThePeerNeverProcessed() throws {
        // Streams above the last one a GOAWAY names were never looked at, and
        // are refused -- which is what makes them safe to send again. Streams
        // at or below it are finished as normal. And nothing new goes down a
        // connection that has been told to go away.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        let client = h2ClientApp().test
        var wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        let low = origin.held.map(\.stream).min() ?? 1
        let lowName = origin.held.first { $0.stream == low }?.path.dropFirst() ?? "a"
        let highName = lowName == "a" ? "b" : "a"
        origin.queue(0, [goaway(lastStream: low)])
        origin.answerHeld({ $0.stream == low }, answer("processed"))
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes[String(lowName)] == "200|processed")
        #expect(outcomes[highName] == "streamReset(\(H2Error.refusedStream.rawValue))")

        origin.hold = false
        origin.forgetHeld()
        origin.respond = answer("elsewhere")
        wires += try start(client, ["/multi/c"])
        #expect(turn(client, origin) { outcomes["c"] != nil })
        #expect(outcomes["c"] == "200|elsewhere")
        #expect(origin.accepted == 2)
        withExtendedLifetime(wires) {}
    }

    @Test func anIdleConnectionToldToGoAwayIsNotUsedAgain() throws {
        // Nobody reads a connection with no streams, so a GOAWAY that arrives
        // while it is idle sits unread. A request sent down it anyway fails for
        // no reason of its own; reading what is waiting before reusing the
        // connection is what finds out in time to go elsewhere.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.respond = answer("first")
        originURL = origin.url
        let client = h2ClientApp().test
        var wires = try start(client, ["/multi/a"])
        #expect(turn(client, origin) { outcomes["a"] != nil })
        #expect(outcomes["a"] == "200|first")

        origin.queue(0, [goaway(lastStream: 1)])
        turn(client, origin, turns: 50) { false }

        origin.respond = answer("second")
        wires += try start(client, ["/multi/b"])
        #expect(turn(client, origin) { outcomes["b"] != nil })
        #expect(outcomes["b"] == "200|second")
        #expect(origin.accepted == 2)
        withExtendedLifetime(wires) {}
    }

    @Test func aFullConnectionSendsTheNextRequestToAnother() throws {
        // SETTINGS_MAX_CONCURRENT_STREAMS is the peer's limit, and a stream
        // past it is refused on arrival. So a request finding the connection
        // full opens another rather than joining it.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.announce = [(.maxConcurrentStreams, 1)]
        origin.hold = true
        originURL = origin.url
        let client = h2ClientApp().test
        var wires = try start(client, ["/multi/a"])
        // The setting only binds once it has been read, and the client says it
        // has by acknowledging it.
        #expect(turn(client, origin) {
            origin.held.count == 1
                && origin.frames(ofType: .settings).contains { $0.flags & H2Flags.ack.rawValue != 0 }
        })
        wires += try start(client, ["/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        #expect(origin.accepted == 2)
        origin.answerHeld({ _ in true }, answer("ok"))
        #expect(turn(client, origin) { outcomes.count == 2 })
        #expect(outcomes["a"] == "200|ok")
        #expect(outcomes["b"] == "200|ok")
        withExtendedLifetime(wires) {}
    }

    @Test func oneRequestTimingOutDoesNotStopTheOthers() throws {
        // Silence on one stream is that stream's problem. A connection that
        // treated it as its own would fail every request sharing it.
        reset()
        guard let origin = FakeH2Origin() else { Issue.record("no socket"); return }
        origin.hold = true
        originURL = origin.url
        timeoutWanted = 400
        let client = h2ClientApp().test
        let wires = try start(client, ["/multi/a", "/multi/b"])
        #expect(turn(client, origin) { origin.held.count == 2 })
        origin.answerHeld({ $0.path == "/b" }, answer("body-b"))
        #expect(turn(client, origin, turns: 400_000) { outcomes.count == 2 })
        #expect(outcomes["a"] == "timedOut")
        #expect(outcomes["b"] == "200|body-b")
        withExtendedLifetime(wires) {}
    }
}

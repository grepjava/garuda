import Testing
import CGaruda
import GarudaCore
@testable import Garuda

/// What the handler under test saw, read back by the test.
nonisolated(unsafe) private var outcome = ""
/// The name the handler should look up, and whether it wants an IPv6 address.
nonisolated(unsafe) private var nameWanted = ""
nonisolated(unsafe) private var wantsIPv6 = false
/// Where the plain-connect route should go, for the test that asks whether a
/// resolver's connection can be handed to somebody else.
nonisolated(unsafe) private var connectHost = ""
nonisolated(unsafe) private var connectPort: UInt16 = 0

private func resolverApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/resolve") { request, response in
        // Read before the first await: the request is a view of a slot, and
        // the worker pointer is what outlives the wait.
        let worker = request.worker
        do {
            let found = try await Worker.resolve(worker, name: nameWanted, wantIPv6: wantsIPv6)
            outcome = found.map(\.text).joined(separator: ",")
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // An ordinary caller, wanting an ordinary connection. Used to ask whether
    // a nameserver's TCP connection could be handed to one.
    app.onAsync(.get, "/connect") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, host: connectHost,
                                                  port: connectPort, milliseconds: 2_000)
            outcome = socket.isOpen ? "connected" : "closed"
            socket.close()
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    return app
}

/// A nameserver the test owns, on a port the kernel chose.
///
/// Bound to port 0 and read back rather than given a fixed number: a test that
/// picks a port is a test that fails when something else on the machine holds
/// it, which is exactly why pg_local_port exists.
private final class FakeNameserver {
    let fd: Int32
    let port: UInt16
    /// Every query it received, in order, for a test to assert on.
    private(set) var questions: [String] = []
    /// When true it takes the query and says nothing, which is how a test
    /// makes a server look unreachable without unbinding it.
    var silent = false
    /// Answers are built by this, given the query id and the question name.
    var answer: (UInt16, String) -> [UInt8] = { _, _ in [] }

    init?() {
        let opened = "127.0.0.1".withCString { pg_bind_udp($0, 0, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = pg_local_port(opened)
        guard got != 0 else { _ = pg_close(opened); return nil }
        fd = opened
        port = got
    }

    deinit { _ = pg_close(fd) }

    /// Reads any waiting query and replies. Called once per turn of the
    /// worker, since both ends are on this thread.
    ///
    /// The shim receives in batches, because that is the ratio QUIC needs; one
    /// datagram at a time is a batch of one.
    func pump() {
        let stride = 1500
        var buffer = [UInt8](repeating: 0, count: stride)
        var message = pg_udp_msg()
        let count = buffer.withUnsafeMutableBytes { raw in
            Int(pg_udp_recv_batch(fd, raw.baseAddress, stride, &message, 1))
        }
        guard count == 1 else { return }
        let got = Int(message.len)
        guard got > 12 else { return }
        let id = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
        let name = questionName(buffer, count: got)
        questions.append(name)
        guard !silent else { return }
        let payload = answer(id, name)
        guard !payload.isEmpty else { return }
        // Back to whoever asked, from whichever local address the datagram
        // arrived on -- the shim recovered both, and a reply from the wrong
        // source would be dropped.
        var peer = message.peer
        var local = message.local
        _ = payload.withUnsafeBytes { raw in
            pg_udp_send(fd, raw.baseAddress, raw.count, &peer, &local, 0)
        }
    }

    /// The question name out of a query, so the fake can answer what it was
    /// actually asked. Queries are never compressed, so this walks labels.
    private func questionName(_ bytes: [UInt8], count: Int) -> String {
        var parts: [String] = []
        var at = 12
        while at < count {
            let length = Int(bytes[at])
            if length == 0 { break }
            guard length < 64, at + 1 + length <= count else { break }
            parts.append(String(decoding: bytes[(at + 1)..<(at + 1 + length)], as: UTF8.self))
            at += 1 + length
        }
        return parts.joined(separator: ".")
    }
}

/// The TCP half of a nameserver, for the retry a truncated answer asks for.
///
/// Listens on the same port its UDP sibling was given, so one `nameserverPort`
/// reaches both -- which is how a real nameserver is reached too.
private final class FakeNameserverTCP {
    let fd: Int32
    private(set) var questions: [String] = []
    var answer: (UInt16, String) -> [UInt8] = { _, _ in [] }
    /// Sends the length prefix and the body as two writes rather than one, so
    /// the reader has to reassemble rather than getting a whole message per
    /// read. TCP is entitled to split anywhere; this makes it certain.
    var splitWrites = false
    /// Accepted connections still being served, so a reply split across turns
    /// is not dropped halfway.
    private var open: [Int32] = []
    /// Bodies owed to a peer whose length prefix has already gone, sent on the
    /// next pump so the reader has to come back for them.
    private var pending: [(Int32, [UInt8])] = []

    init?(port: UInt16) {
        let opened = "127.0.0.1".withCString { pg_listen_tcp($0, port, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        fd = opened
    }

    deinit {
        for peer in open { _ = pg_close(peer) }
        _ = pg_close(fd)
    }

    /// Accepts anything waiting and serves whatever has arrived on it.
    func pump() {
        // Whatever was owed from last time goes first, so a body always lands
        // in a read after the one that took its length.
        let owed = pending
        pending.removeAll()
        for (peer, body) in owed {
            _ = body.withUnsafeBytes { pg_write(peer, $0.baseAddress, $0.count) }
        }

        var address = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        let peer = pg_accept(fd, &address, 64, &port)
        if peer >= 0 { open.append(peer) }

        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 1500)
            let got = buffer.withUnsafeMutableBytes { raw in
                pg_read(peer, raw.baseAddress, raw.count)
            }
            // Two bytes of length in front of the message, unlike UDP.
            guard got > 14 else { continue }
            let id = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            let name = questionName(buffer, count: got, from: 14)
            questions.append(name)
            let payload = answer(id, name)
            guard !payload.isEmpty else { continue }
            let prefix: [UInt8] = [
                UInt8(truncatingIfNeeded: payload.count >> 8),
                UInt8(truncatingIfNeeded: payload.count),
            ]
            if splitWrites {
                // The prefix and the first byte of the body now, the rest on a
                // later pump.
                //
                // Splitting *between* the length and the body is not enough:
                // those are two separate readExactly calls, and each still
                // completes in one read, so the loop inside can be cut to a
                // single iteration with nothing failing. The split has to fall
                // inside one call, which means inside the body.
                var head = prefix
                head.append(payload[0])
                _ = head.withUnsafeBytes { pg_write(peer, $0.baseAddress, $0.count) }
                pending.append((peer, Array(payload.dropFirst())))
            } else {
                var framed = prefix
                framed.append(contentsOf: payload)
                _ = framed.withUnsafeBytes { raw in
                    pg_write(peer, raw.baseAddress, raw.count)
                }
            }
        }
    }

    private func questionName(_ bytes: [UInt8], count: Int, from: Int) -> String {
        var parts: [String] = []
        var at = from
        while at < count {
            let length = Int(bytes[at])
            if length == 0 { break }
            guard length < 64, at + 1 + length <= count else { break }
            parts.append(String(decoding: bytes[(at + 1)..<(at + 1 + length)], as: UTF8.self))
            at += 1 + length
        }
        return parts.joined(separator: ".")
    }
}

/// Builds a reply to a query, by hand, so a test says what is on the wire.
private func reply(id: UInt16, name: String, flags: UInt16 = 0x8180,
                   records: [(type: UInt16, data: [UInt8])] = []) -> [UInt8] {
    var out: [UInt8] = []
    func u16(_ v: UInt16) {
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }
    func writeName(_ text: String) {
        for label in text.split(separator: ".") {
            out.append(UInt8(label.utf8.count))
            out.append(contentsOf: Array(label.utf8))
        }
        out.append(0)
    }
    u16(id); u16(flags); u16(1); u16(UInt16(records.count)); u16(0); u16(0)
    writeName(name)
    u16(records.first?.type ?? 1); u16(1)
    for record in records {
        // The owner name points back at the question, as a real server does.
        u16(0xc00c)
        u16(record.type); u16(1)
        u16(0); u16(60)                                  // TTL
        u16(UInt16(record.data.count))
        out.append(contentsOf: record.data)
    }
    return out
}

@Suite("Resolver", .serialized)
struct ResolverTests {
    /// Runs one request while being the nameserver on the other end.
    private func resolve(_ client: TestClient, _ servers: [FakeNameserver],
                         stream: FakeNameserverTCP? = nil,
                         name: String, ipv6: Bool = false) throws -> String {
        outcome = ""
        nameWanted = name
        wantsIPv6 = ipv6
        let wire = try TestWire(client)
        wire.send("GET /resolve HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            for server in servers { server.pump() }
            // Both transports are pumped every turn: a truncated datagram
            // sends the lookup to TCP part way through, and nothing else here
            // would be servicing that listener.
            stream?.pump()
            return !outcome.isEmpty
        }, turns: 20_000)
        return wire.receive() ?? "no response"
    }

    /// Runs the plain-connect route, pumping both fakes as `resolve` does so
    /// the listener still accepts while the handler is waiting.
    private func connect(_ client: TestClient, _ servers: [FakeNameserver],
                         stream: FakeNameserverTCP? = nil) throws -> String {
        outcome = ""
        let wire = try TestWire(client)
        wire.send("GET /connect HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            for server in servers { server.pump() }
            stream?.pump()
            return !outcome.isEmpty
        }, turns: 20_000)
        return wire.receive() ?? "no response"
    }

    /// A client whose resolver points at the fakes rather than at whatever
    /// this machine happens to have in /etc/resolv.conf.
    private func client(_ servers: [FakeNameserver], search: [String] = [],
                        ndots: Int = 1, attempts: Int = 2) -> TestClient {
        let made = resolverApp().test
        var config = ResolverConfig()
        config.nameservers = servers.map { _ in "127.0.0.1" }
        config.search = search
        config.ndots = ndots
        config.attempts = attempts
        config.timeoutSeconds = 1
        made.worker.pointee.resolverConfig = config
        made.worker.pointee.nameserverPort = servers[0].port
        return made
    }

    @Test func anAddressComesBack() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id, name: name, records: [(type: 1, data: [93, 184, 216, 34])])
        }
        let client = client([server])
        #expect(try resolve(client, [server], name: "alpha.example")
                    .hasSuffix("93.184.216.34"))
        #expect(server.questions == ["alpha.example"])
    }

    @Test func everyAddressInTheAnswerIsKeptInOrder() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id, name: name, records: [
                (type: 1, data: [10, 0, 0, 1]),
                (type: 1, data: [10, 0, 0, 2]),
            ])
        }
        let client = client([server])
        // A server rotates its own records; reordering them here would undo
        // whatever balancing it was doing.
        #expect(try resolve(client, [server], name: "alpha.example")
                    .hasSuffix("10.0.0.1,10.0.0.2"))
    }

    /// The check that makes the id worth having. An attacker who guesses the
    /// id but not the question must get nothing.
    @Test func anAnswerToADifferentQuestionIsNotBelieved() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, _ in
            // Right id, wrong name.
            reply(id: id, name: "evil.example", records: [(type: 1, data: [6, 6, 6, 6])])
        }
        let client = client([server], attempts: 1)
        let text = try resolve(client, [server], name: "alpha.example")
        #expect(!text.contains("6.6.6.6"))
        #expect(text.hasSuffix("unanswered"))
    }

    @Test func aWrongIdIsNotBelieved() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id &+ 1, name: name, records: [(type: 1, data: [6, 6, 6, 6])])
        }
        let client = client([server], attempts: 1)
        let text = try resolve(client, [server], name: "alpha.example")
        #expect(!text.contains("6.6.6.6"))
    }

    @Test func aNameThatDoesNotExistSaysSo() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in reply(id: id, name: name, flags: 0x8183) }
        let client = client([server])
        #expect(try resolve(client, [server], name: "nope.example").hasSuffix("noAddress"))
    }

    /// Truncation means "ask me again over TCP", so that is what happens: the
    /// lookup succeeds with the answer the datagram could not carry.
    @Test func aTruncatedAnswerIsAskedAgainOverTCP() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        guard let stream = FakeNameserverTCP(port: server.port) else {
            Issue.record("no tcp listener"); return
        }
        // The datagram says there is more, and carries a record anyway -- a
        // resolver that read it would return one address and believe it had
        // them all.
        server.answer = { id, name in
            reply(id: id, name: name, flags: 0x8380,
                  records: [(type: 1, data: [10, 0, 0, 1])])
        }
        stream.answer = { id, name in
            reply(id: id, name: name, records: [
                (type: 1, data: [10, 0, 0, 1]),
                (type: 1, data: [10, 0, 0, 2]),
                (type: 1, data: [10, 0, 0, 3]),
            ])
        }
        let client = client([server])
        let text = try resolve(client, [server], stream: stream, name: "alpha.example")
        #expect(text.hasSuffix("10.0.0.1,10.0.0.2,10.0.0.3"))
        // Asked over both transports, in that order.
        #expect(server.questions == ["alpha.example"])
        #expect(stream.questions == ["alpha.example"])
    }

    /// The retry carries a fresh id. Reusing the one the truncated datagram
    /// used would let an answer aimed at that query be taken for this one.
    @Test func theTCPRetryUsesADifferentId() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        guard let stream = FakeNameserverTCP(port: server.port) else {
            Issue.record("no tcp listener"); return
        }
        nonisolated(unsafe) var datagramID: UInt16 = 0
        nonisolated(unsafe) var streamID: UInt16 = 1
        server.answer = { id, name in
            datagramID = id
            return reply(id: id, name: name, flags: 0x8380)
        }
        stream.answer = { id, name in
            streamID = id
            return reply(id: id, name: name, records: [(type: 1, data: [10, 0, 0, 7])])
        }
        let client = client([server])
        #expect(try resolve(client, [server], stream: stream, name: "alpha.example")
                    .hasSuffix("10.0.0.7"))
        #expect(datagramID != streamID)
    }

    /// A server that truncates over TCP as well is contradicting itself, and
    /// there is no third transport. It must say so rather than read as a
    /// server that never answered.
    @Test func truncatedOverTCPAsWellIsReported() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        guard let stream = FakeNameserverTCP(port: server.port) else {
            Issue.record("no tcp listener"); return
        }
        server.answer = { id, name in reply(id: id, name: name, flags: 0x8380) }
        stream.answer = { id, name in reply(id: id, name: name, flags: 0x8380) }
        let client = client([server])
        #expect(try resolve(client, [server], stream: stream, name: "alpha.example")
                    .hasSuffix("truncated"))
    }

    /// A reply written in two pieces is still understood.
    ///
    /// What this does **not** prove is that the reassembly loop works: cutting
    /// that loop to one iteration leaves this green, because on loopback both
    /// pieces have arrived by the time the reader wakes and a single read
    /// takes them all. Splitting between the length and the body, and then
    /// inside the body, both failed to change that. The limitation is recorded
    /// on `readExactly` itself; this test holds the framing, not the loop.
    @Test func aReplyWrittenInTwoPiecesIsUnderstood() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        guard let stream = FakeNameserverTCP(port: server.port) else {
            Issue.record("no tcp listener"); return
        }
        server.answer = { id, name in reply(id: id, name: name, flags: 0x8380) }
        stream.splitWrites = true
        stream.answer = { id, name in
            reply(id: id, name: name, records: [(type: 1, data: [10, 0, 0, 5])])
        }
        let client = client([server])
        #expect(try resolve(client, [server], stream: stream, name: "alpha.example")
                    .hasSuffix("10.0.0.5"))
    }

    /// The resolver leaves nothing behind, and the caller that comes next gets
    /// its own connection.
    ///
    /// This does not test a pool marker, because there is no longer one to
    /// test: the resolver closes its TCP connection on every path, so it never
    /// reaches the pool, and a marker guarding that was provably dead. What is
    /// worth holding is the behaviour -- nothing left open, nothing inherited.
    @Test func theTCPConnectionIsNotLeftBehind() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        guard let stream = FakeNameserverTCP(port: server.port) else {
            Issue.record("no tcp listener"); return
        }
        server.answer = { id, name in reply(id: id, name: name, flags: 0x8380) }
        stream.answer = { id, name in
            reply(id: id, name: name, records: [(type: 1, data: [10, 0, 0, 1])])
        }
        let client = client([server])
        _ = try resolve(client, [server], stream: stream, name: "alpha.example")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)

        // Now be an ordinary caller wanting that very address and port. It
        // must open its own socket rather than inherit the resolver's key.
        let opened = client.worker.pointee.outboundOpened
        connectHost = "127.0.0.1"
        connectPort = server.port
        #expect(try connect(client, [server], stream: stream).hasSuffix("connected"))
        #expect(client.worker.pointee.outboundOpened == opened + 1)
    }

    /// A server that takes the question and says nothing must not be the end
    /// of it: the timeout has to fire and the next attempt go out.
    @Test func aSilentServerIsAskedAgain() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.silent = true
        let client = client([server], attempts: 2)
        #expect(try resolve(client, [server], name: "alpha.example").hasSuffix("unanswered"))
        // Asked twice, not once: the retry is real.
        #expect(server.questions.count == 2)
    }

    @Test func theSearchListIsWalkedInOrder() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            // Only the second candidate exists.
            name == "db.two.internal"
                ? reply(id: id, name: name, records: [(type: 1, data: [10, 0, 0, 9])])
                : reply(id: id, name: name, flags: 0x8183)
        }
        let client = client([server], search: ["one.internal", "two.internal"], attempts: 1)
        #expect(try resolve(client, [server], name: "db").hasSuffix("10.0.0.9"))
        #expect(server.questions == ["db.one.internal", "db.two.internal"])
    }

    /// An address needs no lookup, and asking about one would be a round trip
    /// to be told what was already in hand.
    @Test func aLiteralAddressIsNotLookedUp() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        let client = client([server])
        #expect(try resolve(client, [server], name: "10.1.2.3").hasSuffix("10.1.2.3"))
        #expect(server.questions.isEmpty)
    }

    @Test func anIPv6LiteralIsNotLookedUpEither() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        let client = client([server])
        let text = try resolve(client, [server], name: "::1", ipv6: true)
        #expect(text.hasSuffix("0:0:0:0:0:0:0:1"))
        #expect(server.questions.isEmpty)
    }

    @Test func anAAAALookupTakesSixteenByteRecords() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id, name: name,
                  records: [(type: 28, data: Array(repeating: 0, count: 15) + [1])])
        }
        let client = client([server])
        #expect(try resolve(client, [server], name: "alpha.example", ipv6: true)
                    .hasSuffix("0:0:0:0:0:0:0:1"))
    }

    /// Nothing is left behind: a resolver socket is never pooled, so the table
    /// is empty once the lookup is over.
    @Test func theSocketIsClosedAfterwards() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id, name: name, records: [(type: 1, data: [10, 0, 0, 1])])
        }
        let client = client([server])
        _ = try resolve(client, [server], name: "alpha.example")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }
}

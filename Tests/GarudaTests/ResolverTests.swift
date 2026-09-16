import Testing
import CGaruda
import GarudaCore
@testable import Garuda

/// What the handler under test saw, read back by the test.
nonisolated(unsafe) private var outcome = ""
/// The name the handler should look up, and whether it wants an IPv6 address.
nonisolated(unsafe) private var nameWanted = ""
nonisolated(unsafe) private var wantsIPv6 = false

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
                         name: String, ipv6: Bool = false) throws -> String {
        outcome = ""
        nameWanted = name
        wantsIPv6 = ipv6
        let wire = try TestWire(client)
        wire.send("GET /resolve HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            for server in servers { server.pump() }
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

    /// Truncation is reported rather than hidden: half an answer handed over
    /// as though it were whole is worse than no answer.
    @Test func aTruncatedAnswerIsNotTreatedAsWhole() throws {
        guard let server = FakeNameserver() else { Issue.record("no socket"); return }
        server.answer = { id, name in
            reply(id: id, name: name, flags: 0x8380,
                  records: [(type: 1, data: [10, 0, 0, 1])])
        }
        let client = client([server])
        #expect(try resolve(client, [server], name: "alpha.example").hasSuffix("truncated"))
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

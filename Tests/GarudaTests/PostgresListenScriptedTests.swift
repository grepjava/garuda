import Testing
import CAvian
import AvianCore
@testable import Garuda

// A listener against a server that says exactly what the test wants, on cue:
// a notification that lands in the same read as the ReadyForQuery ending the
// statement that subscribed, a notice in the middle of waiting, a reply to a
// statement nobody ran, and a server that goes away. A real PostgreSQL cannot
// be asked to do these at a chosen moment.
//
// Both ends are on this thread, as in the Redis scripted tests: the worker
// turns, and the fake is pumped on each turn.

nonisolated(unsafe) private var outcome = ""

private func i32(_ v: Int32) -> [UInt8] {
    let u = UInt32(bitPattern: v)
    return [UInt8(u >> 24), UInt8(truncatingIfNeeded: u >> 16),
            UInt8(truncatingIfNeeded: u >> 8), UInt8(truncatingIfNeeded: u)]
}

private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

/// One backend message: its type, its length, its body.
private func msg(_ type: Character, _ body: [UInt8] = []) -> [UInt8] {
    [UInt8(ascii: type.unicodeScalars.first!)] + i32(Int32(4 + body.count)) + body
}

private func notification(_ channel: String, _ payload: String, from pid: Int32 = 99) -> [UInt8] {
    msg("A", i32(pid) + cstr(channel) + cstr(payload))
}

/// What the server answers a statement with when it returns no rows.
private let listenReply = msg("1") + msg("2") + msg("n") + msg("C", cstr("LISTEN"))
    + msg("Z", [UInt8(ascii: "I")])

/// A PostgreSQL that authenticates anyone, answers each read with the next
/// reply in its script, and can be told to push bytes nobody asked for.
private final class FakePostgres: @unchecked Sendable {
    struct Step {
        /// What the read must contain, or nil for anything.
        var expect: String?
        var reply: [UInt8]?
        var closeAfter = false
    }

    let fd: Int32
    let port: UInt16
    var script: [Step] = []
    private(set) var received: [String] = []
    private(set) var mismatches: [String] = []
    private var queued: [UInt8] = []
    private var open: [Int32] = []
    private var next = 0
    private var authenticated = false

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        fd = opened
        port = av_local_port(opened)
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        _ = av_close(fd)
    }

    /// Bytes to write on the next turn, without being asked for them.
    func push(_ bytes: [UInt8]) { queued.append(contentsOf: bytes) }

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 { open.append(peer) }
        for peer in open {
            if !queued.isEmpty {
                write(peer, queued)
                queued.removeAll()
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            received.append(String(decoding: buffer.prefix(got), as: UTF8.self))
            guard authenticated else {
                // The startup message: nobody is turned away here.
                authenticated = true
                write(peer, msg("R", i32(0)) + msg("K", i32(4_242) + i32(1))
                          + msg("Z", [UInt8(ascii: "I")]))
                continue
            }
            guard next < script.count else { continue }
            let step = script[next]
            next += 1
            if let expect = step.expect, !received[received.count - 1].contains(expect) {
                mismatches.append("expected \(expect) in \(received[received.count - 1].debugDescription)")
            }
            if let reply = step.reply { write(peer, reply) }
            if step.closeAfter {
                _ = av_close(peer)
                open.removeAll { $0 == peer }
                return
            }
        }
    }

    /// Closes whatever the client is connected on, as a server restarting does.
    func drop() {
        for peer in open { _ = av_close(peer) }
        open.removeAll()
    }

    private func write(_ peer: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { _ = av_write(peer, $0.baseAddress!, $0.count) }
    }
}

/// Runs `body` in a handler against `fake`, turning the worker and pumping the
/// fake until it answers.
private func run(_ fake: FakePostgres,
                 _ body: @escaping @Sendable (PostgresPool) async throws -> String) throws -> String {
    var configuration = PostgresConfiguration(host: "127.0.0.1", port: fake.port,
                                              user: "garuda", password: "secret")
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 1_000
    let settled = configuration
    outcome = ""
    let app = Application()
    app.state { _ in PostgresPool(settled, maxConnections: 2) }
    app.get("/run") { (db: State<PostgresPool>) async -> String in
        do {
            outcome = try await body(db.value)
        } catch {
            outcome = "threw \(error)"
        }
        return outcome
    }
    let wire = try TestWire(app.test)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    wire.turn(until: {
        fake.pump()
        return !outcome.isEmpty
    }, turns: 200_000)
    return outcome
}

@Suite("A PostgreSQL listener against a scripted server", .serialized)
struct PostgresListenScriptedTests {
    /// A notification the server sends as `LISTEN` finishes arrives in the
    /// same read as the ReadyForQuery. It belongs to the listener, not to the
    /// statement, and refusing it would end the listener for being told a
    /// moment too late.
    @Test func aNotificationInTheSameReadAsTheReplyIsKept() throws {
        let fake = try #require(FakePostgres())
        fake.script = [
            .init(expect: "listen", reply: listenReply + notification("jobs", "one")
                      + notification("jobs", "two")),
        ]
        let result = try run(fake) { pool in
            let listener = try await pool.listen("jobs")
            defer { listener.close() }
            // Both are already in hand: no wait at all finds them, in order.
            let first = try await listener.next(timeoutMilliseconds: 0)
            let second = try await listener.next(timeoutMilliseconds: 0)
            let third = try await listener.next(timeoutMilliseconds: 20)
            return "\(first?.payload ?? "-")|\(second?.payload ?? "-")"
                + "|\(third == nil ? "quiet" : "more")|\(listener.isOpen)"
        }
        #expect(fake.mismatches == [])
        #expect(result == "one|two|quiet|true")
    }

    /// A notice, and a setting that changed: neither is a notification, and
    /// neither ends the waiting.
    @Test func aNoticeWhileWaitingIsPassedOver() throws {
        let fake = try #require(FakePostgres())
        fake.script = [.init(expect: "listen", reply: listenReply)]
        let result = try run(fake) { pool in
            let listener = try await pool.listen("jobs")
            defer { listener.close() }
            fake.push(msg("N", [UInt8(ascii: "S")] + cstr("NOTICE")
                               + [UInt8(ascii: "M")] + cstr("table created") + [0]))
            fake.push(msg("S", cstr("TimeZone") + cstr("UTC")))
            fake.push(notification("jobs", "after the noise"))
            let heard = try await listener.next(timeoutMilliseconds: 2_000)
            return "\(heard?.payload ?? "-")|\(listener.isOpen)"
        }
        #expect(fake.mismatches == [])
        #expect(result == "after the noise|true")
    }

    /// A row description with no statement to describe: a server saying
    /// something after which nothing it says can be placed.
    @Test func aReplyNobodyAskedForEndsTheListener() throws {
        let fake = try #require(FakePostgres())
        fake.script = [.init(expect: "listen", reply: listenReply)]
        let result = try run(fake) { pool in
            let listener = try await pool.listen("jobs")
            defer { listener.close() }
            fake.push(msg("T", [0, 0]))
            do {
                _ = try await listener.next(timeoutMilliseconds: 2_000)
                return "accepted"
            } catch {
                return "\(error)|\(listener.isOpen)"
            }
        }
        #expect(result == "postgres(GarudaPostgres.PostgresError.unexpectedMessage(84))|false")
    }

    /// The server goes away. The listener says so, and every channel has to be
    /// listened to again on a new one -- which is what `app.listen` does.
    @Test func aServerThatGoesAwayIsReported() throws {
        let fake = try #require(FakePostgres())
        fake.script = [.init(expect: "listen", reply: listenReply)]
        let result = try run(fake) { pool in
            let listener = try await pool.listen("jobs")
            defer { listener.close() }
            fake.drop()
            do {
                _ = try await listener.next(timeoutMilliseconds: 2_000)
                return "accepted"
            } catch {
                return "\(error)|\(listener.isOpen)"
            }
        }
        #expect(result == "closed|false")
    }
}

import Testing
import CAvian
import AvianCore
@testable import Garuda

// The Redis driver against a server that says exactly what the test wants:
// what no real server can be made to do on cue. An old server with no HELLO,
// a message that arrives between subscription confirmations, pushes among
// replies, a close part-way through a reply, silence.
//
// Both ends are on this thread, as in HTTPClientTests: the worker turns, and
// the fake is pumped on each turn.

nonisolated(unsafe) private var outcome = ""

/// A Redis server that answers each read with the next reply in its script.
private final class FakeRedis {
    struct Step {
        /// What the read must contain, or nil for anything.
        var expect: String?
        /// Bytes to answer with, or nil to say nothing.
        var reply: String?
        var closeAfter = false
    }

    let fd: Int32
    let port: UInt16
    var script: [Step] = []
    private(set) var received: [String] = []
    private(set) var mismatches: [String] = []
    private(set) var accepted = 0
    private var open: [Int32] = []
    private var next = 0

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

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 {
            open.append(peer)
            accepted += 1
        }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            let text = String(decoding: buffer.prefix(got), as: UTF8.self)
            received.append(text)
            guard next < script.count else { continue }
            let step = script[next]
            next += 1
            if let expect = step.expect, !text.contains(expect) {
                mismatches.append("expected \(expect) in \(text.debugDescription)")
            }
            if let reply = step.reply {
                var bytes = reply
                bytes.withUTF8 { _ = av_write(peer, $0.baseAddress!, $0.count) }
            }
            if step.closeAfter {
                _ = av_close(peer)
                open.removeAll { $0 == peer }
                return
            }
        }
    }
}

private let hello3 = "%1\r\n$5\r\nproto\r\n:3\r\n"

/// Runs `body` in a handler against `fake`, turning the worker and pumping the
/// fake until it answers.
private func run(_ fake: FakeRedis, configure: (inout RedisConfiguration) -> Void = { _ in },
                 _ body: @escaping @Sendable (RedisPool) async throws -> String) throws -> String {
    var configuration = RedisConfiguration(host: "127.0.0.1", port: fake.port)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 1_000
    configure(&configuration)
    let settled = configuration
    outcome = ""
    let app = Application()
    app.state { _ in RedisPool(settled, maxConnections: 2) }
    app.get("/run") { (redis: State<RedisPool>) async -> String in
        do {
            outcome = try await body(redis.value)
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
    }, turns: 50_000)
    return outcome
}

@Suite("Redis against a scripted server", .serialized)
struct RedisScriptedTests {
    @Test func anOldServerIsSpokenToInRESP2() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: "-ERR unknown command 'HELLO', with args beginning with: '3'\r\n"),
            .init(expect: "AUTH", reply: "+OK\r\n"),
            .init(expect: "GET", reply: "$2\r\nhi\r\n"),
            .init(expect: "HGETALL", reply: "*4\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n$1\r\n2\r\n"),
        ]
        let result = try run(fake, configure: { $0.password = "secret" }) { redis in
            let value = try await redis.get("k") ?? "nil"
            let hash = try await redis.hgetall("h")
            return "\(value)|\(hash.sorted { $0.key < $1.key })"
        }
        #expect(fake.mismatches == [])
        #expect(result == #"hi|[(key: "a", value: "1"), (key: "b", value: "2")]"#)
        #expect(fake.received[1].contains("$6\r\nsecret\r\n"))
    }

    @Test func aMessageBetweenConfirmationsIsKept() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: hello3),
            .init(expect: "SUBSCRIBE",
                  reply: ">3\r\n$9\r\nsubscribe\r\n$2\r\nc1\r\n:1\r\n"
                       + ">3\r\n$7\r\nmessage\r\n$2\r\nc1\r\n$5\r\nearly\r\n"
                       + ">3\r\n$9\r\nsubscribe\r\n$2\r\nc2\r\n:2\r\n"
                       + ">3\r\n$7\r\nmessage\r\n$2\r\nc2\r\n$5\r\nlater\r\n"),
        ]
        let result = try run(fake) { redis in
            let subscription = try await redis.subscribe(channels: ["c1", "c2"])
            let first = try await subscription.next(timeoutMilliseconds: 500)
            let second = try await subscription.next(timeoutMilliseconds: 500)
            return "\(first?.channel ?? "-") \(first?.text ?? "-")|\(second?.channel ?? "-") \(second?.text ?? "-")"
        }
        #expect(fake.mismatches == [])
        #expect(result == "c1 early|c2 later")
    }

    @Test func aRESP2SubscriptionReadsArrays() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: "-ERR unknown command 'HELLO'\r\n"),
            .init(expect: "PSUBSCRIBE",
                  reply: "*3\r\n$10\r\npsubscribe\r\n$3\r\nch*\r\n:1\r\n"
                       + "*4\r\n$8\r\npmessage\r\n$3\r\nch*\r\n$4\r\nchat\r\n$2\r\nhi\r\n"),
        ]
        let result = try run(fake) { redis in
            let subscription = try await redis.subscribe(patterns: ["ch*"])
            let message = try await subscription.next(timeoutMilliseconds: 500)
            return "\(message?.pattern ?? "-") \(message?.channel ?? "-") \(message?.text ?? "-")"
        }
        #expect(result == "ch* chat hi")
    }

    @Test func pushesAmongRepliesAreNotTakenForThem() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: hello3),
            .init(expect: "GET", reply: ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nk\r\n$3\r\nabc\r\n:5\r\n"),
        ]
        let result = try run(fake) { redis in
            let replies = try await redis.pipeline([RedisCommand("GET", "k"), RedisCommand("INCR", "n")])
            return "\(replies)"
        }
        #expect(result == "[GarudaRedis.RedisValue.bulkString([97, 98, 99]), GarudaRedis.RedisValue.integer(5)]")
    }

    @Test func bytesNobodyAskedForAfterTheHandshakeAreRefused() throws {
        let fake = try #require(FakeRedis())
        fake.script = [.init(expect: "HELLO", reply: hello3 + "+SURPRISE\r\n")]
        let result = try run(fake) { redis in "\(try await redis.send("PING"))" }
        #expect(result == "threw protocolViolation(GarudaRedis.RedisProtocolError.badValue)")
    }

    @Test func aCloseInTheMiddleOfAReplyFailsAndIsNotReused() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: hello3),
            .init(expect: "GET", reply: "$10\r\nhalf", closeAfter: true),
            .init(expect: "HELLO", reply: hello3),
            .init(expect: "PING", reply: "+PONG\r\n"),
        ]
        let result = try run(fake) { redis in
            var out: [String] = []
            do {
                _ = try await redis.get("k")
                out.append("read")
            } catch {
                out.append("\(error)")
            }
            out.append("\(redis.counts)")
            out.append("\(try await redis.send("PING"))")
            return out.joined(separator: "|")
        }
        #expect(result == "closed|(open: 0, idle: 0)|simpleString(\"PONG\")")
        #expect(fake.accepted == 2)
    }

    @Test func silenceTimesOut() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: hello3),
            .init(expect: "GET", reply: nil),
        ]
        let result = try run(fake, configure: { $0.timeoutMilliseconds = 100 }) { redis in
            let start = av_monotonic_ms()
            do {
                _ = try await redis.get("k")
                return "answered"
            } catch {
                return "\(error)|\(av_monotonic_ms() - start >= 90)|\(redis.counts)"
            }
        }
        #expect(result == "timedOut|true|(open: 0, idle: 0)")
    }

    @Test func aRefusedHandshakeClosesTheConnection() throws {
        let fake = try #require(FakeRedis())
        fake.script = [
            .init(expect: "HELLO", reply: "-WRONGPASS invalid username-password pair\r\n"),
        ]
        let result = try run(fake, configure: { $0.password = "wrong" }) { redis in
            do {
                _ = try await redis.send("PING")
                return "connected"
            } catch let error as RedisClientError {
                if case .handshake(.authentication(let refusal)) = error { return "\(refusal.code)|\(redis.counts)" }
                return "\(error)"
            }
        }
        #expect(result == "WRONGPASS|(open: 0, idle: 0)")
    }
}

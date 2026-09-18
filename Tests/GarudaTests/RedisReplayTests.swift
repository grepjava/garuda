import Testing
import CAvian
import AvianCore
import GarudaRedis
@testable import Garuda

// What may be sent again, and what may not.
//
// A retry is only safe when the client knows the command did not run. A
// connection that fails before its first byte gives that knowledge; one that
// fails with the bytes already out gives nothing, and the difference between
// those two is the whole of this file. The scripted nodes below stage the
// cases a real cluster only produces while it is being resharded or failing
// over: a batch half answered and half redirected, and a node that takes a
// write and then goes away without answering.

nonisolated(unsafe) private var replayOutcome = ""

/// Runs `body` against a cluster seeded with `seed`, turning the worker and
/// pumping every node until it answers.
private func runReplayCluster(_ nodes: [FakeRedisNode], seed: FakeRedisNode,
                              replay: RedisReplay = .reads,
                              _ body: @escaping @Sendable (RedisCluster) async throws -> String) throws -> String {
    var configuration = RedisConfiguration(host: "127.0.0.1", port: seed.port)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 1_000
    let settled = configuration
    let policy = replay
    replayOutcome = ""
    let app = Application()
    app.state { _ in RedisCluster(settled, maxConnectionsPerNode: 2, replay: policy) }
    app.get("/run") { (cluster: State<RedisCluster>) async -> String in
        do {
            replayOutcome = try await body(cluster.value)
        } catch {
            replayOutcome = "threw \(error)"
        }
        return replayOutcome
    }
    let wire = try TestWire(app.test)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    wire.turn(until: {
        for node in nodes { node.pump() }
        return !replayOutcome.isEmpty
    }, turns: 200_000)
    return replayOutcome
}

/// The same, for a sentinel pool.
private func runReplaySentinel(_ nodes: [FakeRedisNode], sentinels: [FakeRedisNode],
                               replay: RedisReplay = .reads,
                               _ body: @escaping @Sendable (RedisSentinelPool) async throws -> String) throws -> String {
    var server = RedisConfiguration(host: "127.0.0.1", port: 0)
    server.tls = .disable
    server.timeoutMilliseconds = 1_000
    let settled = RedisSentinelConfiguration(
        sentinels: sentinels.map { sentinel in
            var configuration = RedisConfiguration(host: "127.0.0.1", port: sentinel.port)
            configuration.tls = .disable
            configuration.timeoutMilliseconds = 1_000
            return configuration
        },
        master: "cache", server: server)
    let policy = replay
    replayOutcome = ""
    let app = Application()
    app.state { _ in RedisSentinelPool(settled, maxConnections: 2, replay: policy) }
    app.get("/run") { (redis: State<RedisSentinelPool>) async -> String in
        do {
            replayOutcome = try await body(redis.value)
        } catch {
            replayOutcome = "threw \(error)"
        }
        return replayOutcome
    }
    let wire = try TestWire(app.test)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    wire.turn(until: {
        for node in nodes { node.pump() }
        return !replayOutcome.isEmpty
    }, turns: 200_000)
    return replayOutcome
}

private let replayMasterRole = "*3\r\n$6\r\nmaster\r\n:0\r\n*0\r\n"

private func replayAddressReply(_ port: UInt16) -> String {
    let host = "127.0.0.1"
    let number = "\(port)"
    return "*2\r\n$\(host.utf8.count)\r\n\(host)\r\n$\(number.utf8.count)\r\n\(number)\r\n"
}

@Suite("Redis retries that cannot repeat a write", .serialized)
struct RedisReplayTests {
    // MARK: What only reads

    @Test func readsAreToldFromWrites() {
        #expect(RedisReads.only(RedisCommand("GET", "k")))
        #expect(RedisReads.only(RedisCommand("get", "k")), "the name is read whatever its case")
        #expect(RedisReads.only(RedisCommand("MGET", "a", "b")))
        #expect(RedisReads.only(RedisCommand("ZRANGEBYSCORE", "z", "0", "1")))
        #expect(RedisReads.only(RedisCommand("XREAD", "COUNT", "1", "STREAMS", "s", "0")))
        #expect(!RedisReads.only(RedisCommand("INCR", "k")), "the one a retry must never repeat")
        #expect(!RedisReads.only(RedisCommand("SET", "k", "v")))
        #expect(!RedisReads.only(RedisCommand("EXEC")), "a lost EXEC reply is not a rollback")
        #expect(!RedisReads.only(RedisCommand("XREADGROUP")), "it moves the group's cursor")
        #expect(!RedisReads.only(RedisCommand("SORT", "k", "STORE", "d")), "SORT_RO is the read")
        #expect(RedisReads.only(RedisCommand("SORT_RO", "k")))
        #expect(!RedisReads.only(RedisCommand("NEWCOMMAND", "k")),
                "anything unrecognised is a write, which is the safe way to be wrong")
        #expect(RedisReads.only([RedisCommand("GET", "a"), RedisCommand("TTL", "a")]))
        #expect(!RedisReads.only([RedisCommand("GET", "a"), RedisCommand("DEL", "a")]),
                "one write in a batch is a batch that cannot go again")
    }

    @Test func aFailureBeforeTheFirstByteIsAlwaysSentAgain() {
        let write = [RedisCommand("INCR", "k")]
        let read = [RedisCommand("GET", "k")]
        // Nothing reached the server, so nothing can be repeated.
        #expect(RedisReplay.reads.allows(.closed, write))
        #expect(RedisReplay.nothing.allows(.timedOut, write))
        // The bytes went out, and what the server did with them is unknown.
        #expect(!RedisReplay.reads.allows(.unknownOutcome(.closed), write))
        #expect(RedisReplay.reads.allows(.unknownOutcome(.closed), read))
        #expect(RedisReplay.anything.allows(.unknownOutcome(.timedOut), write))
        #expect(!RedisReplay.nothing.allows(.unknownOutcome(.timedOut), read))
    }

    @Test func theCauseIsReadableThroughTheWrapper() {
        let error = RedisClientError.unknownOutcome(.timedOut)
        #expect(error.cause == .timedOut)
        #expect(error.mayHaveRun)
        #expect(!RedisClientError.timedOut.mayHaveRun)
        #expect(RedisClientError.timedOut.cause == .timedOut)
    }

    // MARK: A cluster's pipeline

    /// A slot half migrated answers some of a batch and redirects the rest.
    /// Only what was redirected goes again: sending the whole batch would
    /// count the first key twice.
    @Test func onlyTheRedirectedPartOfAPipelineGoesAgain() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        let slot = RedisSlots.slot(of: "t")
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            // One read holding both commands, so one write holding an answer
            // for the first and a redirect for the second.
            .init(expect: "INCR", reply: ":1\r\n-ASK \(slot) \(b.address)\r\n"),
        ]
        b.script = [.init(expect: "ASKING", reply: "+OK\r\n:1\r\n")]
        let result = try runReplayCluster([a, b], seed: a) { cluster in
            let replies = try await cluster.pipeline([RedisCommand("INCR", "{t}:one"),
                                                      RedisCommand("INCR", "{t}:two")])
            return replies.map { "\($0.int ?? -1)" }.joined(separator: ",")
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(result == "1,1")
        #expect(a.received.filter { $0.contains("{t}:one") }.count == 1,
                "the answered command is not sent a second time")
        #expect(b.received.contains { $0.contains("{t}:one") } == false,
                "and it does not follow the redirect that was not its own")
        #expect(b.received.contains { $0.contains("{t}:two") },
                "the redirected one goes where it was sent")
    }

    // MARK: A write whose outcome is not known

    /// A node that takes an `INCR` and goes away without answering. Whether it
    /// counted is not knowable, so the command is reported rather than aimed
    /// somewhere else.
    @Test func aWriteThatMayHaveRunIsNotSentAgain() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        a.script = [.init(expect: "SLOTS", reply: slotsReply([(0, 8_191, a.port), (8_192, 16_383, b.port)]))]
        b.script = [.init(expect: "INCR", reply: nil, goAway: true)]
        let result = try runReplayCluster([a, b], seed: a) { cluster in
            "\(try await cluster.send(RedisCommand("INCR", "foo")).int ?? -1)"
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(result.contains("unknownOutcome"), "\(result)")
        #expect(a.received.contains { $0.contains("INCR") } == false,
                "no other node is asked to do what may already be done")
    }

    /// The same failure with `replay: .anything`, for a cache where counting
    /// twice costs nothing. The command does go again -- which is the point:
    /// it is the caller's choice, not the transport's guess.
    @Test func anythingMayBeSentAgainWhenTheCallerSaysSo() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 8_191, a.port), (8_192, 16_383, b.port)])),
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            .init(expect: "INCR", reply: ":7\r\n"),
        ]
        b.script = [.init(expect: "INCR", reply: nil, goAway: true)]
        let result = try runReplayCluster([a, b], seed: a, replay: .anything) { cluster in
            "\(try await cluster.send(RedisCommand("INCR", "foo")).int ?? -1)"
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(result == "7")
    }

    // MARK: A sentinel's failover

    /// A failover in the middle of a batch: what the old master answered
    /// stands, and only what it refused with READONLY goes to the new one.
    @Test func onlyTheRefusedPartOfAPipelineFollowsTheFailover() throws {
        let sentinel = try #require(FakeRedisNode())
        let old = try #require(FakeRedisNode())
        let new = try #require(FakeRedisNode())
        sentinel.script = [
            .init(expect: "get-master-addr-by-name", reply: replayAddressReply(old.port)),
            .init(expect: "get-master-addr-by-name", reply: replayAddressReply(new.port)),
        ]
        old.script = [
            .init(expect: "ROLE", reply: replayMasterRole),
            .init(expect: "alpha", reply: "+OK\r\n-READONLY You can't write against a read only replica.\r\n"),
        ]
        new.script = [
            .init(expect: "ROLE", reply: replayMasterRole),
            .init(expect: "beta", reply: "+OK\r\n"),
        ]
        let result = try runReplaySentinel([sentinel, old, new], sentinels: [sentinel]) { redis in
            let replies = try await redis.pipeline([RedisCommand("SET", "alpha", "1"),
                                                    RedisCommand("SET", "beta", "2")])
            return replies.map { $0.string ?? "?" }.joined(separator: ",")
        }
        #expect(sentinel.mismatches + old.mismatches + new.mismatches == [])
        #expect(result == "OK,OK")
        #expect(new.received.contains { $0.contains("alpha") } == false,
                "the write the old master took is not done again on the new one")
        #expect(new.received.contains { $0.contains("beta") })
    }

    /// A master that takes a write and goes away without answering. The
    /// sentinels would name a new master, but nobody knows what the old one
    /// did, so the command stops here.
    @Test func aWriteLostInAFailoverIsReportedRatherThanRepeated() throws {
        let sentinel = try #require(FakeRedisNode())
        let old = try #require(FakeRedisNode())
        let new = try #require(FakeRedisNode())
        sentinel.script = [
            .init(expect: "get-master-addr-by-name", reply: replayAddressReply(old.port)),
            .init(expect: "get-master-addr-by-name", reply: replayAddressReply(new.port)),
        ]
        old.script = [
            .init(expect: "ROLE", reply: replayMasterRole),
            .init(expect: "SET", reply: nil, goAway: true),
        ]
        new.script = [
            .init(expect: "ROLE", reply: replayMasterRole),
            .init(expect: "SET", reply: "+OK\r\n"),
        ]
        let result = try runReplaySentinel([sentinel, old, new], sentinels: [sentinel]) { redis in
            try await redis.set("k", "v")
            return "wrote"
        }
        #expect(result.contains("unknownOutcome"), "\(result)")
        #expect(new.received.contains { $0.contains("SET") } == false)
    }
}

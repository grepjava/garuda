import Testing
import CAvian
import AvianCore
@testable import Garuda

// Sentinel: where the master is, asked of the sentinels rather than
// configured. Against scripted sentinels -- one that is down, one that is
// behind and names a replica, a master that has been demoted -- and against a
// real set of three, which is asked to fail over.

nonisolated(unsafe) private var outcome = ""

/// The reply to `SENTINEL get-master-addr-by-name`: a host and a port.
private func addressReply(_ port: UInt16) -> String {
    let host = "127.0.0.1"
    let number = "\(port)"
    return "*2\r\n$\(host.utf8.count)\r\n\(host)\r\n$\(number.utf8.count)\r\n\(number)\r\n"
}

private let masterRole = "*3\r\n$6\r\nmaster\r\n:0\r\n*0\r\n"
private let replicaRole = "*5\r\n$5\r\nslave\r\n$9\r\n127.0.0.1\r\n:1\r\n$9\r\nconnected\r\n:0\r\n"

/// Runs `body` against a sentinel pool, turning the worker and pumping every
/// fake until it answers.
private func run(_ nodes: [FakeRedisNode], sentinels: [FakeRedisNode],
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
    outcome = ""
    let app = Application()
    app.state { _ in RedisSentinelPool(settled, maxConnections: 2) }
    app.get("/run") { (redis: State<RedisSentinelPool>) async -> String in
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
        for node in nodes { node.pump() }
        return !outcome.isEmpty
    }, turns: 200_000)
    return outcome
}

@Suite("Redis Sentinel against scripted sentinels", .serialized)
struct RedisSentinelScriptedTests {
    @Test func theFirstSentinelThatAnswersNamesTheMaster() throws {
        let sentinel = try #require(FakeRedisNode())
        let master = try #require(FakeRedisNode())
        sentinel.script = [.init(expect: "get-master-addr-by-name", reply: addressReply(master.port))]
        master.script = [
            .init(expect: "ROLE", reply: masterRole),
            .init(expect: "SET", reply: "+OK\r\n"),
        ]
        let result = try run([sentinel, master], sentinels: [sentinel]) { redis in
            try await redis.set("k", "v")
            return "\(redis.masterAddress ?? "nil")"
        }
        #expect(sentinel.mismatches + master.mismatches == [])
        #expect(result == master.address)
    }

    /// A sentinel that is not there is not an error: the next one is asked.
    @Test func aSentinelThatIsDownIsSkipped() throws {
        let down = try #require(FakeRedisNode())
        let up = try #require(FakeRedisNode())
        let master = try #require(FakeRedisNode())
        // Answering nothing and closing, which is what a sentinel being
        // restarted looks like.
        down.script = [.init(expect: nil, reply: nil, goAway: true)]
        up.script = [.init(expect: "get-master-addr-by-name", reply: addressReply(master.port))]
        master.script = [
            .init(expect: "ROLE", reply: masterRole),
            .init(expect: "GET", reply: "$5\r\nthere\r\n"),
        ]
        let result = try run([down, up, master], sentinels: [down, up]) { redis in
            try await redis.get("k") ?? "nil"
        }
        #expect(up.mismatches + master.mismatches == [])
        #expect(result == "there")
    }

    /// A sentinel can be behind and name a node that has been demoted. The
    /// node says so itself, and the next sentinel is asked.
    @Test func aSentinelNamingAReplicaIsNotBelieved() throws {
        let behind = try #require(FakeRedisNode())
        let current = try #require(FakeRedisNode())
        let demoted = try #require(FakeRedisNode())
        let master = try #require(FakeRedisNode())
        behind.script = [.init(expect: "get-master-addr-by-name", reply: addressReply(demoted.port))]
        current.script = [.init(expect: "get-master-addr-by-name", reply: addressReply(master.port))]
        demoted.script = [.init(expect: "ROLE", reply: replicaRole)]
        master.script = [
            .init(expect: "ROLE", reply: masterRole),
            .init(expect: "GET", reply: "$7\r\ncorrect\r\n"),
        ]
        let result = try run([behind, current, demoted, master], sentinels: [behind, current]) { redis in
            let value = try await redis.get("k") ?? "nil"
            return "\(value)|\(redis.masterAddress == master.address)"
        }
        #expect(behind.mismatches + current.mismatches + demoted.mismatches + master.mismatches == [])
        #expect(result == "correct|true")
    }

    /// READONLY is what a master that has just been demoted says to a write.
    /// It means the master has moved, so the sentinels are asked again.
    @Test func readOnlyMeansTheMasterHasMoved() throws {
        let sentinel = try #require(FakeRedisNode())
        let old = try #require(FakeRedisNode())
        let new = try #require(FakeRedisNode())
        sentinel.script = [
            .init(expect: "get-master-addr-by-name", reply: addressReply(old.port)),
            .init(expect: "get-master-addr-by-name", reply: addressReply(new.port)),
        ]
        old.script = [
            .init(expect: "ROLE", reply: masterRole),
            .init(expect: "SET", reply: "-READONLY You can't write against a read only replica.\r\n"),
        ]
        new.script = [
            .init(expect: "ROLE", reply: masterRole),
            .init(expect: "SET", reply: "+OK\r\n"),
        ]
        let result = try run([sentinel, old, new], sentinels: [sentinel]) { redis in
            try await redis.set("k", "v")
            return "\(redis.masterAddress == new.address)"
        }
        #expect(sentinel.mismatches + old.mismatches + new.mismatches == [])
        #expect(result == "true")
    }

    /// Every sentinel down: the failure is the caller's to see, not something
    /// to be retried for ever.
    @Test func noSentinelAtAllIsReported() throws {
        let sentinel = try #require(FakeRedisNode())
        sentinel.script = [.init(expect: nil, reply: nil, goAway: true)]
        let result = try run([sentinel], sentinels: [sentinel]) { redis in
            try await redis.get("k") ?? "nil"
        }
        #expect(result.hasPrefix("threw"), "\(result)")
    }

    @Test func repliesThatAreNotAnAddressOrARoleAreRefused() throws {
        #expect(RedisSentinelPool.parseAddress(.array([.bulkString(Array("h".utf8)),
                                                       .bulkString(Array("1".utf8))])) == "h:1")
        #expect(RedisSentinelPool.parseAddress(.null) == nil, "a master nobody watches")
        #expect(RedisSentinelPool.parseAddress(.array([])) == nil)
        #expect(RedisSentinelPool.parseAddress(.array([.bulkString(Array("h".utf8)),
                                                       .bulkString(Array("0".utf8))])) == nil)
        #expect(RedisSentinelPool.parseAddress(.array([.bulkString([]),
                                                       .bulkString(Array("1".utf8))])) == nil)
        #expect(RedisSentinelPool.isMaster(.array([.bulkString(Array("master".utf8))])))
        #expect(!RedisSentinelPool.isMaster(.array([.bulkString(Array("slave".utf8))])))
        #expect(!RedisSentinelPool.isMaster(.simpleString("master")))
        #expect(!RedisSentinelPool.isMaster(.null))
    }
}

// MARK: - Against a real set of sentinels

private let sentinelTarget: (sentinel: RedisConfiguration, master: String,
                             server: RedisConfiguration)? = {
    guard let raw = av_getenv("GARUDA_REDIS_SENTINEL") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, let port = UInt16(parts[1]) else { return nil }
    var sentinel = RedisConfiguration(host: String(parts[0]), port: port)
    sentinel.tls = .disable
    sentinel.timeoutMilliseconds = 5_000
    var server = RedisConfiguration(host: String(parts[0]), password: String(parts[3]))
    server.tls = .disable
    server.timeoutMilliseconds = 5_000
    return (sentinel, String(parts[2]), server)
}()

@Suite("Redis Sentinel against a real set", .serialized,
       .enabled(if: sentinelTarget != nil, "set GARUDA_REDIS_SENTINEL to run"))
struct RedisSentinelIntegrationTests {
    /// Runs `body` in a handler with a sentinel pool of its own.
    private func onSentinel(_ body: @escaping @Sendable (RedisSentinelPool) async throws -> String) throws -> String {
        let target = sentinelTarget!
        let settled = RedisSentinelConfiguration(sentinels: [target.sentinel], master: target.master,
                                                 server: target.server)
        let app = Application()
        app.state { _ in RedisSentinelPool(settled, maxConnections: 2) }
        app.get("/run") { (redis: State<RedisSentinelPool>) async -> String in
            do {
                return try await body(redis.value)
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 60_000
        return try client.get("/run").text
    }

    @Test func theMasterIsFoundAndUsed() throws {
        let text = try onSentinel { redis in
            try await redis.set("sn:key", "value")
            var out: [String] = []
            out.append(try await redis.get("sn:key") ?? "nil")
            out.append("\(redis.masterAddress != nil)")
            // The node it found says it is the master, which is what was
            // checked before anything was sent to it.
            out.append("\(RedisSentinelPool.isMaster(try await redis.send(RedisCommand("ROLE"))))")
            return out.joined(separator: "|")
        }
        #expect(text == "value|true|true", "\(text)")
    }

    /// The sentinels are asked to promote the replica. Commands keep working
    /// across it, and the pool ends up on the new master.
    @Test func aFailoverIsFollowed() throws {
        let target = sentinelTarget!
        let text = try onSentinel { redis in
            try await redis.set("sn:before", "written")
            let first = redis.masterAddress ?? "?"

            // Asked of a sentinel, which is not the master and has no pool of
            // its own here.
            let sentinels = RedisPool(target.sentinel, maxConnections: 1)
            defer { sentinels.close() }
            _ = try await sentinels.send(RedisCommand("SENTINEL", "failover", target.master))

            // A failover takes a moment. Until it is done there may be no
            // master to write to, which is a failure worth retrying rather
            // than one worth reporting.
            var wrote = false
            var address = first
            for _ in 0..<60 {
                do {
                    try await redis.set("sn:after", "written")
                    address = redis.masterAddress ?? "?"
                    if address != first {
                        wrote = true
                        break
                    }
                } catch {
                    // Keep trying: this is what an application would do.
                }
                await pauseOnWorker(500)
            }
            var out: [String] = []
            out.append(wrote ? "moved" : "still \(address)")
            out.append(try await redis.get("sn:before") ?? "nil")
            out.append(try await redis.get("sn:after") ?? "nil")
            out.append("\(RedisSentinelPool.isMaster(try await redis.send(RedisCommand("ROLE"))))")
            return out.joined(separator: "|")
        }
        #expect(text == "moved|written|written|true", "\(text)")
    }
}

/// Waits on the worker's timer, from inside a handler.
private func pauseOnWorker(_ milliseconds: UInt64) async {
    guard let worker = currentWorker else { return }
    _ = await Worker.waitTimed(worker, milliseconds: milliseconds, register: { _ in })
}

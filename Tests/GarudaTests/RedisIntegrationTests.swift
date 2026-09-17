import Testing
import CAvian
import AvianCore
@testable import Garuda

// The Redis driver against a real server: commands and their typed replies,
// pipelines, transactions and watches, sessions that must not be handed on,
// authentication, pub/sub, limits, and a connection the server dropped.
//
// Opt-in: set GARUDA_REDIS to host:port:password, and GARUDA_REDIS_SOCKET to a
// unix socket on the same server, for example
//
//     GARUDA_REDIS=127.0.0.1:56379:garuda-secret swift test --filter Redis
//
// The ACL tests expect a user `app` with password `app-secret` allowed only
// keys under `app:`.

private let target: RedisConfiguration? = {
    guard let raw = av_getenv("GARUDA_REDIS") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port,
                                           password: parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 3_000
    return configuration
}()

private let socketPath: String? = av_getenv("GARUDA_REDIS_SOCKET").map { String(cString: $0) }

/// GARUDA_REDIS_TLS: host:port:password:ca-file, for a server whose
/// certificate names `host` and is signed by the CA in the file.
private let tlsTarget: RedisConfiguration? = {
    guard let raw = av_getenv("GARUDA_REDIS_TLS") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port, password: String(parts[2]))
    configuration.caFile = String(parts[3])
    configuration.timeoutMilliseconds = 3_000
    return configuration
}()

/// Waits on the worker's timers: `Task.sleep` would resume off its thread.
private func pause(_ milliseconds: UInt64) async {
    _ = await Worker.waitTimed(currentWorker!, milliseconds: milliseconds) { _ in }
}

/// A key of its own for each test.
private func key(_ name: String) -> String {
    "garuda-test:\(name):\(av_monotonic_us())"
}

/// Runs `body` in a handler with a pool, and returns what it returns, or the
/// error it threw, written out.
private func run(maxConnections: Int = 4, acquireTimeoutMilliseconds: UInt64? = nil,
                 configure: (inout RedisConfiguration) -> Void = { _ in },
                 _ body: @escaping @Sendable (RedisPool) async throws -> String) throws -> String {
    var configuration = target!
    configure(&configuration)
    let settled = configuration
    let app = Application()
    app.state { _ in
        RedisPool(settled, maxConnections: maxConnections, acquireTimeoutMilliseconds: acquireTimeoutMilliseconds)
    }
    app.get("/run") { (redis: State<RedisPool>) async -> String in
        do {
            return try await body(redis.value)
        } catch {
            return "threw \(error)"
        }
    }
    let client = app.test
    client.timeoutMillis = 15_000
    return try client.get("/run").text
}

@Suite("Redis integration", .serialized,
       .enabled(if: target != nil, "set GARUDA_REDIS to run"))
struct RedisIntegrationTests {
    @Test func stringsKeysAndExpiry() throws {
        let k = key("strings")
        let result = try run { redis in
            var out: [String] = []
            out.append("\(try await redis.get(k) ?? "nil")")
            out.append("\(try await redis.set(k, "hello"))")
            out.append("\(try await redis.set(k, "again", condition: .ifAbsent))")
            out.append(try await redis.get(k) ?? "nil")
            out.append("\(try await redis.exists(k, k))")
            out.append("\(try await redis.pttl(k) ?? -9)")
            out.append("\(try await redis.pexpire(k, milliseconds: 60_000))")
            let ttl = try await redis.pttl(k) ?? -9
            out.append(ttl > 50_000 && ttl <= 60_000 ? "ttl ok" : "ttl \(ttl)")
            out.append("\(try await redis.del(k, k + ":none"))")
            out.append("\(try await redis.pttl(k) as Int?)")
            out.append("\(try await redis.set(k, "x", condition: .ifPresent))")
            out.append("\(try await redis.incr(k + ":n"))")
            out.append("\(try await redis.incr(k + ":n", by: 41))")
            out.append(try await redis.get(k + ":n") ?? "nil")
            try await redis.set(k + ":bin", [UInt8]([0, 13, 10, 255]))
            out.append("\(try await redis.getBytes(k + ":bin") ?? [])")
            try await redis.set(k + ":px", "gone", expireMilliseconds: 20)
            await pause(60)
            out.append(try await redis.get(k + ":px") ?? "expired")
            try await redis.del(k + ":n", k + ":bin")
            return out.joined(separator: "|")
        }
        #expect(result == "nil|true|false|hello|2|-1|true|ttl ok|1|nil|false|1|42|42|[0, 13, 10, 255]|expired")
    }

    @Test func hashesListsSetsAndJSON() throws {
        struct Profile: Codable, Equatable { let name: String; let visits: Int }
        let k = key("structures")
        let result = try run { redis in
            var out: [String] = []
            out.append("\(try await redis.hset(k + ":h", [("name", "ada"), ("visits", 3)]))")
            out.append(try await redis.hget(k + ":h", "name") ?? "nil")
            out.append("\(try await redis.hgetall(k + ":h").sorted { $0.key < $1.key })")
            out.append("\(try await redis.hdel(k + ":h", "visits", "missing"))")
            out.append("\(try await redis.rpush(k + ":l", "b", "c"))")
            out.append("\(try await redis.lpush(k + ":l", "a"))")
            out.append("\(try await redis.lrange(k + ":l", 0, -1))")
            out.append(try await redis.lpop(k + ":l") ?? "nil")
            out.append(try await redis.rpop(k + ":l") ?? "nil")
            out.append("\(try await redis.sadd(k + ":s", "x", "y", "x"))")
            out.append("\(try await redis.smembers(k + ":s").sorted())")
            out.append("\(try await redis.srem(k + ":s", "x"))")
            try await redis.setJSON(k + ":j", Profile(name: "ada", visits: 7))
            out.append("\(try await redis.getJSON(Profile.self, k + ":j") == Profile(name: "ada", visits: 7))")
            out.append("\(try await redis.getJSON(Profile.self, k + ":missing") == nil)")
            try await redis.del(k + ":h", k + ":l", k + ":s", k + ":j")
            return out.joined(separator: "|")
        }
        #expect(result == #"2|ada|[(key: "name", value: "ada"), (key: "visits", value: "3")]|1|2|3|["a", "b", "c"]|a|c|2|["x", "y"]|1|true|true"#)
    }

    @Test func aRefusedCommandIsAServerErrorAndTheConnectionCarriesOn() throws {
        let k = key("wrongtype")
        let result = try run(maxConnections: 1) { redis in
            try await redis.rpush(k, "a")
            var out: [String] = []
            do {
                _ = try await redis.get(k)
                out.append("no error")
            } catch let error as RedisClientError {
                if case .server(let refusal) = error { out.append(refusal.code) } else { out.append("\(error)") }
            }
            // The same, and only, connection answers the next command.
            out.append("\(try await redis.send("PING"))")
            out.append("\(redis.counts.open)")
            try await redis.del(k)
            return out.joined(separator: "|")
        }
        #expect(result == "WRONGTYPE|simpleString(\"PONG\")|1")
    }

    @Test func aPipelineIsOneRoundTripWithEveryReply() throws {
        let k = key("pipeline")
        let result = try run { redis in
            let replies = try await redis.pipeline([
                RedisCommand("SET", k, "1"),
                RedisCommand("INCR", k),
                RedisCommand("NOSUCHCOMMAND"),
                RedisCommand("GET", k),
                RedisCommand("DEL", k),
            ])
            return replies.map { reply in
                if case .error(let e) = reply { return e.code }
                return reply.string ?? "\(reply)"
            }.joined(separator: "|")
        }
        #expect(result == "OK|2|ERR|2|1")
    }

    @Test func aTransactionRunsTogether() throws {
        let k = key("multi")
        let result = try run { redis in
            var out: [String] = []
            let replies = try await redis.transaction([RedisCommand("SET", k, "text"),
                                                       RedisCommand("INCR", k),
                                                       RedisCommand("APPEND", k, "!")])
            // INCR fails as it runs; the others still ran.
            out.append(replies.map { reply -> String in
                if case .error(let e) = reply { return e.code }
                return reply.string ?? "\(reply)"
            }.joined(separator: ","))
            out.append(try await redis.get(k) ?? "nil")
            do {
                _ = try await redis.transaction([RedisCommand("SET", k, "never"), RedisCommand("NOSUCHCOMMAND")])
                out.append("ran")
            } catch let error as RedisClientError {
                if case .server(let refusal) = error { out.append(refusal.code) } else { out.append("\(error)") }
            }
            out.append(try await redis.get(k) ?? "nil")
            try await redis.del(k)
            return out.joined(separator: "|")
        }
        #expect(result == "OK,ERR,5|text!|ERR|text!")
    }

    @Test func aWatchedKeyThatChangesStopsTheTransaction() throws {
        let k = key("watch")
        let result = try run { redis in
            try await redis.set(k, "10")
            let first = try await redis.session { s in
                try await s.watch(k)
                let stock = Int(try await s.get(k) ?? "0") ?? 0
                // Someone else, on another connection, between the read and
                // the transaction.
                try await redis.set(k, "0")
                return try await s.transaction([RedisCommand("SET", k, stock - 1)]) == nil ? "aborted" : "ran"
            }
            let second = try await redis.session { s in
                try await s.watch(k)
                let stock = Int(try await s.get(k) ?? "0") ?? 0
                return try await s.transaction([RedisCommand("SET", k, stock + 5)]) == nil ? "aborted" : "ran"
            }
            let value = try await redis.get(k) ?? "nil"
            try await redis.del(k)
            return "\(first)|\(second)|\(value)"
        }
        #expect(result == "aborted|ran|5")
    }

    @Test func aSessionLeftInsideATransactionIsNotHandedOn() throws {
        let k = key("leftover")
        let result = try run(maxConnections: 1) { redis in
            var out: [String] = []
            try await redis.session { s in
                _ = try await s.send("MULTI")
                _ = try await s.send("SET", k, "queued")
            }
            out.append("\(redis.counts)")
            // Were that connection reused, this would be QUEUED, not run.
            out.append("\(try await redis.set(k, "direct"))")
            out.append(try await redis.get(k) ?? "nil")
            try await redis.session { s in _ = try await s.send("SELECT", 1) }
            out.append("\(redis.counts)")
            try await redis.session { s in try await s.watch(k) }
            out.append("\(redis.counts)")
            out.append(try await redis.get(k) ?? "nil in database 1")
            try await redis.del(k)
            return out.joined(separator: "|")
        }
        #expect(result == "(open: 0, idle: 0)|true|direct|(open: 0, idle: 0)|(open: 0, idle: 0)|direct")
    }

    @Test func aFullPoolTimesOut() throws {
        let result = try run(maxConnections: 1, acquireTimeoutMilliseconds: 50) { redis in
            try await redis.session { _ in
                do {
                    _ = try await redis.send("PING")
                    return "got a second connection"
                } catch let error as RedisClientError {
                    return "\(error)|\(redis.waitingCount)"
                }
            }
        }
        #expect(result == "poolTimedOut|0")
    }

    @Test func authenticationIsRequiredAndRefusedWhenWrong() throws {
        let wrong = try run(configure: { $0.password = "wrong" }) { redis in
            _ = try await redis.send("PING")
            return "authenticated"
        }
        #expect(wrong.hasPrefix("threw handshake("))
        #expect(wrong.contains("authentication") && wrong.contains("WRONGPASS"))

        // HELLO without credentials is itself refused by a server that wants
        // them, so the connection never opens.
        let none = try run(configure: { $0.password = nil }) { redis in
            _ = try await redis.send("GET", "anything")
            return "ran without a password"
        }
        #expect(none.hasPrefix("threw handshake("))
        #expect(none.contains("NOAUTH"))
    }

    @Test func anACLUserIsHeldToItsKeys() throws {
        let result = try run(configure: {
            $0.username = "app"
            $0.password = "app-secret"
            $0.clientName = "garuda-tests"
        }) { redis in
            var out: [String] = []
            out.append("\(try await redis.set("app:\(av_monotonic_us())", "mine", expireMilliseconds: 1000))")
            do {
                try await redis.set("other:key", "not mine")
                out.append("allowed")
            } catch let error as RedisClientError {
                if case .server(let refusal) = error { out.append(refusal.code) } else { out.append("\(error)") }
            }
            let name = try await redis.send("CLIENT", "GETNAME")
            out.append(name.string ?? "nil")
            return out.joined(separator: "|")
        }
        #expect(result == "true|NOPERM|garuda-tests")
    }

    @Test func aDatabaseOtherThanZeroIsSelected() throws {
        let k = key("database")
        let result = try run(configure: { $0.database = 3 }) { redis in
            try await redis.set(k, "in three", expireMilliseconds: 5_000)
            let here = try await redis.get(k) ?? "nil"
            let index = try await redis.send("CLIENT", "INFO").string ?? ""
            return "\(here)|\(index.contains("db=3"))"
        }
        #expect(result == "in three|true")
        let elsewhere = try run { redis in try await redis.get(k) ?? "not in zero" }
        #expect(elsewhere == "not in zero")
    }

    @Test(.enabled(if: socketPath != nil, "set GARUDA_REDIS_SOCKET to run"))
    func aUnixSocketConnects() throws {
        let result = try run(configure: {
            let password = $0.password
            $0 = RedisConfiguration(unixSocketPath: socketPath!, password: password)
        }) { redis in
            "\(try await redis.send("PING"))"
        }
        #expect(result == "simpleString(\"PONG\")")
    }

    @Test(.enabled(if: tlsTarget != nil, "set GARUDA_REDIS_TLS to run"))
    func tlsIsVerified() throws {
        let tls = tlsTarget!
        let verified = try run(configure: { $0 = tls }) { redis in
            let pong = try await redis.send("PING")
            let key = "garuda-test:tls:\(av_monotonic_us())"
            try await redis.set(key, "encrypted", expireMilliseconds: 1_000)
            return "\(pong.string ?? "")|\(try await redis.get(key) ?? "nil")"
        }
        #expect(verified == "PONG|encrypted")

        // The same server, checked against the system's trust store, which
        // has never heard of the test CA.
        let untrusted = try run(configure: { $0 = tls; $0.caFile = "" }) { redis in
            _ = try await redis.send("PING")
            return "connected"
        }
        #expect(untrusted.hasPrefix("threw connect("))

        // A trusted certificate that does not name the host it was reached
        // by: the test certificate names localhost, not the address.
        let misnamed = try run(configure: { $0 = tls; $0.host = "127.0.0.1" }) { redis in
            _ = try await redis.send("PING")
            return "connected"
        }
        #expect(misnamed.hasPrefix("threw connect("))
    }

    @Test func largeRepliesArriveWhole() throws {
        let k = key("large")
        let result = try run { redis in
            let big = [UInt8]((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try await redis.set(k, big)
            let back = try await redis.getBytes(k)
            var elements: [RedisCommand] = []
            for batch in 0..<10 {
                var push = RedisCommand("RPUSH", k + ":list")
                for i in 0..<10_000 { push.append("item-\(batch)-\(i)") }
                elements.append(push)
            }
            _ = try await redis.pipeline(elements)
            let all = try await redis.lrange(k + ":list", 0, -1)
            try await redis.del(k, k + ":list")
            return "\(back == big)|\(all.count)|\(all.last ?? "")"
        }
        #expect(result == "true|100000|item-9-9999")
    }

    @Test func aReplyPastTheLimitClosesTheConnection() throws {
        let k = key("limit")
        let result = try run(maxConnections: 1, configure: { $0.maxBulkBytes = 1024 }) { redis in
            try await redis.set(k, [UInt8](repeating: 7, count: 4096))
            var out: [String] = []
            do {
                _ = try await redis.getBytes(k)
                out.append("read it")
            } catch let error as RedisClientError {
                out.append("\(error)")
            }
            out.append("\(redis.counts)")
            out.append("\(try await redis.del(k))")
            return out.joined(separator: "|")
        }
        #expect(result == "protocolViolation(GarudaRedis.RedisProtocolError.tooLarge)|(open: 0, idle: 0)|1")
    }

    @Test func aConnectionTheServerDroppedIsReplacedBeforeUse() throws {
        let result = try run(maxConnections: 1, configure: { $0.clientName = "garuda-dropped" }) { redis in
            let id = try await redis.send("CLIENT", "ID")
            // Killed from a session of its own, while the first sits idle.
            try await redis.session { _ in }
            _ = try await redis.pipeline([RedisCommand("PING")])
            let killer = RedisPool(redis.configuration, maxConnections: 1)
            _ = try await killer.send("CLIENT", "KILL", "ID", id.int ?? 0)
            killer.close()
            await pause(50)
            let after = try await redis.send("CLIENT", "ID")
            return "\(after != id)|\(try await redis.send("PING"))"
        }
        #expect(result == "true|simpleString(\"PONG\")")
    }

    @Test func blockingCommandsWaitAsLongAsTheyAreGiven() throws {
        let k = key("blocking")
        let result = try run { redis in
            let start = av_monotonic_ms()
            let reply = try await redis.send(RedisCommand("BLPOP", k, "0.2"), timeoutMilliseconds: 5_000)
            let waited = av_monotonic_ms() - start
            return "\(reply.isNull)|\(waited >= 150)"
        }
        #expect(result == "true|true")
    }

    @Test func publishedMessagesReachASubscriber() throws {
        let channel = key("channel")
        let result = try run { redis in
            let subscription = try await redis.subscribe(channels: [channel], patterns: [channel + ":*"])
            defer { subscription.close() }
            var out: [String] = []
            out.append("\(try await redis.publish(channel, "hello"))")
            if let message = try await subscription.next(timeoutMilliseconds: 2_000) {
                out.append("\(message.channel == channel) \(message.pattern ?? "-") \(message.text)")
            }
            try await redis.publish(channel + ":room", [UInt8]([0, 1, 2]))
            if let message = try await subscription.next(timeoutMilliseconds: 2_000) {
                out.append("\(message.pattern == channel + ":*") \(message.payload)")
            }
            let quiet = try await subscription.next(timeoutMilliseconds: 50)
            out.append(quiet == nil ? "quiet" : "unexpected")
            try await subscription.subscribe(channel + "-more")
            // Until the server has confirmed, a publish may reach no one.
            await pause(50)
            try await redis.publish(channel + "-more", "later")
            out.append(try await subscription.next(timeoutMilliseconds: 2_000)?.text ?? "none")
            out.append("\(redis.counts.open)")
            return out.joined(separator: "|")
        }
        #expect(result == "1|true - hello|true [0, 1, 2]|quiet|later|1")
    }
}

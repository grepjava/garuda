import Testing
import CAvian
import AvianCore
@testable import Garuda

// A real Redis Cluster: keys aimed at the node that owns them, a map put right
// by a redirect, keys that must share a slot, sharded channels, and a failover
// the cluster is asked to perform.
//
// Opt-in: set GARUDA_REDIS_CLUSTER to host:port:password of any node, for
// example
//
//     GARUDA_REDIS_CLUSTER=192.168.100.100:54001:garuda-secret swift test
//
// and these run; without it they are skipped, so the unit suite never depends
// on a cluster being up.

private let clusterSeed: RedisConfiguration? = {
    guard let raw = av_getenv("GARUDA_REDIS_CLUSTER") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port,
                                           password: String(parts[2]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

/// Runs `body` in a handler with a cluster of its own, and returns what it
/// says. A cluster belongs to a worker, as a pool does.
private func onCluster(_ body: @escaping @Sendable (RedisCluster) async throws -> String) throws -> String {
    let seed = clusterSeed!
    let app = Application()
    app.state { _ in RedisCluster(seed, maxConnectionsPerNode: 2) }
    app.get("/run") { (cluster: State<RedisCluster>) async -> String in
        do {
            return try await body(cluster.value)
        } catch {
            return "threw \(error)"
        }
    }
    let client = app.test
    client.timeoutMillis = 30_000
    return try client.get("/run").text
}

@Suite("Redis Cluster against a real cluster", .serialized,
       .enabled(if: clusterSeed != nil, "set GARUDA_REDIS_CLUSTER to run"))
struct RedisClusterIntegrationTests {
    /// The cluster's own `CLUSTER KEYSLOT` against this implementation's hash,
    /// for the keys that make hashing interesting.
    @Test func everySlotAgreesWithTheCluster() throws {
        let text = try onCluster { cluster in
            let keys = ["foo", "bar", "hello", "somekey", "", "a", "0", "\u{1F600}",
                        "user:{42}:name", "user:{42}:email", "{}{bar}", "foo{}{bar}",
                        "foo{{bar}}", "foo}{bar}", "{user1000}.following", "user1000",
                        "{}", "{{}}", "}{", "session:abc123", "refresh:s:ada",
                        String(repeating: "k", count: 200)]
            var wrong: [String] = []
            for key in keys {
                let reply = try await cluster.send(RedisCommand("CLUSTER", "KEYSLOT", key))
                guard case .integer(let said) = reply else {
                    wrong.append("\(key.debugDescription): \(reply)")
                    continue
                }
                let mine = RedisSlots.slot(of: key)
                if Int(said) != mine { wrong.append("\(key.debugDescription): \(said) not \(mine)") }
            }
            return wrong.isEmpty ? "all agree" : wrong.joined(separator: "; ")
        }
        #expect(text == "all agree", "\(text)")
    }

    /// Keys in different slots, which is most keys: each goes to its owner,
    /// and the map covers every slot exactly once.
    @Test func keysGoToTheNodeThatOwnsThem() throws {
        let text = try onCluster { cluster in
            var out: [String] = []
            // From whatever an earlier run left: a counter counts from zero.
            for key in ["cl:foo", "cl:bar", "cl:hello", "cl:counter"] {
                _ = try await cluster.del(key)
            }
            // These three hash into three different slots, and on a cluster of
            // three masters they are almost certainly three different nodes.
            for (key, value) in [("foo", "1"), ("bar", "2"), ("hello", "3")] {
                try await cluster.set("cl:" + key, value)
            }
            for (key, value) in [("foo", "1"), ("bar", "2"), ("hello", "3")] {
                out.append(try await cluster.get("cl:" + key) ?? "nil")
            }
            out.append("\(try await cluster.incr("cl:counter", by: 5))")
            // One key at a time: two keys in one DEL are two slots, which is
            // a CROSSSLOT and has its own test.
            var deleted = 0
            for key in ["cl:foo", "cl:bar"] { deleted += try await cluster.del(key) }
            out.append("\(deleted)")
            // Every slot is owned, once.
            var covered = 0
            var last = -1
            var ordered = true
            for range in cluster.slotRanges {
                covered += range.to - range.from + 1
                if range.from <= last { ordered = false }
                last = range.to
            }
            out.append("\(covered)")
            out.append("\(ordered)")
            out.append("\(cluster.addresses.count)")
            return out.joined(separator: "|")
        }
        #expect(text == "1|2|3|5|2|16384|true|3", "\(text)")
    }

    /// Keys touched together have to share a slot. The cluster says so, and a
    /// hash tag is the answer.
    @Test func keysTouchedTogetherMustShareASlot() throws {
        let text = try onCluster { cluster in
            var out: [String] = []
            do {
                _ = try await cluster.send(RedisCommand("MGET", "cl:one", "cl:two"))
                out.append("allowed")
            } catch RedisClientError.server(let error) {
                out.append(error.code)
            }
            // Tagged, so one slot, so one node: the same command works.
            try await cluster.set("cl:{t}:one", "1")
            try await cluster.set("cl:{t}:two", "2")
            let both = try await cluster.send(RedisCommand("MGET", "cl:{t}:one", "cl:{t}:two"))
            out.append((both.array ?? []).compactMap(\.string).joined(separator: ","))
            // A transaction, and a watch, are one node's as well.
            let replies = try await cluster.transaction([
                RedisCommand("INCR", "cl:{t}:one"),
                RedisCommand("INCR", "cl:{t}:two"),
            ])
            out.append(replies.map { "\($0.integer ?? -1)" }.joined(separator: ","))
            let watched = try await cluster.session(for: "cl:{t}:one") { session in
                try await session.watch("cl:{t}:one")
                let value = try await session.get("cl:{t}:one") ?? "0"
                let done = try await session.transaction([RedisCommand("SET", "cl:{t}:one", value + "!")])
                return done != nil
            }
            out.append("\(watched)")
            out.append(try await cluster.get("cl:{t}:one") ?? "nil")
            return out.joined(separator: "|")
        }
        #expect(text == "CROSSSLOT|1,2|2,3|true|2!", "\(text)")
    }

    /// A map that is wrong -- a slot has moved, a node was promoted -- is what
    /// `MOVED` is for. The command still lands, and the map is corrected.
    @Test func aWrongMapIsPutRightByARedirect() throws {
        let text = try onCluster { cluster in
            try await cluster.refresh()
            let slot = RedisSlots.slot(of: "cl:moved")
            let owner = cluster.slotRanges.first { slot >= $0.from && slot <= $0.to }?.address ?? "?"
            // Point the slot at a node that does not own it, as a stale map
            // does, and then use it.
            let wrong = cluster.addresses.first { $0 != owner } ?? owner
            cluster.remember(slot: slot, at: wrong)
            try await cluster.set("cl:moved", "followed")
            var out: [String] = []
            out.append("\(wrong != owner)")
            out.append(try await cluster.get("cl:moved") ?? "nil")
            // And the map is right again, without being asked to reload.
            let now = cluster.slotRanges.first { slot >= $0.from && slot <= $0.to }?.address ?? "?"
            out.append("\(now == owner)")
            return out.joined(separator: "|")
        }
        #expect(text == "true|followed|true", "\(text)")
    }

    /// An ordinary channel reaches every subscriber in the cluster. A sharded
    /// one belongs to a slot, and reaches the shard that owns it.
    @Test func channelsReachSubscribersAcrossTheCluster() throws {
        let text = try onCluster { cluster in
            var out: [String] = []
            let channel = "cl:news"
            let subscription = try await cluster.subscribe(channels: [channel])
            defer { subscription.close() }
            // Published through the cluster, which sends it to whichever node
            // the command lands on -- not necessarily the subscriber's.
            _ = try await cluster.send(RedisCommand("PUBLISH", channel, "everywhere"))
            out.append(try await subscription.next(timeoutMilliseconds: 2_000)?.text ?? "none")

            let sharded = "cl:{shard}:news"
            let shardedSubscription = try await cluster.subscribeSharded(channels: [sharded])
            defer { shardedSubscription.close() }
            out.append("\(try await cluster.spublish(sharded, "one shard"))")
            out.append(try await shardedSubscription.next(timeoutMilliseconds: 2_000)?.text ?? "none")
            return out.joined(separator: "|")
        }
        #expect(text == "everywhere|1|one shard", "\(text)")
    }

    /// Garuda's own Redis-backed stores, on a cluster. A session is one key;
    /// a refresh token's record, its family and its subject's index are three
    /// keys in three slots, which is what one write per slot is for.
    @Test func theStoresWorkOnACluster() throws {
        let text = try onCluster { cluster in
            var out: [String] = []
            // Names of this run's own, so that what an earlier run left --
            // a token already spent, a family already revoked -- is not this
            // run's answer.
            let run = "\(av_monotonic_us())"
            let sessions = RedisSessionStore(cluster, prefix: "cl:session:")
            try await sessions.save(id: run, data: ["user": "ada"], ttlMilliseconds: 60_000)
            out.append(try await sessions.load(id: run, ttlMilliseconds: 60_000)?["user"] ?? "nil")
            try await sessions.delete(id: run)
            out.append(try await sessions.load(id: run, ttlMilliseconds: 60_000) == nil ? "gone" : "there")

            let tokens = RedisRefreshTokenStore(cluster, prefix: "cl:refresh:")
            let until = Timestamp.now.secondsSinceEpoch + 3_600
            let digest = "dig" + run
            try await tokens.createFamily("fam" + run, subject: "ada" + run, expiresAt: until)
            try await tokens.insert(RefreshTokenRecord(digest: digest, family: "fam" + run,
                                                       subject: "ada" + run,
                                                       issuedAt: Timestamp.now.secondsSinceEpoch,
                                                       expiresAt: until, familyExpiresAt: until))
            let found = try await tokens.find(digest: digest)
            out.append("\(found?.subject == "ada" + run) \(found?.revoked == false)")
            out.append("\(try await tokens.markUsed(digest: digest, at: Timestamp.now.secondsSinceEpoch))")
            out.append("\(try await tokens.markUsed(digest: digest, at: Timestamp.now.secondsSinceEpoch))")
            try await tokens.revokeSubject("ada" + run)
            out.append("\(try await tokens.find(digest: digest)?.revoked == true)")
            return out.joined(separator: "|")
        }
        #expect(text == "ada|gone|true true|true|false|true", "\(text)")
    }

    /// The cluster is asked to promote a replica. Every slot that node owned
    /// is somewhere else afterwards, which the client finds out the way it
    /// finds out everything: by being told.
    @Test func aFailoverIsFollowed() throws {
        let text = try onCluster { cluster in
            try await cluster.refresh()
            let before = cluster.addresses.sorted()
            let slot = RedisSlots.slot(of: "cl:failover")
            try await cluster.set("cl:failover", "before")

            // A replica of the node that owns this slot, from the cluster's
            // own account of itself.
            let owner = cluster.slotRanges.first { slot >= $0.from && slot <= $0.to }?.address ?? "?"
            let reply = try await cluster.send(RedisCommand("CLUSTER", "SLOTS"))
            var replica: String? = nil
            for shard in reply.array ?? [] {
                guard let parts = shard.array, parts.count >= 4,
                      let master = parts[2].array, let host = master[0].string,
                      case .integer(let port) = master[1], "\(host):\(port)" == owner else { continue }
                if let node = parts[3].array, let host = node[0].string, case .integer(let port) = node[1] {
                    replica = "\(host):\(port)"
                }
            }
            guard let replica else { return "no replica for \(owner)" }

            var settings = cluster.seeds[0]
            let colon = replica.lastIndex(of: ":")!
            settings.host = String(replica[replica.startIndex..<colon])
            settings.port = UInt16(replica[replica.index(after: colon)...]) ?? 0
            let pool = RedisPool(settings, maxConnections: 1)
            defer { pool.close() }
            _ = try await pool.send(RedisCommand("CLUSTER", "FAILOVER"))

            // The promotion takes a moment. Meanwhile the old master redirects
            // for the slots it has given up, and the cluster follows.
            var owners: [String] = []
            for _ in 0..<40 {
                _ = try? await cluster.send(RedisCommand("PING"))
                try await cluster.refresh()
                let now = cluster.slotRanges.first { slot >= $0.from && slot <= $0.to }?.address ?? "?"
                owners.append(now)
                if now == replica { break }
                await pauseOnWorker(250)
            }
            var out: [String] = []
            out.append(owners.last == replica ? "promoted" : "still \(owners.last ?? "?")")
            // The value is there, read through whoever owns the slot now, and
            // writing still works.
            out.append(try await cluster.get("cl:failover") ?? "nil")
            try await cluster.set("cl:failover", "after")
            out.append(try await cluster.get("cl:failover") ?? "nil")
            out.append("\(cluster.addresses.count == before.count)")
            return out.joined(separator: "|")
        }
        #expect(text == "promoted|before|after|true", "\(text)")
    }
}

/// Waits on the worker's timer, from inside a handler.
private func pauseOnWorker(_ milliseconds: UInt64) async {
    guard let worker = currentWorker else { return }
    _ = await Worker.waitTimed(worker, milliseconds: milliseconds, register: { _ in })
}

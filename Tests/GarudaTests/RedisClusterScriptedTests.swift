import Testing
import CAvian
import AvianCore
@testable import Garuda

// A cluster of servers that say exactly what the test wants, on cue: ASK for
// a key that has already moved, TRYAGAIN for a slot in the middle of moving,
// and a node that goes away with a command in flight. A real cluster does
// these only while it is being resharded, and not to order.
//
// Both ends are on this thread, as in the other scripted tests: the worker
// turns, and every fake node is pumped on each turn.

nonisolated(unsafe) private var outcome = ""

/// Runs `body` against a cluster seeded with `seed`, turning the worker and
/// pumping every node until it answers.
private func run(_ nodes: [FakeRedisNode], seed: FakeRedisNode,
                 _ body: @escaping @Sendable (RedisCluster) async throws -> String) throws -> String {
    var configuration = RedisConfiguration(host: "127.0.0.1", port: seed.port)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 1_000
    let settled = configuration
    outcome = ""
    let app = Application()
    app.state { _ in RedisCluster(settled, maxConnectionsPerNode: 2) }
    app.get("/run") { (cluster: State<RedisCluster>) async -> String in
        do {
            outcome = try await body(cluster.value)
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

@Suite("Redis Cluster against scripted nodes", .serialized)
struct RedisClusterScriptedTests {
    /// `MOVED`: the slot is somewhere else for good. The command goes again to
    /// the node named, and the map remembers it.
    @Test func movedSendsTheCommandToTheNodeNamed() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            .init(expect: "GET", reply: "-MOVED 12182 \(b.address)\r\n"),
        ]
        b.script = [.init(expect: "GET", reply: "$5\r\nthere\r\n")]
        let result = try run([a, b], seed: a) { cluster in
            let value = try await cluster.get("foo") ?? "nil"
            let owner = cluster.slotRanges.first { 12_182 >= $0.from && 12_182 <= $0.to }?.address ?? "?"
            return "\(value)|\(owner == b.address)"
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(result == "there|true")
    }

    /// `ASK`: this one key has moved already, the rest of the slot has not.
    /// The command goes to the node taking the slot on, behind an `ASKING`
    /// that says the client knows -- and the map is left alone.
    @Test func askSendsAskingAndLeavesTheMapAlone() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            .init(expect: "GET", reply: "-ASK 12182 \(b.address)\r\n"),
        ]
        // One read holding ASKING and the command, so one write holding both
        // replies.
        b.script = [.init(expect: "ASKING", reply: "+OK\r\n$8\r\nmigrated\r\n")]
        let result = try run([a, b], seed: a) { cluster in
            let value = try await cluster.get("foo") ?? "nil"
            let owner = cluster.slotRanges.first { 12_182 >= $0.from && 12_182 <= $0.to }?.address ?? "?"
            return "\(value)|\(owner == a.address)"
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(b.received.last?.contains("GET") == true, "the command follows ASKING in one write")
        #expect(result == "migrated|true", "the slot still belongs to the node it is moving from")
    }

    /// `TRYAGAIN`: the keys are in a slot halfway between two nodes. Waiting
    /// and asking again is all a client can do, and is what it does.
    @Test func tryAgainIsTriedAgain() throws {
        let a = try #require(FakeRedisNode())
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            .init(expect: "MGET", reply: "-TRYAGAIN Multiple keys request during rehashing of slot\r\n"),
            .init(expect: "MGET", reply: "*2\r\n$1\r\n1\r\n$1\r\n2\r\n"),
        ]
        let result = try run([a], seed: a) { cluster in
            let reply = try await cluster.send(RedisCommand("MGET", "{t}:one", "{t}:two"))
            return (reply.array ?? []).compactMap(\.string).joined(separator: ",")
        }
        #expect(a.mismatches == [])
        #expect(result == "1,2")
    }

    /// A node that goes away with a command in flight. Whoever owns the slot
    /// now is in a map, and a map comes from whichever node is still there.
    @Test func aNodeThatGoesAwayIsLeftForWhoeverOwnsTheSlotNow() throws {
        let a = try #require(FakeRedisNode())
        let b = try #require(FakeRedisNode())
        a.script = [
            .init(expect: "SLOTS", reply: slotsReply([(0, 8_191, a.port), (8_192, 16_383, b.port)])),
            // Asked again once b has gone, and this time a owns everything.
            .init(expect: "SLOTS", reply: slotsReply([(0, 16_383, a.port)])),
            .init(expect: "GET", reply: "$5\r\nsaved\r\n"),
        ]
        b.script = [.init(expect: "GET", reply: nil, goAway: true)]
        let result = try run([a, b], seed: a) { cluster in
            let value = try await cluster.get("foo") ?? "nil"
            return "\(value)|\(cluster.addresses)"
        }
        #expect(a.mismatches + b.mismatches == [])
        #expect(result == "saved|[\"\(a.address)\"]")
    }

    /// A command that belongs to no slot -- `PING` -- goes to a node without
    /// the map being loaded for it.
    @Test func aCommandWithNoKeyGoesToAnyNode() throws {
        let a = try #require(FakeRedisNode())
        a.script = [.init(expect: "PING", reply: "+PONG\r\n")]
        let result = try run([a], seed: a) { cluster in
            "\(try await cluster.send(RedisCommand("PING")).string ?? "nil")"
        }
        #expect(a.mismatches == [])
        #expect(a.received.contains { $0.contains("SLOTS") } == false, "no map is needed to ping")
        #expect(result == "PONG")
    }
}

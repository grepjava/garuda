import Testing
import GarudaRedis
@testable import Garuda

// Which slot a key belongs to, where a command's keys are, and the three
// things a cluster says that are not answers: MOVED, ASK, and the map itself.
//
// Every slot number below is what a real Valkey 8 cluster answered
// `CLUSTER KEYSLOT` with, so the hash is held to the server's own, not to
// what this implementation believes.

@Suite("Redis cluster slots")
struct RedisSlotTests {
    @Test func keysHashToTheSlotTheServerSays() throws {
        #expect(RedisSlots.count == 16_384)
        #expect(RedisSlots.slot(of: "foo") == 12_182)
        #expect(RedisSlots.slot(of: "bar") == 5_061)
        #expect(RedisSlots.slot(of: "hello") == 866)
        #expect(RedisSlots.slot(of: "somekey") == 11_058)
        #expect(RedisSlots.slot(of: "") == 0)
        // The check value of CRC16/XMODEM, which is the hash a slot uses.
        #expect(RedisSlots.crc16(Array("123456789".utf8)[...]) == 0x31C3)
    }

    @Test func aHashTagIsWhatMakesKeysShareASlot() throws {
        #expect(RedisSlots.slot(of: "user:{42}:name") == 8_000)
        #expect(RedisSlots.slot(of: "user:{42}:email") == 8_000)
        #expect(RedisSlots.slot(of: "{user1000}.following") == 3_443)
        #expect(RedisSlots.slot(of: "user1000") == 3_443, "the tag is hashed, not the key")

        // An empty tag is no tag: the whole key is hashed.
        #expect(RedisSlots.slot(of: "{}{bar}") == 11_272)
        #expect(RedisSlots.slot(of: "foo{}{bar}") == 8_363)
        // The first brace and the first close after it, so the tag here is
        // `{bar` and not `bar`.
        #expect(RedisSlots.slot(of: "foo{{bar}}") == 4_015)
        // A close brace before the open one is part of no tag.
        #expect(RedisSlots.slot(of: "foo}{bar}") == 5_061)
        #expect(RedisSlots.slot(of: "foo{bar") == RedisSlots.slot(of: "foo{bar"), "unclosed: the whole key")
        #expect(RedisSlots.slot(of: "{bar}") == RedisSlots.slot(of: "bar"))
    }

    @Test func aCommandsKeysAreWhereRedisSaysTheyAre() throws {
        func keys(_ name: String, _ arguments: any RedisArgument...) -> [String] {
            RedisKeys.keys(of: RedisCommand(name, arguments: arguments))
                .map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(keys("GET", "k") == ["k"])
        #expect(keys("SET", "k", "v", "PX", 100) == ["k"])
        #expect(keys("INCRBY", "k", 2) == ["k"])
        #expect(keys("DEL", "a", "b", "c") == ["a", "b", "c"])
        #expect(keys("MGET", "a", "b") == ["a", "b"])
        #expect(keys("MSET", "a", 1, "b", 2) == ["a", "b"])
        #expect(keys("RENAME", "a", "b") == ["a", "b"])
        #expect(keys("BITOP", "AND", "dst", "a", "b") == ["dst", "a", "b"])
        #expect(keys("BLPOP", "a", "b", 0) == ["a", "b"])
        #expect(keys("ZUNIONSTORE", "dst", 2, "a", "b") == ["dst", "a", "b"])
        #expect(keys("ZINTERCARD", 2, "a", "b") == ["a", "b"])
        #expect(keys("OBJECT", "ENCODING", "k") == ["k"])
        #expect(keys("SORT", "k", "STORE", "d") == ["k", "d"])
        #expect(keys("XREAD", "COUNT", 2, "STREAMS", "s1", "s2", 0, 0) == ["s1", "s2"])
        #expect(keys("EVAL", "return 1", 2, "k1", "k2", "arg") == ["k1", "k2"])
        #expect(keys("EVALSHA", "abc", 1, "k1") == ["k1"])

        // Nothing keyed, so it may go to any node.
        #expect(keys("PING").isEmpty)
        #expect(keys("EVAL", "return 1", 0, "arg").isEmpty)
        #expect(keys("CLUSTER", "SLOTS").isEmpty)
        #expect(keys("SCRIPT", "LOAD", "return 1").isEmpty)
        #expect(keys("MULTI").isEmpty)
        // A channel is not a key, unless it is a sharded one.
        #expect(keys("SUBSCRIBE", "news").isEmpty)
        #expect(keys("PUBLISH", "news", "hi").isEmpty)
        #expect(keys("SPUBLISH", "news", "hi") == ["news"])
        #expect(keys("SSUBSCRIBE", "news") == ["news"])

        // A count that is not a number, or promises more keys than there are:
        // no keys rather than a crash or a wrong one.
        #expect(keys("EVAL", "return 1", "two", "k1", "k2").isEmpty)
        #expect(keys("EVAL", "return 1", 5, "k1").isEmpty)
        #expect(keys("EVAL").isEmpty)
        #expect(keys("GET").isEmpty)

        #expect(RedisKeys.slot(of: RedisCommand("GET", "foo")) == 12_182)
        #expect(RedisKeys.slot(of: RedisCommand("PING")) == nil)
    }

    /// `CLUSTER SLOTS`: a range, then the master and its replicas. Only the
    /// master is kept -- a replica answers a command nobody sent it MOVED.
    @Test func theMapIsReadFromClusterSlots() throws {
        func node(_ host: String, _ port: Int, _ id: String) -> RedisValue {
            .array([.bulkString(Array(host.utf8)), .integer(Int64(port)), .bulkString(Array(id.utf8))])
        }
        let reply = RedisValue.array([
            .array([.integer(0), .integer(5_460), node("10.0.0.1", 6_379, "a"), node("10.0.0.4", 6_379, "d")]),
            .array([.integer(5_461), .integer(16_383), node("10.0.0.2", 6_379, "b")]),
        ])
        let ranges = try #require(RedisCluster.parseSlots(reply))
        #expect(ranges.count == 2)
        #expect(ranges[0].from == 0 && ranges[0].to == 5_460 && ranges[0].address == "10.0.0.1:6379")
        #expect(ranges[1].address == "10.0.0.2:6379", "the replica is not an owner")

        // Shapes that are not a map: refused, so a stale map is kept rather
        // than replaced with nonsense.
        #expect(RedisCluster.parseSlots(.integer(1)) == nil)
        #expect(RedisCluster.parseSlots(.array([.array([.integer(0)])])) == nil)
        #expect(RedisCluster.parseSlots(.array([
            .array([.integer(5_000), .integer(1), node("h", 1, "a")])])) == nil, "backwards")
        #expect(RedisCluster.parseSlots(.array([
            .array([.integer(0), .integer(99_999), node("h", 1, "a")])])) == nil, "past the last slot")
        #expect(RedisCluster.parseSlots(.array([
            .array([.integer(0), .integer(1), node("h", 0, "a")])])) == nil, "port zero")
        #expect(RedisCluster.parseSlots(.array([])) != nil, "an empty map is a shape, just useless")
    }

    /// `MOVED 3999 127.0.0.1:6381`: the slot, and where it went.
    @Test func redirectsSayTheSlotAndTheNode() throws {
        let moved = try #require(RedisCluster.Redirect(.error(RedisServerError("MOVED 3999 127.0.0.1:6381"))))
        #expect(moved.kind == .moved && moved.slot == 3_999 && moved.address == "127.0.0.1:6381")
        let ask = try #require(RedisCluster.Redirect(.error(RedisServerError("ASK 42 10.0.0.2:7000"))))
        #expect(ask.kind == .ask && ask.slot == 42 && ask.address == "10.0.0.2:7000")
        // An IPv6 node, whose port is after the last colon and not the first.
        let six = try #require(RedisCluster.Redirect(.error(RedisServerError("MOVED 1 ::1:6379"))))
        #expect(six.address == "::1:6379")

        // Everything else is an error like any other, not a redirect.
        #expect(RedisCluster.Redirect(.error(RedisServerError("WRONGTYPE nope"))) == nil)
        #expect(RedisCluster.Redirect(.error(RedisServerError("MOVED"))) == nil)
        #expect(RedisCluster.Redirect(.error(RedisServerError("MOVED x 127.0.0.1:1"))) == nil)
        #expect(RedisCluster.Redirect(.error(RedisServerError("MOVED 99999 127.0.0.1:1"))) == nil)
        #expect(RedisCluster.Redirect(.error(RedisServerError("MOVED 1 nowhere"))) == nil)
        #expect(RedisCluster.Redirect(.simpleString("OK")) == nil)
    }
}

//===----------------------------------------------------------------------===//
// Which of a cluster's 16,384 slots a key belongs to, and where a command's
// keys are.
//
// A cluster splits the key space by slot, and a node owns a range of them. A
// client that knows the map sends each command straight to the node that owns
// its key; one that does not is told `MOVED` and has to go again. So this is
// how a command is aimed -- but never how correctness is decided. Redis
// itself has the last word: a command sent to the wrong node comes back
// `MOVED`, and the cluster follows it. The table below being incomplete, or
// wrong about a command added tomorrow, costs a round trip and nothing else.
//===----------------------------------------------------------------------===//

public enum RedisSlots {
    /// How many slots a cluster has, which the protocol fixes.
    public static let count = 16_384

    /// The slot a key belongs to: CRC16 of the key, or of its hash tag when it
    /// has one, modulo the number of slots.
    public static func slot(of key: String) -> Int {
        slot(of: Array(key.utf8))
    }

    public static func slot(of key: [UInt8]) -> Int {
        Int(crc16(hashTag(key))) % count
    }

    /// What is between the first `{` and the next `}` after it, when there is
    /// something between them -- and the whole key otherwise.
    ///
    /// This is how keys are made to share a slot, which is the only way a
    /// command may touch more than one of them: `user:{42}:name` and
    /// `user:{42}:email` are both slot 4,242's.
    public static func hashTag(_ key: [UInt8]) -> ArraySlice<UInt8> {
        guard let open = key.firstIndex(of: UInt8(ascii: "{")) else { return key[...] }
        let after = open + 1
        guard let close = key[after...].firstIndex(of: UInt8(ascii: "}")), close > after else {
            return key[...]
        }
        return key[after..<close]
    }

    /// CRC16/XMODEM: the polynomial 0x1021, starting at zero, as Redis
    /// computes it for a slot.
    public static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

/// Where the keys of a command are, so that it can be aimed at a node.
///
/// Redis publishes this per command through `COMMAND INFO`, which would be a
/// round trip and a cache; the commands below are the ones Garuda's own API
/// sends and the ones an application reaches for. Anything not named here is
/// assumed to keep its key first, which is true of nearly every command that
/// has one -- and where it is not, the server says `MOVED` and the cluster
/// follows it.
public enum RedisKeys {
    /// The keys `command` touches, in order. Empty means it belongs to no slot
    /// and may go to any node.
    public static func keys(of command: RedisCommand) -> [[UInt8]] {
        // The name is argument zero; `name` is already upper-cased.
        let arguments = Array(command.arguments.dropFirst())
        switch command.name {
        // Nothing keyed: the server itself, the connection, scripts as
        // objects, a transaction's frame, pub/sub over channels rather than
        // keys.
        case "PING", "ECHO", "INFO", "TIME", "DBSIZE", "LASTSAVE", "RESET", "QUIT",
             "HELLO", "AUTH", "SELECT", "SWAPDB", "CLIENT", "CONFIG", "COMMAND",
             "CLUSTER", "ACL", "MEMORY", "LATENCY", "SLOWLOG", "MONITOR", "SHUTDOWN",
             "REPLICAOF", "SLAVEOF", "FAILOVER", "SAVE", "BGSAVE", "BGREWRITEAOF",
             "FLUSHALL", "FLUSHDB", "SCAN", "RANDOMKEY", "SCRIPT", "FUNCTION",
             "MULTI", "EXEC", "DISCARD", "UNWATCH", "WAIT", "PUBLISH", "PUBSUB",
             "SUBSCRIBE", "PSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "READONLY",
             "READWRITE", "ASKING", "DEBUG", "SENTINEL":
            return []
        // A channel that is routed like a key: sharded pub/sub is per slot.
        case "SPUBLISH", "SSUBSCRIBE", "SUNSUBSCRIBE":
            return arguments.isEmpty ? [] : [arguments[0]]
        // Every argument is a key.
        case "DEL", "UNLINK", "EXISTS", "TOUCH", "MGET", "WATCH", "SINTER", "SUNION",
             "SDIFF", "PFCOUNT", "PFMERGE", "SUBSTR":
            return arguments
        // Every other argument, from the first.
        case "MSET", "MSETNX":
            return stride(from: 0, to: arguments.count, by: 2).map { arguments[$0] }
        // A count of keys, and then that many.
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO":
            return counted(arguments, countAt: 1)
        case "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE":
            // The destination, then a count and that many sources.
            guard let destination = arguments.first else { return [] }
            return [destination] + counted(arguments, countAt: 1)
        case "ZUNION", "ZINTER", "ZDIFF", "ZINTERCARD", "SINTERCARD", "LMPOP", "ZMPOP":
            return counted(arguments, countAt: 0)
        case "BLMPOP", "BZMPOP":
            // A timeout first, then the count.
            return counted(arguments, countAt: 1)
        // Two keys, side by side.
        case "RENAME", "RENAMENX", "SMOVE", "LMOVE", "RPOPLPUSH", "COPY", "LCS", "GEOSEARCHSTORE",
             "ZRANGESTORE":
            return Array(arguments.prefix(2))
        case "BLMOVE", "BRPOPLPUSH":
            return Array(arguments.prefix(2))
        // A destination, then sources.
        case "BITOP":
            return Array(arguments.dropFirst())
        // Keys, then a timeout as the last argument.
        case "BLPOP", "BRPOP", "BZPOPMIN", "BZPOPMAX":
            return Array(arguments.dropLast())
        // A subcommand, then the key.
        case "OBJECT", "XINFO", "XGROUP":
            return arguments.count >= 2 ? [arguments[1]] : []
        case "GEORADIUS", "GEORADIUSBYMEMBER", "SORT", "SORT_RO":
            // The key, and any STORE that follows.
            guard let key = arguments.first else { return [] }
            var keys = [key]
            for (i, argument) in arguments.enumerated() where i > 0 {
                let word = String(decoding: argument, as: UTF8.self).uppercased()
                if word == "STORE" || word == "STOREDIST", i + 1 < arguments.count {
                    keys.append(arguments[i + 1])
                }
            }
            return keys
        case "XREAD", "XREADGROUP":
            // Everything after STREAMS, half keys and half IDs.
            guard let streams = arguments.firstIndex(where: {
                String(decoding: $0, as: UTF8.self).uppercased() == "STREAMS"
            }) else { return [] }
            let rest = arguments[(streams + 1)...]
            return Array(rest.prefix(rest.count / 2))
        default:
            // The key is the first argument, if the command takes one at all.
            return arguments.isEmpty ? [] : [arguments[0]]
        }
    }

    /// The slot a command belongs to, or nil when it has no key -- and so can
    /// go to any node.
    ///
    /// A command whose keys are in different slots is aimed at the first of
    /// them. Redis then refuses it with CROSSSLOT, which says exactly what is
    /// wrong: keys touched together have to share a slot, which is what a
    /// hash tag is for.
    public static func slot(of command: RedisCommand) -> Int? {
        guard let first = keys(of: command).first else { return nil }
        return RedisSlots.slot(of: first)
    }

    /// `count` keys, starting after the count itself.
    private static func counted(_ arguments: [[UInt8]], countAt index: Int) -> [[UInt8]] {
        guard index < arguments.count,
              let count = Int(String(decoding: arguments[index], as: UTF8.self)),
              count > 0, index + count < arguments.count + 1 else { return [] }
        let start = index + 1
        let end = min(start + count, arguments.count)
        guard start < end else { return [] }
        return Array(arguments[start..<end])
    }
}

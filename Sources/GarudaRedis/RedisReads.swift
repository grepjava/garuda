//===----------------------------------------------------------------------===//
// Which commands only read, so that sending one again repeats nothing.
//
// This matters exactly once: when a connection fails with the bytes already
// written and no reply back. Whether the server ran the command is then
// unknowable from the client's side, and the only safe question left is
// whether running it twice would matter. For `GET` it would not. For `INCR`
// it would, and quietly.
//
// Redis publishes the answer per command as the `readonly` flag, which would
// be a `COMMAND INFO` round trip and a cache to keep. The list below is the
// commands Garuda's own API sends and the ones an application reaches for.
// Anything not named is treated as a write, which is the safe way to be
// wrong: an unnecessary error rather than a repeated one.
//===----------------------------------------------------------------------===//

public enum RedisReads {
    /// Whether `command` only reads.
    ///
    /// False for anything this does not recognise, and false for the few
    /// commands that read on one form and write on another -- `SORT` with
    /// `STORE`, `GETEX` with an expiry -- which are named by their read-only
    /// spellings instead.
    public static func only(_ command: RedisCommand) -> Bool {
        switch command.name {
        // Strings and keys.
        case "GET", "GETRANGE", "SUBSTR", "MGET", "STRLEN", "EXISTS", "TYPE",
             "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN",
             "RANDOMKEY", "DBSIZE", "DUMP", "OBJECT", "LCS",
             "BITCOUNT", "BITPOS", "GETBIT":
            return true
        // Hashes.
        case "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS",
             "HSTRLEN", "HRANDFIELD", "HSCAN":
            return true
        // Lists.
        case "LLEN", "LINDEX", "LRANGE", "LPOS":
            return true
        // Sets.
        case "SCARD", "SISMEMBER", "SMISMEMBER", "SMEMBERS", "SRANDMEMBER",
             "SSCAN", "SINTER", "SUNION", "SDIFF", "SINTERCARD":
            return true
        // Sorted sets.
        case "ZCARD", "ZCOUNT", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK",
             "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE",
             "ZRANGEBYLEX", "ZREVRANGEBYLEX", "ZLEXCOUNT", "ZRANDMEMBER",
             "ZSCAN", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD":
            return true
        // Streams. XREADGROUP is not here: it moves a group's cursor.
        case "XLEN", "XRANGE", "XREVRANGE", "XREAD", "XPENDING", "XINFO":
            return true
        // Geo, and the read-only spellings of the two that can store.
        case "GEODIST", "GEOPOS", "GEOHASH", "GEOSEARCH",
             "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO":
            return true
        // HyperLogLog: PFCOUNT may rewrite its own cached cardinality, which
        // is not something an application can see or count.
        case "PFCOUNT":
            return true
        // Scripts and functions promised read-only by the caller. Plain EVAL
        // is a write until the server is told otherwise.
        case "EVAL_RO", "EVALSHA_RO", "FCALL_RO", "SORT_RO":
            return true
        // The connection and the server itself. ASKING only tells the node
        // that the client knows a key has moved.
        case "PING", "ECHO", "TIME", "INFO", "LASTSAVE", "ROLE", "COMMAND",
             "ASKING":
            return true
        default:
            return false
        }
    }

    /// Whether every one of `commands` only reads, which is what makes a
    /// whole batch safe to send again.
    public static func only(_ commands: [RedisCommand]) -> Bool {
        commands.allSatisfy { only($0) }
    }
}

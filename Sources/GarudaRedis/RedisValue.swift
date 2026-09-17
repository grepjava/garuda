//===----------------------------------------------------------------------===//
// What a Redis server answers with: RESP2's five types and RESP3's additions,
// as one value.
//
// Like GarudaPostgres, this target has no sockets, no poller and no threads.
// Replies are parsed from bytes and commands written as bytes, so the protocol
// is tested against recorded exchanges and fuzzed, and the engine only moves
// bytes (Sources/Garuda/Redis.swift).
//===----------------------------------------------------------------------===//

/// One reply, or one element of one.
public enum RedisValue: Sendable, Equatable {
    /// `+OK`: a short status line.
    case simpleString(String)
    /// `-ERR ...` or RESP3's `!`: the server refusing a command. Only an
    /// element of a larger reply is left as a value -- a failed command in a
    /// transaction's result, say. A reply that is an error is thrown.
    case error(RedisServerError)
    case integer(Int64)
    /// A binary-safe string: whatever bytes were stored.
    case bulkString([UInt8])
    /// RESP2's null bulk string and null array, and RESP3's `_`.
    case null
    case array([RedisValue])
    // RESP3
    case double(Double)
    case boolean(Bool)
    /// A number too large for 64 bits, as its decimal digits.
    case bigNumber(String)
    /// Text with a three-letter format: `txt` or `mkd`.
    case verbatim(format: String, text: String)
    /// Key and value pairs, in the order the server sent them.
    case map([RedisPair])
    case set([RedisValue])
    /// Out-of-band data: a published message, a tracking invalidation.
    case push([RedisValue])

    /// The value as text: a bulk, simple or verbatim string, or a number
    /// written out. Nil for null and for anything else.
    public var string: String? {
        switch self {
        case .simpleString(let s): return s
        case .bulkString(let b): return String(decoding: b, as: UTF8.self)
        case .verbatim(_, let text): return text
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .bigNumber(let n): return n
        default: return nil
        }
    }

    /// The value's bytes: a bulk string's own, or a string's UTF-8.
    public var bytes: [UInt8]? {
        switch self {
        case .bulkString(let b): return b
        case .simpleString(let s): return Array(s.utf8)
        case .verbatim(_, let text): return Array(text.utf8)
        default: return nil
        }
    }

    /// The value as an integer: an integer reply, or a string holding one --
    /// what GET answers for a key INCR has counted.
    public var int: Int? {
        switch self {
        case .integer(let i): return Int(exactly: i)
        case .bulkString, .simpleString: return string.flatMap { Int($0) }
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        case .bulkString, .simpleString: return string.flatMap { Double($0) }
        default: return nil
        }
    }

    /// RESP3's boolean, or RESP2's way of saying one: the integer 1 or 0.
    public var bool: Bool? {
        switch self {
        case .boolean(let b): return b
        case .integer(1): return true
        case .integer(0): return false
        default: return nil
        }
    }

    /// The elements of an array, set or push, or of a map flattened into key,
    /// value, key, value -- the shape RESP2 gives the same reply.
    public var array: [RedisValue]? {
        switch self {
        case .array(let a), .set(let a), .push(let a): return a
        case .map(let pairs): return pairs.flatMap { [$0.key, $0.value] }
        default: return nil
        }
    }

    /// Key and value pairs: a map, or an array of alternating keys and values
    /// as RESP2 sends HGETALL.
    public var pairs: [RedisPair]? {
        switch self {
        case .map(let pairs): return pairs
        case .array(let a) where a.count % 2 == 0:
            return stride(from: 0, to: a.count, by: 2).map { RedisPair(key: a[$0], value: a[$0 + 1]) }
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }
}

public struct RedisPair: Sendable, Equatable {
    public var key: RedisValue
    public var value: RedisValue

    public init(key: RedisValue, value: RedisValue) {
        self.key = key
        self.value = value
    }
}

/// The server refusing a command: `WRONGTYPE Operation against a key holding
/// the wrong kind of value`.
public struct RedisServerError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// The first word, by convention the kind of error: `ERR`, `WRONGTYPE`,
    /// `NOAUTH`, `MOVED`. What to branch on.
    public var code: String {
        String(message.prefix { $0 != " " })
    }

    public var description: String { message }
}

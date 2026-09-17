//===----------------------------------------------------------------------===//
// Reading replies: RESP2 and RESP3, as they arrive.
//
// The parser resumes. Every whole line it reads is consumed and its place in
// the reply kept on a stack, so a reply of a million elements arriving over a
// thousand reads is parsed once, not a thousand times from its start. A bulk
// string is taken only once all of it is there; until then its header is left
// unconsumed, which costs one short line to read again.
//
// Every length and count is the server's claim and checked before it is used:
// against what has arrived, and against limits on a string's size, a reply's
// elements and its nesting, so neither a hostile server nor a corrupted stream
// can make a worker allocate without bound or recurse off its stack.
//===----------------------------------------------------------------------===//

/// Why a reply could not be read. After any of these the connection's stream
/// cannot be trusted and it is closed.
public enum RedisProtocolError: Error, Equatable, Sendable {
    /// A type byte RESP2 and RESP3 do not have.
    case unknownType(UInt8)
    /// A length or count that is not a number, or is negative where it may
    /// not be.
    case badLength
    /// A line longer than `maxLineBytes` without an end.
    case lineTooLong
    /// A bulk string longer than `maxBulkBytes`.
    case tooLarge
    /// A reply with more than `maxElements` elements in all.
    case tooManyElements
    /// A reply nested deeper than `maxDepth`.
    case tooDeep
    /// A value that is not what its type says: an integer that is not one, a
    /// bulk string not followed by CRLF.
    case badValue
    /// RESP3's streamed strings and aggregates, which no command this client
    /// sends is answered with.
    case streamed
}

public struct RedisParser {
    public struct Limits: Sendable {
        public var maxBulkBytes = 64 * 1024 * 1024
        public var maxElements = 1_000_000
        public var maxDepth = 32
        public var maxLineBytes = 64 * 1024

        public init() {}
    }

    public enum Outcome: Equatable {
        case value(RedisValue)
        /// More bytes are needed. What was consumed is held here; offer the
        /// rest, and what follows, next time.
        case incomplete
    }

    private enum Kind { case array, set, push, map, attribute }

    private struct Frame {
        var kind: Kind
        var remaining: Int
        var items: [RedisValue]
    }

    public let limits: Limits
    private var stack: [Frame] = []
    private var elements = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Whether part of a reply has been consumed and the rest not yet seen.
    public var isMidReply: Bool { !stack.isEmpty }

    /// Forgets a reply part-way through.
    public mutating func reset() {
        stack.removeAll()
        elements = 0
    }

    /// Reads the next reply from `count` bytes at `base`. Returns what it
    /// found and how many bytes it consumed, which the caller drops from its
    /// buffer either way.
    public mutating func parse(_ base: UnsafePointer<UInt8>, _ count: Int)
        throws(RedisProtocolError) -> (Outcome, consumed: Int) {
        var offset = 0
        while true {
            guard offset < count else { return (.incomplete, offset) }
            let type = base[offset]
            // Refused on the byte itself, before any of its line has to arrive.
            guard RedisParser.isType(type) else { throw .unknownType(type) }
            let lineStart = offset + 1
            // Scanned no further than a line may be long, so what lies past
            // the limit -- which may or may not have arrived yet -- cannot
            // change which error a long line is.
            guard let lineEnd = try RedisParser.lineEnd(base, from: lineStart, count,
                                                         limit: limits.maxLineBytes) else {
                if count - lineStart > limits.maxLineBytes + 1 { throw .lineTooLong }
                return (.incomplete, offset)
            }
            let lineLength = lineEnd - lineStart
            let line = UnsafeBufferPointer(start: base + lineStart, count: lineLength)
            var next = lineEnd + 2
            var scalar: RedisValue? = nil

            switch type {
            case UInt8(ascii: "+"):
                scalar = .simpleString(String(decoding: line, as: UTF8.self))
            case UInt8(ascii: "-"):
                scalar = .error(RedisServerError(String(decoding: line, as: UTF8.self)))
            case UInt8(ascii: ":"):
                guard let value = RedisParser.integer(line) else { throw .badValue }
                scalar = .integer(value)
            case UInt8(ascii: "_"):
                guard lineLength == 0 else { throw .badValue }
                scalar = .null
            case UInt8(ascii: "#"):
                guard lineLength == 1 else { throw .badValue }
                switch line[0] {
                case UInt8(ascii: "t"): scalar = .boolean(true)
                case UInt8(ascii: "f"): scalar = .boolean(false)
                default: throw .badValue
                }
            case UInt8(ascii: ","):
                guard let value = RedisParser.double(line) else { throw .badValue }
                scalar = .double(value)
            case UInt8(ascii: "("):
                guard RedisParser.isBigNumber(line) else { throw .badValue }
                scalar = .bigNumber(String(decoding: line, as: UTF8.self))

            case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
                if lineLength == 1 && line[0] == UInt8(ascii: "?") { throw .streamed }
                guard let length = RedisParser.integer(line) else { throw .badLength }
                if length == -1 && type == UInt8(ascii: "$") {
                    scalar = .null
                    break
                }
                guard length >= 0 else { throw .badLength }
                guard length <= limits.maxBulkBytes else { throw .tooLarge }
                let n = Int(length)
                // The header stays unconsumed until the whole string is here.
                guard count - next >= n + 2 else { return (.incomplete, offset) }
                guard base[next + n] == 13 && base[next + n + 1] == 10 else { throw .badValue }
                let payload = UnsafeBufferPointer(start: base + next, count: n)
                switch type {
                case UInt8(ascii: "$"):
                    scalar = .bulkString(Array(payload))
                case UInt8(ascii: "!"):
                    scalar = .error(RedisServerError(String(decoding: payload, as: UTF8.self)))
                default:
                    guard n >= 4, payload[3] == UInt8(ascii: ":") else { throw .badValue }
                    scalar = .verbatim(format: String(decoding: UnsafeBufferPointer(rebasing: payload[0..<3]),
                                                      as: UTF8.self),
                                       text: String(decoding: UnsafeBufferPointer(rebasing: payload[4...]),
                                                    as: UTF8.self))
                }
                next += n + 2

            case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"),
                 UInt8(ascii: "%"), UInt8(ascii: "|"):
                if lineLength == 1 && line[0] == UInt8(ascii: "?") { throw .streamed }
                guard let n = RedisParser.integer(line) else { throw .badLength }
                if n == -1 && type == UInt8(ascii: "*") {
                    scalar = .null
                    break
                }
                guard n >= 0 else { throw .badLength }
                guard n <= limits.maxElements else { throw .tooManyElements }
                let kind: Kind
                switch type {
                case UInt8(ascii: "*"): kind = .array
                case UInt8(ascii: "~"): kind = .set
                case UInt8(ascii: ">"): kind = .push
                case UInt8(ascii: "%"): kind = .map
                default: kind = .attribute
                }
                let items = (kind == .map || kind == .attribute) ? Int(n) * 2 : Int(n)
                elements += items
                guard elements <= limits.maxElements else { throw .tooManyElements }
                if items == 0 {
                    switch kind {
                    case .array: scalar = .array([])
                    case .set: scalar = .set([])
                    case .push: scalar = .push([])
                    case .map: scalar = .map([])
                    case .attribute: break
                    }
                    break
                }
                guard stack.count < limits.maxDepth else { throw .tooDeep }
                var frame = Frame(kind: kind, remaining: items, items: [])
                // What the server says is coming, up to what has arrived: a
                // count is a claim, and reserving on a claim is an allocation
                // a few bytes can ask for.
                frame.items.reserveCapacity(min(items, max(16, (count - next) / 4)))
                stack.append(frame)

            default:
                throw .unknownType(type)
            }

            offset = next
            guard var value = scalar else { continue }
            // Folded into whatever it is an element of, and those into theirs.
            while true {
                guard !stack.isEmpty else {
                    elements = 0
                    return (.value(value), offset)
                }
                let top = stack.count - 1
                stack[top].items.append(value)
                stack[top].remaining -= 1
                if stack[top].remaining > 0 { break }
                let frame = stack.removeLast()
                switch frame.kind {
                case .array: value = .array(frame.items)
                case .set: value = .set(frame.items)
                case .push: value = .push(frame.items)
                case .map:
                    value = .map(stride(from: 0, to: frame.items.count, by: 2).map {
                        RedisPair(key: frame.items[$0], value: frame.items[$0 + 1])
                    })
                case .attribute:
                    // Information about the value that follows, which this
                    // client has no use for. It is not an element of anything.
                    break
                }
                if frame.kind == .attribute { break }
            }
        }
    }

    // MARK: Pieces

    /// Where the line's CRLF starts, or nil when it has not arrived. A CR
    /// followed by anything else is not a line RESP has.
    private static func lineEnd(_ base: UnsafePointer<UInt8>, from start: Int, _ count: Int,
                                limit: Int) throws(RedisProtocolError) -> Int? {
        var i = start
        let stop = min(count, start + limit + 1)
        while i < stop {
            if base[i] == 13 {
                guard i + 1 < count else { return nil }
                guard base[i + 1] == 10 else { throw .badValue }
                return i
            }
            i += 1
        }
        return nil
    }

    static func isType(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "_"),
             UInt8(ascii: "#"), UInt8(ascii: ","), UInt8(ascii: "("), UInt8(ascii: "$"),
             UInt8(ascii: "!"), UInt8(ascii: "="), UInt8(ascii: "*"), UInt8(ascii: "~"),
             UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
            return true
        default:
            return false
        }
    }

    /// An optional minus and at least one digit, and nothing else, in range.
    static func integer(_ line: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard line.count > 0, line.count <= 20 else { return nil }
        var i = 0
        let negative = line[0] == UInt8(ascii: "-")
        if negative { i = 1 }
        guard i < line.count else { return nil }
        var value: Int64 = 0
        while i < line.count {
            let c = line[i]
            guard c >= 48 && c <= 57 else { return nil }
            let digit = Int64(c - 48)
            let (shifted, o1) = value.multipliedReportingOverflow(by: 10)
            let (sum, o2) = negative ? shifted.subtractingReportingOverflow(digit)
                                     : shifted.addingReportingOverflow(digit)
            guard !o1, !o2 else { return nil }
            value = sum
            i += 1
        }
        return value
    }

    static func double(_ line: UnsafeBufferPointer<UInt8>) -> Double? {
        guard line.count > 0, line.count <= 64 else { return nil }
        let text = String(decoding: line, as: UTF8.self)
        switch text {
        case "inf": return .infinity
        case "-inf": return -.infinity
        case "nan", "-nan": return .nan
        default: break
        }
        // Decimal only: no hex floats, no spaces, whatever Double(_:) allows.
        for c in line {
            switch c {
            case 48...57, UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."),
                 UInt8(ascii: "e"), UInt8(ascii: "E"):
                continue
            default:
                return nil
            }
        }
        return Double(text)
    }

    static func isBigNumber(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        if line.count > 0 && line[0] == UInt8(ascii: "-") { i = 1 }
        guard i < line.count else { return false }
        while i < line.count {
            guard line[i] >= 48 && line[i] <= 57 else { return false }
            i += 1
        }
        return true
    }
}

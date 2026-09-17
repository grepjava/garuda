import Testing
import AvianCore
import GarudaRedis

// The Redis protocol with no server: every RESP2 and RESP3 type, replies split
// at every byte, limits a hostile server runs into, commands as bytes, and the
// handshake's way through old and new servers.

private struct Parsed {
    var values: [RedisValue] = []
    var consumed = 0
}

/// Parses all of `text`, offered `chunk` bytes more at a time, as a
/// connection's buffer would be.
private func parse(_ text: String, chunk: Int = .max, limits: RedisParser.Limits = RedisParser.Limits())
    throws(RedisProtocolError) -> Parsed {
    try parse(Array(text.utf8), chunk: chunk, limits: limits)
}

private func parse(_ bytes: [UInt8], chunk: Int = .max, limits: RedisParser.Limits = RedisParser.Limits())
    throws(RedisProtocolError) -> Parsed {
    var parser = RedisParser(limits: limits)
    var out = Parsed()
    var buffer: [UInt8] = []
    var offered = 0
    while offered < bytes.count || !buffer.isEmpty {
        let more = min(chunk, bytes.count - offered)
        buffer.append(contentsOf: bytes[offered..<offered + more])
        offered += more
        var progressed = false
        while !buffer.isEmpty {
            let (outcome, consumed) = try buffer.withUnsafeBufferPointer { p throws(RedisProtocolError) in
                try parser.parse(p.baseAddress!, p.count)
            }
            buffer.removeFirst(consumed)
            out.consumed += consumed
            if consumed > 0 { progressed = true }
            guard case .value(let value) = outcome else { break }
            out.values.append(value)
        }
        if offered == bytes.count && !progressed { break }
    }
    return out
}

private func one(_ text: String) throws(RedisProtocolError) -> RedisValue? {
    try parse(text).values.first
}

@Suite("Redis protocol")
struct RedisProtocolTests {
    @Test func everyRESP2TypeReads() throws {
        #expect(try one("+OK\r\n") == .simpleString("OK"))
        #expect(try one("-WRONGTYPE Operation against a key\r\n")
                == .error(RedisServerError("WRONGTYPE Operation against a key")))
        #expect(try one(":1000\r\n") == .integer(1000))
        #expect(try one(":-42\r\n") == .integer(-42))
        #expect(try one("$5\r\nhello\r\n") == .bulkString(Array("hello".utf8)))
        #expect(try one("$0\r\n\r\n") == .bulkString([]))
        #expect(try one("$-1\r\n") == .null)
        #expect(try one("*-1\r\n") == .null)
        #expect(try one("*0\r\n") == .array([]))
        #expect(try one("*3\r\n:1\r\n*2\r\n+a\r\n$-1\r\n$1\r\nb\r\n")
                == .array([.integer(1), .array([.simpleString("a"), .null]), .bulkString([98])]))
        #expect(RedisServerError("WRONGTYPE Operation").code == "WRONGTYPE")
    }

    @Test func everyRESP3TypeReads() throws {
        #expect(try one("_\r\n") == .null)
        #expect(try one("#t\r\n") == .boolean(true))
        #expect(try one("#f\r\n") == .boolean(false))
        #expect(try one(",3.25\r\n") == .double(3.25))
        #expect(try one(",-1e3\r\n") == .double(-1000))
        #expect(try one(",inf\r\n") == .double(.infinity))
        #expect(try one(",-inf\r\n") == .double(-.infinity))
        if case .double(let nan)? = try one(",nan\r\n") { #expect(nan.isNaN) } else { Issue.record("nan") }
        #expect(try one("(3492890328409238509324850943850943825024385\r\n")
                == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try one("!21\r\nSYNTAX invalid syntax\r\n") == .error(RedisServerError("SYNTAX invalid syntax")))
        #expect(try one("=15\r\ntxt:Some string\r\n") == .verbatim(format: "txt", text: "Some string"))
        #expect(try one("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n")
                == .map([RedisPair(key: .simpleString("first"), value: .integer(1)),
                         RedisPair(key: .simpleString("second"), value: .integer(2))]))
        #expect(try one("~2\r\n+a\r\n+b\r\n") == .set([.simpleString("a"), .simpleString("b")]))
        #expect(try one(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n")
                == .push([.bulkString(Array("message".utf8)), .bulkString(Array("ch".utf8)),
                          .bulkString(Array("hi".utf8))]))
    }

    @Test func attributesAreSkipped() throws {
        // An attribute describes the value after it and is no value itself,
        // at the top level or inside an aggregate.
        #expect(try one("|1\r\n+key-popularity\r\n%1\r\n$1\r\na\r\n,0.19\r\n*2\r\n:2039123\r\n:9543892\r\n")
                == .array([.integer(2039123), .integer(9543892)]))
        #expect(try one("*2\r\n:1\r\n|1\r\n+ttl\r\n:3600\r\n:2\r\n") == .array([.integer(1), .integer(2)]))
    }

    @Test func aBulkStringIsBinarySafe() throws {
        #expect(try one("$6\r\na\r\n*1\r\r\n") == .bulkString(Array("a\r\n*1\r".utf8)))
    }

    @Test func replyThatArrivesInPiecesIsTheSameReply() throws {
        let text = "*4\r\n%1\r\n+k\r\n~2\r\n$3\r\nabc\r\n_\r\n$10\r\n0123456789\r\n|1\r\n+a\r\n+b\r\n,1.5\r\n>2\r\n+x\r\n:7\r\n+OK\r\n"
        let whole = try parse(text)
        #expect(whole.values.count == 2)
        #expect(whole.consumed == text.utf8.count)
        for chunk in 1...text.utf8.count {
            let pieces = try parse(text, chunk: chunk)
            #expect(pieces.values == whole.values, "split every \(chunk) bytes")
        }
    }

    @Test func aReplyStopsWhereItEnds() throws {
        var parser = RedisParser()
        let bytes = Array("+OK\r\n:1\r\n".utf8)
        let (outcome, consumed) = try bytes.withUnsafeBufferPointer { try parser.parse($0.baseAddress!, $0.count) }
        #expect(outcome == .value(.simpleString("OK")))
        #expect(consumed == 5)
    }

    @Test func anIncompleteBulkStringConsumesNothing() throws {
        var parser = RedisParser()
        let bytes = Array("$10\r\n01234".utf8)
        let (outcome, consumed) = try bytes.withUnsafeBufferPointer { try parser.parse($0.baseAddress!, $0.count) }
        #expect(outcome == .incomplete)
        #expect(consumed == 0)
    }

    @Test func malformedRepliesAreRefused() {
        let cases: [(String, RedisProtocolError)] = [
            ("?what\r\n", .unknownType(UInt8(ascii: "?"))),
            ("$abc\r\n", .badLength),
            ("$-2\r\n", .badLength),
            ("*-2\r\n", .badLength),
            ("%-1\r\n", .badLength),
            ("+OK\rX\n", .badValue),
            ("$3\r\nabcXY", .badValue),
            (":12a\r\n", .badValue),
            (":\r\n", .badValue),
            (":-\r\n", .badValue),
            (":99999999999999999999\r\n", .badValue),
            ("#x\r\n", .badValue),
            (",1.0abc\r\n", .badValue),
            (",0x10\r\n", .badValue),
            ("(12a\r\n", .badValue),
            ("_x\r\n", .badValue),
            ("=3\r\ntxt\r\n", .badValue),
            ("$?\r\n", .streamed),
            ("*?\r\n", .streamed),
        ]
        for (text, expected) in cases {
            #expect(throws: expected, "\(text.debugDescription)") { try parse(text) }
        }
    }

    @Test func limitsHoldAgainstWhatAServerClaims() {
        var limits = RedisParser.Limits()
        limits.maxBulkBytes = 16
        limits.maxElements = 10
        limits.maxDepth = 3
        limits.maxLineBytes = 32
        #expect(throws: RedisProtocolError.tooLarge) { try parse("$17\r\n", limits: limits) }
        #expect(throws: RedisProtocolError.tooManyElements) { try parse("*11\r\n", limits: limits) }
        // Counted across the reply, not per aggregate.
        #expect(throws: RedisProtocolError.tooManyElements) {
            try parse("*2\r\n*6\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n*6\r\n", limits: limits)
        }
        // A map's count is pairs.
        #expect(throws: RedisProtocolError.tooManyElements) { try parse("%6\r\n", limits: limits) }
        #expect(throws: RedisProtocolError.tooDeep) { try parse("*1\r\n*1\r\n*1\r\n*1\r\n", limits: limits) }
        #expect(throws: RedisProtocolError.lineTooLong) {
            try parse("+" + String(repeating: "a", count: 40), limits: limits)
        }
        // A count claimed in the billions is refused, not allocated for.
        #expect(throws: RedisProtocolError.tooManyElements) { try parse("*2147483647\r\n") }
        // The element count starts again with the next reply.
        #expect((try? parse("*6\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n*6\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n",
                            limits: limits).values.count) == 2)
    }

    @Test func valuesReadAsTheTypesAskedFor() {
        #expect(RedisValue.bulkString(Array("42".utf8)).int == 42)
        #expect(RedisValue.integer(1).bool == true)
        #expect(RedisValue.boolean(false).bool == false)
        #expect(RedisValue.verbatim(format: "txt", text: "hi").string == "hi")
        #expect(RedisValue.array([.bulkString([97]), .integer(1)]).pairs == [RedisPair(key: .bulkString([97]), value: .integer(1))])
        #expect(RedisValue.map([RedisPair(key: .simpleString("a"), value: .null)]).array == [.simpleString("a"), .null])
        #expect(RedisValue.array([.integer(1)]).pairs == nil)
        #expect(RedisValue.null.string == nil)
    }

    @Test func commandsAreArraysOfBulkStrings() {
        let command = RedisCommand("set", "key", "va\r\nlue", 12, [UInt8]([0, 255]), 1.5, true)
        #expect(String(decoding: command.bytes(), as: UTF8.self)
                == "*7\r\n$3\r\nset\r\n$3\r\nkey\r\n$7\r\nva\r\nlue\r\n$2\r\n12\r\n$2\r\n\u{0}\u{FFFD}\r\n$3\r\n1.5\r\n$1\r\n1\r\n")
        #expect(command.bytes().count == 67)
        #expect(command.name == "SET")
        #expect(RedisCommand("PING").bytes() == Array("*1\r\n$4\r\nPING\r\n".utf8))
    }

    @Test func theHandshakeSpeaksRESP3WhenItCan() throws {
        var handshake = RedisHandshake(username: "app", password: "secret", clientName: "garuda", database: 2)
        let hello = handshake.start()
        #expect(hello.arguments.map { String(decoding: $0, as: UTF8.self) }
                == ["HELLO", "3", "AUTH", "app", "secret", "SETNAME", "garuda"])
        let step = try handshake.receive(.map([RedisPair(key: .simpleString("version"), value: .bulkString(Array("7.4.2".utf8))),
                                               RedisPair(key: .simpleString("proto"), value: .integer(3))]))
        #expect(step == .send(RedisCommand("SELECT", 2)))
        #expect(try handshake.receive(.simpleString("OK")) == .ready)
        #expect(handshake.protocolVersion == 3)
        #expect(handshake.server["version"] == "7.4.2")
    }

    @Test func aServerWithoutHELLOIsSpokenToInRESP2() throws {
        var handshake = RedisHandshake(password: "secret", clientName: "garuda")
        _ = handshake.start()
        let auth = try handshake.receive(.error(RedisServerError("ERR unknown command 'HELLO', with args beginning with: '3'")))
        #expect(auth == .send(RedisCommand("AUTH", "secret")))
        #expect(try handshake.receive(.simpleString("OK")) == .send(RedisCommand("CLIENT", "SETNAME", "garuda")))
        #expect(try handshake.receive(.simpleString("OK")) == .ready)
        #expect(handshake.protocolVersion == 2)

        var noproto = RedisHandshake()
        _ = noproto.start()
        #expect(try noproto.receive(.error(RedisServerError("NOPROTO unsupported protocol version"))) == .ready)
        #expect(noproto.protocolVersion == 2)
    }

    @Test func aRefusedPasswordIsNotRetriedAnotherWay() throws {
        var handshake = RedisHandshake(password: "wrong")
        _ = handshake.start()
        let refusal = RedisServerError("WRONGPASS invalid username-password pair or user is disabled.")
        #expect(throws: RedisHandshakeError.authentication(refusal)) { try handshake.receive(.error(refusal)) }

        var badDatabase = RedisHandshake(database: 99)
        _ = badDatabase.start()
        _ = try badDatabase.receive(.map([]))
        let range = RedisServerError("ERR DB index is out of range")
        #expect(throws: RedisHandshakeError.refused(range)) { try badDatabase.receive(.error(range)) }
    }
}

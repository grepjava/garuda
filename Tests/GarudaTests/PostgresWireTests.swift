import Testing
@testable import AvianCore
@testable import GarudaPostgres

// The PostgreSQL wire codec. Every length and count a backend message carries
// is the server's claim, so most of these are about claims that cannot be
// true: a length shorter than itself, a count the body cannot hold, a string
// with no end, a column length below -1.

private func frame(_ bytes: [UInt8], max: Int = 1 << 20) -> PostgresFramed {
    bytes.withUnsafeBufferPointer { buf in
        PostgresBackend.frame(buf.baseAddress ?? UnsafePointer(bitPattern: 1)!, buf.count,
                              maxLength: max)
    }
}

/// A backend message: type, length, body.
private func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
    let length = UInt32(body.count + 4)
    return [UInt8(ascii: type.unicodeScalars.first!),
            UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + body
}

private func i16(_ v: Int16) -> [UInt8] {
    let u = UInt16(bitPattern: v)
    return [UInt8(u >> 8), UInt8(truncatingIfNeeded: u)]
}

private func i32(_ v: Int32) -> [UInt8] {
    let u = UInt32(bitPattern: v)
    return [UInt8(u >> 24), UInt8(truncatingIfNeeded: u >> 16),
            UInt8(truncatingIfNeeded: u >> 8), UInt8(truncatingIfNeeded: u)]
}

private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

/// Runs `body` on a reader over `bytes`.
///
/// Takes an untyped closure: a closure literal does not pick up a typed throw
/// from the parameter it is passed to, so the error comes back as `any Error`
/// and is put back here.
private func reading<T>(_ bytes: [UInt8],
                        _ body: (PostgresReader) throws -> T)
    -> Result<T, PostgresProtocolError> {
    let storage = bytes.isEmpty ? [UInt8(0)] : bytes
    return storage.withUnsafeBufferPointer { buf in
        do {
            return .success(try body(PostgresReader(buf.baseAddress!, bytes.count)))
        } catch {
            return .failure((error as? PostgresProtocolError) ?? .truncated)
        }
    }
}

private func refusal<T>(_ result: Result<T, PostgresProtocolError>) -> PostgresProtocolError? {
    if case .failure(let e) = result { return e }
    return nil
}

private func written(_ body: (inout ByteBuffer) -> Bool) -> [UInt8]? {
    var out = ByteBuffer(capacity: 256)
    defer { out.destroy() }
    guard body(&out) else { return nil }
    return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
}

@Suite("PostgreSQL wire")
struct PostgresWireTests {

    // MARK: Framing

    @Test func aMessageShorterThanItsHeaderIsIncomplete() throws {
        #expect(frame([UInt8(ascii: "Z"), 0, 0, 0]) == .incomplete)
    }

    @Test func aWholeMessageIsFramed() throws {
        let bytes = message("Z", [UInt8(ascii: "I")])
        #expect(frame(bytes) == .frame(PostgresFrame(type: UInt8(ascii: "Z"),
                                                     bodyOffset: 5, bodyLength: 1)))
    }

    @Test func aBodyNotYetArrivedIsIncomplete() throws {
        let bytes = message("C", cstr("SELECT 1"))
        #expect(frame(Array(bytes.dropLast())) == .incomplete)
    }

    @Test func aLengthShorterThanItselfIsRefused() throws {
        // Four is the least a length can be, since it counts its own bytes.
        #expect(frame([UInt8(ascii: "Z"), 0, 0, 0, 3]) == .failure(.badLength))
    }

    @Test func aLengthPastTheLimitIsRefusedBeforeTheBodyIsWaitedFor() throws {
        // Five bytes claiming a gigabyte. Refused on those five bytes, not
        // after buffering however much the server said was coming.
        #expect(frame([UInt8(ascii: "D"), 0x40, 0, 0, 0], max: 1 << 20) == .failure(.tooLarge))
    }

    // MARK: Authentication

    @Test func authenticationRequestsAreRead() throws {
        #expect(try reading(i32(0)) { try PostgresBackend.authentication($0) }.get() == .ok)
        #expect(try reading(i32(3)) { try PostgresBackend.authentication($0) }.get()
                == .cleartextPassword)
        #expect(try reading(i32(5) + [1, 2, 3, 4]) { try PostgresBackend.authentication($0) }.get()
                == .md5Password(salt: [1, 2, 3, 4]))
        #expect(try reading(i32(11) + [9, 8]) { try PostgresBackend.authentication($0) }.get()
                == .saslContinue([9, 8]))
        #expect(try reading(i32(12) + [7]) { try PostgresBackend.authentication($0) }.get()
                == .saslFinal([7]))
    }

    @Test func saslMechanismsAreReadToTheirTerminator() throws {
        let body = i32(10) + cstr("SCRAM-SHA-256-PLUS") + cstr("SCRAM-SHA-256") + [0]
        #expect(try reading(body) { try PostgresBackend.authentication($0) }.get()
                == .sasl(mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]))
    }

    @Test func aMechanismListWithoutItsTerminatorIsRefused() throws {
        // A list that stops short is a list this client may have read only
        // part of -- which, for a list of what the server will accept, is not
        // a list to choose from.
        let body = i32(10) + cstr("SCRAM-SHA-256")
        #expect(refusal(reading(body) { try PostgresBackend.authentication($0) }) == .unterminated)
    }

    @Test func anUnknownAuthenticationRequestIsRefused() throws {
        #expect(refusal(reading(i32(7)) { try PostgresBackend.authentication($0) })
                == .unsupportedAuthentication(7))
    }

    @Test func extraBytesAfterAFixedShapeAreRefused() throws {
        // `ok` has nothing after its code. Something there means the message
        // is not the shape its type says, which is not safe to half-believe.
        #expect(refusal(reading(i32(0) + [0]) { try PostgresBackend.authentication($0) })
                == .trailingBytes)
    }

    // MARK: Status messages

    @Test func aParameterStatusIsRead() throws {
        let result = reading(cstr("server_version") + cstr("16.15")) {
            try PostgresBackend.parameterStatus($0)
        }
        #expect(try result.get() == ("server_version", "16.15"))
    }

    @Test func aStringWithNoEndIsRefused() throws {
        #expect(refusal(reading(Array("server_version".utf8)) {
            try PostgresBackend.parameterStatus($0)
        }) == .unterminated)
    }

    @Test func backendKeyDataIsRead() throws {
        let result = reading(i32(4242) + i32(-17)) { try PostgresBackend.backendKeyData($0) }
        #expect(try result.get() == (4242, -17))
    }

    @Test func readyForQueryStatusesAreRead() throws {
        for (byte, status) in [("I", PostgresTransactionStatus.idle),
                               ("T", .inTransaction), ("E", .failedTransaction)] {
            let body = [UInt8(ascii: byte.unicodeScalars.first!)]
            #expect(try reading(body) { try PostgresBackend.readyForQuery($0) }.get() == status)
        }
        #expect(refusal(reading([UInt8(ascii: "X")]) { try PostgresBackend.readyForQuery($0) })
                == .badCount)
    }

    @Test func aCommandTagIsRead() throws {
        #expect(try reading(cstr("INSERT 0 1")) { try PostgresBackend.commandComplete($0) }.get()
                == "INSERT 0 1")
    }

    // MARK: Errors

    @Test func anErrorResponseIsRead() throws {
        let body = [UInt8(ascii: "S")] + cstr("ERROR")
            + [UInt8(ascii: "C")] + cstr("23505")
            + [UInt8(ascii: "M")] + cstr("duplicate key value")
            + [UInt8(ascii: "D")] + cstr("Key (id)=(1) already exists.")
            + [UInt8(ascii: "n")] + cstr("users_pkey")
            + [UInt8(ascii: "R")] + cstr("_bt_check_unique")
            + [0]
        let fields = try? reading(body) { try PostgresBackend.errorFields($0) }.get()
        #expect(fields?.code == "23505")
        #expect(fields?.message == "duplicate key value")
        #expect(fields?.detail == "Key (id)=(1) already exists.")
        #expect(fields?.constraint == "users_pkey")
    }

    @Test func anErrorResponseWithoutItsTerminatorIsRefused() throws {
        let body = [UInt8(ascii: "C")] + cstr("23505")
        #expect(refusal(reading(body) { try PostgresBackend.errorFields($0) }) == .truncated)
    }

    // MARK: Rows

    @Test func aRowDescriptionIsRead() throws {
        let body = i16(2)
            + cstr("id") + i32(16384) + i16(1) + i32(23) + i16(4) + i32(-1) + i16(0)
            + cstr("name") + i32(16384) + i16(2) + i32(25) + i16(-1) + i32(-1) + i16(0)
        let columns = try? reading(body) { try PostgresBackend.rowDescription($0) }.get()
        #expect(columns?.map(\.name) == ["id", "name"])
        #expect(columns?.map(\.typeOID) == [23, 25])
        #expect(columns?.allSatisfy { !$0.binary } == true)
    }

    @Test func aColumnCountTheBodyCannotHoldIsRefused() throws {
        // Refused before an array is sized to it: thirty thousand columns in
        // a body of two bytes is an allocation, not a description.
        #expect(refusal(reading(i16(30_000)) { try PostgresBackend.rowDescription($0) })
                == .badCount)
        #expect(refusal(reading(i16(-1)) { try PostgresBackend.rowDescription($0) })
                == .badCount)
    }

    @Test func aDataRowIsReadAsRangesWithNull() throws {
        let body = i16(3) + i32(1) + Array("7".utf8) + i32(-1) + i32(3) + Array("bob".utf8)
        var values: [Range<Int>?] = []
        let ok = reading(body) { (r: PostgresReader) throws in
            try PostgresBackend.dataRow(r, into: &values)
        }
        #expect((try? ok.get()) != nil)
        #expect(values.count == 3)
        #expect(values[1] == nil)
        let texts = values.compactMap { $0 }.map { String(decoding: body[$0], as: UTF8.self) }
        #expect(texts == ["7", "bob"])
    }

    @Test func aColumnLengthBelowMinusOneIsRefused() throws {
        // -1 is NULL. Nothing else below zero means anything, and -2 read as
        // a length is a read backwards.
        var values: [Range<Int>?] = []
        let result = reading(i16(1) + i32(-2)) { (r: PostgresReader) throws in
            try PostgresBackend.dataRow(r, into: &values)
        }
        #expect(refusal(result) == .badCount)
    }

    @Test func aColumnLongerThanTheRowIsRefused() throws {
        var values: [Range<Int>?] = []
        let result = reading(i16(1) + i32(100) + [1, 2]) {
            (r: PostgresReader) throws in
            try PostgresBackend.dataRow(r, into: &values)
        }
        #expect(refusal(result) == .truncated)
    }

    @Test func aDataRowColumnCountTheBodyCannotHoldIsRefused() throws {
        var values: [Range<Int>?] = []
        let result = reading(i16(1000)) { (r: PostgresReader) throws in
            try PostgresBackend.dataRow(r, into: &values)
        }
        #expect(refusal(result) == .badCount)
    }

    @Test func aParameterDescriptionIsRead() throws {
        let result = reading(i16(2) + i32(23) + i32(25)) {
            try PostgresBackend.parameterDescription($0)
        }
        #expect(try result.get() == [23, 25])
    }

    // MARK: Frontend messages, byte for byte

    @Test func theStartupMessageIsLaidOutAsTheProtocolSays() throws {
        let bytes = written {
            PostgresFrontend.startup(user: "garuda", database: "app", into: &$0)
        }
        let body = i32(196_608) + cstr("user") + cstr("garuda") + cstr("database") + cstr("app") + [0]
        #expect(bytes == i32(Int32(body.count + 4)) + body)
    }

    @Test func aNulInAStartupParameterIsRefused() throws {
        // The message is NUL-separated. A user name with a NUL inside it ends
        // early and becomes a second parameter chosen by whoever supplied it.
        #expect(written { PostgresFrontend.startup(user: "a\u{0}database", database: nil,
                                                   into: &$0) } == nil)
    }

    @Test func theSSLRequestIsLaidOutAsTheProtocolSays() throws {
        let bytes = written { PostgresFrontend.sslRequest(into: &$0); return true }
        #expect(bytes == i32(8) + i32(80_877_103))
    }

    @Test func extendedQueryMessagesAreLaidOutAsTheProtocolSays() throws {
        #expect(written { PostgresFrontend.parse(name: "", sql: "select $1", parameterTypes: [23],
                                                 into: &$0) }
                == message("P", cstr("") + cstr("select $1") + i16(1) + i32(23)))
        #expect(written { PostgresFrontend.bind(portal: "", statement: "", values: [PostgresValue("7"), .null],
                                                into: &$0) }
                == message("B", cstr("") + cstr("") + i16(0) + i16(2)
                           + i32(1) + Array("7".utf8) + i32(-1) + i16(0)))
        // A binary parameter makes the formats explicit, one per parameter,
        // and results can be asked for per column.
        #expect(written { PostgresFrontend.bind(portal: "p", statement: "s",
                                                values: [PostgresValue("7"), .binary([1, 2], type: 17)],
                                                resultFormats: [1, 0], into: &$0) }
                == message("B", cstr("p") + cstr("s") + i16(2) + i16(0) + i16(1) + i16(2)
                           + i32(1) + Array("7".utf8) + i32(2) + [1, 2] + i16(2) + i16(1) + i16(0)))
        #expect(written { PostgresFrontend.describe(portal: "", into: &$0) }
                == message("D", [UInt8(ascii: "P")] + cstr("")))
        #expect(written { PostgresFrontend.execute(portal: "", into: &$0) }
                == message("E", cstr("") + i32(0)))
        #expect(written { PostgresFrontend.sync(into: &$0); return true } == message("S", []))
        #expect(written { PostgresFrontend.close(statement: "garuda_7", into: &$0) }
                == message("C", [UInt8(ascii: "S")] + cstr("garuda_7")))
    }

    @Test func aNulInSQLIsRefusedRatherThanTruncatingIt() throws {
        // The server would read the statement up to the NUL and run that --
        // a different statement from the one that was written.
        #expect(written { PostgresFrontend.parse(name: "", sql: "select 1\u{0}; drop table x",
                                                 parameterTypes: [], into: &$0) } == nil)
        #expect(written { PostgresFrontend.query("select 1\u{0}", into: &$0) } == nil)
    }

    @Test func saslMessagesCarryTheirData() throws {
        #expect(written { PostgresFrontend.saslInitialResponse(mechanism: "SCRAM-SHA-256",
                                                               data: [1, 2, 3], into: &$0); return true }
                == message("p", cstr("SCRAM-SHA-256") + i32(3) + [1, 2, 3]))
        #expect(written { PostgresFrontend.saslResponse([4, 5], into: &$0); return true }
                == message("p", [4, 5]))
    }

    // MARK: bytea

    @Test func byteaHexDecodes() {
        #expect(PostgresBytea.decodeHex(ArraySlice(Array("\\x".utf8))) == [])
        #expect(PostgresBytea.decodeHex(ArraySlice(Array("\\x00ff7Fa0".utf8))) == [0, 255, 127, 160])
        // A slice that does not start at zero, as a cell in a result is.
        let row = Array("junk\\x0102".utf8)
        #expect(PostgresBytea.decodeHex(row[4...]) == [1, 2])
    }

    @Test func byteaThatIsNotHexIsRefused() {
        for bad in ["", "x00", "\\x0", "\\xzz", "\\000", "/x00"] {
            #expect(PostgresBytea.decodeHex(ArraySlice(Array(bad.utf8))) == nil, "\(bad)")
        }
    }

    // MARK: Binary values

    @Test func floatsAreWrittenAsTheServerWritesThem() {
        let float8: [(Double, String)] = [
            (0.1, "0.1"), (1.5, "1.5"), (100, "100"), (1e14, "100000000000000"), (1e15, "1e+15"),
            (123456789012345, "123456789012345"), (1.5e20, "1.5e+20"), (1e-4, "0.0001"), (1e-5, "1e-05"),
            (0.000123, "0.000123"), (-2.5, "-2.5"), (0, "0"), (-0.0, "-0"), (5e-324, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"), (.nan, "NaN"), (.infinity, "Infinity"),
            (-.infinity, "-Infinity"),
        ]
        for (value, expected) in float8 {
            #expect(PostgresBinary.text(ArraySlice(bigEndian(value.bitPattern)), type: PostgresType.float8) == expected)
        }
        let float4: [(Float, String)] = [
            (0.1, "0.1"), (123456, "123456"), (1e6, "1e+06"), (3.4e38, "3.4e+38"), (1.5e-7, "1.5e-07"),
            (12.25, "12.25"),
        ]
        for (value, expected) in float4 {
            #expect(PostgresBinary.text(ArraySlice(bigEndian(value.bitPattern)), type: PostgresType.float4) == expected)
        }
    }

    @Test func binaryIntegersAndBooleansRead() {
        #expect(PostgresBinary.integer(ArraySlice(bigEndian(UInt16(bitPattern: -2)))) == -2)
        #expect(PostgresBinary.integer(ArraySlice(bigEndian(UInt32(bitPattern: Int32.min)))) == Int64(Int32.min))
        #expect(PostgresBinary.integer(ArraySlice(bigEndian(UInt64(bitPattern: Int64.max)))) == Int64.max)
        #expect(PostgresBinary.integer([1, 2, 3][...]) == nil)
        #expect(PostgresBinary.bool([1][...]) == true)
        #expect(PostgresBinary.bool([0][...]) == false)
        #expect(PostgresBinary.bool([2][...]) == nil)
        #expect(PostgresBinary.text([0, 0xAB][...], type: PostgresType.bytea) == "\\x00ab")
    }

    @Test func onlyDecodableColumnsAreAskedForInBinary() {
        func column(_ type: UInt32) -> PostgresColumn {
            PostgresColumn(name: "c", tableOID: 0, attribute: 0, typeOID: type, size: 0, modifier: 0, binary: false)
        }
        #expect(PostgresBinary.resultFormats([column(PostgresType.text), column(1043)]) == [])
        #expect(PostgresBinary.resultFormats([column(PostgresType.int4), column(PostgresType.text)]) == [1, 0])
    }
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

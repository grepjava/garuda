import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// Arrays: the text form both ways, the OID an element has, and lists bound
// and read back through a real server.

private struct Tag: Codable, Equatable, Sendable {
    let name: String
}

@Suite("PostgreSQL arrays")
struct PostgresArrayTests {
    @Test func parsesWhatTheServerWrites() throws {
        #expect(PostgresArrayText.parse("{1,2,3}") == ["1", "2", "3"])
        #expect(PostgresArrayText.parse("{}") == [])
        #expect(PostgresArrayText.parse("{swift,http}") == ["swift", "http"])
        // Quotes, and what they hold: a comma, a brace, a quote, a backslash.
        #expect(PostgresArrayText.parse(#"{"a,b"}"#) == ["a,b"])
        #expect(PostgresArrayText.parse(#"{"{}"}"#) == ["{}"])
        #expect(PostgresArrayText.parse(#"{"say \"hi\""}"#) == [#"say "hi""#])
        #expect(PostgresArrayText.parse(#"{"back\\slash"}"#) == [#"back\slash"#])
        #expect(PostgresArrayText.parse(#"{""}"#) == [""])
        // NULL is the bare word; quoted, it is four letters.
        #expect(PostgresArrayText.parse("{1,NULL,3}") == ["1", nil, "3"])
        #expect(PostgresArrayText.parse("{null}") == [nil])
        #expect(PostgresArrayText.parse(#"{"NULL"}"#) == ["NULL"])
        #expect(PostgresArrayText.parse(#"{\N\U\L\L}"#) == ["NULL"], "escaped, so not a NULL")
        // Whitespace around an unquoted element is not part of it; inside is.
        #expect(PostgresArrayText.parse("{ a , b }") == ["a", "b"])
        #expect(PostgresArrayText.parse("{two words,b}") == ["two words", "b"])
        #expect(PostgresArrayText.parse(#"{ "a" , "b" }"#) == ["a", "b"])
        #expect(PostgresArrayText.parse(#"{" a "}"#) == [" a "], "quoted whitespace is the value")
        // The bounds the server writes when the lower one is not 1.
        #expect(PostgresArrayText.parse("[0:2]={1,2,3}") == ["1", "2", "3"])
    }

    @Test func refusesWhatIsNotOneDimension() throws {
        // Rectangular arrays of more than one dimension: refused rather than
        // flattened into a list that was never one.
        #expect(PostgresArrayText.parse("{{1,2},{3,4}}") == nil)
        #expect(PostgresArrayText.parse("1,2") == nil)
        #expect(PostgresArrayText.parse("") == nil)
        #expect(PostgresArrayText.parse("{1,2") == nil)
        #expect(PostgresArrayText.parse("1,2}") == nil)
        #expect(PostgresArrayText.parse(#"{"unterminated}"#) == nil)
        #expect(PostgresArrayText.parse("{1,}") == nil, "no element after the comma")
        #expect(PostgresArrayText.parse("{,1}") == nil)
        #expect(PostgresArrayText.parse("{1, }") == nil)
    }

    @Test func formatsWhatTheServerTakes() throws {
        #expect(PostgresArrayText.format([]) == "{}")
        #expect(PostgresArrayText.format(["1", "2"]) == #"{"1","2"}"#)
        #expect(PostgresArrayText.format(["a,b", nil]) == #"{"a,b",NULL}"#)
        #expect(PostgresArrayText.format(["NULL"]) == #"{"NULL"}"#, "a value spelling NULL is quoted")
        #expect(PostgresArrayText.format([#"say "hi""#]) == #"{"say \"hi\""}"#)
        #expect(PostgresArrayText.format([#"back\slash"#]) == #"{"back\\slash"}"#)
        #expect(PostgresArrayText.format([""]) == #"{""}"#)

        // Whatever is written, reading it back gives the same elements.
        for elements in [["1", "2"], ["a,b", "{", #"\"#, #"""#, "", "NULL", " x "], []] as [[String?]] {
            #expect(PostgresArrayText.parse(PostgresArrayText.format(elements)) == elements)
        }
        #expect(PostgresArrayText.parse(PostgresArrayText.format([nil, "1", nil])) == [nil, "1", nil])
    }

    @Test func listsBindAsArrayLiterals() throws {
        #expect(boundText(["swift", "http"].postgresValue) == #"{"swift","http"}"#)
        #expect(boundText([1, 2, 3].postgresValue) == #"{"1","2","3"}"#)
        #expect(boundText([true, false].postgresValue) == #"{"true","false"}"#)
        #expect(boundText([String]().postgresValue) == "{}")
        #expect(boundText(["a", nil, "b"].postgresValue) == #"{"a",NULL,"b"}"#)
        #expect(boundText([PostgresDate(2026, 9, 18)!].postgresValue) == #"{"2026-09-18"}"#)
        // Bytes are a bytea, not a list of numbers -- and a list of them is a
        // bytea[], each element the hex a bytea takes.
        #expect(([1, 2, 255] as [UInt8]).postgresValue == .binary([1, 2, 255], type: PostgresType.bytea))
        // An empty array casts to `[UInt8]` whatever its elements are, so the
        // element type decides, not a cast.
        #expect(([] as [UInt8]).postgresValue == .binary([], type: PostgresType.bytea))
        #expect(boundText([[UInt8]]().postgresValue) == "{}")
        // A value that binds in binary goes in as the text the server writes
        // for those bytes, not as their hex.
        #expect(boundText([UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")!].postgresValue)
                    == #"{"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}"#)
        #expect(boundText([Timestamp(microsecondsSinceEpoch: 1_758_153_600_000_000)].postgresValue)
                    == #"{"2025-09-18 00:00:00+00"}"#)
        #expect(boundText([[1, 2] as [UInt8], []].postgresValue) == #"{"\\x0102","\\x"}"#)
    }

    @Test func elementTypesAreWhatPgTypeSays() throws {
        #expect(PostgresType.elementType(of: PostgresType.textArray) == PostgresType.text)
        #expect(PostgresType.elementType(of: PostgresType.int4Array) == PostgresType.int4)
        #expect(PostgresType.elementType(of: PostgresType.byteaArray) == PostgresType.bytea)
        #expect(PostgresType.elementType(of: PostgresType.timestamptzArray) == PostgresType.timestamptz)
        #expect(PostgresType.elementType(of: PostgresType.jsonbArray) == PostgresType.jsonb)
        // A scalar is not an array, and a type with no reader here has none.
        #expect(PostgresType.elementType(of: PostgresType.text) == nil)
        #expect(PostgresType.elementType(of: 3_615) == nil, "tsquery")

        // Arrays come as text: there is no binary reader to ask for.
        #expect(!PostgresBinary.isDecodable(PostgresType.int4Array))
        #expect(!PostgresBinary.isDecodable(PostgresType.textArray))
    }

    @Test func elementsDecodeAsCellsOfTheirTypeWould() throws {
        func decode<T: Decodable>(_ type: T.Type, _ text: String, element: UInt32) throws -> T {
            try PostgresTextValue(text: text, name: "tags", typeOID: element).decode(type)
        }
        #expect(try decode([String].self, #"{a,"b,c"}"#, element: PostgresType.textArray) == ["a", "b,c"])
        #expect(try decode([Int].self, "{1,-2}", element: PostgresType.int4Array) == [1, -2])
        #expect(try decode([Bool].self, "{t,f}", element: PostgresType.boolArray) == [true, false])
        #expect(try decode([Double].self, "{1.5,0.25}", element: PostgresType.float8Array) == [1.5, 0.25])
        #expect(try decode([String?].self, "{a,NULL}", element: PostgresType.textArray) == ["a", nil])
        #expect(try decode([PostgresDate].self, "{2026-09-18}", element: PostgresType.dateArray)
                    == [PostgresDate(2026, 9, 18)!])
        #expect(try decode([PostgresNumeric].self, "{1234.56}", element: PostgresType.numericArray)
                    == [PostgresNumeric("1234.56")!])
        #expect(try decode([[UInt8]].self, #"{"\\x0102"}"#, element: PostgresType.byteaArray)
                    == [[1, 2]])
        #expect(try decode([PostgresJSON<Tag>].self, #"{"{\"name\":\"swift\"}"}"#,
                           element: PostgresType.jsonbArray).map(\.value) == [Tag(name: "swift")])

        // What cannot be read says which column it was, and a NULL needs an
        // Optional element to land in.
        #expect(throws: PostgresDecodingError.notConvertible(column: "tags", value: "x", expected: "Int")) {
            try decode([Int].self, "{x}", element: PostgresType.int4Array)
        }
        #expect(throws: PostgresDecodingError.null(column: "tags")) {
            try decode([String].self, "{NULL}", element: PostgresType.textArray)
        }
        #expect(throws: PostgresDecodingError.notConvertible(column: "tags", value: "{{1},{2}}",
                                                             expected: "[Int]")) {
            try decode([Int].self, "{{1},{2}}", element: PostgresType.int4Array)
        }
    }
}

/// What a bound value carries, as text.
private func boundText(_ value: PostgresValue) -> String? {
    guard case .text(let bytes) = value else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

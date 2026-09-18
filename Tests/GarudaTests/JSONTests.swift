import Testing
@testable import Garuda

private func text(_ value: some Encodable) throws -> String {
    String(decoding: try JSONCoder.encode(value), as: UTF8.self)
}

private struct Author: Codable, Equatable {
    var name: String
    var age: Int
}

private struct Article: Codable, Equatable {
    var title: String
    var words: Int
    var draft: Bool
    var rating: Double
    var author: Author
    var tags: [String]
    var note: String?
}

private struct Empty: Codable, Equatable {}

/// Reads the coding path it was decoded at, as an error would name it. The
/// coder only puts a path together when something asks, and this asks.
private struct PathReader: Decodable {
    var path: String

    init(from decoder: any Decoder) throws {
        path = describe(decoder.codingPath)
        _ = try decoder.singleValueContainer().decode(Int.self)
    }
}

private struct Inner: Decodable {
    var deep: [PathReader]
}

private struct Holder: Decodable {
    var inner: Inner
}

/// Writes the coding path it is encoded at, as a string.
private struct PathWriter: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(describe(encoder.codingPath))
    }
}

private struct PathWriters: Encodable {
    var items: [[PathWriter]]
}

/// An array nested `depth` deep, to run past the writer's limit.
private struct Nest: Encodable {
    var depth: Int

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if depth > 0 {
            try container.encode(Nest(depth: depth - 1))
        } else {
            try container.encode(1)
        }
    }
}

@Suite("JSON encoding")
struct JSONEncodingTests {
    @Test func scalarsStandAloneAsDocuments() throws {
        #expect(try text(42) == "42")
        #expect(try text(-7) == "-7")
        #expect(try text("hello") == "\"hello\"")
        #expect(try text(true) == "true")
        #expect(try text(false) == "false")
        #expect(try text(Int?.none) == "null")
        #expect(try text([1, 2, 3]) == "[1,2,3]")
    }

    @Test func objectsKeepTheirTypesShape() throws {
        let article = Article(title: "Garuda", words: 900, draft: false, rating: 4.5,
                              author: Author(name: "Ada", age: 36),
                              tags: ["swift", "http"], note: nil)
        // A nil Optional is left out, as the synthesized encoding does.
        #expect(try text(article) == """
            {"title":"Garuda","words":900,"draft":false,"rating":4.5,\
            "author":{"name":"Ada","age":36},"tags":["swift","http"]}
            """)
    }

    @Test func nestingRunsBothWays() throws {
        #expect(try text([["a": 1], ["b": 2]]) == "[{\"a\":1},{\"b\":2}]")
        #expect(try text([[1, 2], [3]]) == "[[1,2],[3]]")
        #expect(try text(["outer": ["inner": [1]]]) == "{\"outer\":{\"inner\":[1]}}")
        #expect(try text([Empty(), Empty()]) == "[{},{}]")
        #expect(try text(Empty()) == "{}")
    }

    @Test func stringsEscapeWhatTheyMust() throws {
        #expect(try text("a\"b") == "\"a\\\"b\"")
        #expect(try text("a\\b") == "\"a\\\\b\"")
        #expect(try text("line\nbreak\ttab") == "\"line\\nbreak\\ttab\"")
        #expect(try text("\u{0008}\u{000C}\r") == "\"\\b\\f\\r\"")
        #expect(try text("\u{0001}\u{001F}") == "\"\\u0001\\u001f\"")
        // UTF-8 is passed through: a JSON document is UTF-8 already.
        #expect(try text("héllo → 世界") == "\"héllo → 世界\"")
    }

    @Test func integersKeepTheirRange() throws {
        #expect(try text(Int64.min) == "-9223372036854775808")
        #expect(try text(Int64.max) == "9223372036854775807")
        #expect(try text(UInt64.max) == "18446744073709551615")
        #expect(try text(0) == "0")
        #expect(try text([UInt8.max, 0]) == "[255,0]")
    }

    @Test func doublesReadBackAsThemselves() throws {
        #expect(try text(1.0) == "1.0")
        #expect(try text(-0.5) == "-0.5")
        #expect(try text(0.1) == "0.1")
        #expect(try text(1e-5) == "1e-05")
        #expect(try text(Float(0.5)) == "0.5")
    }

    @Test func aNumberThatIsNotOneIsRefused() throws {
        #expect(throws: JSONError.self) { try JSONCoder.encode(Double.infinity) }
        #expect(throws: JSONError.self) { try JSONCoder.encode(Double.nan) }
        #expect(throws: JSONError.self) { try JSONCoder.encode(["x": -Double.infinity]) }
    }

    @Test func nestingPastTheLimitIsRefused() throws {
        #expect(throws: Never.self) { try JSONCoder.encode(Nest(depth: JSONCoder.depthLimit - 2)) }
        #expect(throws: JSONError.self) { try JSONCoder.encode(Nest(depth: JSONCoder.depthLimit + 8)) }
    }

    @Test func aValueInsideAnArraySaysWhereItIs() throws {
        #expect(throws: JSONError.invalidValue(path: "[2]", reason: "NaN is not a JSON number")) {
            try JSONCoder.encode([1.0, 2.0, .nan])
        }
        #expect(throws: JSONError.invalidValue(path: "x[1]", reason: "infinity is not a JSON number")) {
            try JSONCoder.encode(["x": [0, Double.infinity]])
        }
        let writers = PathWriters(items: [[PathWriter()], [PathWriter(), PathWriter()]])
        #expect(try text(writers) == #"{"items":[["items[0][0]"],["items[1][0]","items[1][1]"]]}"#)
    }

    @Test func stringsAndIntegersOfEveryLengthAreWhole() throws {
        // The writer copies a string needing no escape in one piece, and
        // formats an integer on the stack: the edges of both.
        #expect(try text("") == "\"\"")
        #expect(try text(["", "a", String(repeating: "b", count: 300)])
                == "[\"\",\"a\",\"" + String(repeating: "b", count: 300) + "\"]")
        #expect(try text([9, 10, -1, -10, 99, 100]) == "[9,10,-1,-10,99,100]")
        #expect(try text([Int64.min, Int64.max]) == "[-9223372036854775808,9223372036854775807]")
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoder.decode(type, from: Array(json.utf8))
}

@Suite("JSON decoding")
struct JSONDecodingTests {
    @Test func aTypeComesBackAsItWent() throws {
        let article = Article(title: "Garuda", words: 900, draft: false, rating: 4.5,
                              author: Author(name: "Ada", age: 36),
                              tags: ["swift", "http"], note: "kept")
        let bytes = try JSONCoder.encode(article)
        #expect(try JSONCoder.decode(Article.self, from: bytes) == article)

        let withoutNote = Article(title: "T", words: 1, draft: true, rating: 0,
                                  author: Author(name: "B", age: 1), tags: [], note: nil)
        #expect(try JSONCoder.decode(Article.self, from: JSONCoder.encode(withoutNote)) == withoutNote)
    }

    @Test func scalarsAndCollectionsDecodeOnTheirOwn() throws {
        #expect(try decode(Int.self, "42") == 42)
        #expect(try decode(String.self, "\"hi\"") == "hi")
        #expect(try decode(Bool.self, "true") == true)
        #expect(try decode(Int?.self, "null") == nil)
        #expect(try decode([Int].self, "[1,2,3]") == [1, 2, 3])
        #expect(try decode([Int].self, "[]") == [])
        #expect(try decode([String: Int].self, "{\"a\":1,\"b\":2}") == ["a": 1, "b": 2])
        #expect(try decode([[Int]].self, "[[1],[2,3]]") == [[1], [2, 3]])
        #expect(try decode(Empty.self, "{}") == Empty())
    }

    @Test func whitespaceAndUnknownKeysAreIgnored() throws {
        let json = """
            {  "name" : "Ada" ,\n "extra": {"ignored": [1, 2, {"deep": null}]},\t"age":36 }
            """
        #expect(try decode(Author.self, json) == Author(name: "Ada", age: 36))
    }

    @Test func aBodyIsReadStraightFromLentBytes() throws {
        let bytes = Array(#"{"name":"Ada","age":36}"#.utf8)
        let author = try bytes.withUnsafeBufferPointer { buffer in
            try JSONCoder.decode(Author.self, from: buffer.span)
        }
        #expect(author == Author(name: "Ada", age: 36))
    }

    @Test func stringsComeBackUnescaped() throws {
        #expect(try decode(String.self, #""a\"b""#) == "a\"b")
        #expect(try decode(String.self, #""line\nbreak\ttab""#) == "line\nbreak\ttab")
        #expect(try decode(String.self, #""Aé""#) == "Aé")
        #expect(try decode(String.self, #""\/slash""#) == "/slash")
        // A surrogate pair is one scalar.
        #expect(try decode(String.self, #""😀""#) == "😀")
        #expect(try decode(String.self, #""héllo → 世界""#) == "héllo → 世界")
    }

    @Test func numbersKeepTheirRangeAndType() throws {
        #expect(try decode(Int64.self, "-9223372036854775808") == Int64.min)
        #expect(try decode(UInt64.self, "18446744073709551615") == UInt64.max)
        #expect(try decode(Double.self, "1e-5") == 1e-5)
        #expect(try decode(Double.self, "-0.5") == -0.5)
        #expect(try decode(Double.self, "3") == 3)
        #expect(try decode(Int8.self, "-128") == -128)
        // A number with a fraction is not an integer, and a wide one does not fit.
        #expect(throws: JSONError.self) { try decode(Int.self, "1.0") }
        #expect(throws: JSONError.self) { try decode(Int8.self, "128") }
        #expect(throws: JSONError.self) { try decode(UInt8.self, "-1") }
        #expect(throws: JSONError.self) { try decode(UInt64.self, "18446744073709551616") }
        // Syntactically a number, but not a Double the encoder could write back.
        #expect(throws: JSONError.self) { try decode(Double.self, "1e400") }
        #expect(throws: JSONError.self) { try decode(Double.self, "-1e400") }
    }

    @Test func aValueOfTheWrongShapeSaysWhereItIs() throws {
        #expect(throws: JSONError.typeMismatch(path: "age", expected: "Int")) {
            try decode(Author.self, #"{"name":"Ada","age":"old"}"#)
        }
        #expect(throws: JSONError.missingKey(path: "age")) {
            try decode(Author.self, #"{"name":"Ada"}"#)
        }
        #expect(throws: JSONError.valueNotFound(path: "age", expected: "Int")) {
            try decode(Author.self, #"{"name":"Ada","age":null}"#)
        }
        #expect(throws: JSONError.typeMismatch(path: "author.name", expected: "String")) {
            try decode(Article.self, """
                {"title":"T","words":1,"draft":true,"rating":1,"author":{"name":7,"age":1},"tags":[]}
                """)
        }
    }

    @Test func aValueInsideAnArraySaysWhereItIs() throws {
        #expect(throws: JSONError.typeMismatch(path: "tags[1]", expected: "String")) {
            try decode(Article.self, """
                {"title":"T","words":1,"draft":true,"rating":1,"author":{"name":"A","age":1},"tags":["a",2]}
                """)
        }
        #expect(throws: JSONError.typeMismatch(path: "[1].age", expected: "Int")) {
            try decode([Author].self, #"[{"name":"A","age":1},{"name":"B","age":"x"}]"#)
        }
        #expect(throws: JSONError.numberOutOfRange(path: "[0][1]")) {
            try decode([[UInt8]].self, "[[1,256]]")
        }
        #expect(try decode([[PathReader]].self, "[[0],[0,0]]").map { $0.map(\.path) }
                == [["[0][0]"], ["[1][0]", "[1][1]"]])
        #expect(try decode(Holder.self, #"{"inner":{"deep":[0,0]}}"#).inner.deep.map(\.path)
                == ["inner.deep[0]", "inner.deep[1]"])
    }

    @Test func aKeyIsFoundHoweverItIsWritten() throws {
        // Keys are compared as bytes unless they hold an escape.
        #expect(try decode(Author.self, #"{"n\u0061me":"Ada","age":36}"#) == Author(name: "Ada", age: 36))
        #expect(try decode(Author.self, #"{"age":36,"name":"Ada"}"#) == Author(name: "Ada", age: 36))
        // A key that only starts like the one wanted is not it.
        #expect(throws: JSONError.missingKey(path: "age")) {
            try decode(Author.self, #"{"name":"Ada","ag":1,"agee":2}"#)
        }
        #expect(try decode([String: Int].self, #"{"":1,"é":2}"#) == ["": 1, "é": 2])
    }

    @Test func malformedDocumentsAreRefused() throws {
        let bad = [
            "", "{", "[1,2", "{\"a\":1,}", "[1,]", "{a:1}", "{\"a\" 1}",
            "01", "1.", "1e", "-", "tru", "\"unterminated", "nul",
        ]
        for json in bad {
            #expect(throws: JSONError.self, "\(json)") { try decode(Int.self, json) }
        }
        // A control character may not appear raw inside a string.
        #expect(throws: JSONError.self) { try JSONCoder.decode(String.self, from: [0x22, 0x01, 0x22]) }
    }

    @Test func aSecondValueAfterTheFirstIsRefused() throws {
        #expect(throws: JSONError.self) { try decode(Int.self, "1 2") }
        #expect(throws: JSONError.self) { try decode([Int].self, "[1] []") }
        // Trailing whitespace is not trailing bytes.
        #expect(try decode(Int.self, " 1 \n") == 1)
    }

    @Test func nestingPastTheLimitIsRefused() throws {
        let deep = String(repeating: "[", count: JSONCoder.depthLimit + 8)
            + String(repeating: "]", count: JSONCoder.depthLimit + 8)
        #expect(throws: JSONError.self) { try decode([Int].self, deep) }
        let shallow = String(repeating: "[", count: 8) + String(repeating: "]", count: 8)
        #expect(throws: Never.self) { try JSONCoder.decode([[[[[[[[Int]]]]]]]].self,
                                                      from: Array(shallow.utf8)) }
    }
}

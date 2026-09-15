import Testing
@testable import Garuda

private func text(_ value: some Encodable) throws -> String {
    String(decoding: try JSON.encode(value), as: UTF8.self)
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
        #expect(throws: JSONError.self) { try JSON.encode(Double.infinity) }
        #expect(throws: JSONError.self) { try JSON.encode(Double.nan) }
        #expect(throws: JSONError.self) { try JSON.encode(["x": -Double.infinity]) }
    }

    @Test func nestingPastTheLimitIsRefused() throws {
        #expect(throws: Never.self) { try JSON.encode(Nest(depth: JSON.depthLimit - 2)) }
        #expect(throws: JSONError.self) { try JSON.encode(Nest(depth: JSON.depthLimit + 8)) }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSON.decode(type, from: Array(json.utf8))
}

@Suite("JSON decoding")
struct JSONDecodingTests {
    @Test func aTypeComesBackAsItWent() throws {
        let article = Article(title: "Garuda", words: 900, draft: false, rating: 4.5,
                              author: Author(name: "Ada", age: 36),
                              tags: ["swift", "http"], note: "kept")
        let bytes = try JSON.encode(article)
        #expect(try JSON.decode(Article.self, from: bytes) == article)

        let withoutNote = Article(title: "T", words: 1, draft: true, rating: 0,
                                  author: Author(name: "B", age: 1), tags: [], note: nil)
        #expect(try JSON.decode(Article.self, from: JSON.encode(withoutNote)) == withoutNote)
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
            try JSON.decode(Author.self, from: buffer.span)
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

    @Test func malformedDocumentsAreRefused() throws {
        let bad = [
            "", "{", "[1,2", "{\"a\":1,}", "[1,]", "{a:1}", "{\"a\" 1}",
            "01", "1.", "1e", "-", "tru", "\"unterminated", "nul",
        ]
        for json in bad {
            #expect(throws: JSONError.self, "\(json)") { try decode(Int.self, json) }
        }
        // A control character may not appear raw inside a string.
        #expect(throws: JSONError.self) { try JSON.decode(String.self, from: [0x22, 0x01, 0x22]) }
    }

    @Test func aSecondValueAfterTheFirstIsRefused() throws {
        #expect(throws: JSONError.self) { try decode(Int.self, "1 2") }
        #expect(throws: JSONError.self) { try decode([Int].self, "[1] []") }
        // Trailing whitespace is not trailing bytes.
        #expect(try decode(Int.self, " 1 \n") == 1)
    }

    @Test func nestingPastTheLimitIsRefused() throws {
        let deep = String(repeating: "[", count: JSON.depthLimit + 8)
            + String(repeating: "]", count: JSON.depthLimit + 8)
        #expect(throws: JSONError.self) { try decode([Int].self, deep) }
        let shallow = String(repeating: "[", count: 8) + String(repeating: "]", count: 8)
        #expect(throws: Never.self) { try JSON.decode([[[[[[[[Int]]]]]]]].self,
                                                      from: Array(shallow.utf8)) }
    }
}

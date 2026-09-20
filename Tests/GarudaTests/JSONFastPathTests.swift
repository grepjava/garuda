import Testing
@testable import Garuda

// A type that reads and writes its own JSON, of the kind `@JSON` generates.
// Written out here so that the reader, the writer and the coder's choice
// between the two paths are tested without the macro in the way.

private struct Line: Codable, Equatable, JSONReadable, JSONWritable {
    var sku: String
    var quantity: Int

    init(sku: String, quantity: Int) {
        self.sku = sku
        self.quantity = quantity
    }

    init(json reader: inout JSONReader) throws {
        var sku: String?
        var quantity: Int?
        try reader.beginObject()
        while let key = try reader.nextKey() {
            if key.matches("sku") {
                sku = try reader.read(String.self, named: "sku")
            } else if key.matches("quantity") {
                quantity = try reader.read(Int.self, named: "quantity")
            } else {
                try reader.skipValue()
            }
        }
        guard let sku else { throw JSONError.missingKey(path: "sku") }
        guard let quantity else { throw JSONError.missingKey(path: "quantity") }
        self.sku = sku
        self.quantity = quantity
    }

    func write(json output: inout JSONOutput) {
        output.beginObject()
        output.key("sku")
        output.write(sku)
        output.key("quantity")
        output.write(quantity)
        output.endObject()
    }
}

private struct Basket: Codable, Equatable, JSONReadable, JSONWritable {
    var id: Int
    var owner: String
    var lines: [Line]
    var note: String?
    var open: Bool
    var total: Double

    init(id: Int, owner: String, lines: [Line], note: String?, open: Bool, total: Double) {
        self.id = id
        self.owner = owner
        self.lines = lines
        self.note = note
        self.open = open
        self.total = total
    }

    init(json reader: inout JSONReader) throws {
        var id: Int?
        var owner: String?
        var lines: [Line]?
        var note: String??
        var open: Bool?
        var total: Double?
        try reader.beginObject()
        while let key = try reader.nextKey() {
            if key.matches("id") {
                id = try reader.read(Int.self, named: "id")
            } else if key.matches("owner") {
                owner = try reader.read(String.self, named: "owner")
            } else if key.matches("lines") {
                lines = try reader.read([Line].self, named: "lines")
            } else if key.matches("note") {
                note = try reader.read(String?.self, named: "note")
            } else if key.matches("open") {
                open = try reader.read(Bool.self, named: "open")
            } else if key.matches("total") {
                total = try reader.read(Double.self, named: "total")
            } else {
                try reader.skipValue()
            }
        }
        guard let id else { throw JSONError.missingKey(path: "id") }
        guard let owner else { throw JSONError.missingKey(path: "owner") }
        guard let lines else { throw JSONError.missingKey(path: "lines") }
        guard let open else { throw JSONError.missingKey(path: "open") }
        guard let total else { throw JSONError.missingKey(path: "total") }
        self.id = id
        self.owner = owner
        self.lines = lines
        self.note = note ?? nil
        self.open = open
        self.total = total
    }

    func write(json output: inout JSONOutput) {
        output.beginObject()
        output.key("id")
        output.write(id)
        output.key("owner")
        output.write(owner)
        output.key("lines")
        lines.write(json: &output)
        // Left out when it is nil, as Codable leaves it out: a type that
        // gains its own code must not change what it sends.
        if let note {
            output.key("note")
            output.write(note)
        }
        output.key("open")
        output.write(open)
        output.key("total")
        output.write(total)
        output.endObject()
    }
}

/// The same shapes with no reader or writer of their own, to prove the coder
/// still takes the Codable path for a type that has none -- and that a type
/// that has one sends exactly what Codable would have sent.
private struct PlainLine: Codable, Equatable {
    var sku: String
    var quantity: Int
}

private struct PlainBasket: Codable, Equatable {
    var id: Int
    var owner: String
    var lines: [PlainLine]
    var note: String?
    var open: Bool
    var total: Double
}

private let basket = Basket(id: 7, owner: "ann",
                            lines: [Line(sku: "a-1", quantity: 2), Line(sku: "b-2", quantity: 1)],
                            note: nil, open: true, total: 12.5)

private func text(_ value: some Encodable) throws -> String {
    String(decoding: try JSONCoder.encode(value), as: UTF8.self)
}

private func read<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoder.decode(type, from: Array(json.utf8))
}

@Suite("JSON a type reads and writes itself")
struct JSONFastPathTests {
    @Test func aTypeWithItsOwnCodeWritesWhatCodableWould() throws {
        let plain = PlainBasket(id: basket.id, owner: basket.owner,
                                lines: basket.lines.map { PlainLine(sku: $0.sku,
                                                                    quantity: $0.quantity) },
                                note: basket.note, open: basket.open, total: basket.total)
        #expect(try text(basket) == text(plain))
        #expect(try text(basket) == #"{"id":7,"owner":"ann","lines":[{"sku":"a-1","quantity":2},"#
                                  + #"{"sku":"b-2","quantity":1}],"open":true,"total":12.5}"#)
    }

    @Test func andWithTheOptionalMemberFilledIn() throws {
        var full = basket
        full.note = "gift"
        let plain = PlainBasket(id: full.id, owner: full.owner,
                                lines: full.lines.map { PlainLine(sku: $0.sku,
                                                                  quantity: $0.quantity) },
                                note: full.note, open: full.open, total: full.total)
        #expect(try text(full) == text(plain))
        #expect(try read(Basket.self, text(full)) == full)
    }

    @Test func andReadsBackWhatItWrote() throws {
        let json = try text(basket)
        #expect(try read(Basket.self, json) == basket)
    }

    @Test func aTypeWithNoneOfItsOwnStillGoesThroughCodable() throws {
        let line = PlainLine(sku: "a-1", quantity: 2)
        #expect(try text(line) == #"{"sku":"a-1","quantity":2}"#)
        #expect(try read(PlainLine.self, #"{"sku":"a-1","quantity":2}"#) == line)
    }

    @Test func membersItDoesNotKnowArePassedOver() throws {
        let json = #"{"id":7,"extra":{"deep":[1,2,3]},"owner":"ann","lines":[],"#
                 + #""open":false,"total":0,"note":"hi","late":null}"#
        let read = try read(Basket.self, json)
        #expect(read.id == 7)
        #expect(read.owner == "ann")
        #expect(read.note == "hi")
        #expect(read.lines.isEmpty)
    }

    @Test func spacesBetweenEverythingAreAllowed() throws {
        let json = """
            { "sku" : "a-1" , "quantity" : 2 }
            """
        #expect(try read(Line.self, json) == Line(sku: "a-1", quantity: 2))
    }

    @Test func aMissingMemberSaysWhichOne() throws {
        #expect(throws: JSONError.missingKey(path: "quantity")) {
            try read(Line.self, #"{"sku":"a-1"}"#)
        }
    }

    @Test func aMemberOfTheWrongTypeIsNamedByThePathToIt() throws {
        let json = #"{"id":7,"owner":"ann","lines":[{"sku":"a-1","quantity":"two"}],"#
                 + #""open":true,"total":1}"#
        #expect(throws: JSONError.typeMismatch(path: "lines[0].quantity", expected: "Int")) {
            try read(Basket.self, json)
        }
    }

    @Test func escapesSurviveBothWays() throws {
        let line = Line(sku: "a\"b\\c\nd\te", quantity: 1)
        let json = try text(line)
        #expect(json == #"{"sku":"a\"b\\c\nd\te","quantity":1}"#)
        #expect(try read(Line.self, json) == line)
    }

    @Test func aControlCharacterIsWrittenAsItsNumber() throws {
        #expect(try text(Line(sku: "a\u{01}b", quantity: 1))
                == "{\"sku\":\"a\\u0001b\",\"quantity\":1}")
    }

    @Test func anEscapedKeyIsStillTheKeyItSpells() throws {
        // The key is written "\u0073ku", which spells "sku".
        #expect(try read(Line.self, "{\"\\u0073ku\":\"a-1\",\"quantity\":2}")
                == Line(sku: "a-1", quantity: 2))
    }

    @Test func numbersAtTheEdgesOfTheirTypes() throws {
        var output = JSONOutput()
        output.write(Int.min)
        output.comma()
        output.write(Int.max)
        output.comma()
        output.write(UInt64.max)
        output.comma()
        output.write(0)
        #expect(String(decoding: output.bytes, as: UTF8.self)
                == "\(Int.min),\(Int.max),\(UInt64.max),0")
    }

    @Test func aNumberTooBigForItsTypeIsRefused() throws {
        #expect(throws: JSONError.numberOutOfRange(path: "quantity")) {
            try read(Line.self, #"{"sku":"a","quantity":99999999999999999999}"#)
        }
    }

    @Test func aFractionWhereAWholeNumberIsNeededIsRefused() throws {
        #expect(throws: JSONError.self) {
            try read(Line.self, #"{"sku":"a","quantity":1.5}"#)
        }
    }

    @Test func anInfiniteDoubleIsWrittenAsNull() throws {
        var output = JSONOutput()
        output.write(Double.infinity)
        #expect(String(decoding: output.bytes, as: UTF8.self) == "null")
    }

    @Test func bytesAfterTheDocumentAreRefused() throws {
        #expect(throws: JSONError.self) {
            try read(Line.self, #"{"sku":"a","quantity":1} {"#)
        }
    }

    @Test func aDocumentThatIsNotAnObjectSaysSo() throws {
        #expect(throws: JSONError.typeMismatch(path: "", expected: "an object")) {
            try read(Line.self, "[1,2]")
        }
    }

    @Test func aListOfThemReadsAndWrites() throws {
        let lines = [Line(sku: "a", quantity: 1), Line(sku: "b", quantity: 2)]
        let json = try text(lines)
        #expect(json == #"[{"sku":"a","quantity":1},{"sku":"b","quantity":2}]"#)
        #expect(try read([Line].self, json) == lines)
    }

    @Test func aDictionaryOfThemReadsAndWrites() throws {
        let json = #"{"first":{"sku":"a","quantity":1}}"#
        let read = try read([String: Line].self, json)
        #expect(read == ["first": Line(sku: "a", quantity: 1)])
        #expect(try text(read) == json)
    }

    @Test func anEmptyObjectAndAnEmptyArray() throws {
        #expect(try read([Line].self, "[]").isEmpty)
        #expect(try read([String: Line].self, "{}").isEmpty)
    }

    @Test func aRequestBodyTakesThisPath() throws {
        // What `Body<Basket>` does, through the same entry point.
        let json = Array(#"{"id":1,"owner":"bo","lines":[],"open":true,"total":0}"#.utf8)
        let read = try json.withUnsafeBufferPointer { buffer in
            try JSONCoder.decode(Basket.self, from: buffer.span)
        }
        #expect(read.id == 1)
        #expect(read.note == nil)
    }
}

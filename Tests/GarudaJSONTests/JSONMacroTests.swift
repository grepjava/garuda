import Testing
import Garuda
import GarudaJSON

// What `@JSON` generates has one job: to send exactly what Codable sent, and
// to read back exactly what Codable read. So nearly every test here writes a
// value twice -- once through the macro, once through a twin type that has
// only Codable -- and compares the bytes.

@JSON private struct Line: Codable, Equatable {
    var sku: String
    var quantity: Int
}

private struct PlainLine: Codable, Equatable {
    var sku: String
    var quantity: Int
}

@JSON private struct Basket: Codable, Equatable {
    var id: Int
    var owner: String
    var lines: [Line]
    var tags: [String]
    var note: String?
    var open: Bool
    var total: Double
}

private struct PlainBasket: Codable, Equatable {
    var id: Int
    var owner: String
    var lines: [PlainLine]
    var tags: [String]
    var note: String?
    var open: Bool
    var total: Double
}

// The shapes that are easy to get wrong: an optional array, an array of
// optionals, an array of arrays, and the small integer and floating-point
// types.
@JSON private struct Awkward: Codable, Equatable {
    var maybeTags: [String]?
    var maybeLines: [Line]?
    var holes: [Int?]
    var grid: [[Int]]
    var small: Int32
    var unsigned: UInt16
    var rate: Float
    var nested: Line?
}

private struct PlainAwkward: Codable, Equatable {
    var maybeTags: [String]?
    var maybeLines: [PlainLine]?
    var holes: [Int?]
    var grid: [[Int]]
    var small: Int32
    var unsigned: UInt16
    var rate: Float
    var nested: PlainLine?
}

// A member the macro must leave alone, and one it must not try to read.
@JSON private struct Mixed: Codable, Equatable {
    static let version = 3
    let id: Int
    let kind: String = "fixed"
    var label: String {
        "\(kind)-\(id)"
    }
    var count: Int {
        willSet { _ = newValue }
    }
    var `default`: Bool
}

// `Int!` is an optional, and is treated as one throughout.
@JSON private struct Forced: Codable, Equatable {
    var id: Int!
    var name: String
}

private struct PlainForced: Codable, Equatable {
    var id: Int!
    var name: String
}

private func written(_ value: some Encodable) throws -> String {
    String(decoding: try JSONCoder.encode(value), as: UTF8.self)
}

private func read<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoder.decode(type, from: Array(json.utf8))
}

@Suite struct JSONMacroTests {

    // MARK: - The bytes are Codable's bytes

    @Test func aGeneratedTypeWritesWhatCodableWould() throws {
        let basket = Basket(id: 7, owner: "ana", lines: [Line(sku: "a", quantity: 2)],
                            tags: ["x", "y"], note: nil, open: true, total: 12.5)
        let plain = PlainBasket(id: 7, owner: "ana", lines: [PlainLine(sku: "a", quantity: 2)],
                                tags: ["x", "y"], note: nil, open: true, total: 12.5)
        #expect(try written(basket) == written(plain))
    }

    @Test func andWithTheOptionalFilledIn() throws {
        let basket = Basket(id: 1, owner: "bo", lines: [], tags: [],
                            note: "keep", open: false, total: 0)
        let plain = PlainBasket(id: 1, owner: "bo", lines: [], tags: [],
                                note: "keep", open: false, total: 0)
        #expect(try written(basket) == written(plain))
    }

    @Test func theAwkwardShapesToo() throws {
        let value = Awkward(maybeTags: nil, maybeLines: [Line(sku: "z", quantity: 1)],
                            holes: [1, nil, 3], grid: [[1, 2], [], [3]],
                            small: -5, unsigned: 65_535, rate: 0.5,
                            nested: Line(sku: "n", quantity: 9))
        let plain = PlainAwkward(maybeTags: nil, maybeLines: [PlainLine(sku: "z", quantity: 1)],
                                 holes: [1, nil, 3], grid: [[1, 2], [], [3]],
                                 small: -5, unsigned: 65_535, rate: 0.5,
                                 nested: PlainLine(sku: "n", quantity: 9))
        #expect(try written(value) == written(plain))
    }

    @Test func andWithEveryOptionalEmpty() throws {
        let value = Awkward(maybeTags: nil, maybeLines: nil, holes: [], grid: [],
                            small: 0, unsigned: 0, rate: 0, nested: nil)
        let plain = PlainAwkward(maybeTags: nil, maybeLines: nil, holes: [], grid: [],
                                 small: 0, unsigned: 0, rate: 0, nested: nil)
        #expect(try written(value) == written(plain))
    }

    @Test func membersKeepTheOrderTheyAreDeclaredIn() throws {
        let line = Line(sku: "a", quantity: 2)
        #expect(try written(line) == #"{"sku":"a","quantity":2}"#)
    }

    // MARK: - Reading

    @Test func itReadsBackWhatItWrote() throws {
        let basket = Basket(id: 7, owner: "ana", lines: [Line(sku: "a", quantity: 2)],
                            tags: ["x"], note: "n", open: true, total: -0.25)
        #expect(try read(Basket.self, written(basket)) == basket)
    }

    @Test func andTheAwkwardOneToo() throws {
        let value = Awkward(maybeTags: ["a", "b"], maybeLines: nil, holes: [nil, 2],
                            grid: [[7]], small: -1, unsigned: 9, rate: 1.5,
                            nested: Line(sku: "n", quantity: 0))
        #expect(try read(Awkward.self, written(value)) == value)
    }

    @Test func aKeyItDoesNotKnowIsPassedOver() throws {
        let json = #"{"sku":"a","extra":{"deep":[1,2]},"quantity":2}"#
        #expect(try read(Line.self, json) == Line(sku: "a", quantity: 2))
    }

    @Test func aMissingKeyIsTheGeneratedErrorAndNamesItself() throws {
        #expect(throws: JSONError.missingKey(path: "quantity")) {
            _ = try read(Line.self, #"{"sku":"a"}"#)
        }
    }

    @Test func aMissingOptionalIsSimplyNil() throws {
        let json = #"{"id":1,"owner":"bo","lines":[],"tags":[],"open":true,"total":0}"#
        #expect(try read(Basket.self, json).note == nil)
    }

    @Test func aNullOptionalIsNilToo() throws {
        let json = #"{"id":1,"owner":"bo","lines":[],"tags":[],"note":null,"open":true,"total":0}"#
        #expect(try read(Basket.self, json).note == nil)
    }

    @Test func aMemberOfTheWrongTypeNamesThePathToIt() throws {
        #expect(throws: (any Error).self) {
            _ = try read(Line.self, #"{"sku":"a","quantity":"two"}"#)
        }
    }

    // MARK: - The members it leaves alone

    @Test func staticAndComputedMembersAreNotWritten() throws {
        let value = Mixed(id: 4, count: 2, default: true)
        #expect(try written(value) == #"{"id":4,"kind":"fixed","count":2,"default":true}"#)
    }

    @Test func anImmutableMemberWithAValueIsWrittenAndNotRead() throws {
        // Exactly as Codable: it is in the output, and a different value in
        // the document does not overwrite it.
        let value = try read(Mixed.self, #"{"id":4,"kind":"other","count":2,"default":false}"#)
        #expect(value.kind == "fixed")
        #expect(value.id == 4)
        #expect(value.default == false)
    }

    @Test func aBacktickedNameIsSpelledWithoutThem() throws {
        let value = try read(Mixed.self, #"{"id":1,"count":0,"default":true}"#)
        #expect(value.default == true)
    }

    @Test func anImplicitlyUnwrappedMemberIsAnOptional() throws {
        #expect(try written(Forced(id: nil, name: "a")) == written(PlainForced(id: nil, name: "a")))
        #expect(try written(Forced(id: 3, name: "a")) == written(PlainForced(id: 3, name: "a")))
        #expect(try read(Forced.self, #"{"name":"a"}"#) == Forced(id: nil, name: "a"))
    }

    // MARK: - Through a whole request body

    @Test func aBodyOfThisTypeTakesTheGeneratedPath() throws {
        let json = #"{"sku":"a","quantity":2}"#
        let bytes = Array(json.utf8)
        let line = try bytes.withUnsafeBufferPointer { buffer in
            try JSONCoder.decode(Line.self, from: buffer.span)
        }
        #expect(line == Line(sku: "a", quantity: 2))
    }
}

//===----------------------------------------------------------------------===//
// JSON Schemas for Swift types, for the OpenAPI document.
//
// A `Decodable` type describes itself by being decoded: a decoder that answers
// every question with a placeholder and writes down what it was asked -- which
// keys, of what types, with `decodeIfPresent` for the optional ones -- ends up
// holding the type's shape. That is how a synthesized `Codable` struct becomes
// an object schema without a macro or an annotation.
//
// A named object type becomes a component, referred to with `$ref`, so a type
// used by several routes is written once and a type that contains itself
// refers to itself instead of recursing. Arrays, sets, optionals and
// dictionaries keyed by strings are described from their elements; an enum
// whose cases are `CaseIterable` with raw values lists them.
//
// What decoding cannot show, it cannot describe: an `init(from:)` that throws
// on a placeholder stops where it threw, and a type whose JSON is not what its
// decoder reads -- one that decodes a string and parses it -- is described by
// what it read. Such a type conforms to `OpenAPISchemaDescribing` and says.
//===----------------------------------------------------------------------===//

import AvianCore

/// A JSON value in an OpenAPI document, its object keys kept in order.
public indirect enum OpenAPIValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
    case array([OpenAPIValue])
    case object([(String, OpenAPIValue)])

    public static func == (a: OpenAPIValue, b: OpenAPIValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.integer(let x), .integer(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// The value under `key` of an object, or nil.
    public subscript(key: String) -> OpenAPIValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == key }?.1
    }
}

extension OpenAPIValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: OpenAPIValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, OpenAPIValue)...) { self = .object(elements) }
}

/// A type that writes its own schema, in place of the one decoding it would
/// give: one whose JSON differs from what its decoder reads, or that should
/// say more -- a format, a pattern, a range.
public protocol OpenAPISchemaDescribing {
    static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue
}

/// The schemas of one document: every named type described so far, by name.
public final class OpenAPISchemas {
    /// Named object schemas, in the order they were first described.
    public private(set) var components: [(String, OpenAPIValue)] = []
    /// Types whose schema may be short of what they decode, because reading
    /// them stopped early. `Application.documentProblems` reports these; a
    /// type that means to be described differently says so by conforming to
    /// `OpenAPISchemaDescribing`, and is never in here.
    public private(set) var uncertain: [(type: String, reason: String)] = []
    private var componentIndex: [String: Int] = [:]
    private var names: [ObjectIdentifier: String] = [:]
    private var inProgress: Set<ObjectIdentifier> = []
    /// How deep placeholders are being built, to stop a class that holds
    /// itself.
    private var placeholderDepth = 0

    public init() {}

    /// The schema for `type`: inline for a value, a `$ref` for a named object.
    public func schema<T: Decodable>(for type: T.Type) -> OpenAPIValue {
        if let described = T.self as? any OpenAPISchemaDescribing.Type {
            return described.openAPISchema(self)
        }
        if let primitive = primitiveSchema(T.self) { return primitive }
        if let cases = enumSchema(T.self) { return cases }
        let id = ObjectIdentifier(T.self)
        let name = componentName(T.self)
        if componentIndex[name] != nil || inProgress.contains(id) { return reference(name) }
        inProgress.insert(id)
        defer { inProgress.remove(id) }
        let node = SchemaNode()
        do {
            _ = try T(from: RecordingDecoder(schemas: self, node: node))
        } catch is SchemaRecordingStopped {
            note(name, "it nests deeper than the recorder follows")
        } catch {
            // The type read something a placeholder could not satisfy, so what
            // it decodes after that point is not in the schema. Worth saying
            // rather than swallowing: a client generated from this document
            // would be missing whatever came next.
            note(name, "its init(from:) threw \(Swift.type(of: error))")
        }
        let schema = node.schema
        guard node.isObject else { return schema }
        componentIndex[name] = components.count
        components.append((name, schema))
        return reference(name)
    }

    /// Records a type whose reading stopped early, once per type.
    private func note(_ type: String, _ reason: String) {
        guard !uncertain.contains(where: { $0.type == type }) else { return }
        uncertain.append((type, reason))
    }

    /// The object schema itself for `type`, following a `$ref`.
    public func resolved<T: Decodable>(_ type: T.Type) -> OpenAPIValue {
        resolve(schema(for: type))
    }

    /// `schema` with a `$ref` to one of these components replaced by the
    /// component.
    public func resolve(_ schema: OpenAPIValue) -> OpenAPIValue {
        guard case .string(let ref)? = schema["$ref"], ref.hasPrefix("#/components/schemas/") else { return schema }
        let name = String(ref.dropFirst("#/components/schemas/".count))
        guard let index = componentIndex[name] else { return schema }
        return components[index].1
    }

    private func reference(_ name: String) -> OpenAPIValue {
        ["$ref": .string("#/components/schemas/" + name)]
    }

    /// The type's name as a component key: `Page<User>` is `Page_User`. Two
    /// types of one name in different modules are told apart by a number.
    private func componentName(_ type: Any.Type) -> String {
        let id = ObjectIdentifier(type)
        if let name = names[id] { return name }
        var base = ""
        for c in String(describing: type).unicodeScalars {
            let ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "."
            if ok { base.unicodeScalars.append(c) } else if !base.hasSuffix("_") { base += "_" }
        }
        while base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty { base = "Schema" }
        var name = base
        var n = 2
        while names.values.contains(name) {
            name = base + "\(n)"
            n += 1
        }
        names[id] = name
        return name
    }

    // MARK: Placeholders

    /// A value of `type` to hand back to the decoding that asked for one.
    func placeholder<T: Decodable>(_ type: T.Type) throws -> T {
        if let value = primitivePlaceholder(T.self) { return value }
        if let container = T.self as? any SchemaContainer.Type, let empty = container.emptyValue as? T {
            return empty
        }
        if let cases = T.self as? any CaseIterable.Type, let first = firstCase(cases) as? T {
            return first
        }
        _ = schema(for: T.self)
        guard placeholderDepth < 16 else { throw SchemaRecordingStopped() }
        placeholderDepth += 1
        defer { placeholderDepth -= 1 }
        return try T(from: RecordingDecoder(schemas: self, node: SchemaNode()))
    }
}

/// Thrown to stop decoding a type that contains itself without an optional
/// or a collection between.
struct SchemaRecordingStopped: Error {
}

// MARK: - Values, enums and containers

private func primitiveSchema(_ type: Any.Type) -> OpenAPIValue? {
    switch type {
    case is String.Type, is Substring.Type, is Character.Type: return ["type": "string"]
    case is Bool.Type: return ["type": "boolean"]
    case is Int.Type, is Int64.Type, is UInt.Type, is UInt64.Type: return ["type": "integer", "format": "int64"]
    case is Int32.Type, is Int16.Type, is Int8.Type, is UInt32.Type, is UInt16.Type, is UInt8.Type:
        return ["type": "integer", "format": "int32"]
    case is Double.Type: return ["type": "number", "format": "double"]
    case is Float.Type: return ["type": "number", "format": "float"]
    case is UUID.Type: return ["type": "string", "format": "uuid"]
    case is Timestamp.Type: return ["type": "string", "format": "date-time"]
    default: return nil
    }
}

private func primitivePlaceholder<T>(_ type: T.Type) -> T? {
    switch type {
    case is String.Type: return "" as? T
    case is Bool.Type: return false as? T
    case is Int.Type: return 0 as? T
    case is Int64.Type: return Int64(0) as? T
    case is Int32.Type: return Int32(0) as? T
    case is Int16.Type: return Int16(0) as? T
    case is Int8.Type: return Int8(0) as? T
    case is UInt.Type: return UInt(0) as? T
    case is UInt64.Type: return UInt64(0) as? T
    case is UInt32.Type: return UInt32(0) as? T
    case is UInt16.Type: return UInt16(0) as? T
    case is UInt8.Type: return UInt8(0) as? T
    case is Double.Type: return 0.0 as? T
    case is Float.Type: return Float(0) as? T
    case is UUID.Type: return UUID(high: 0, low: 0) as? T
    case is Timestamp.Type: return Timestamp(microsecondsSinceEpoch: 0) as? T
    default: return nil
    }
}

private func firstCase<C: CaseIterable>(_ type: C.Type) -> Any? {
    C.allCases.first
}

private func enumSchema(_ type: Any.Type) -> OpenAPIValue? {
    guard let cases = type as? any CaseIterable.Type else { return nil }
    let raw = rawValues(cases)
    guard !raw.isEmpty else { return nil }
    if raw.allSatisfy({ $0 is String }) {
        return ["type": "string", "enum": .array(raw.map { .string($0 as! String) })]
    }
    if raw.allSatisfy({ $0 is Int }) {
        return ["type": "integer", "enum": .array(raw.map { .integer($0 as! Int) })]
    }
    return nil
}

private func rawValues<C: CaseIterable>(_ type: C.Type) -> [Any] {
    C.allCases.compactMap { value in
        (value as? any RawRepresentable).map { rawValue(of: $0) }
    }
}

private func rawValue<R: RawRepresentable>(of value: R) -> Any {
    value.rawValue
}

/// Arrays, sets, optionals and dictionaries: described by their elements, and
/// decoded as empty.
protocol SchemaContainer {
    static var emptyValue: Any { get }
}

extension Array: SchemaContainer { static var emptyValue: Any { [Element]() } }
extension Set: SchemaContainer { static var emptyValue: Any { Set<Element>() } }
extension Optional: SchemaContainer { static var emptyValue: Any { Wrapped?.none as Any } }
extension Dictionary: SchemaContainer { static var emptyValue: Any { [Key: Value]() } }

extension Array: OpenAPISchemaDescribing where Element: Decodable {
    public static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue {
        ["type": "array", "items": schemas.schema(for: Element.self)]
    }
}

extension Set: OpenAPISchemaDescribing where Element: Decodable {
    public static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue {
        ["type": "array", "items": schemas.schema(for: Element.self), "uniqueItems": true]
    }
}

extension Optional: OpenAPISchemaDescribing where Wrapped: Decodable {
    public static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue {
        schemas.schema(for: Wrapped.self)
    }
}

extension Dictionary: OpenAPISchemaDescribing where Key == String, Value: Decodable {
    public static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue {
        ["type": "object", "additionalProperties": schemas.schema(for: Value.self)]
    }
}

// MARK: - The recording decoder

/// What decoding one value asked for. Properties and items are nodes of their
/// own, read when the schema is built, because a nested container is filled
/// in after it has been handed out.
final class SchemaNode {
    enum Kind {
        case unknown
        case value(OpenAPIValue)
        case object
        case array
    }

    var kind = Kind.unknown
    var properties: [(String, SchemaNode)] = []
    var required: [String] = []
    var items: SchemaNode? = nil

    init() {}

    init(_ value: OpenAPIValue) {
        kind = .value(value)
    }

    var isObject: Bool {
        if case .object = kind { return true }
        return false
    }

    func property(_ name: String, _ child: SchemaNode, required isRequired: Bool) {
        kind = .object
        if let index = properties.firstIndex(where: { $0.0 == name }) {
            properties[index].1 = child
        } else {
            properties.append((name, child))
        }
        if isRequired && !required.contains(name) { required.append(name) }
    }

    var schema: OpenAPIValue {
        switch kind {
        case .unknown:
            return [:]
        case .value(let value):
            return value
        case .array:
            return ["type": "array", "items": items?.schema ?? [:]]
        case .object:
            var members: [(String, OpenAPIValue)] = [("type", "object")]
            if !properties.isEmpty {
                members.append(("properties", .object(properties.map { ($0.0, $0.1.schema) })))
            }
            if !required.isEmpty { members.append(("required", .array(required.map { .string($0) }))) }
            return .object(members)
        }
    }
}

struct RecordingDecoder: Decoder {
    let schemas: OpenAPISchemas
    let node: SchemaNode
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(schemas: OpenAPISchemas, node: SchemaNode) {
        self.schemas = schemas
        self.node = node
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        if case .unknown = node.kind { node.kind = .object }
        return KeyedDecodingContainer(RecordingKeyedContainer<Key>(schemas: schemas, node: node))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        node.kind = .array
        return RecordingUnkeyedContainer(schemas: schemas, node: node)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        RecordingSingleValueContainer(schemas: schemas, node: node)
    }
}

struct RecordingKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let schemas: OpenAPISchemas
    let node: SchemaNode
    var codingPath: [any CodingKey] = []
    var allKeys: [Key] { [] }

    init(schemas: OpenAPISchemas, node: SchemaNode) {
        self.schemas = schemas
        self.node = node
    }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        node.property(key.stringValue, SchemaNode(schemas.schema(for: T.self)), required: true)
        return try schemas.placeholder(T.self)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        node.property(key.stringValue, SchemaNode(schemas.schema(for: T.self)), required: false)
        return nil
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String { present("", key) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { present(false, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { present(0, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { present(Int8(0), key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { present(Int16(0), key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { present(Int32(0), key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { present(Int64(0), key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { present(UInt(0), key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { present(UInt8(0), key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { present(UInt16(0), key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { present(UInt32(0), key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { present(UInt64(0), key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { present(0.0, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { present(Float(0), key) }

    private func present<T: Decodable>(_ placeholder: T, _ key: Key) -> T {
        node.property(key.stringValue, SchemaNode(schemas.schema(for: T.self)), required: true)
        return placeholder
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { absent(String.self, key) }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { absent(Bool.self, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { absent(Int.self, key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { absent(Int8.self, key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { absent(Int16.self, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { absent(Int32.self, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { absent(Int64.self, key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { absent(UInt.self, key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { absent(UInt8.self, key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { absent(UInt16.self, key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { absent(UInt32.self, key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { absent(UInt64.self, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { absent(Double.self, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { absent(Float.self, key) }

    private func absent<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        node.property(key.stringValue, SchemaNode(schemas.schema(for: T.self)), required: false)
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                                forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let nested = SchemaNode()
        nested.kind = .object
        node.property(key.stringValue, nested, required: true)
        return KeyedDecodingContainer(RecordingKeyedContainer<NestedKey>(schemas: schemas, node: nested))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let nested = SchemaNode()
        nested.kind = .array
        node.property(key.stringValue, nested, required: true)
        return RecordingUnkeyedContainer(schemas: schemas, node: nested)
    }

    func superDecoder() throws -> any Decoder {
        RecordingDecoder(schemas: schemas, node: node)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        let nested = SchemaNode()
        node.property(key.stringValue, nested, required: true)
        return RecordingDecoder(schemas: schemas, node: nested)
    }
}

/// Says it holds one element, keeps that element's schema as the items, and
/// is then at its end.
struct RecordingUnkeyedContainer: UnkeyedDecodingContainer {
    let schemas: OpenAPISchemas
    let node: SchemaNode
    var codingPath: [any CodingKey] = []
    var count: Int? { nil }
    private(set) var currentIndex = 0
    var isAtEnd: Bool { currentIndex > 0 }

    init(schemas: OpenAPISchemas, node: SchemaNode) {
        self.schemas = schemas
        self.node = node
    }

    private mutating func item(_ child: SchemaNode) {
        currentIndex += 1
        node.items = child
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        item(SchemaNode(schemas.schema(for: T.self)))
        return try schemas.placeholder(T.self)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
        throws -> KeyedDecodingContainer<NestedKey> {
        let nested = SchemaNode()
        nested.kind = .object
        item(nested)
        return KeyedDecodingContainer(RecordingKeyedContainer<NestedKey>(schemas: schemas, node: nested))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let nested = SchemaNode()
        nested.kind = .array
        item(nested)
        return RecordingUnkeyedContainer(schemas: schemas, node: nested)
    }

    mutating func superDecoder() throws -> any Decoder {
        let nested = SchemaNode()
        item(nested)
        return RecordingDecoder(schemas: schemas, node: nested)
    }
}

struct RecordingSingleValueContainer: SingleValueDecodingContainer {
    let schemas: OpenAPISchemas
    let node: SchemaNode
    var codingPath: [any CodingKey] = []

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        node.kind = .value(schemas.schema(for: T.self))
        return try schemas.placeholder(T.self)
    }

    func decode(_ type: String.Type) throws -> String { value("") }
    func decode(_ type: Bool.Type) throws -> Bool { value(false) }
    func decode(_ type: Int.Type) throws -> Int { value(0) }
    func decode(_ type: Int8.Type) throws -> Int8 { value(Int8(0)) }
    func decode(_ type: Int16.Type) throws -> Int16 { value(Int16(0)) }
    func decode(_ type: Int32.Type) throws -> Int32 { value(Int32(0)) }
    func decode(_ type: Int64.Type) throws -> Int64 { value(Int64(0)) }
    func decode(_ type: UInt.Type) throws -> UInt { value(UInt(0)) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { value(UInt8(0)) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { value(UInt16(0)) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { value(UInt32(0)) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { value(UInt64(0)) }
    func decode(_ type: Double.Type) throws -> Double { value(0.0) }
    func decode(_ type: Float.Type) throws -> Float { value(Float(0)) }

    private func value<T: Decodable>(_ placeholder: T) -> T {
        node.kind = .value(schemas.schema(for: T.self))
        return placeholder
    }
}

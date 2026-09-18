//===----------------------------------------------------------------------===//
// Validation: the rules a decoded value has to hold to before a handler runs.
//
// Decoding says whether a request has the right shape. It cannot say whether a
// quantity is positive or an email address has an @ in it, and every
// application needs that said somewhere. Said in each handler, it is said
// differently in each handler; said on the type, it is one answer with every
// broken rule named:
//
//     struct NewOrder: Decodable, Validated {
//         let quantity: Int
//         let email: String
//         let note: String?
//
//         func validate(_ check: inout Validation) {
//             check.range("quantity", quantity, atLeast: 1, atMost: 100)
//             check.email("email", email)
//             check.length("note", note, atMost: 280)
//         }
//     }
//
//     app.post("/orders") { (order: Body<NewOrder>) async throws -> JSON<Order> in
//         // Reached only when every rule above holds.
//     }
//
// A broken rule is 422, with all of them in the body rather than the first:
//
//     {"error":"quantity must be at least 1; email must look like an email address",
//      "fields":[{"field":"quantity","message":"must be at least 1"},
//                {"field":"email","message":"must look like an email address"}]}
//
// 422 and not 400 because the two failures are not the same failure. 400 is a
// body that is not the type -- the client is building its request wrongly, and
// no value would work. 422 is a body that is the type, asking for something
// this application will not do -- the client is fine and the value is wrong. A
// client can tell which from the status alone, and `fields` says where to put
// the message on the form either way.
//
// `Body`, `Query` and `Form` check whatever they decode, so a type conforming
// to `Validated` is checked everywhere it is taken from a request: the
// conformance is the opt-in, and there is no call at a route to forget. The
// cost to a type that does not conform is one cast that fails per extraction.
//===----------------------------------------------------------------------===//

/// A type whose values have rules beyond their shape.
public protocol Validated {
    /// Every rule a value of this type holds to. Add each broken one to
    /// `check`; they are all answered together, so there is nothing to gain by
    /// stopping at the first.
    func validate(_ check: inout Validation)
}

extension Validated {
    /// The rules this value breaks, in the order they were checked, and empty
    /// when it breaks none.
    public var validationProblems: [ValidationProblem] {
        var check = Validation()
        validate(&check)
        return check.problems
    }

    /// This value when every rule holds, and `ValidationError` when one does
    /// not -- what extraction calls, and what to call on a value that came
    /// from somewhere else: a queue, a file, another service.
    @discardableResult
    public func validated() throws -> Self {
        let problems = validationProblems
        guard problems.isEmpty else { throw ValidationError(problems) }
        return self
    }
}

/// One broken rule.
public struct ValidationProblem: Codable, Sendable, Equatable, Hashable {
    /// Which field, as the path from the value that was decoded -- `email`,
    /// `address.city`, `items[0].sku` -- or "" for the value as a whole.
    public var field: String
    /// What is wrong with it, written to follow the field's name: "must not
    /// be empty".
    public var message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    /// The problem as a sentence: `quantity must be at least 1`.
    public var sentence: String {
        field.isEmpty ? message : field + " " + message
    }
}

/// Rules broken, as the answer to the request that broke them.
public struct ValidationError: ResponseError, Equatable, Hashable, Sendable {
    public let problems: [ValidationProblem]

    public init(_ problems: [ValidationProblem]) {
        self.problems = problems
    }

    public init(field: String, message: String) {
        self.problems = [ValidationProblem(field: field, message: message)]
    }

    /// 422: the request was understood, and what it asks for is not allowed.
    public var status: HTTPStatus { .unprocessableContent }

    /// Every problem as one line, for whoever is reading a response by hand.
    /// Long enough to be useful and bounded, because the number of fields in a
    /// type is not: past `sentencesInReason` it says how many more there are,
    /// and `fields` has them all.
    public var reason: String? {
        guard !problems.isEmpty else { return "the request is not valid" }
        var text = problems.prefix(Self.sentencesInReason).map(\.sentence).joined(separator: "; ")
        if problems.count > Self.sentencesInReason {
            text += "; and \(problems.count - Self.sentencesInReason) more"
        }
        return text
    }

    public var fields: [ValidationProblem] { problems }

    /// How many problems `reason` spells out.
    public static let sentencesInReason = 5
}

/// The rules of one value as they are checked, and what they found.
///
/// Every rule takes the field's name first, so a `validate` reads as the list
/// of what the type requires. A rule with no method of its own is `require`,
/// and the field name "" is the value as a whole -- two fields that disagree
/// with each other belong to neither.
public struct Validation: Sendable {
    /// What has been found so far, in the order it was found.
    public private(set) var problems: [ValidationProblem] = []

    /// The path to what is being checked: empty at the top, and `address`
    /// inside `nested("address", ...)`.
    private var prefix = ""

    public init() {}

    /// Whether every rule checked so far holds.
    public var isValid: Bool { problems.isEmpty }

    // MARK: - Saying what is wrong

    /// Records a broken rule.
    public mutating func fail(_ field: String, _ message: String) {
        problems.append(ValidationProblem(field: path(field), message: message))
    }

    /// Records a broken rule when `condition` is false: the rule for anything
    /// with no rule of its own.
    ///
    ///     check.require(quantity % boxSize == 0, "quantity", "must be whole boxes")
    public mutating func require(_ condition: Bool, _ field: String, _ message: String) {
        if !condition { fail(field, message) }
    }

    // MARK: - Strings

    /// A string that says something. Whitespace only is not something, since a
    /// name of one space is not a name; `length(atLeast: 1)` is the rule that
    /// counts a space.
    public mutating func notEmpty(_ field: String, _ value: String) {
        require(!value.trimmingWhitespace().isEmpty, field, "must not be empty")
    }

    /// A string that says something, when there is one at all. Nil is absent
    /// rather than wrong: a field the type makes optional is optional.
    public mutating func notEmpty(_ field: String, _ value: String?) {
        if let value { notEmpty(field, value) }
    }

    /// How long a string may be, counted in characters as a person counts
    /// them: an accented letter is one, and so is an emoji.
    public mutating func length(_ field: String, _ value: String,
                                atLeast: Int = 0, atMost: Int = .max) {
        let count = value.count
        if count < atLeast {
            fail(field, atLeast == 1 ? "must not be empty"
                                     : "must be at least \(atLeast) characters")
        } else if count > atMost {
            fail(field, "must be at most \(atMost) characters")
        }
    }

    public mutating func length(_ field: String, _ value: String?,
                                atLeast: Int = 0, atMost: Int = .max) {
        if let value { length(field, value, atLeast: atLeast, atMost: atMost) }
    }

    /// The shape of an email address: something, an @, and a domain with a dot
    /// in it. Whether anyone reads mail there is not in the string, so this is
    /// a shape and nothing more -- an address is confirmed by sending to it.
    public mutating func email(_ field: String, _ value: String) {
        require(Validation.looksLikeEmail(value), field, "must look like an email address")
    }

    public mutating func email(_ field: String, _ value: String?) {
        if let value { email(field, value) }
    }

    /// Whether a string has an email address's shape.
    public static func looksLikeEmail(_ value: String) -> Bool {
        // No longer than a mailbox can be (RFC 5321), and nothing a header
        // could be broken with.
        guard value.utf8.count <= 254,
              !value.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let domain = parts[1]
        guard !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              let dot = domain.lastIndex(of: "."), domain.index(after: dot) != domain.endIndex
        else { return false }
        return true
    }

    // MARK: - Numbers, and anything else ordered

    /// Bounds on a number, a date, a version -- anything that compares. A
    /// bound left out is not a bound.
    public mutating func range<Value: Comparable>(_ field: String, _ value: Value,
                                                  atLeast: Value? = nil, atMost: Value? = nil) {
        if let atLeast, value < atLeast {
            fail(field, "must be at least \(atLeast)")
        } else if let atMost, value > atMost {
            fail(field, "must be at most \(atMost)")
        }
    }

    public mutating func range<Value: Comparable>(_ field: String, _ value: Value?,
                                                  atLeast: Value? = nil, atMost: Value? = nil) {
        if let value { range(field, value, atLeast: atLeast, atMost: atMost) }
    }

    /// One of a set of values, for a field whose type is wider than what it
    /// accepts. A field that only ever accepts these is better as an enum,
    /// which decoding checks for nothing.
    public mutating func oneOf<Value: Equatable>(_ field: String, _ value: Value, _ allowed: [Value]) {
        require(allowed.contains(value), field,
                "must be one of " + allowed.map { "\($0)" }.joined(separator: ", "))
    }

    public mutating func oneOf<Value: Equatable>(_ field: String, _ value: Value?, _ allowed: [Value]) {
        if let value { oneOf(field, value, allowed) }
    }

    // MARK: - Lists, and values inside this one

    /// How many elements a list may have.
    public mutating func count(_ field: String, _ value: some Collection,
                               atLeast: Int = 0, atMost: Int = .max) {
        let count = value.count
        if count < atLeast {
            fail(field, atLeast == 1 ? "must not be empty" : "must have at least \(atLeast) items")
        } else if count > atMost {
            fail(field, "must have at most \(atMost) items")
        }
    }

    /// A value inside this one, its problems named by the path to it:
    /// `nested("address", address)` reports `address.city`.
    public mutating func nested(_ field: String, _ value: some Validated) {
        let outer = prefix
        prefix = path(field)
        value.validate(&self)
        prefix = outer
    }

    public mutating func nested(_ field: String, _ value: (some Validated)?) {
        if let value { nested(field, value) }
    }

    /// Every element of a list, reported as `items[0]`, `items[1]`, which is
    /// the path JSON decoding gives the same place.
    public mutating func each<Value: Validated>(_ field: String, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            nested("\(field)[\(index)]", value)
        }
    }

    // MARK: - Where a problem is

    private func path(_ field: String) -> String {
        if prefix.isEmpty { return field }
        if field.isEmpty { return prefix }
        // An index belongs to the name before it: `items[0]`, not `items.[0]`.
        return field.hasPrefix("[") ? prefix + field : prefix + "." + field
    }
}

extension Validation {
    /// The rules of whatever was just decoded, when its type has any. `Body`,
    /// `Query` and `Form` call this; the cast is what makes the conformance
    /// enough on its own, and what a type without one pays.
    static func check<Value>(_ value: Value) throws {
        guard let validated = value as? any Validated else { return }
        let problems = validated.validationProblems
        guard problems.isEmpty else { throw ValidationError(problems) }
    }
}

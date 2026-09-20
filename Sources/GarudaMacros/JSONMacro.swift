import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// `@JSON` writes the two conformances that let a type read and write its own
// JSON: `JSONReadable.init(json:)` and `JSONWritable.write(json:)`. The coder
// picks them up on its own, so nothing at the call site changes.
//
// What it writes is what a hand would write, and what Codable would have
// produced byte for byte: members in declaration order, under their own names,
// a missing key an error unless the member is optional, and a nil optional
// written as null.
//
// Where it cannot be sure of that, it refuses rather than guessing. Every
// refusal below names the shape and says what to do instead, because the
// alternative -- falling back to Codable quietly -- would leave someone
// wondering why their type is slow.

public struct JSONMacro: ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            throw Problem.error(at: node, .notAStruct)
        }
        if let parameters = structure.genericParameterClause {
            throw Problem.error(at: parameters, .generic)
        }
        // Reading delegates to the memberwise initializer, which an
        // initializer written in the body would have replaced.
        if let written = structure.memberBlock.members.lazy
            .compactMap({ $0.decl.as(InitializerDeclSyntax.self) }).first {
            throw Problem.error(at: written, .hasInitializer)
        }

        let members = try readMembers(of: structure)
        let name = type.trimmedDescription
        let visibility = visibility(of: structure)

        // A conformance the type already declares is not in `protocols`, so a
        // half-written pair -- the reader by hand, the writer from here -- is
        // allowed, and the macro fills in only what is missing.
        let wanted = Set(protocols.map { $0.trimmedDescription })
        var extensions: [ExtensionDeclSyntax] = []
        if protocols.isEmpty || wanted.contains("JSONReadable") {
            extensions.append(try reader(name: name, visibility: visibility, members: members))
        }
        if protocols.isEmpty || wanted.contains("JSONWritable") {
            extensions.append(try writer(name: name, visibility: visibility, members: members))
        }
        return extensions
    }

    // MARK: - The members to read and write

    struct Member {
        /// Without backticks: the JSON key, and the initializer's label.
        var name: String
        /// With them, always, which is legal for any identifier and which
        /// saves knowing whether this one is a keyword.
        var held: String { "`\(name)`" }
        var type: TypeSyntax
        /// A `let` with a value of its own cannot be read back into, exactly
        /// as Codable cannot: it is written, and not read.
        var readable: Bool
    }

    static func readMembers(of structure: StructDeclSyntax) throws -> [Member] {
        var members: [Member] = []
        for item in structure.memberBlock.members {
            guard let property = item.decl.as(VariableDeclSyntax.self) else { continue }
            let modifiers = property.modifiers.map(\.name.tokenKind)
            if modifiers.contains(.keyword(.static)) || modifiers.contains(.keyword(.class)) {
                continue
            }
            if modifiers.contains(.keyword(.lazy)) {
                throw Problem.error(at: property, .lazyProperty)
            }
            let isLet = property.bindingSpecifier.tokenKind == .keyword(.let)
            for binding in property.bindings {
                // A computed property is not stored, so there is nothing to
                // read or write. `willSet`/`didSet` leave it stored.
                if let accessors = binding.accessorBlock, isComputed(accessors) { continue }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw Problem.error(at: binding.pattern, .destructured)
                }
                guard let annotation = binding.typeAnnotation else {
                    throw Problem.error(at: binding, .noType(pattern.identifier.text))
                }
                // `Int!` is an optional everywhere below, and `Int!.self` is
                // not something that can be written, so it is normalised here
                // rather than special-cased in three places.
                var type = annotation.type.trimmed
                if let forced = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                    type = TypeSyntax("\(forced.wrappedType.trimmed)?")
                }
                members.append(Member(
                    name: pattern.identifier.text.trimmingBackticks,
                    type: type,
                    readable: !(isLet && binding.initializer != nil)))
            }
        }
        return members
    }

    static func isComputed(_ accessors: AccessorBlockSyntax) -> Bool {
        switch accessors.accessors {
        case .getter: return true
        case .accessors(let list):
            return list.contains {
                switch $0.accessorSpecifier.tokenKind {
                case .keyword(.willSet), .keyword(.didSet): return false
                default: return true
                }
            }
        }
    }

    /// How the generated members are spelled, so that a public type's
    /// conformance is usable from another module.
    static func visibility(of structure: StructDeclSyntax) -> String {
        for modifier in structure.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }

    // MARK: - Reading

    static func reader(name: String, visibility: String, members: [Member]) throws -> ExtensionDeclSyntax {
        var lines: [String] = []
        for member in members where member.readable {
            // An optional member holds its own absence, so it starts as nil
            // and no key is demanded. Anything else starts unset, and the
            // guard below turns a missing key into an error, as Codable does.
            if isOptional(member.type) {
                lines.append("var \(member.held): \(member.type) = nil")
            } else {
                lines.append("var \(member.held): \(member.type)?")
            }
        }
        lines.append("try _json.beginObject()")
        lines.append("while let _key = try _json.nextKey() {")
        var first = true
        for member in members where member.readable {
            let test = first ? "if" : "} else if"
            first = false
            lines.append("    \(test) _key.matches(\"\(member.name)\") {")
            lines.append("        \(member.held) = try _json.read(\(member.type).self, named: \"\(member.name)\")")
        }
        if first {
            lines.append("    _ = _key")
            lines.append("    try _json.skipValue()")
        } else {
            lines.append("    } else {")
            lines.append("        try _json.skipValue()")
            lines.append("    }")
        }
        lines.append("}")
        for member in members where member.readable && !isOptional(member.type) {
            lines.append("guard let \(member.held) else { throw JSONError.missingKey(path: \"\(member.name)\") }")
        }
        let arguments = members.filter(\.readable)
            .map { "\($0.name): \($0.held)" }.joined(separator: ", ")
        lines.append("self.init(\(arguments))")

        return try ExtensionDeclSyntax("""
            extension \(raw: name): JSONReadable {
                \(raw: visibility)init(json _json: inout JSONReader) throws {
                    \(raw: lines.joined(separator: "\n        "))
                }
            }
            """)
    }

    // MARK: - Writing

    static func writer(name: String, visibility: String, members: [Member]) throws -> ExtensionDeclSyntax {
        var lines: [String] = ["_out.beginObject()"]
        for (index, member) in members.enumerated() {
            // A nil member is left out of the object altogether rather than
            // written as null, because that is what the coder does with one
            // over Codable. A nil *inside* an array is still null, which is
            // also what it does.
            guard let wrapped = unwrapped(member.type) else {
                lines.append("_out.key(\"\(member.name)\")")
                lines += try value(of: member.type, held: "self.\(member.held)", depth: 0)
                continue
            }
            let some = "_some\(index)"
            lines.append("if let \(some) = self.\(member.held) {")
            lines.append("    _out.key(\"\(member.name)\")")
            lines += try value(of: wrapped, held: some, depth: 0).map { "    " + $0 }
            lines.append("}")
        }
        lines.append("_out.endObject()")

        return try ExtensionDeclSyntax("""
            extension \(raw: name): JSONWritable {
                \(raw: visibility)func write(json _out: inout JSONOutput) {
                    \(raw: lines.joined(separator: "\n        "))
                }
            }
            """)
    }

    /// The statements that write one value.
    ///
    /// A scalar does not conform to `JSONWritable` -- deliberately, so that
    /// nothing outside an opted-in type changes path -- so an array of them
    /// cannot simply be written. The loop is spelled out here instead, which
    /// costs nothing at run time and works whether the element is a scalar or
    /// another type with `@JSON` on it.
    static func value(of type: TypeSyntax, held expression: String, depth: Int) throws -> [String] {
        if let array = type.as(ArrayTypeSyntax.self) {
            let element = "_element\(depth)"
            let inner = try value(of: array.element.trimmed, held: element, depth: depth + 1)
            return ["_out.beginArray()",
                    "for \(element) in \(expression) {",
                    "    _out.element()"]
                + inner.map { "    " + $0 }
                + ["}", "_out.endArray()"]
        }
        if let wrapped = unwrapped(type) {
            let some = "_value\(depth)"
            let inner = try value(of: wrapped, held: some, depth: depth + 1)
            return ["if let \(some) = \(expression) {"]
                + inner.map { "    " + $0 }
                + ["} else {", "    _out.writeNull()", "}"]
        }
        if type.is(DictionaryTypeSyntax.self) {
            throw Problem.error(at: type, .dictionary)
        }
        if let named = type.as(IdentifierTypeSyntax.self) {
            switch named.name.text {
            case "Dictionary": throw Problem.error(at: type, .dictionary)
            case "Set": throw Problem.error(at: type, .set)
            case "Array", "Optional": throw Problem.error(at: type, .spelledOut(named.name.text))
            default: break
            }
        }
        return ["_out.write(\(expression))"]
    }

    static func isOptional(_ type: TypeSyntax) -> Bool { unwrapped(type) != nil }

    /// What an optional holds, or nil if this is not one.
    static func unwrapped(_ type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) { return optional.wrappedType.trimmed }
        if let forced = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return forced.wrappedType.trimmed
        }
        return nil
    }
}

private extension String {
    /// `default` is spelled with backticks in Swift and without them in JSON.
    var trimmingBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count > 1
            ? String(dropFirst().dropLast()) : self
    }
}

// MARK: - What it refuses, and why

struct Problem: DiagnosticMessage, Error {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity = .error

    init(_ message: String, _ id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "Garuda", id: id)
    }

    static func error(at node: some SyntaxProtocol, _ problem: Problem) -> DiagnosticsError {
        DiagnosticsError(diagnostics: [Diagnostic(node: Syntax(node), message: problem)])
    }

    static let notAStruct = Problem(
        "'@JSON' can be attached to a struct. A class cannot take an initializer in an extension, and an enum's shape is not an object: write 'JSONReadable' and 'JSONWritable' by hand.",
        "json.notAStruct")
    static let generic = Problem(
        "'@JSON' cannot be attached to a generic struct: the conformance would need constraints the macro cannot work out. Write it by hand.",
        "json.generic")
    static let hasInitializer = Problem(
        "'@JSON' reads a value by calling the memberwise initializer, which this initializer replaces. Move it into an extension, or write 'JSONReadable' by hand.",
        "json.hasInitializer")
    static let lazyProperty = Problem(
        "'@JSON' cannot read or write a 'lazy' property. Make it computed, or write the conformances by hand.",
        "json.lazy")
    static let destructured = Problem(
        "'@JSON' cannot read or write a destructured binding. Declare one property a line.",
        "json.destructured")
    static let dictionary = Problem(
        "'@JSON' cannot write a dictionary member, because nothing fixes the order of its keys. Use a struct, or write 'JSONWritable' by hand.",
        "json.dictionary")
    static let set = Problem(
        "'@JSON' cannot write a set member, because nothing fixes the order of its elements. Use an array, or write 'JSONWritable' by hand.",
        "json.set")

    static func noType(_ name: String) -> Problem {
        Problem("'@JSON' needs the type of '\(name)' written out, so that it knows what to read.",
                "json.noType")
    }
    static func spelledOut(_ name: String) -> Problem {
        Problem("'@JSON' reads '\(name)' written the short way: '[Element]' rather than 'Array<Element>', 'Wrapped?' rather than 'Optional<Wrapped>'.",
                "json.spelledOut")
    }
}

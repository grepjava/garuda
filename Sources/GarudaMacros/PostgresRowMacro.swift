import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// `@PostgresRow` writes the `PostgresReadable` conformance that lets a type
// read itself out of a result row instead of going through `Codable`. The
// pool picks it up on its own, so `first(User.self, ...)` is written the same
// way either way.
//
// Simpler than `@JSON`: a column is found by name and decoded, whatever it
// holds, so there is no type to walk. The only distinction is whether the
// member is optional, because an optional one must keep meaning what
// `decodeIfPresent` meant -- no such column, or a NULL, is nil.

public struct PostgresRowMacro: ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            throw Problem.error(at: node, .rowNotAStruct)
        }
        if let parameters = structure.genericParameterClause {
            throw Problem.error(at: parameters, .rowGeneric)
        }
        // Reading delegates to the memberwise initializer, which an
        // initializer written in the body would have replaced.
        if let written = structure.memberBlock.members.lazy
            .compactMap({ $0.decl.as(InitializerDeclSyntax.self) }).first {
            throw Problem.error(at: written, .rowHasInitializer)
        }
        // A conformance the type already declares is not in `protocols`.
        if !protocols.isEmpty,
           !protocols.contains(where: { $0.trimmedDescription == "PostgresReadable" }) {
            return []
        }

        let members = try JSONMacro.readMembers(of: structure).filter(\.readable)
        let visibility = JSONMacro.visibility(of: structure)
        var arguments: [String] = []
        for member in members {
            if let wrapped = JSONMacro.unwrapped(member.type) {
                arguments.append("\(member.name): try _row.optional(\(wrapped).self, \"\(member.name)\")")
            } else {
                arguments.append("\(member.name): try _row.value(\(member.type).self, \"\(member.name)\")")
            }
        }

        return [try ExtensionDeclSyntax("""
            extension \(raw: type.trimmedDescription): PostgresReadable {
                \(raw: visibility)init(row _row: PostgresRowReader) throws {
                    self.init(\(raw: arguments.joined(separator: ",\n                              ")))
                }
            }
            """)]
    }
}

extension Problem {
    static let rowNotAStruct = Problem(
        "'@PostgresRow' can be attached to a struct: it reads a row by calling the memberwise initializer, which a class cannot take in an extension and an enum does not have.",
        "row.notAStruct")
    static let rowGeneric = Problem(
        "'@PostgresRow' cannot be attached to a generic struct: the conformance would need constraints the macro cannot work out. Write it by hand.",
        "row.generic")
    static let rowHasInitializer = Problem(
        "'@PostgresRow' reads a row by calling the memberwise initializer, which this initializer replaces. Move it into an extension, or write 'PostgresReadable' by hand.",
        "row.hasInitializer")
}

import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The plugin the compiler loads.
@main
struct GarudaMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [JSONMacro.self, PostgresRowMacro.self]
}

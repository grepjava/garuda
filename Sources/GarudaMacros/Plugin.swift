import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The plugin the compiler loads. One macro so far.
@main
struct GarudaMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [JSONMacro.self]
}

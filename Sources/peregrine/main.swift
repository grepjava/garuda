//===----------------------------------------------------------------------===//
// Command line entry point.
//
// The parser is PeregrineCLI, shared with peregrine._native, which runs the
// same command line inside python.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import PeregrineServer

exit(PeregrineCLI.main(argc: Int(CommandLine.argc), argv: CommandLine.unsafeArgv))

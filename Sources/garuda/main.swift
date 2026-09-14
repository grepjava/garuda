//===----------------------------------------------------------------------===//
// Command line entry point.
//
// The parser is GarudaCLI.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import GarudaServer

exit(GarudaCLI.main(argc: Int(CommandLine.argc), argv: CommandLine.unsafeArgv))

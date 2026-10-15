#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// Where tests put scratch files: /tmp, or %TEMP% on Windows, with forward
/// slashes, which Windows takes as well.
let temporaryDirectory: String = {
    #if os(Windows)
    var dir = getenv("TEMP").map { String(cString: $0) } ?? "C:/Windows/Temp"
    dir = String(dir.map { $0 == "\\" ? "/" : $0 })
    while dir.hasSuffix("/") { dir.removeLast() }
    return dir
    #else
    return "/tmp"
    #endif
}()

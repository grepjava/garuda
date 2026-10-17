#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#endif

/// Where the tests put scratch files: /tmp, or %TEMP% on Windows, with
/// forward slashes, which Windows takes as well.
let scratchRoot: String = {
    #if os(Windows)
    var dir = getenv("TEMP").map { String(cString: $0) } ?? "C:/Windows/Temp"
    dir = String(dir.map { $0 == "\\" ? "/" : $0 })
    while dir.hasSuffix("/") { dir.removeLast() }
    return dir
    #else
    return "/tmp"
    #endif
}()

/// A new, empty directory under `scratchRoot`, its name starting `prefix`.
func makeScratchDirectory(_ prefix: String) -> String {
    #if os(Windows)
    let path = "\(scratchRoot)/\(prefix)-\(_getpid())-\(UInt64.random(in: 0...UInt64.max))"
    precondition(_mkdir(path) == 0, "no scratch directory")
    return path
    #else
    var template = Array("\(scratchRoot)/\(prefix)-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil, "no scratch directory")
    return String(cString: template)
    #endif
}

/// Whether there is a file or directory at `path`.
func fileExists(_ path: String) -> Bool {
    #if os(Windows)
    _access(path, 0) == 0
    #else
    access(path, F_OK) == 0
    #endif
}

/// The bytes of the file at `path`, or nil when it cannot be read.
func fileBytes(_ path: String) -> [UInt8]? {
    #if os(Windows)
    // ucrt's open is variadic, which Swift cannot call: stdio, in binary.
    guard let file = fopen(path, "rb") else { return nil }
    defer { _ = fclose(file) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { fread($0.baseAddress!, 1, $0.count, file) }
        if n == 0 { break }
        out += chunk[0..<n]
    }
    return out
    #else
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { _ = close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
        if n <= 0 { break }
        out += chunk[0..<n]
    }
    return out
    #endif
}

/// The names in `directory`, without `.` and `..`.
func directoryListing(_ directory: String) -> [String] {
    var names: [String] = []
    #if os(Windows)
    var data = WIN32_FIND_DATAW()
    let find = (directory + "/*").withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
    guard let find, find != INVALID_HANDLE_VALUE else { return [] }
    defer { FindClose(find) }
    repeat {
        let name = withUnsafeBytes(of: data.cFileName) {
            String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
        }
        if name != "." && name != ".." { names.append(name) }
    } while FindNextFileW(find, &data)
    #else
    guard let dir = opendir(directory) else { return [] }
    defer { closedir(dir) }
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." { names.append(name) }
    }
    #endif
    return names
}

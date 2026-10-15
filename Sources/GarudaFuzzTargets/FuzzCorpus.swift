//===----------------------------------------------------------------------===//
// Reading a corpus off disk.
//
// `fuzz/corpus/<target>/` holds inputs worth keeping: what a run found
// interesting, and above all anything that once broke an invariant. The fuzzer
// starts from them, and the test suite replays them on every `swift test`,
// which is what stops a fixed bug from coming back quietly.
//
// C's stdio for the files and the platform's own directory listing, rather
// than Foundation, which this package does not link anywhere.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#endif

public enum FuzzCorpus {

    /// Every file in `directory`, in a stable order. An unreadable or missing
    /// directory is empty rather than an error: a corpus is optional.
    public static func files(in directory: String) -> [String] {
        var names: [String] = []
        #if os(Windows)
        var found = WIN32_FIND_DATAA()
        let handle = FindFirstFileA(directory + "\\*", &found)
        guard handle != INVALID_HANDLE_VALUE else { return [] }
        defer { FindClose(handle) }
        repeat {
            if found.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { continue }
            names.append(withUnsafeBytes(of: found.cFileName) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            })
        } while FindNextFileA(handle, &found)
        #else
        guard let dir = opendir(directory) else { return [] }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            names.append(withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            })
        }
        #endif
        return names.filter { !$0.hasPrefix(".") }.map { directory + "/" + $0 }.sorted()
    }

    public static func read(_ path: String) -> [UInt8]? {
        // "b": on Windows, text mode would turn CRLF -- which half these
        // inputs are made of -- into LF.
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    /// Writes `bytes` to `path`, replacing it. False if it could not.
    public static func write(_ path: String, _ bytes: [UInt8]) -> Bool {
        guard let file = fopen(path, "wb") else { return false }
        defer { fclose(file) }
        return bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) } == bytes.count
    }

    /// Every checked-in input for one target, paired with the file it came
    /// from so a failure can name it.
    public static func inputs(for target: FuzzTarget,
                              root: String) -> [(path: String, bytes: [UInt8])] {
        files(in: "\(root)/\(target.rawValue)").compactMap { path in
            read(path).map { (path, $0) }
        }
    }
}

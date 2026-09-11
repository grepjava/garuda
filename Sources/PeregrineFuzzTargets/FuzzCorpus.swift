//===----------------------------------------------------------------------===//
// Reading a corpus off disk.
//
// `fuzz/corpus/<target>/` holds inputs worth keeping: what a run found
// interesting, and above all anything that once broke an invariant. The fuzzer
// starts from them, and the test suite replays them on every `swift test`,
// which is what stops a fixed bug from coming back quietly.
//
// The reading is done with open/read and opendir/readdir rather than
// Foundation, which this package does not link anywhere.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum FuzzCorpus {

    /// Every file in `directory`, in a stable order. An unreadable or missing
    /// directory is empty rather than an error: a corpus is optional.
    public static func files(in directory: String) -> [String] {
        guard let dir = opendir(directory) else { return [] }
        defer { closedir(dir) }
        var paths: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name.hasPrefix(".") { continue }
            paths.append(directory + "/" + name)
        }
        return paths.sorted()
    }

    public static func read(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return nil }
        defer { close(fd) }
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            // Spelled out because `read` inside this type resolves to the
            // static method above it.
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Glibc)
                return Glibc.read(fd, raw.baseAddress, raw.count)
                #else
                return Darwin.read(fd, raw.baseAddress, raw.count)
                #endif
            }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
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

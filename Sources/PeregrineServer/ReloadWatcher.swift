//===----------------------------------------------------------------------===//
// --reload: restart workers when the application source changes.
//
// This is a development convenience, polled a couple of times a second from the
// supervisor, so it is written for clarity: ordinary Swift strings and arrays,
// ARC and all. Nothing here runs in a worker or touches a request.
//
// Polling rather than inotify/FSEvents is deliberate. The watcher has to work
// identically on Linux and macOS, has to survive editors that replace files
// rather than writing them in place, and has a budget measured in whole
// milliseconds -- a stat() walk over a project tree costs far less than that.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CPeregrine
import PeregrineCore

final class ReloadWatcher {
    private let roots: [String]
    private let intervalMs: UInt64
    private var lastScan: UInt64 = 0
    private var signature: UInt64 = 0

    /// Directories that are never worth walking: caches, version control, and
    /// installed packages, which together dominate the file count of a typical
    /// project tree without ever being the thing the developer just edited.
    private static let skipped: Set<String> = [
        "__pycache__", ".git", ".hg", ".svn", ".mypy_cache", ".pytest_cache",
        ".ruff_cache", ".tox", "node_modules", "site-packages", ".venv", "venv",
        ".build", "build", "dist", ".eggs",
    ]

    private static let watchedSuffixes = [".py", ".pyi", ".env", ".ini", ".toml", ".cfg"]

    init(config: ServerConfig) {
        var dirs: [String] = ["."]
        for extra in config.pythonPaths {
            dirs.append(String(cString: extra))
        }
        self.roots = dirs
        self.intervalMs = max(100, config.reloadIntervalMs)
        self.signature = scan()
        self.lastScan = pg_monotonic_ms()
    }

    /// Whether anything changed since the last call. Rate-limited internally so
    /// the supervisor can call it on every loop turn.
    func changed() -> Bool {
        let now = pg_monotonic_ms()
        if now &- lastScan < intervalMs { return false }
        lastScan = now
        let next = scan()
        if next == signature { return false }
        signature = next
        return true
    }

    /// A digest over (path, mtime) for every watched file. Any addition,
    /// removal or edit changes it; ordering does not, because the combining
    /// step is a sum.
    private func scan() -> UInt64 {
        var digest: UInt64 = 0
        for root in roots {
            walk(root, depth: 0, into: &digest)
        }
        return digest
    }

    private func walk(_ path: String, depth: Int, into digest: inout UInt64) {
        // A deep tree is almost always a dependency directory that slipped past
        // the skip list; stop rather than crawl it.
        if depth > 12 { return }
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            var e = entry.pointee
            let name = withUnsafeBytes(of: &e.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            if name.hasPrefix(".") && name != ".env" { continue }
            if ReloadWatcher.skipped.contains(name) { continue }

            let child = path == "." ? name : path + "/" + name
            if pg_is_dir(child) == 1 {
                walk(child, depth: depth + 1, into: &digest)
                continue
            }
            var watched = false
            for suffix in ReloadWatcher.watchedSuffixes where name.hasSuffix(suffix) {
                watched = true
                break
            }
            if !watched { continue }

            let mtime = pg_mtime_ns(child)
            if mtime < 0 { continue }
            var h: UInt64 = 1469598103934665603
            for byte in child.utf8 {
                h = (h ^ UInt64(byte)) &* 1099511628211
            }
            digest = digest &+ (h ^ UInt64(bitPattern: mtime))
        }
    }
}

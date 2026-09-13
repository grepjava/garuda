//===----------------------------------------------------------------------===//
// --reload: restart workers when the application source changes.
//
// This is a development convenience, run from the supervisor, so it is written
// for clarity: ordinary Swift strings and arrays, ARC and all. Nothing here
// runs in a worker or touches a request.
//
// What decides whether anything changed is a scan: a digest over the path and
// modification time of every watched file. It works the same on Linux and
// macOS, survives editors that replace files rather than writing them in
// place, and costs a stat() walk -- a few milliseconds at most for a project
// tree.
//
// What decides when to scan is the kernel where it can say, and a clock
// everywhere. Every directory the scan walks is watched -- inotify on Linux,
// kqueue on macOS -- and a change wakes the supervisor, which scans once the
// save has had a moment to finish: an editor writes a temporary file, renames
// it and touches the directory in several steps, and scanning after the first
// would reload twice. The scan still runs every --reload-interval as well,
// because a notification is not always delivered: a bind mount, a network
// filesystem or WSL's view of a Windows drive may never send one, and on macOS
// only a directory's own changes are watched, so a file written in place is
// not seen. There, the watcher is exactly the poller it always was.
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

    /// The kernel's change notification, readable when something changed, or
    /// -1 where there is none.
    let notifyFD: Int32
    /// Directories added to `notifyFD`.
    private var watched = Set<String>()
    /// When the last notification not yet scanned for arrived, or 0.
    private var notifiedAt: UInt64 = 0

    /// How long a notification waits for more before the scan. Long enough
    /// for an editor's save to finish, short enough not to be noticed.
    static let settleMs: UInt64 = 50

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
        self.notifyFD = pg_watch_open()
        self.signature = scan()
        self.lastScan = pg_monotonic_ms()
    }

    deinit {
        if notifyFD >= 0 { pg_watch_close(notifyFD) }
    }

    /// Whether a notification is waiting out `settleMs`, so the supervisor
    /// should come back in milliseconds rather than a quarter of a second.
    var checkSoon: Bool { notifiedAt != 0 }

    /// Whether anything changed since the last call. Cheap when nothing is
    /// due, so the supervisor calls it on every loop turn.
    func changed() -> Bool {
        let now = pg_monotonic_ms()
        if notifyFD >= 0 && pg_watch_drain(notifyFD) > 0 {
            // Every event restarts the wait: a save still in progress is not
            // yet the change to reload for. A tree that never stops changing
            // is still scanned, on the interval below.
            notifiedAt = now
        }
        let settled = notifiedAt != 0 && now &- notifiedAt >= ReloadWatcher.settleMs
        if !settled && now &- lastScan < intervalMs { return false }
        notifiedAt = 0
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
        var visited = Set<String>()
        for root in roots {
            walk(root, depth: 0, into: &digest, visited: &visited)
        }
        // A directory that is gone lost its watch with it. Forgetting it here
        // means one recreated under the same name is watched again.
        if notifyFD >= 0 { watched.formIntersection(visited) }
        return digest
    }

    private func walk(_ path: String, depth: Int, into digest: inout UInt64,
                      visited: inout Set<String>) {
        // A deep tree is almost always a dependency directory that slipped past
        // the skip list; stop rather than crawl it.
        if depth > 12 { return }
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        if notifyFD >= 0 {
            visited.insert(path)
            if !watched.contains(path) && pg_watch_add(notifyFD, path) == 0 {
                watched.insert(path)
            }
        }

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
                walk(child, depth: depth + 1, into: &digest, visited: &visited)
                continue
            }
            var watchedFile = false
            for suffix in ReloadWatcher.watchedSuffixes where name.hasSuffix(suffix) {
                watchedFile = true
                break
            }
            if !watchedFile { continue }

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

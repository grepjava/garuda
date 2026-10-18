//===----------------------------------------------------------------------===//
// --reload: pick up a rebuilt executable, and certificates changed on disk.
//
// The application is compiled into the server, so the file whose change
// matters is the executable itself. A rebuild never reaches shards forked
// from the supervisor already running, so the supervisor restarts on the new
// file (Vega's ShardWatchAction.restartSupervisor: the same pid, its
// listeners and shards handed over, the shards then replaced one at a time).
// A --tls-cert or --tls-key file that changes needs only new shards, which
// read it again as they start.
//
// A development convenience, run in the supervisor between its waits, so
// written for clarity: nothing here runs in a shard or touches a request.
//
// Whether anything changed is a stat of each watched file: device, inode,
// size, mode and modification time. A linker that writes a new file and
// renames it over the old one changes the inode; one that writes in place
// changes the size and the time.
//
// When to look is the kernel's to say where it can -- the directories holding
// the files are watched with inotify on Linux -- and every --reload-interval
// regardless, because a bind mount, a network filesystem or WSL's view of a
// Windows drive may never send a notification. A change is acted on only once
// it has held still for `stable`: a linker writes an executable in many
// steps, and one exec'd half-written would fail to start (and if it does
// anyway, Vega tries it before it becomes it).
//===----------------------------------------------------------------------===//

#if os(Linux) || os(macOS)
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Vega

final class ReloadWatcher: @unchecked Sendable {
    // Called only by the supervisor's one thread.

    /// The running executable, as it was found at start, or nil.
    private let executable: String?
    private let certificates: [String]
    private let interval: UInt64
    private var lastScan: UInt64

    /// What the files looked like when last acted on.
    private var executableSignature: UInt64 = 0
    private var certificateSignature: UInt64 = 0
    /// A change seen and not yet held still for `stable`.
    private var pendingExecutable: UInt64 = 0
    private var pendingCertificates: UInt64 = 0
    private var pendingSince: UInt64 = 0

    /// inotify, readable when something in a watched directory changed, or
    /// -1 where there is none.
    private let notify: Int32
    /// When the last notification not yet scanned for arrived, or 0.
    private var notifiedAt: UInt64 = 0

    /// How long a notification waits for more before the scan.
    static let settle: UInt64 = 50_000_000
    /// How long a change has to stay the same before it is acted on.
    static let stable: UInt64 = 300_000_000

    init(_ config: ServerConfig) {
        executable = Runtime.executablePath
        certificates = config.tlsCertificates.flatMap { [$0.chain, $0.key] }
        let (seconds, attos) = config.reloadInterval.components
        interval = UInt64(seconds) &* 1_000_000_000 &+ UInt64(attos / 1_000_000_000)
        #if os(Linux)
        notify = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        if notify >= 0 {
            var directories: [String] = []
            for path in (executable.map { [$0] } ?? []) + certificates {
                let directory = ReloadWatcher.directory(of: path)
                if !directories.contains(directory) { directories.append(directory) }
            }
            let events = UInt32(IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_ATTRIB | IN_MODIFY)
            for directory in directories { _ = inotify_add_watch(notify, directory, events) }
        }
        #else
        notify = -1
        #endif
        lastScan = monotonicNanos()
        (executableSignature, certificateSignature) = scan()
    }

    /// --reload in `options`: the watch, and what its events are logged as.
    /// With no supervisor there is nothing to restart, so --reload brings
    /// one shard where the platform would serve in-process, unless
    /// --shards 0 was asked for.
    static func install(_ config: ServerConfig, into options: inout ShardConfiguration) {
        if options.shards == 0 {
            guard config.shards == nil else {
                Log.warning("--reload restarts the shards' supervisor, and --shards 0 has none; it has no effect")
                return
            }
            options.shards = 1
        }
        // A shard that stops closes the sockets it bound, and with a socket
        // of its own per shard (SO_REUSEPORT) the connections the kernel had
        // queued on it go with it, reset. One socket the supervisor holds
        // outlives every shard, so a restart costs a client nothing; and
        // reloading is what --reload is for, where spreading load is not.
        if config.balance == nil { options.listenerMode = .shared }
        let watcher = ReloadWatcher(config)
        options.watch = { watcher.check() }
        options.watchInterval = .milliseconds(50)
        let logged = options.onEvent
        options.onEvent = { event in
            logged?(event)
            switch event.kind {
            case .restartingSupervisor:
                Log.info("executable rebuilt; restarting the supervisor on it")
            case .supervisorRestartFailed:
                Log.error("--reload: \(event.reason ?? "unknown"); keeping the current executable")
            default:
                break
            }
        }
    }

    /// What to do about whatever changed since the last call. Cheap when
    /// nothing is due, so the supervisor calls it often.
    func check() -> ShardWatchAction {
        let now = monotonicNanos()
        if drained() {
            // Every event restarts the wait: a build still writing is not
            // yet the change to act on.
            notifiedAt = now
        }
        let settled = notifiedAt != 0 && now &- notifiedAt >= ReloadWatcher.settle
        let pendingDue = pendingSince != 0 && now &- pendingSince >= ReloadWatcher.stable
        if !settled && !pendingDue && now &- lastScan < interval { return .nothing }
        if settled { notifiedAt = 0 }
        lastScan = now

        let (executable, certificates) = scan()
        if executable == executableSignature && certificates == certificateSignature {
            // Nothing, or a change since undone.
            pendingSince = 0
            return .nothing
        }
        if pendingSince == 0 || executable != pendingExecutable || certificates != pendingCertificates {
            pendingExecutable = executable
            pendingCertificates = certificates
            pendingSince = now
            return .nothing
        }
        if now &- pendingSince < ReloadWatcher.stable { return .nothing }

        pendingSince = 0
        let rebuilt = executable != executableSignature
        let renewed = certificates != certificateSignature
        executableSignature = executable
        certificateSignature = certificates
        // An executable that is gone, or not executable yet, is a build in
        // progress or a clean; the one to restart on is the next to appear.
        if rebuilt && executable != 0 { return .restartSupervisor }
        if renewed {
            Log.info("certificate changed on disk; reloading workers")
            return .reload
        }
        return .nothing
    }

    /// Whether inotify had anything to say, read to the end.
    private func drained() -> Bool {
        guard notify >= 0 else { return false }
        var any = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(notify, $0.baseAddress, $0.count) }
            if n <= 0 { return any }
            any = true
        }
    }

    private func scan() -> (executable: UInt64, certificates: UInt64) {
        let program = executable.map { ReloadWatcher.signature($0, executable: true) } ?? 0
        var digest: UInt64 = 0
        for path in certificates {
            digest = digest &* 31 &+ ReloadWatcher.signature(path, executable: false)
        }
        return (program, digest)
    }

    /// The file's device, inode, size, mode and modification time, hashed;
    /// 0 when it is not there, or for `executable`, cannot be run.
    static func signature(_ path: String, executable: Bool) -> UInt64 {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        if executable && info.st_mode & 0o111 == 0 { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in [UInt64(truncatingIfNeeded: info.st_dev), UInt64(truncatingIfNeeded: info.st_ino),
                     UInt64(truncatingIfNeeded: info.st_size), UInt64(truncatingIfNeeded: info.st_mode),
                     UInt64(truncatingIfNeeded: modificationTime(path))] {
            hash = (hash ^ part) &* 0x100_0000_01b3
        }
        return hash == 0 ? 1 : hash
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }
}
#endif

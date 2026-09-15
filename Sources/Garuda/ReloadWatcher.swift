//===----------------------------------------------------------------------===//
// --reload: pick up a rebuilt executable, and certificates changed on disk.
//
// The application is compiled into the server, so the file whose change
// matters is the executable itself. A rebuild never reaches workers forked from
// the process already running, so the supervisor restarts on the new file
// (Reexec.swift) and replaces its workers from there. A --tls-cert or --tls-key
// file that changes needs only new workers, which read it again as they start.
//
// This is a development convenience, run from the supervisor, so it is written
// for clarity: ordinary Swift strings and arrays, ARC and all. Nothing here
// runs in a worker or touches a request.
//
// Whether anything changed is a stat of each watched file: device, inode, size,
// mode and modification time. A linker that writes a new file and renames it
// over the old one changes the inode; one that writes in place changes the
// size and the time.
//
// When to look is the kernel's to say where it can -- the directories holding
// the files are watched, inotify on Linux, kqueue on macOS -- and every
// --reload-interval regardless, because a bind mount, a network filesystem or
// WSL's view of a Windows drive may never send a notification. A change is
// acted on only once it has held still for `stableMs`: a linker writes an
// executable in many steps, and one exec'd half-written would fail to start.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CGaruda
import GarudaCore

final class ReloadWatcher {
    enum Change {
        case none
        /// The executable was rebuilt: restart the supervisor on it.
        case executable
        /// Only a certificate or key changed: new workers are enough.
        case certificates
    }

    /// The running executable, resolved at start-up, or nil where it cannot
    /// be found.
    let executablePath: String?
    private let certificates: [String]
    private let intervalMs: UInt64
    private var lastScan: UInt64 = 0

    /// What the files looked like when last acted on.
    private var executableSignature: UInt64 = 0
    private var certificateSignature: UInt64 = 0

    /// A change seen and not yet held still for `stableMs`.
    private var pendingExecutable: UInt64 = 0
    private var pendingCertificates: UInt64 = 0
    private var pendingSince: UInt64 = 0

    /// The kernel's change notification, readable when something changed, or
    /// -1 where there is none.
    let notifyFD: Int32
    /// When the last notification not yet scanned for arrived, or 0.
    private var notifiedAt: UInt64 = 0

    /// How long a notification waits for more before the scan.
    static let settleMs: UInt64 = 50
    /// How long a change has to stay the same before it is acted on.
    static let stableMs: UInt64 = 300

    init(config: ServerConfig) {
        var buffer = [CChar](repeating: 0, count: 4096)
        let found = buffer.withUnsafeMutableBufferPointer {
            pg_executable_path($0.baseAddress!, $0.count) == 0
        }
        executablePath = found
            ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : nil

        // A certificate --acme-domain manages is installed by its helper, which
        // reloads the workers itself; watching it too would reload them twice.
        var certificates: [String] = []
        if !config.acmeEnabled {
            if let path = config.tlsCertPath { certificates.append(String(cString: path)) }
            if let path = config.tlsKeyPath { certificates.append(String(cString: path)) }
            for extra in config.tlsExtraCerts {
                certificates.append(String(cString: extra.cert))
                certificates.append(String(cString: extra.key))
            }
        }
        self.certificates = certificates
        intervalMs = max(100, config.reloadIntervalMs)

        notifyFD = pg_watch_open()
        if notifyFD >= 0 {
            var directories: [String] = []
            for path in (executablePath.map { [$0] } ?? []) + certificates {
                let directory = ReloadWatcher.directory(of: path)
                if !directories.contains(directory) { directories.append(directory) }
            }
            for directory in directories { _ = pg_watch_add(notifyFD, directory) }
        }

        (executableSignature, certificateSignature) = scan()
        lastScan = pg_monotonic_ms()
    }

    deinit {
        if notifyFD >= 0 { pg_watch_close(notifyFD) }
    }

    /// Whether the supervisor should come back in milliseconds rather than a
    /// quarter of a second: a notification is settling, or a change is
    /// waiting to hold still.
    var checkSoon: Bool { notifiedAt != 0 || pendingSince != 0 }

    /// What changed since the last call. Cheap when nothing is due, so the
    /// supervisor calls it on every loop turn.
    func poll() -> Change {
        let now = pg_monotonic_ms()
        if notifyFD >= 0 && pg_watch_drain(notifyFD) > 0 {
            // Every event restarts the wait: a build still writing is not yet
            // the change to act on.
            notifiedAt = now
        }
        let settled = notifiedAt != 0 && now &- notifiedAt >= ReloadWatcher.settleMs
        let pendingDue = pendingSince != 0 && now &- pendingSince >= ReloadWatcher.stableMs
        if !settled && !pendingDue && now &- lastScan < intervalMs { return .none }
        if settled { notifiedAt = 0 }
        lastScan = now

        let (executable, certificates) = scan()
        if executable == executableSignature && certificates == certificateSignature {
            // Nothing, or a change that has since been undone.
            pendingSince = 0
            return .none
        }
        if pendingSince == 0 || executable != pendingExecutable
            || certificates != pendingCertificates {
            pendingExecutable = executable
            pendingCertificates = certificates
            pendingSince = now
            return .none
        }
        if now &- pendingSince < ReloadWatcher.stableMs { return .none }

        pendingSince = 0
        let rebuilt = executable != executableSignature
        let certificatesChanged = certificates != certificateSignature
        executableSignature = executable
        certificateSignature = certificates
        // An executable that is gone, or not executable yet, is a build in
        // progress or a clean; the one to restart on is the next that appears.
        if rebuilt && executable != 0 { return .executable }
        return certificatesChanged ? .certificates : .none
    }

    private func scan() -> (executable: UInt64, certificates: UInt64) {
        let executable = executablePath.map { pg_file_signature($0, 1) } ?? 0
        var digest: UInt64 = 0
        for path in certificates {
            digest = digest &* 31 &+ pg_file_signature(path, 0)
        }
        return (executable, digest)
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }
}

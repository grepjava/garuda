//===----------------------------------------------------------------------===//
// The server's own log: standard error, one line per write, held to
// --log-level. A line is written with a single write so that shards sharing
// one pipe never splice their lines into each other.
//
// The application log (`request.log`, `AppLog`) and the access log are
// written through the same level and the same single write (Logging.swift).
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Synchronization

/// debug, info, warning, error or silent, as --log-level takes them.
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error, silent

    public init?(name: String) {
        switch name {
        case "debug": self = .debug
        case "info": self = .info
        case "warning", "warn": self = .warning
        case "error": self = .error
        case "silent", "none": self = .silent
        default: return nil
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        case .silent: "silent"
        }
    }
}

enum Log {
    static let threshold = Atomic<Int>(LogLevel.info.rawValue)

    static var level: LogLevel {
        get { LogLevel(rawValue: threshold.load(ordering: .relaxed)) ?? .info }
        set { threshold.store(newValue.rawValue, ordering: .relaxed) }
    }

    static func enabled(_ level: LogLevel) -> Bool {
        level != .silent && level.rawValue >= threshold.load(ordering: .relaxed)
    }

    static func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    static func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    static func warning(_ message: @autoclosure () -> String) { emit(.warning, message) }
    static func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    static func emit(_ level: LogLevel, _ message: () -> String) {
        guard enabled(level) else { return }
        var line = "garuda \(level.label): "
        // A message can carry what a client sent: it may not start a line.
        for scalar in message().unicodeScalars {
            if scalar == "\n" { line += "\\n" } else if scalar == "\r" { line += "\\r" } else {
                line.unicodeScalars.append(scalar)
            }
        }
        line += "\n"
        var bytes = Array(line.utf8.prefix(lineCapacity))
        if bytes.last != 0x0A { bytes[bytes.count - 1] = 0x0A }
        bytes.withUnsafeBytes { writeLine($0) }
    }

    /// The most a line may take, newline included: what one write to a pipe
    /// delivers whole.
    static let lineCapacity = 4096

    /// Writes `line`, newline and all, to standard error in one write.
    static func writeLine(_ line: UnsafeRawBufferPointer) {
        guard let base = line.baseAddress, line.count > 0 else { return }
        #if os(Windows)
        _ = _write(2, base, UInt32(line.count))
        #else
        _ = write(2, base, line.count)
        #endif
    }

    /// The process ID the application and access logs put on a JSON line,
    /// so that shards sharing one output can be told apart; when set, this
    /// instead, and 0 leaves it out (tests).
    nonisolated(unsafe) static var fixedPID: Int32? = nil

    static var pid: Int32 {
        if let fixedPID { return fixedPID }
        #if os(Windows)
        return Int32(_getpid())
        #else
        return getpid()
        #endif
    }
}

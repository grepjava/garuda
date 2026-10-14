//===----------------------------------------------------------------------===//
// The server's own log: standard error, one line per write, held to
// --log-level. A line is written with a single write so that shards sharing
// one pipe never splice their lines into each other.
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
        var bytes = Array(line.utf8.prefix(4096))
        if bytes.last != 0x0A { bytes[bytes.count - 1] = 0x0A }
        bytes.withUnsafeBytes { raw in
            #if os(Windows)
            _ = _write(2, raw.baseAddress, UInt32(raw.count))
            #else
            _ = write(2, raw.baseAddress, raw.count)
            #endif
        }
    }
}

//===----------------------------------------------------------------------===//
// An application's own settings, read from the environment and checked once,
// before anything is served.
//
//     struct Settings {
//         let databaseURL: String
//         let signingKey: String
//         let poolSize: Int
//         let signUpsOpen: Bool
//     }
//
//     func settings() throws -> Settings {
//         var env = AppEnvironment()
//         let production = env.mode == .production
//         let settings = Settings(
//             databaseURL: env.string("DATABASE_URL", default: production ? nil : "postgres://localhost/dev"),
//             signingKey: env.secretOrFile("JWT_PRIVATE_KEY", default: production ? nil : ""),
//             poolSize: env.int("DATABASE_POOL_SIZE", default: 8, in: 1...500),
//             signUpsOpen: env.bool("SIGNUPS_OPEN", default: true))
//         try env.check()
//         return settings
//     }
//
// The point is the *shape*: every variable is read, every problem is collected,
// and `check()` throws once with all of them. A missing secret and a
// mistyped number are then one restart, not two. A reader always returns a
// usable value, so reading goes on after a problem and the report is complete.
//
// Garuda's own settings stay on the command line, where `garuda --help` and
// CONFIG.md document them. This is for what the application needs: where its
// database is, what signs its tokens, which features are on.
//
// `mode` reads `APP_ENV`, and the convention is that development may have
// defaults and production may not: pass `default: production ? nil : something`
// and a missing variable is an error in production and a default elsewhere.
//
// Nothing here is Garuda-specific and nothing is magic: it is a struct that
// collects strings. `summary()` prints what was read, with secrets held back,
// for a `myapp env` command.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import CAvian

/// What was wrong with the environment, all of it at once.
public struct AppEnvironmentError: Error, CustomStringConvertible, Equatable, Sendable {
    public let problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }

    public var description: String {
        problems.count == 1
            ? "the environment is not usable: \(problems[0])"
            : "the environment is not usable:\n" + problems.map { "  - " + $0 }.joined(separator: "\n")
    }
}

/// Reads an application's settings from the environment, collecting every
/// problem rather than failing at the first.
public struct AppEnvironment {
    /// What `APP_ENV` said, or `development` when it said nothing. An
    /// application is free to ignore it.
    public enum Mode: String, Sendable, CaseIterable {
        case development
        case test
        case staging
        case production
    }

    public let mode: Mode
    /// The variable `mode` came from.
    public static let modeVariable = "APP_ENV"

    private let read: (String) -> String?
    private var found: [(name: String, shown: String)] = []
    private var collected: [String] = []

    /// Reads the process's environment, or `read` instead -- a dictionary's
    /// subscript, in a test.
    public init(_ read: @escaping (String) -> String? = AppEnvironment.processEnvironment) {
        self.read = read
        let raw = read(AppEnvironment.modeVariable)
        if let raw, !raw.isEmpty, let known = Mode(rawValue: raw.lowercased()) {
            mode = known
        } else {
            mode = .development
        }
        if let raw, !raw.isEmpty, Mode(rawValue: raw.lowercased()) == nil {
            collected.append("\(AppEnvironment.modeVariable) is \"\(raw)\"; it is one of "
                                 + Mode.allCases.map(\.rawValue).joined(separator: ", "))
        }
        found.append((AppEnvironment.modeVariable, mode.rawValue))
    }

    /// One variable from the process, or nil when it is unset.
    public static func processEnvironment(_ name: String) -> String? {
        guard let raw = av_getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    // MARK: Problems

    /// Every problem so far, in the order they were found.
    public var problems: [String] { collected }

    /// Records a problem of the application's own: a pair of settings that
    /// cannot both be true, a file that is not where it says.
    public mutating func problem(_ description: String) {
        collected.append(description)
    }

    /// Throws `AppEnvironmentError` if anything was wrong.
    public func check() throws {
        guard collected.isEmpty else { throw AppEnvironmentError(problems: collected) }
    }

    // MARK: Readers

    /// A string. `default: nil` makes it required.
    public mutating func string(_ name: String, default fallback: String? = nil) -> String {
        if let value = read(name) {
            found.append((name, value))
            return value
        }
        guard let fallback else {
            collected.append("\(name) is not set, and there is no default for it in \(mode.rawValue)")
            found.append((name, "missing"))
            return ""
        }
        found.append((name, fallback))
        return fallback
    }

    /// A whole number, refused outside `range`.
    public mutating func int(_ name: String, default fallback: Int? = nil,
                             in range: ClosedRange<Int> = 1...Int.max) -> Int {
        guard let raw = read(name) else {
            guard let fallback else {
                collected.append("\(name) is not set, and there is no default for it in \(mode.rawValue)")
                found.append((name, "missing"))
                return range.lowerBound
            }
            found.append((name, "\(fallback)"))
            return fallback
        }
        guard let value = Int(raw) else {
            collected.append("\(name) is \"\(raw)\"; it is a whole number")
            found.append((name, raw))
            return fallback ?? range.lowerBound
        }
        guard range.contains(value) else {
            collected.append("\(name) is \(value); it is \(range.lowerBound) to "
                                 + (range.upperBound == Int.max ? "any number above that" : "\(range.upperBound)"))
            found.append((name, raw))
            return fallback ?? range.lowerBound
        }
        found.append((name, raw))
        return value
    }

    /// True, yes, on and 1, or their opposites, in any case.
    public mutating func bool(_ name: String, default fallback: Bool? = nil) -> Bool {
        guard let raw = read(name) else {
            guard let fallback else {
                collected.append("\(name) is not set, and there is no default for it in \(mode.rawValue)")
                found.append((name, "missing"))
                return false
            }
            found.append((name, "\(fallback)"))
            return fallback
        }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            found.append((name, "true"))
            return true
        case "0", "false", "no", "off":
            found.append((name, "false"))
            return false
        default:
            collected.append("\(name) is \"\(raw)\"; it is true or false")
            found.append((name, raw))
            return fallback ?? false
        }
    }

    /// One of a `RawRepresentable`'s cases, named by its raw value.
    public mutating func choice<Choice: RawRepresentable & CaseIterable>(
        _ name: String, default fallback: Choice
    ) -> Choice where Choice.RawValue == String {
        guard let raw = read(name) else {
            found.append((name, fallback.rawValue))
            return fallback
        }
        guard let value = Choice(rawValue: raw.lowercased()) else {
            collected.append("\(name) is \"\(raw)\"; it is one of "
                                 + Choice.allCases.map(\.rawValue).joined(separator: ", "))
            found.append((name, raw))
            return fallback
        }
        found.append((name, value.rawValue))
        return value
    }

    /// A secret: read like `string`, but `summary()` says only whether it is
    /// set.
    public mutating func secret(_ name: String, default fallback: String? = nil) -> String {
        let value = string(name, default: fallback)
        found[found.count - 1] = (name, value.isEmpty ? "not set" : "set")
        return value
    }

    /// A secret, or the contents of the file that `<name>_FILE` names -- which
    /// is how a container or systemd usually passes one. The file wins.
    public mutating func secretOrFile(_ name: String, default fallback: String? = nil) -> String {
        let fileVariable = name + "_FILE"
        if let path = read(fileVariable) {
            guard let contents = AppEnvironment.contentsOfFile(path) else {
                collected.append("\(fileVariable) names \"\(path)\", which cannot be read")
                found.append((fileVariable, "unreadable"))
                return ""
            }
            found.append((fileVariable, "read from \(path)"))
            return contents
        }
        return secret(name, default: fallback)
    }

    /// A URL with its password taken out, for a summary or a log line.
    ///
    /// `postgres://app:secret@db/shop` becomes `postgres://app:***@db/shop`.
    public static func redacting(_ url: String) -> String {
        guard let colon = url.firstIndex(of: ":"), url[colon...].hasPrefix("://") else { return url }
        let afterScheme = url.index(colon, offsetBy: 3)
        // The authority ends at the first / , and the credentials at the last
        // @ within it: a password may hold one.
        let authorityEnd = url[afterScheme...].firstIndex(of: "/") ?? url.endIndex
        guard let at = url[afterScheme..<authorityEnd].lastIndex(of: "@"),
              let password = url[afterScheme..<at].firstIndex(of: ":") else { return url }
        return String(url[url.startIndex...password]) + "***" + String(url[at...])
    }

    /// A connection URL: read, and refused now rather than at the first query.
    /// Its password is held back from `summary()`.
    public mutating func url(_ name: String, default fallback: String? = nil) -> String {
        let value = string(name, default: fallback)
        found[found.count - 1] = (name, value.isEmpty ? "missing" : AppEnvironment.redacting(value))
        return value
    }

    // MARK: Reporting

    /// What was read, a variable to a line, with secrets held back and
    /// passwords taken out of URLs: for a `myapp env` command.
    public func summary() -> String {
        let width = found.map(\.name.count).max() ?? 0
        return found.map { entry in
            entry.name + String(repeating: " ", count: width - entry.name.count + 2) + entry.shown
        }.joined(separator: "\n")
    }

    /// A file's contents as text, or nil when it cannot be read.
    public static func contentsOfFile(_ path: String) -> String? {
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = fread(&buffer, 1, buffer.count, file)
            if read <= 0 { break }
            bytes.append(contentsOf: buffer[0..<read])
        }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

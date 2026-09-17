//===----------------------------------------------------------------------===//
// What /etc/resolv.conf says, read once per worker at start-up.
//
// Read at start-up rather than per lookup: the file changes rarely, a worker
// is one thread, and opening a file mid-request to answer a question about a
// hostname is exactly the blocking this layer exists to avoid. A server that
// needs to notice a change restarts, which is how every other piece of
// configuration here behaves too.
//
// Almost every machine this runs on points at a local stub resolver -- systemd
// resolved on 127.0.0.53, or WSL's gateway -- which answers everything and
// hides search domains, truncation and retries behind itself. That is a good
// reason to parse the file honestly rather than test against whatever the
// local one happens to say: the interesting configurations are the ones this
// machine does not have.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// The parts of resolv.conf a stub resolver acts on.
///
/// Options nobody here implements are ignored rather than refused: the file is
/// the system's, not this server's, and failing to start because it mentions
/// `attempts:3` would be a server that breaks on somebody else's settings.
struct ResolverConfig: Equatable {
    /// Nameservers in the order given, as literal addresses. A name here would
    /// be a chicken-and-egg problem, and resolv.conf does not allow one.
    var nameservers: [String] = []
    /// Domains appended to a name that has too few dots to be tried on its own.
    var search: [String] = []
    /// A name with at least this many dots is tried as it stands first. The
    /// default is 1, which is why `example.com` is looked up directly while a
    /// bare `db` goes through the search list.
    var ndots = 1
    /// Kept because a resolver that ignores it asks for trouble on a network
    /// where the first server is slow: RES_OPTIONS timeout, in seconds.
    var timeoutSeconds = 5
    var attempts = 2

    /// The address to fall back on when the file names none. Localhost rather
    /// than a public resolver: a machine with no nameserver configured has not
    /// consented to its lookups leaving it.
    static let fallbackNameserver = "127.0.0.1"

    /// Whether a name should be tried on its own before the search list, which
    /// is what ndots decides. A trailing dot makes it absolute, always.
    func isAbsolute(_ name: String) -> Bool {
        if name.hasSuffix(".") { return true }
        var dots = 0
        for byte in name.utf8 where byte == UInt8(ascii: ".") { dots += 1 }
        return dots >= ndots
    }

    /// The names to try, in order, for `name`.
    ///
    /// A name with enough dots is tried bare first and then through the search
    /// list; one without is tried through the list first. Getting this the
    /// wrong way round is the classic Kubernetes pathology, where ndots is 5
    /// and every external lookup does four pointless round trips before the
    /// real one.
    func candidates(for name: String) -> [String] {
        if name.hasSuffix(".") { return [String(name.dropLast())] }
        var out: [String] = []
        out.reserveCapacity(search.count + 1)
        if isAbsolute(name) { out.append(name) }
        for domain in search { out.append("\(name).\(domain)") }
        if !isAbsolute(name) { out.append(name) }
        return out
    }
}

extension ResolverConfig {
    /// Reads and parses `path`, or returns the defaults when it cannot be read
    /// at all. A missing resolv.conf is a machine with no DNS configured, not
    /// a reason to refuse to start.
    static func read(path: String = "/etc/resolv.conf") -> ResolverConfig {
        guard let text = slurp(path) else {
            var config = ResolverConfig()
            config.nameservers = [fallbackNameserver]
            return config
        }
        var config = parse(text)
        if config.nameservers.isEmpty { config.nameservers = [fallbackNameserver] }
        return config
    }

    /// Reads a small file whole. Bounded: resolv.conf is a few hundred bytes,
    /// and a path that has grown to a gigabyte is not one this should read
    /// into a worker.
    private static func slurp(_ path: String, limit: Int = 64 * 1024) -> [UInt8]? {
        let fd = path.withCString { av_open_read($0) }
        guard fd >= 0 else { return nil }
        defer { _ = av_close(fd) }
        var bytes = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < limit {
            let got = chunk.withUnsafeMutableBytes { buffer -> Int in
                av_read(fd, buffer.baseAddress, min(buffer.count, limit - bytes.count))
            }
            if got > 0 {
                bytes.append(contentsOf: chunk[0..<got])
                continue
            }
            // 0 is the end of the file. Anything else is a read that failed,
            // and half a configuration is worse than none: a file that names
            // two nameservers and is cut after the first would silently send
            // every lookup to one server.
            return got == 0 ? bytes : nil
        }
        return bytes
    }

    /// Parses the file's text. Exposed for tests, which have to drive
    /// configurations this machine does not have.
    static func parse(_ bytes: [UInt8]) -> ResolverConfig {
        var config = ResolverConfig()
        for line in lines(of: bytes) {
            // A comment runs to the end of the line, and resolv.conf takes
            // both markers.
            var content = line
            if let cut = content.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                content = String(content[content.startIndex..<cut])
            }
            let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "nameserver":
                // One address per line; a second on the same line is not
                // something resolv.conf defines, so it is ignored rather than
                // guessed at.
                if fields.count > 1 { config.nameservers.append(String(fields[1])) }
            case "search":
                // The last search line wins, which is what every resolver
                // does: the file is a sequence of settings, not a list to be
                // accumulated.
                config.search = fields.dropFirst().map(String.init)
            case "domain":
                // An older spelling of a one-entry search list. Only used when
                // no search line has been seen, since search supersedes it.
                if config.search.isEmpty, fields.count > 1 {
                    config.search = [String(fields[1])]
                }
            case "options":
                for option in fields.dropFirst() {
                    if let value = number(option, after: "ndots:") {
                        // Capped as every resolver caps it. A file asking for
                        // fifteen would mean fifteen round trips before a name
                        // is ever tried as written.
                        config.ndots = min(value, 15)
                    } else if let value = number(option, after: "timeout:") {
                        config.timeoutSeconds = min(max(value, 1), 30)
                    } else if let value = number(option, after: "attempts:") {
                        config.attempts = min(max(value, 1), 5)
                    }
                }
            default:
                continue
            }
        }
        // "search ." is systemd saying there is no search list at all, and
        // appending a bare dot to every name would make each lookup a query
        // for "name." with a trailing empty label.
        config.search.removeAll { $0 == "." || $0.isEmpty }
        return config
    }

    private static func number(_ field: Substring, after prefix: String) -> Int? {
        guard field.hasPrefix(prefix) else { return nil }
        let digits = field.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// Splits on newlines without Foundation, tolerating CRLF.
    private static func lines(of bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var start = 0
        var index = 0
        func take(_ end: Int) {
            var stop = end
            if stop > start, bytes[stop - 1] == 13 { stop -= 1 }
            if stop > start {
                out.append(String(decoding: bytes[start..<stop], as: UTF8.self))
            }
        }
        while index < bytes.count {
            if bytes[index] == 10 {
                take(index)
                start = index + 1
            }
            index += 1
        }
        take(bytes.count)
        return out
    }

    static func parse(_ text: String) -> ResolverConfig {
        parse(Array(text.utf8))
    }
}

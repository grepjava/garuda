//===----------------------------------------------------------------------===//
// Logging and the shared HTTP date cache.
//
// The logger writes preformatted bytes straight to fd 2 with one write(2). It
// never builds a Swift String, never uses string interpolation (which allocates
// and retains), and never allocates: a log line is assembled in a fixed stack
// buffer. That means logging at info level costs the same whether or not anyone
// is reading it.
//===----------------------------------------------------------------------===//

import CPeregrine

public enum LogLevel: UInt8, Comparable, Sendable {
    case debug = 0, info = 1, warning = 2, error = 3, silent = 4
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A stack-allocated line builder. Passed `inout` so it never escapes.
public struct LogLine {
    @usableFromInline var buf: UnsafeMutablePointer<UInt8>
    @usableFromInline var len: Int
    @usableFromInline let cap: Int

    @inlinable
    init(_ p: UnsafeMutablePointer<UInt8>, _ cap: Int) {
        self.buf = p
        self.len = 0
        self.cap = cap
    }

    @inlinable
    public mutating func str(_ s: StaticString) {
        let n = min(s.utf8CodeUnitCount, cap &- len)
        if n > 0 { memcpy(buf + len, s.utf8Start, n); len &+= n }
    }

    @inlinable
    public mutating func bytes(_ p: UnsafePointer<UInt8>, _ n0: Int) {
        let n = min(n0, cap &- len)
        if n > 0 { memcpy(buf + len, p, n); len &+= n }
    }

    @inlinable
    public mutating func span(_ s: ByteSpan) { bytes(s.base, s.count) }

    @inlinable
    public mutating func int(_ v: Int) {
        if cap &- len < 24 { return }
        if v < 0 { buf[len] = 45; len &+= 1; len &+= writeDecimal(-v, buf + len); return }
        len &+= writeDecimal(v, buf + len)
    }

    /// Writes a JSON string, quotes included.
    ///
    /// Escapes what JSON requires and nothing else: a request target is the
    /// peer's bytes, and a log line that can be broken by putting a quote in a
    /// URL is a log injection rather than a log.
    ///
    /// `asciiOnly` additionally escapes every byte above 0x7F as `\u00XX`.
    /// That is for a field whose bytes are not valid UTF-8 -- lossless, since
    /// each byte becomes one escape, and valid JSON, which raw bytes would not
    /// be. A field that is valid UTF-8 is written through unchanged, so an
    /// ordinary non-ASCII URL stays readable.
    public mutating func jsonString(_ p: UnsafePointer<UInt8>, _ n: Int,
                                    asciiOnly: Bool = false) {
        if len < cap { buf[len] = 0x22; len &+= 1 }        // "
        var i = 0
        while i < n {
            let b = p[i]
            i &+= 1
            switch b {
            case 0x22: escape(0x22)                        // \"
            case 0x5C: escape(0x5C)                        // backslash
            case 0x08: escape(0x62)                        // \b
            case 0x0C: escape(0x66)                        // \f
            case 0x0A: escape(0x6E)                        // \n
            case 0x0D: escape(0x72)                        // \r
            case 0x09: escape(0x74)                        // \t
            default:
                if b < 0x20 || (asciiOnly && b > 0x7F) {
                    unicodeEscape(b)
                } else if len < cap {
                    buf[len] = b
                    len &+= 1
                }
            }
        }
        if len < cap { buf[len] = 0x22; len &+= 1 }
    }

    @usableFromInline
    mutating func escape(_ c: UInt8) {
        if cap &- len < 2 { return }
        buf[len] = 0x5C
        buf[len &+ 1] = c
        len &+= 2
    }

    /// `\u00XX`, the only escape that covers every byte JSON cannot carry.
    @usableFromInline
    mutating func unicodeEscape(_ b: UInt8) {
        if cap &- len < 6 { return }
        let digits: StaticString = "0123456789abcdef"
        buf[len] = 0x5C
        buf[len &+ 1] = 0x75                               // u
        buf[len &+ 2] = 0x30
        buf[len &+ 3] = 0x30
        buf[len &+ 4] = digits.utf8Start[Int(b >> 4)]
        buf[len &+ 5] = digits.utf8Start[Int(b & 0xF)]
        len &+= 6
    }

    @inlinable
    public mutating func cstr(_ p: UnsafePointer<CChar>) {
        var i = 0
        while p[i] != 0 && len < cap { buf[len] = UInt8(bitPattern: p[i]); len &+= 1; i &+= 1 }
    }
}

public enum Log {
    /// Set once at startup, read on every log call. `nonisolated(unsafe)` is
    /// accurate rather than a loophole: it is written before any worker exists.
    public nonisolated(unsafe) static var level: LogLevel = .info
    public nonisolated(unsafe) static var pid: Int = 0

    @inlinable
    public static func enabled(_ l: LogLevel) -> Bool { l >= level }

    /// Assembles and emits one line. The closure is inlined into the caller so
    /// nothing escapes and nothing allocates.
    @inlinable
    public static func emit(_ l: LogLevel, _ body: (inout LogLine) -> Void) {
        guard l >= level else { return }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1024) { raw in
            var line = LogLine(raw.baseAddress!, 1024)
            switch l {
            case .debug:   line.str("[debug] ")
            case .info:    line.str("[info]  ")
            case .warning: line.str("[warn]  ")
            case .error:   line.str("[error] ")
            case .silent:  return
            }
            if pid != 0 {
                line.str("pid=")
                line.int(pid)
                line.str(" ")
            }
            body(&line)
            if line.len < line.cap { line.buf[line.len] = cLF; line.len &+= 1 }
            _ = pg_write(2, line.buf, line.len)
        }
    }

    /// Emits a line with no level or pid prefix in front of it.
    ///
    /// For a line that is already structured: half a JSON object behind
    /// `[info]  pid=1234` is not JSON, and a collector handed that is back to
    /// writing a regex, which is the thing structured logging is for. The
    /// caller puts whatever it wants of the prefix inside its own structure.
    @inlinable
    public static func emitBare(_ l: LogLevel, _ body: (inout LogLine) -> Void) {
        guard l >= level else { return }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1024) { raw in
            var line = LogLine(raw.baseAddress!, 1024)
            body(&line)
            if line.len < line.cap { line.buf[line.len] = cLF; line.len &+= 1 }
            _ = pg_write(2, line.buf, line.len)
        }
    }

    @inlinable public static func debug(_ body: (inout LogLine) -> Void) { emit(.debug, body) }
    @inlinable public static func info(_ body: (inout LogLine) -> Void) { emit(.info, body) }
    @inlinable public static func warn(_ body: (inout LogLine) -> Void) { emit(.warning, body) }
    @inlinable public static func error(_ body: (inout LogLine) -> Void) { emit(.error, body) }

    @inlinable
    public static func info(_ s: StaticString) { emit(.info) { $0.str(s) } }
    @inlinable
    public static func warn(_ s: StaticString) { emit(.warning) { $0.str(s) } }
    @inlinable
    public static func error(_ s: StaticString) { emit(.error) { $0.str(s) } }

    /// Writes an arbitrary blob (a Python traceback) straight through.
    public static func raw(_ p: UnsafePointer<UInt8>, _ n: Int) {
        _ = pg_write(2, p, n)
        var nl: UInt8 = cLF
        _ = pg_write(2, &nl, 1)
    }
}

/// Caches the `Date:` header value, which every response must carry.
/// Reformatting it per response would cost a clock_gettime plus a date
/// conversion on every single request; here it happens at most once a second.
public struct DateCache {
    public private(set) var bytes: UnsafeMutablePointer<UInt8>
    private var lastSecond: Int64

    public init() {
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 29)
        lastSecond = 0
        refresh(force: true)
    }

    @inlinable
    public var count: Int { 29 }

    public mutating func refresh(force: Bool = false) {
        let now = pg_unix_seconds()
        if force || now != lastSecond {
            lastSecond = now
            bytes.withMemoryRebound(to: CChar.self, capacity: 29) { p in
                _ = pg_http_date(p, now)
            }
        }
    }

    public func destroy() { bytes.deallocate() }
}

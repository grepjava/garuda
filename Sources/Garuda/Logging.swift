//===----------------------------------------------------------------------===//
// The application's log: lines a handler writes, carrying the request.
//
//     app.post("/orders") { request, response in
//         request.log.info("order placed", ["order": "\(id)", "cents": 1250])
//     }
//
// A line from `request.log` carries what finds it again: the method and path,
// the request ID with --request-id, and the trace and parent span with
// --trace-context. These are the fields the access log carries, so a line in
// one leads to the other. Outside a request, `AppLog` writes the same lines
// without them.
//
// The output is the server's own: standard error, one line at a time, held to
// --log-level, as text or, with --log-format json, as one JSON object per
// line. A line is written with a single write of at most 4096 bytes. That is
// what keeps workers sharing one pipe from splicing lines into each other, so
// a longer line is cut, and says so.
//
// Text follows the access log's shape: the message, then `key=value` pairs,
// with a value quoted when it holds a space, a quote, an equals sign or a
// control character. A message or value cannot start a new line. Both formats
// escape what would, since a message often holds something a client sent.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// debug, info, warning, error or silent, as --log-level takes them.
public typealias LogLevel = AvianCore.LogLevel

/// One field's value: text, a whole number, a fraction or a truth value.
/// Written as a literal, or as an interpolated string.
public enum LogValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
                      ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Fields for a line, in the order they are written: `["order": "42", "cents": 1250]`.
public typealias LogFields = KeyValuePairs<String, LogValue>

/// Writes lines to the application log. Copy it out of the request to use it
/// after an `await`, or to hand to a function: it holds its own copies of the
/// request's fields, and outlives the request.
public struct RequestLogger: Sendable {
    /// The request's fields, then any added with `with`.
    let context: [(String, LogValue)]

    init(context: [(String, LogValue)]) {
        self.context = context
    }

    public func debug(_ message: String, _ fields: LogFields = [:]) { write(.debug, message, fields) }
    public func info(_ message: String, _ fields: LogFields = [:]) { write(.info, message, fields) }
    public func warning(_ message: String, _ fields: LogFields = [:]) { write(.warning, message, fields) }
    public func error(_ message: String, _ fields: LogFields = [:]) { write(.error, message, fields) }

    /// Whether a line at `level` would be written, for a field that is
    /// expensive to work out.
    public func enabled(_ level: LogLevel) -> Bool { Log.enabled(level) }

    /// A logger whose every line also carries `fields`: a user once they are
    /// known, a job's ID for the lines about it.
    public func with(_ fields: LogFields) -> RequestLogger {
        RequestLogger(context: context + fields.map { ($0.key, $0.value) })
    }

    func write(_ level: LogLevel, _ message: String, _ fields: LogFields) {
        guard level != .silent, Log.enabled(level) else { return }
        AppLogOutput.emit(level, message, context, fields)
    }
}

/// The application log outside a request: at start-up, in a state factory,
/// in a background task.
public enum AppLog {
    public static func debug(_ message: String, _ fields: LogFields = [:]) { write(.debug, message, fields) }
    public static func info(_ message: String, _ fields: LogFields = [:]) { write(.info, message, fields) }
    public static func warning(_ message: String, _ fields: LogFields = [:]) { write(.warning, message, fields) }
    public static func error(_ message: String, _ fields: LogFields = [:]) { write(.error, message, fields) }

    /// Whether a line at `level` would be written.
    public static func enabled(_ level: LogLevel) -> Bool { Log.enabled(level) }

    /// A logger whose every line carries `fields`.
    public static func with(_ fields: LogFields) -> RequestLogger {
        RequestLogger(context: fields.map { ($0.key, $0.value) })
    }

    static func write(_ level: LogLevel, _ message: String, _ fields: LogFields) {
        guard level != .silent, Log.enabled(level) else { return }
        AppLogOutput.emit(level, message, [], fields)
    }
}

extension Request {
    /// The application log, with this request's method, path, request ID and
    /// trace context on every line.
    public var log: RequestLogger {
        // Nothing is copied for a line that will not be written.
        guard Log.enabled(.error) else { return RequestLogger(context: []) }
        let c = connection
        var context: [(String, LogValue)] = [
            ("method", .string(c.pointee.head.methodSlice.span(in: c.pointee.headBase()).string)),
            ("path", .string(pathBytes.string)),
        ]
        if let id = requestIDBytes { context.append(("request_id", .string(id.string))) }
        let trace = c.pointee.traceContext
        if trace.readableBytes == TraceContext.traceIDLength + TraceContext.parentIDLength {
            let p = UnsafePointer(trace.readPointer)
            context.append(("trace_id", .string(ByteSpan(p, TraceContext.traceIDLength).string)))
            context.append(("parent_id", .string(ByteSpan(p + TraceContext.traceIDLength,
                                                          TraceContext.parentIDLength).string)))
        }
        return RequestLogger(context: context)
    }
}

/// Formats and writes application log lines.
enum AppLogOutput {
    /// --log-format json. Set before any worker starts.
    nonisolated(unsafe) static var json = false
    /// Where lines go instead of standard error, for tests.
    nonisolated(unsafe) static var capture: ((String) -> Void)? = nil

    /// The most a line may take, newline included: one atomic write to a pipe.
    static let capacity = 4096

    static func emit(_ level: LogLevel, _ message: String,
                     _ context: [(String, LogValue)], _ fields: LogFields) {
        var line = LineBuilder(capacity: capacity - 1)
        if json {
            line.raw("{\"level\":\"")
            line.raw(levelName(level))
            line.raw("\"")
            if Log.pid != 0 {
                line.raw(",\"pid\":")
                line.raw(String(Log.pid))
            }
            line.raw(",\"msg\":")
            line.jsonString(message)
            for (key, value) in context { line.jsonField(key, value) }
            for (key, value) in fields { line.jsonField(key, value) }
            line.finish(json: true)
        } else {
            line.raw("[")
            line.raw(levelName(level))
            line.raw("]")
            line.raw(level == .debug || level == .error ? " " : "  ")
            if Log.pid != 0 {
                line.raw("pid=")
                line.raw(String(Log.pid))
                line.raw(" ")
            }
            line.textMessage(message)
            for (key, value) in fields { line.textField(key, value) }
            for (key, value) in context { line.textField(key, value) }
            line.finish(json: false)
        }
        if let capture {
            capture(String(decoding: line.bytes, as: UTF8.self))
            return
        }
        line.bytes.append(cLF)
        line.bytes.withUnsafeBufferPointer { _ = av_write(2, $0.baseAddress!, $0.count) }
    }

    static func levelName(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warn"
        case .error: return "error"
        case .silent: return "silent"
        }
    }
}

/// A line held to a byte budget. A field goes in whole or not at all, a
/// message is cut at a character boundary, and a line that lost anything
/// ends by saying so -- in a way that keeps JSON valid.
struct LineBuilder {
    var bytes: [UInt8] = []
    let capacity: Int
    var truncated = false

    /// Kept back for what closes the line: `,"truncated":true}` or ` truncated=true`.
    static let tail = 20

    init(capacity: Int) {
        self.capacity = capacity
        bytes.reserveCapacity(256)
    }

    var room: Int { capacity - LineBuilder.tail - bytes.count }

    mutating func raw(_ s: String) {
        var s = s
        s.withUTF8 { bytes.append(contentsOf: $0) }
    }

    /// Appends what `build` writes, or nothing when it does not fit.
    mutating func whole(_ build: (inout [UInt8]) -> Void) {
        var piece: [UInt8] = []
        build(&piece)
        if piece.count <= room {
            bytes.append(contentsOf: piece)
        } else {
            truncated = true
        }
    }

    // MARK: JSON

    mutating func jsonString(_ s: String) {
        // The message is the one piece allowed to be cut: most of it is better
        // than none. The quote that closes it is always written.
        var piece: [UInt8] = []
        LineBuilder.appendJSONString(s, to: &piece)
        if piece.count <= room {
            bytes.append(contentsOf: piece)
            return
        }
        truncated = true
        var cut: [UInt8] = [0x22]
        for scalar in s.unicodeScalars {
            var escaped: [UInt8] = []
            LineBuilder.appendJSONScalar(scalar, to: &escaped)
            if cut.count + escaped.count + 1 > room { break }
            cut.append(contentsOf: escaped)
        }
        cut.append(0x22)
        bytes.append(contentsOf: cut)
    }

    mutating func jsonField(_ key: String, _ value: LogValue) {
        whole { out in
            out.append(0x2C)
            LineBuilder.appendJSONString(key, to: &out)
            out.append(0x3A)
            switch value {
            case .string(let s): LineBuilder.appendJSONString(s, to: &out)
            case .int(let i): out.append(contentsOf: Array(String(i).utf8))
            case .double(let d):
                // JSON has no infinity and no NaN.
                if d.isFinite {
                    out.append(contentsOf: Array("\(d)".utf8))
                } else {
                    LineBuilder.appendJSONString("\(d)", to: &out)
                }
            case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
            }
        }
    }

    static func appendJSONString(_ s: String, to out: inout [UInt8]) {
        out.append(0x22)
        for scalar in s.unicodeScalars { appendJSONScalar(scalar, to: &out) }
        out.append(0x22)
    }

    static func appendJSONScalar(_ scalar: Unicode.Scalar, to out: inout [UInt8]) {
        switch scalar.value {
        case 0x22: out.append(contentsOf: [0x5C, 0x22])
        case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
        case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
        case 0x0D: out.append(contentsOf: [0x5C, 0x72])
        case 0x09: out.append(contentsOf: [0x5C, 0x74])
        case 0x00..<0x20, 0x7F, 0x2028, 0x2029:
            // U+2028 and U+2029 are valid JSON but end a line in JavaScript,
            // and in more than one log viewer.
            out.append(contentsOf: Array(String(unicodeEscape: scalar.value).utf8))
        default:
            out.append(contentsOf: Array(String(scalar).utf8))
        }
    }

    // MARK: Text

    mutating func textMessage(_ s: String) {
        var piece: [UInt8] = []
        for scalar in s.unicodeScalars { LineBuilder.appendTextScalar(scalar, to: &piece) }
        if piece.count <= room {
            bytes.append(contentsOf: piece)
            return
        }
        truncated = true
        var cut: [UInt8] = []
        for scalar in s.unicodeScalars {
            var escaped: [UInt8] = []
            LineBuilder.appendTextScalar(scalar, to: &escaped)
            if cut.count + escaped.count > room { break }
            cut.append(contentsOf: escaped)
        }
        bytes.append(contentsOf: cut)
    }

    mutating func textField(_ key: String, _ value: LogValue) {
        whole { out in
            out.append(0x20)
            // A key is the application's own, but still cannot break the line.
            for scalar in key.unicodeScalars {
                if scalar.value <= 0x20 || scalar == "=" || scalar == "\"" || scalar.value == 0x7F {
                    out.append(0x5F)
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
            out.append(0x3D)
            switch value {
            case .string(let s): LineBuilder.appendTextValue(s, to: &out)
            case .int(let i): out.append(contentsOf: Array(String(i).utf8))
            case .double(let d): out.append(contentsOf: Array("\(d)".utf8))
            case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
            }
        }
    }

    /// A value bare when it can be read back unambiguously, quoted otherwise.
    static func appendTextValue(_ s: String, to out: inout [UInt8]) {
        let plain = !s.isEmpty && s.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F && $0 != "\"" && $0 != "=" && $0 != "\\"
                && $0.value != 0x2028 && $0.value != 0x2029
        }
        if plain {
            out.append(contentsOf: Array(s.utf8))
            return
        }
        out.append(0x22)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: [0x5C, 0x22])
            case "\\": out.append(contentsOf: [0x5C, 0x5C])
            default: appendTextScalar(scalar, to: &out)
            }
        }
        out.append(0x22)
    }

    /// A character of a message or a value, with what would end the line, or
    /// fool a terminal, escaped.
    static func appendTextScalar(_ scalar: Unicode.Scalar, to out: inout [UInt8]) {
        switch scalar.value {
        case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
        case 0x0D: out.append(contentsOf: [0x5C, 0x72])
        case 0x09: out.append(contentsOf: [0x5C, 0x74])
        case 0x00..<0x20, 0x7F, 0x2028, 0x2029:
            out.append(contentsOf: Array(String(unicodeEscape: scalar.value).utf8))
        default:
            out.append(contentsOf: Array(String(scalar).utf8))
        }
    }

    mutating func finish(json: Bool) {
        if json {
            if truncated { bytes.append(contentsOf: Array(",\"truncated\":true".utf8)) }
            bytes.append(0x7D)
        } else if truncated {
            bytes.append(contentsOf: Array(" truncated=true".utf8))
        }
    }
}

extension String {
    /// `\u` and four lowercase hex digits.
    init(unicodeEscape value: UInt32) {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = [0x5C, 0x75]
        for shift in stride(from: 12, through: 0, by: -4) {
            out.append(digits[Int((value >> UInt32(shift)) & 0xF)])
        }
        self = String(decoding: out, as: UTF8.self)
    }
}

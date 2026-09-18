//===----------------------------------------------------------------------===//
// COPY, in both directions, as a state machine over messages.
//
// COPY is the protocol's own bulk path: instead of a row per Bind and Execute,
// the server says "send me data" or "here is data", and bytes flow until one
// side says it is done. It is how a million rows go in without a million round
// trips.
//
// The bytes themselves are whatever the statement asked for -- text, CSV,
// binary -- and are passed through untouched. `PostgresCopyText` writes and
// reads the default text format, which is what a row of Swift values becomes.
//===----------------------------------------------------------------------===//

import AvianCore

/// What the caller should do after handing a `COPY` one message.
public enum PostgresCopyStep: Equatable, Sendable {
    /// Nothing to do; wait for the next message.
    case wait
    /// The server will take data now: write `CopyData` and then `CopyDone`.
    case ready
    /// Data from the server, at this range of the message body.
    case data(Range<Int>)
    /// The server has sent everything.
    case done
    /// ReadyForQuery: the statement is over, and `result()` says how it went.
    case finished
}

/// One `COPY` statement, run through the simple query protocol -- which is
/// what COPY is for, since it takes no parameters and returns no rows.
public struct PostgresCopy {
    let sql: String
    /// The command tag: `COPY 1000`.
    public private(set) var tag = ""
    /// What the server's ReadyForQuery said.
    public private(set) var transactionStatus: PostgresTransactionStatus = .idle
    /// Notifications that arrived while the copy ran, as for any statement.
    public private(set) var notifications: [PostgresNotification] = []
    private var error: PostgresErrorFields? = nil
    /// Whether the server has asked for data, so a failure has to be told to
    /// it with CopyFail rather than simply dropped.
    public private(set) var isTakingData = false

    public init(_ sql: String) {
        self.sql = sql
    }

    /// The statement, as a simple query.
    public func messages() throws(PostgresError) -> [UInt8] {
        var out = ByteBuffer(capacity: 128)
        defer { out.destroy() }
        guard PostgresFrontend.query(sql, into: &out) else { throw .unsendable }
        return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    /// Handles one message.
    public mutating func receive(_ type: UInt8, _ body: PostgresReader) throws(PostgresError) -> PostgresCopyStep {
        do {
            switch type {
            case UInt8(ascii: "G"):
                // CopyInResponse: the format and a column count, neither of
                // which changes what is written -- the statement said what
                // the data looks like.
                isTakingData = true
                return .ready
            case UInt8(ascii: "H"):
                // CopyOutResponse.
                return .wait
            case UInt8(ascii: "d"):
                return .data(0..<body.count)
            case UInt8(ascii: "c"):
                return .done
            case UInt8(ascii: "C"):
                tag = try PostgresBackend.commandComplete(body)
                isTakingData = false
                return .wait
            case UInt8(ascii: "A"):
                notifications.append(try PostgresBackend.notification(body))
                return .wait
            case UInt8(ascii: "E"):
                error = try PostgresBackend.errorFields(body)
                isTakingData = false
                return .wait
            case UInt8(ascii: "Z"):
                transactionStatus = try PostgresBackend.readyForQuery(body)
                return .finished
            // A notice, a setting that changed, an empty statement, and the
            // row descriptions a simple query sends for anything that is not
            // a COPY: none of them ends it.
            case UInt8(ascii: "N"), UInt8(ascii: "S"), UInt8(ascii: "I"),
                 UInt8(ascii: "T"), UInt8(ascii: "D"):
                return .wait
            default:
                throw PostgresError.unexpectedMessage(type)
            }
        } catch let error as PostgresProtocolError {
            throw .protocolViolation(error)
        } catch let error as PostgresError {
            throw error
        } catch {
            throw .protocolViolation(.truncated)
        }
    }

    /// How the copy went: the tag it ended with, or what the server refused.
    public func result() -> Result<String, PostgresError> {
        if let error { return .failure(.server(error)) }
        return .success(tag)
    }

    /// The number the tag ends with: rows copied.
    public var copied: Int {
        Int(tag.split(separator: " ").last ?? "") ?? 0
    }
}

/// COPY's default text format: fields separated by tabs, rows by newlines,
/// `\N` for a null, and a backslash before anything that would be read as
/// punctuation.
public enum PostgresCopyText {
    /// One row, with the newline that ends it.
    public static func encode(_ fields: [String?]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(UInt8(ascii: "\t")) }
            guard let field else {
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "N"))
                continue
            }
            for byte in field.utf8 {
                switch byte {
                case UInt8(ascii: "\\"):
                    out.append(UInt8(ascii: "\\"))
                    out.append(UInt8(ascii: "\\"))
                case 0x08: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
                case 0x0C: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
                case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
                case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
                case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
                case 0x0B: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "v")])
                default: out.append(byte)
                }
            }
        }
        out.append(UInt8(ascii: "\n"))
        return out
    }

    /// Several rows, one after another.
    public static func encode(rows: [[String?]]) -> [UInt8] {
        var out: [UInt8] = []
        for row in rows { out.append(contentsOf: encode(row)) }
        return out
    }

    /// The fields of one row, without its newline. `\N` on its own is a null;
    /// a field that holds those two characters arrives as `\\N`.
    public static func decode(_ line: ArraySlice<UInt8>) -> [String?] {
        var fields: [String?] = []
        var field: [UInt8] = []
        var escaped = false
        var isNull = false
        func finish() {
            fields.append(isNull ? nil : String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            isNull = false
        }
        var index = line.startIndex
        while index < line.endIndex {
            let byte = line[index]
            index += 1
            if escaped {
                escaped = false
                switch byte {
                case UInt8(ascii: "N"):
                    // A null, but only when it is the whole field.
                    if field.isEmpty, index == line.endIndex || line[index] == UInt8(ascii: "\t") {
                        isNull = true
                    } else {
                        field.append(UInt8(ascii: "N"))
                    }
                case UInt8(ascii: "b"): field.append(0x08)
                case UInt8(ascii: "f"): field.append(0x0C)
                case UInt8(ascii: "n"): field.append(0x0A)
                case UInt8(ascii: "r"): field.append(0x0D)
                case UInt8(ascii: "t"): field.append(0x09)
                case UInt8(ascii: "v"): field.append(0x0B)
                // Anything else after a backslash is itself, which is what
                // PostgreSQL does with it.
                default: field.append(byte)
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\\"): escaped = true
            case UInt8(ascii: "\t"): finish()
            default: field.append(byte)
            }
        }
        finish()
        return fields
    }

    /// The rows in `bytes`, split on the newlines that end them. A trailing
    /// `\.` -- which the text format ends a stream with over the wire it does
    /// not use -- is left out.
    public static func rows(_ bytes: ArraySlice<UInt8>) -> [[String?]] {
        var out: [[String?]] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        var escaped = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\n") {
                let line = bytes[start..<index]
                if !(line.count == 2 && line.first == UInt8(ascii: "\\")
                        && line.last == UInt8(ascii: ".")) {
                    out.append(decode(line))
                }
                start = index + 1
            }
            index += 1
        }
        if start < bytes.endIndex { out.append(decode(bytes[start...])) }
        return out
    }
}

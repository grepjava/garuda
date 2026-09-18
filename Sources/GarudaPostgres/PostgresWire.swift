//===----------------------------------------------------------------------===//
// The PostgreSQL wire protocol, version 3.0, as bytes.
//
// No sockets, no poller, no threads: messages in, messages out. The connection
// that drives this lives in the engine, and everything here can be tested
// against recorded exchanges and fuzzed like the HTTP parsers, which is the
// point of keeping it apart (HANDLER-API.md, step 3).
//
// A note on names, since both appear in this tree: the C shim's `pg_` prefix
// is older than the driver and has nothing to do with PostgreSQL. The types here are spelled out as `Postgres` so the two are
// never mistaken for each other.
//
// Every length, count and offset in a backend message is the server's claim,
// and is checked before it is believed. A driver usually trusts its database;
// this one does not have to, because the check costs a comparison, and the
// failure it prevents -- reading past a buffer on a truncated or hostile
// reply -- is a crash in the worker that every other request on it shares.
//===----------------------------------------------------------------------===//

import AvianCore

/// Why a backend message could not be read.
public enum PostgresProtocolError: Error, Equatable, Sendable {
    /// A field ran past the end of its message.
    case truncated
    /// A message length below the four bytes the length itself takes.
    case badLength
    /// A message longer than this connection is willing to hold.
    case tooLarge
    /// A string with no terminating NUL inside its message.
    case unterminated
    /// A count or length that cannot be right: negative where it may not be,
    /// or claiming more than the message holds.
    case badCount
    /// Bytes left over after every field a message has was read -- a message
    /// that is not the shape its type says, which is not safe to half-believe.
    case trailingBytes
    /// An authentication request this client does not implement.
    case unsupportedAuthentication(Int32)
    /// A message type this client does not expect at all.
    case unexpected(UInt8)
}

// MARK: - Reading

/// A bounds-checked cursor over one message body.
public struct PostgresReader {
    public let base: UnsafePointer<UInt8>
    public let count: Int
    public private(set) var offset = 0

    @inlinable
    public init(_ base: UnsafePointer<UInt8>, _ count: Int) {
        self.base = base
        self.count = count
    }

    public var remaining: Int { count &- offset }
    public var isAtEnd: Bool { offset == count }

    public mutating func readUInt8() throws(PostgresProtocolError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { offset &+= 1 }
        return base[offset]
    }

    public mutating func readInt16() throws(PostgresProtocolError) -> Int16 {
        guard remaining >= 2 else { throw .truncated }
        defer { offset &+= 2 }
        return Int16(bitPattern: UInt16(base[offset]) << 8 | UInt16(base[offset &+ 1]))
    }

    public mutating func readInt32() throws(PostgresProtocolError) -> Int32 {
        guard remaining >= 4 else { throw .truncated }
        defer { offset &+= 4 }
        return Int32(bitPattern: UInt32(base[offset]) << 24 | UInt32(base[offset &+ 1]) << 16
                     | UInt32(base[offset &+ 2]) << 8 | UInt32(base[offset &+ 3]))
    }

    /// A NUL-terminated string, which must end inside the message.
    public mutating func readCString() throws(PostgresProtocolError) -> String {
        var end = offset
        while end < count, base[end] != 0 { end &+= 1 }
        guard end < count else { throw .unterminated }
        let text = String(decoding: UnsafeBufferPointer(start: base + offset,
                                                        count: end &- offset), as: UTF8.self)
        offset = end &+ 1
        return text
    }

    /// `n` bytes, as a range of this message.
    public mutating func readBytes(_ n: Int) throws(PostgresProtocolError) -> Range<Int> {
        guard n >= 0 else { throw .badCount }
        guard remaining >= n else { throw .truncated }
        defer { offset &+= n }
        return offset..<(offset &+ n)
    }

    /// Refuses a message with anything left over.
    public func finish() throws(PostgresProtocolError) {
        guard isAtEnd else { throw .trailingBytes }
    }
}

// MARK: - Framing

/// One whole backend message found at the front of a buffer.
public struct PostgresFrame: Equatable, Sendable {
    public var type: UInt8
    /// Where the body starts, relative to the buffer the frame was found in.
    public var bodyOffset: Int
    public var bodyLength: Int
    /// The whole message, type byte included: what to consume.
    public var total: Int { bodyOffset &+ bodyLength }
}

public enum PostgresFramed: Equatable, Sendable {
    case incomplete
    case frame(PostgresFrame)
    case failure(PostgresProtocolError)
}

public enum PostgresBackend {

    /// Frames the message at the front of `base[0..<count]`.
    ///
    /// The length is checked before the body is waited for. A length beyond
    /// `maxLength` is refused on the five bytes that claim it, rather than
    /// after buffering however many megabytes the server said were coming.
    public static func frame(_ base: UnsafePointer<UInt8>, _ count: Int,
                             maxLength: Int) -> PostgresFramed {
        guard count >= 5 else { return .incomplete }
        let length = Int(UInt32(base[1]) << 24 | UInt32(base[2]) << 16
                         | UInt32(base[3]) << 8 | UInt32(base[4]))
        // The length counts itself, and nothing smaller than itself exists.
        guard length >= 4 else { return .failure(.badLength) }
        guard length <= maxLength else { return .failure(.tooLarge) }
        let total = 1 &+ length
        guard count >= total else { return .incomplete }
        return .frame(PostgresFrame(type: base[0], bodyOffset: 5, bodyLength: length &- 4))
    }

    // MARK: Message bodies

    /// An `R` message.
    public static func authentication(_ body: PostgresReader)
        throws(PostgresProtocolError) -> PostgresAuthentication {
        var r = body
        let code = try r.readInt32()
        switch code {
        case 0:
            try r.finish()
            return .ok
        case 3:
            try r.finish()
            return .cleartextPassword
        case 5:
            let salt = try r.readBytes(4)
            try r.finish()
            return .md5Password(salt: Array(UnsafeBufferPointer(
                start: r.base + salt.lowerBound, count: 4)))
        case 10:
            // A list of mechanism names, each NUL-terminated, ended by an empty
            // one. The terminator is required rather than inferred from the end
            // of the message: a list that stops short is a list this client
            // may have read only part of.
            var mechanisms: [String] = []
            while true {
                let name = try r.readCString()
                if name.isEmpty { break }
                mechanisms.append(name)
            }
            try r.finish()
            return .sasl(mechanisms: mechanisms)
        case 11:
            let data = try r.readBytes(r.remaining)
            return .saslContinue(Array(UnsafeBufferPointer(start: r.base + data.lowerBound,
                                                           count: data.count)))
        case 12:
            let data = try r.readBytes(r.remaining)
            return .saslFinal(Array(UnsafeBufferPointer(start: r.base + data.lowerBound,
                                                        count: data.count)))
        default:
            throw .unsupportedAuthentication(code)
        }
    }

    /// An `S` message.
    public static func parameterStatus(_ body: PostgresReader)
        throws(PostgresProtocolError) -> (name: String, value: String) {
        var r = body
        let name = try r.readCString()
        let value = try r.readCString()
        try r.finish()
        return (name, value)
    }

    /// A `K` message.
    public static func backendKeyData(_ body: PostgresReader)
        throws(PostgresProtocolError) -> (processID: Int32, secretKey: Int32) {
        var r = body
        let pid = try r.readInt32()
        let key = try r.readInt32()
        try r.finish()
        return (pid, key)
    }

    /// A `Z` message.
    public static func readyForQuery(_ body: PostgresReader)
        throws(PostgresProtocolError) -> PostgresTransactionStatus {
        var r = body
        let status = try r.readUInt8()
        try r.finish()
        switch status {
        case UInt8(ascii: "I"): return .idle
        case UInt8(ascii: "T"): return .inTransaction
        case UInt8(ascii: "E"): return .failedTransaction
        default: throw .badCount
        }
    }

    /// A `C` message: the command tag, such as `INSERT 0 1`.
    public static func commandComplete(_ body: PostgresReader)
        throws(PostgresProtocolError) -> String {
        var r = body
        let tag = try r.readCString()
        try r.finish()
        return tag
    }

    /// An `E` or `N` message.
    public static func errorFields(_ body: PostgresReader)
        throws(PostgresProtocolError) -> PostgresErrorFields {
        var r = body
        var fields = PostgresErrorFields()
        while true {
            let code = try r.readUInt8()
            if code == 0 { break }
            let value = try r.readCString()
            switch code {
            case UInt8(ascii: "S"): fields.severity = value
            case UInt8(ascii: "V"): fields.severity = value
            case UInt8(ascii: "C"): fields.code = value
            case UInt8(ascii: "M"): fields.message = value
            case UInt8(ascii: "D"): fields.detail = value
            case UInt8(ascii: "H"): fields.hint = value
            case UInt8(ascii: "n"): fields.constraint = value
            default: break
            }
        }
        try r.finish()
        return fields
    }

    /// A `T` message.
    public static func rowDescription(_ body: PostgresReader)
        throws(PostgresProtocolError) -> [PostgresColumn] {
        var r = body
        let n = Int(try r.readInt16())
        // Each field is at least a NUL and eighteen bytes. A count the body
        // cannot hold is refused before an array is sized to it.
        guard n >= 0, n &* 19 <= r.remaining else { throw .badCount }
        var columns: [PostgresColumn] = []
        columns.reserveCapacity(n)
        for _ in 0..<n {
            let name = try r.readCString()
            let tableOID = UInt32(bitPattern: try r.readInt32())
            let attribute = try r.readInt16()
            let typeOID = UInt32(bitPattern: try r.readInt32())
            let size = try r.readInt16()
            let modifier = try r.readInt32()
            let format = try r.readInt16()
            columns.append(PostgresColumn(name: name, tableOID: tableOID, attribute: attribute,
                                          typeOID: typeOID, size: size, modifier: modifier,
                                          binary: format == 1))
        }
        try r.finish()
        return columns
    }

    /// A `D` message, as the range of each column's value within the body, or
    /// nil for SQL NULL. `values` is cleared and reused, so a result of many
    /// rows does not allocate an array per row.
    public static func dataRow(_ body: PostgresReader,
                               into values: inout [Range<Int>?]) throws(PostgresProtocolError) {
        var r = body
        values.removeAll(keepingCapacity: true)
        let n = Int(try r.readInt16())
        // Each column is at least its four-byte length.
        guard n >= 0, n &* 4 <= r.remaining else { throw .badCount }
        for _ in 0..<n {
            let length = try r.readInt32()
            if length == -1 {
                values.append(nil)
                continue
            }
            // -1 is NULL. Anything else below zero is refused by readBytes,
            // which refuses a negative count for every caller -- a second
            // check here survived mutation testing with either one deleted,
            // since each caught what the other would have.
            values.append(try r.readBytes(Int(length)))
        }
        try r.finish()
    }

    /// A `t` message: the type of each parameter a prepared statement takes.
    public static func parameterDescription(_ body: PostgresReader)
        throws(PostgresProtocolError) -> [UInt32] {
        var r = body
        let n = Int(try r.readInt16())
        guard n >= 0, n &* 4 <= r.remaining else { throw .badCount }
        var types: [UInt32] = []
        types.reserveCapacity(n)
        for _ in 0..<n { types.append(UInt32(bitPattern: try r.readInt32())) }
        try r.finish()
        return types
    }
}

public enum PostgresAuthentication: Equatable, Sendable {
    case ok
    case cleartextPassword
    case md5Password(salt: [UInt8])
    case sasl(mechanisms: [String])
    case saslContinue([UInt8])
    case saslFinal([UInt8])
}

public enum PostgresTransactionStatus: Equatable, Sendable {
    case idle
    case inTransaction
    case failedTransaction
}

/// What the server said went wrong, or wanted noticed.
public struct PostgresErrorFields: Equatable, Sendable {
    public var severity = ""
    /// The SQLSTATE: `23505` for a unique violation, `42P01` for an unknown
    /// table. What to branch on, unlike the message, which is localised.
    public var code = ""
    public var message = ""
    public var detail: String? = nil
    public var hint: String? = nil
    public var constraint: String? = nil

    public init() {}
}

/// One column of a result, as a RowDescription describes it.
public struct PostgresColumn: Equatable, Sendable {
    public var name: String
    public var tableOID: UInt32
    public var attribute: Int16
    public var typeOID: UInt32
    public var size: Int16
    public var modifier: Int32
    public var binary: Bool
}

// MARK: - Writing

/// The value for one `$n` placeholder, as it goes on the wire.
public enum PostgresValue: Equatable, Sendable {
    case null
    /// Text PostgreSQL parses into whatever type the placeholder has.
    case text([UInt8])
    /// The type's binary form, with the type's OID: the statement is told the
    /// placeholder's type, since binary bytes mean nothing without one.
    case binary([UInt8], type: UInt32)

    /// Text, or NULL for nil.
    public init(_ text: String?) {
        self = text.map { .text(Array($0.utf8)) } ?? .null
    }

    /// The OID Parse declares for this value, or 0 to let the server infer it.
    public var declaredType: UInt32 {
        if case .binary(_, let type) = self { return type }
        return 0
    }
}

/// bytea's text form.
public enum PostgresBytea {
    /// `\x` and two hex digits a byte, which is how a server has sent bytea
    /// as text since 9.0. The older escape format, which bytea_output can still
    /// ask for, is refused rather than misread.
    public static func decodeHex(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        guard text.count >= 2, text.count % 2 == 0,
              text[text.startIndex] == UInt8(ascii: "\\"),
              text[text.startIndex + 1] == UInt8(ascii: "x") else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 2 - 1)
        var i = text.startIndex + 2
        while i < text.endIndex {
            guard let high = hexValue(text[i]), let low = hexValue(text[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// Type OIDs, as pg_type has them.
public enum PostgresType {
    public static let bool: UInt32 = 16
    public static let bytea: UInt32 = 17
    public static let int8: UInt32 = 20
    public static let int2: UInt32 = 21
    public static let int4: UInt32 = 23
    public static let text: UInt32 = 25
    public static let json: UInt32 = 114
    public static let float4: UInt32 = 700
    public static let float8: UInt32 = 701
    public static let date: UInt32 = 1082
    public static let time: UInt32 = 1083
    public static let timestamp: UInt32 = 1114
    public static let timestamptz: UInt32 = 1184
    public static let interval: UInt32 = 1186
    public static let numeric: UInt32 = 1700
    public static let uuid: UInt32 = 2950
    public static let jsonb: UInt32 = 3802
}

public enum PostgresFrontend {

    /// Protocol 3.0, as the startup message spells it.
    public static let protocolVersion: Int32 = 196_608
    /// The code an SSLRequest carries in place of a protocol version.
    public static let sslRequestCode: Int32 = 80_877_103

    /// Asks the server whether it will do TLS. It answers one byte, `S` or
    /// `N`, before anything else.
    public static func sslRequest(into out: inout ByteBuffer) {
        writeInt32(8, into: &out)
        writeInt32(sslRequestCode, into: &out)
    }

    /// The first message, naming the user and the database.
    ///
    /// Refuses a parameter holding a NUL rather than writing it: the message
    /// is NUL-separated, and a user name with one inside ends early and
    /// becomes a second parameter chosen by whoever supplied the name.
    public static func startup(user: String, database: String?,
                               parameters: [(String, String)] = [],
                               into out: inout ByteBuffer) -> Bool {
        var pairs = [("user", user)]
        if let database { pairs.append(("database", database)) }
        pairs.append(contentsOf: parameters)
        for (name, value) in pairs where name.utf8.contains(0) || value.utf8.contains(0) {
            return false
        }
        let start = beginUntyped(&out)
        writeInt32(protocolVersion, into: &out)
        for (name, value) in pairs {
            writeCString(name, into: &out)
            writeCString(value, into: &out)
        }
        out.writeByte(0)
        endMessage(&out, start)
        return true
    }

    /// A cleartext or MD5 password response.
    public static func password(_ text: String, into out: inout ByteBuffer) -> Bool {
        guard !text.utf8.contains(0) else { return false }
        let start = begin(UInt8(ascii: "p"), &out)
        writeCString(text, into: &out)
        endMessage(&out, start)
        return true
    }

    public static func saslInitialResponse(mechanism: String, data: [UInt8],
                                           into out: inout ByteBuffer) {
        let start = begin(UInt8(ascii: "p"), &out)
        writeCString(mechanism, into: &out)
        writeInt32(Int32(data.count), into: &out)
        data.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
        endMessage(&out, start)
    }

    public static func saslResponse(_ data: [UInt8], into out: inout ByteBuffer) {
        let start = begin(UInt8(ascii: "p"), &out)
        data.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) }
        endMessage(&out, start)
    }

    /// A simple query. Used only where nothing from outside reaches the text:
    /// every query carrying a value goes through `parse` and `bind`, where the
    /// value can never become SQL.
    public static func query(_ sql: String, into out: inout ByteBuffer) -> Bool {
        guard !sql.utf8.contains(0) else { return false }
        let start = begin(UInt8(ascii: "Q"), &out)
        writeCString(sql, into: &out)
        endMessage(&out, start)
        return true
    }

    /// Prepares `sql` under `name` ("" for the unnamed statement).
    public static func parse(name: String, sql: String, parameterTypes: [UInt32],
                             into out: inout ByteBuffer) -> Bool {
        guard !name.utf8.contains(0), !sql.utf8.contains(0),
              parameterTypes.count <= Int(Int16.max) else { return false }
        let start = begin(UInt8(ascii: "P"), &out)
        writeCString(name, into: &out)
        writeCString(sql, into: &out)
        writeInt16(Int16(parameterTypes.count), into: &out)
        for oid in parameterTypes { writeInt32(Int32(bitPattern: oid), into: &out) }
        endMessage(&out, start)
        return true
    }

    /// Binds values to a prepared statement. Each parameter goes in its own
    /// format; `resultFormats` is empty for every column as text, or a code
    /// per column (0 text, 1 binary).
    public static func bind(portal: String, statement: String, values: [PostgresValue],
                            resultFormats: [Int16] = [], into out: inout ByteBuffer) -> Bool {
        guard !portal.utf8.contains(0), !statement.utf8.contains(0),
              values.count <= Int(Int16.max), resultFormats.count <= Int(Int16.max) else { return false }
        let start = begin(UInt8(ascii: "B"), &out)
        writeCString(portal, into: &out)
        writeCString(statement, into: &out)
        if values.contains(where: { $0.declaredType != 0 }) {
            writeInt16(Int16(values.count), into: &out)
            for value in values { writeInt16(value.declaredType != 0 ? 1 : 0, into: &out) }
        } else {
            writeInt16(0, into: &out)                 // every parameter as text
        }
        writeInt16(Int16(values.count), into: &out)
        for value in values {
            switch value {
            case .null:
                writeInt32(-1, into: &out)
            case .text(let bytes), .binary(let bytes, _):
                writeInt32(Int32(bytes.count), into: &out)
                bytes.withUnsafeBufferPointer { if $0.count > 0 { out.write($0.baseAddress!, $0.count) } }
            }
        }
        writeInt16(Int16(resultFormats.count), into: &out)
        for format in resultFormats { writeInt16(format, into: &out) }
        endMessage(&out, start)
        return true
    }

    /// Describes a portal (`P`) or statement (`S`).
    public static func describe(portal name: String, into out: inout ByteBuffer) -> Bool {
        guard !name.utf8.contains(0) else { return false }
        let start = begin(UInt8(ascii: "D"), &out)
        out.writeByte(UInt8(ascii: "P"))
        writeCString(name, into: &out)
        endMessage(&out, start)
        return true
    }

    public static func execute(portal: String, maxRows: Int32 = 0,
                               into out: inout ByteBuffer) -> Bool {
        guard !portal.utf8.contains(0) else { return false }
        let start = begin(UInt8(ascii: "E"), &out)
        writeCString(portal, into: &out)
        writeInt32(maxRows, into: &out)
        endMessage(&out, start)
        return true
    }

    /// Closes a prepared statement. Closing one that does not exist is not an
    /// error, so an eviction can never fail the statement it travels with.
    public static func close(statement name: String, into out: inout ByteBuffer) -> Bool {
        guard !name.utf8.contains(0) else { return false }
        let start = begin(UInt8(ascii: "C"), &out)
        out.writeByte(UInt8(ascii: "S"))
        writeCString(name, into: &out)
        endMessage(&out, start)
        return true
    }

    public static func sync(into out: inout ByteBuffer) {
        out.writeByte(UInt8(ascii: "S"))
        writeInt32(4, into: &out)
    }

    public static func terminate(into out: inout ByteBuffer) {
        out.writeByte(UInt8(ascii: "X"))
        writeInt32(4, into: &out)
    }

    // MARK: Pieces

    /// Starts a typed message and returns where its length goes.
    static func begin(_ type: UInt8, _ out: inout ByteBuffer) -> Int {
        out.writeByte(type)
        return beginUntyped(&out)
    }

    /// Starts a message with no type byte, as the startup message and the
    /// SSL request are, and returns where its length goes.
    static func beginUntyped(_ out: inout ByteBuffer) -> Int {
        let at = out.writerOffset
        writeInt32(0, into: &out)
        return at
    }

    /// Writes the length back, counting itself and everything after it.
    static func endMessage(_ out: inout ByteBuffer, _ lengthAt: Int) {
        let length = UInt32(out.writerOffset &- lengthAt)
        let p = out.pointer(at: lengthAt)
        p[0] = UInt8(truncatingIfNeeded: length >> 24)
        p[1] = UInt8(truncatingIfNeeded: length >> 16)
        p[2] = UInt8(truncatingIfNeeded: length >> 8)
        p[3] = UInt8(truncatingIfNeeded: length)
    }

    static func writeInt16(_ v: Int16, into out: inout ByteBuffer) {
        let u = UInt16(bitPattern: v)
        out.writeByte(UInt8(truncatingIfNeeded: u >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: u))
    }

    static func writeInt32(_ v: Int32, into out: inout ByteBuffer) {
        let u = UInt32(bitPattern: v)
        out.reserve(4)
        out.writeByte(UInt8(truncatingIfNeeded: u >> 24))
        out.writeByte(UInt8(truncatingIfNeeded: u >> 16))
        out.writeByte(UInt8(truncatingIfNeeded: u >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: u))
    }

    static func writeCString(_ s: String, into out: inout ByteBuffer) {
        var s = s
        s.withUTF8 { if $0.count > 0 { out.write($0.baseAddress!, $0.count) } }
        out.writeByte(0)
    }
}

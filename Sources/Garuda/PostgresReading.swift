import Synchronization
import GarudaPostgres

// Reading a row without Codable, the way `JSONReadable` reads a body without
// it. `Codable` decides at run time what is known at compile time: which
// property comes next, what type it is, where it goes. Profiling `/db` put
// the keyed container and the decoder it hangs off at about a fiftieth of the
// whole server's CPU, for work a generated initializer does with none.
//
// A type opts in by conforming; `@PostgresRow` writes the conformance. The
// pool asks once per result whether the type wants this, and a type without
// it is decoded exactly as before.

/// One row of a result, with its columns found by name.
///
/// What a cell decodes to is what `Codable` decoded it to: the same binary
/// and text paths, the same errors, a NULL into a non-optional refused rather
/// than read as zero.
public struct PostgresRowReader {
    let rows: PostgresRows
    let row: Int
    let index: PostgresColumnIndex

    init(rows: PostgresRows, row: Int, index: PostgresColumnIndex) {
        self.rows = rows
        self.row = row
        self.index = index
    }

    /// Whether the result carries that column at all.
    public func has(_ name: String) -> Bool { index[name] != nil }

    private func cell(_ name: String) throws -> PostgresCell {
        guard let column = index[name] else {
            throw PostgresDecodingError.missingColumn(name)
        }
        return PostgresCell(rows: rows, row: row, column: column)
    }

    /// The cell that is there, or nil where `Codable` would have found none:
    /// a column the result does not have, or one holding NULL. That is what
    /// `decodeIfPresent` does for an optional property, and an optional
    /// member must keep meaning the same thing.
    private func present(_ name: String) -> PostgresCell? {
        guard let column = index[name] else { return nil }
        let cell = PostgresCell(rows: rows, row: row, column: column)
        return cell.decodeNil() ? nil : cell
    }
}

// MARK: - The columns a row is made of

// One pair a type, rather than one generic pair: a concrete overload keeps a
// scalar off `Codable`'s path, where a single generic would put every column
// back on it.
extension PostgresRowReader {
    public func value(_ type: Bool.Type, _ name: String) throws -> Bool { try cell(name).decode(type) }
    public func value(_ type: String.Type, _ name: String) throws -> String { try cell(name).decode(type) }
    public func value(_ type: Double.Type, _ name: String) throws -> Double { try cell(name).decode(type) }
    public func value(_ type: Float.Type, _ name: String) throws -> Float { try cell(name).decode(type) }
    public func value(_ type: Int.Type, _ name: String) throws -> Int { try cell(name).decode(type) }
    public func value(_ type: Int8.Type, _ name: String) throws -> Int8 { try cell(name).decode(type) }
    public func value(_ type: Int16.Type, _ name: String) throws -> Int16 { try cell(name).decode(type) }
    public func value(_ type: Int32.Type, _ name: String) throws -> Int32 { try cell(name).decode(type) }
    public func value(_ type: Int64.Type, _ name: String) throws -> Int64 { try cell(name).decode(type) }
    public func value(_ type: UInt.Type, _ name: String) throws -> UInt { try cell(name).decode(type) }
    public func value(_ type: UInt8.Type, _ name: String) throws -> UInt8 { try cell(name).decode(type) }
    public func value(_ type: UInt16.Type, _ name: String) throws -> UInt16 { try cell(name).decode(type) }
    public func value(_ type: UInt32.Type, _ name: String) throws -> UInt32 { try cell(name).decode(type) }
    public func value(_ type: UInt64.Type, _ name: String) throws -> UInt64 { try cell(name).decode(type) }

    /// Anything else -- a `UUID`, a `Timestamp`, a String-backed enum, an
    /// array column -- reads from the cell as it always did.
    public func value<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try cell(name).decode(type)
    }

    public func optional(_ type: Bool.Type, _ name: String) throws -> Bool? { try present(name)?.decode(type) }
    public func optional(_ type: String.Type, _ name: String) throws -> String? { try present(name)?.decode(type) }
    public func optional(_ type: Double.Type, _ name: String) throws -> Double? { try present(name)?.decode(type) }
    public func optional(_ type: Float.Type, _ name: String) throws -> Float? { try present(name)?.decode(type) }
    public func optional(_ type: Int.Type, _ name: String) throws -> Int? { try present(name)?.decode(type) }
    public func optional(_ type: Int8.Type, _ name: String) throws -> Int8? { try present(name)?.decode(type) }
    public func optional(_ type: Int16.Type, _ name: String) throws -> Int16? { try present(name)?.decode(type) }
    public func optional(_ type: Int32.Type, _ name: String) throws -> Int32? { try present(name)?.decode(type) }
    public func optional(_ type: Int64.Type, _ name: String) throws -> Int64? { try present(name)?.decode(type) }
    public func optional(_ type: UInt.Type, _ name: String) throws -> UInt? { try present(name)?.decode(type) }
    public func optional(_ type: UInt8.Type, _ name: String) throws -> UInt8? { try present(name)?.decode(type) }
    public func optional(_ type: UInt16.Type, _ name: String) throws -> UInt16? { try present(name)?.decode(type) }
    public func optional(_ type: UInt32.Type, _ name: String) throws -> UInt32? { try present(name)?.decode(type) }
    public func optional(_ type: UInt64.Type, _ name: String) throws -> UInt64? { try present(name)?.decode(type) }

    public func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        try present(name)?.decode(type)
    }
}

// MARK: - What can be read

/// A type that reads itself from a row rather than through `Codable`.
///
/// `@PostgresRow` writes the conformance; writing one by hand is the same
/// work, with a `PostgresRowReader`.
public protocol PostgresReadable {
    /// Reads one row.
    init(row: PostgresRowReader) throws
}

/// Which types read themselves, remembered as they are asked about.
///
/// The conformance is kept rather than a yes or no, so that finding it again
/// is one dictionary hit instead of a second trip through the runtime.
enum PostgresFastPath {
    private static let readers = Mutex<[ObjectIdentifier: (any PostgresReadable.Type)?]>([:])

    static func reader(for type: Any.Type) -> (any PostgresReadable.Type)? {
        let key = ObjectIdentifier(type)
        return readers.withLock { known in
            if let answer = known[key] { return answer }
            let answer = type as? any PostgresReadable.Type
            known[key] = answer
            return answer
        }
    }
}

extension PostgresReadable {
    /// Reads one row through the conformance, from a metatype the caller only
    /// knows as `any PostgresReadable.Type`.
    static func readRow(_ reader: PostgresRowReader) throws -> Self {
        try Self(row: reader)
    }
}

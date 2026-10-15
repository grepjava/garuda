//===----------------------------------------------------------------------===//
// GarudaPostgres: PostgreSQL for a Garuda application.
//
//     import Garuda
//     import GarudaPostgres
//
//     let db = app.state { _ in
//         try! PostgresPool(PostgresConfiguration(url: "postgres://app:secret@db/app"))
//     }
//     app.get("/users/:id") { (id: Path<Int>, db: State<PostgresPool>) in
//         try await db.first(User.self, "select id, name from users where id = $1", id.value)
//     }
//
// The driver is vega-db's VegaPostgres, re-exported whole. What is here is
// what joins it to Garuda: its `UUID` and `Timestamp` as uuid and timestamptz
// columns, `PostgresJSON` over Garuda's JSON coder, and spans on the tracer
// the application traces with.
//===----------------------------------------------------------------------===//

@_exported import Garuda
@_exported import VegaPostgres

extension UUID: PostgresBindable, PostgresCellConvertible {
    public var postgresValue: PostgresValue { PostgresUUID(bytes: bytes)!.postgresValue }

    public init(postgresRepresentation value: PostgresUUID) throws {
        self.init(bytes: value.bytes)!
    }
}

extension Timestamp: PostgresBindable, PostgresCellConvertible {
    public var postgresValue: PostgresValue {
        PostgresTimestamp(microsecondsSinceEpoch: microsecondsSinceEpoch).postgresValue
    }

    public init(postgresRepresentation value: PostgresTimestamp) throws {
        self.init(microsecondsSinceEpoch: value.microsecondsSinceEpoch)
    }
}

/// A `json` or `jsonb` column, decoded into `Value`.
///
/// ```
/// struct Row: Decodable { let meta: PostgresJSON<Metadata> }
/// let metadata = try await pool.first(Row.self, "select meta from things")?.meta.value
/// ```
public struct PostgresJSON<Value: Codable & Sendable>: Sendable, Codable, CustomStringConvertible {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        // From a row the column's text comes through `postgresRepresentation`;
        // from anything else, it decodes as the value itself.
        value = try Value(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    public var description: String {
        (try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "\(value)"
    }
}

extension PostgresJSON: PostgresCellConvertible {
    /// The column's text, which is the document.
    public init(postgresRepresentation text: String) throws {
        value = try JSONCoder.decode(Value.self, from: Array(text.utf8))
    }
}

extension PostgresJSON: PostgresBindable {
    public var postgresValue: PostgresValue {
        PostgresValue((try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "null")
    }
}

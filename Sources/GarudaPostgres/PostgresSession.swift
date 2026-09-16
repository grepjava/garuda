//===----------------------------------------------------------------------===//
// Starting a PostgreSQL session and running queries on it, as state machines
// over messages.
//
// Still no sockets. The engine frames bytes into messages, hands each one to
// the machine for whatever is in progress, and writes what the machine says
// to write. Everything a server can send in any order is handled here once,
// so the socket layer only ever moves bytes.
//===----------------------------------------------------------------------===//

import GarudaCore

/// Why a session could not start, or a query did not complete.
public enum PostgresError: Error, Equatable, Sendable {
    /// A message that is not well formed.
    case protocolViolation(PostgresProtocolError)
    /// A message that is well formed and not allowed where it arrived.
    case unexpectedMessage(UInt8)
    /// The server wants a way of authenticating this client will not use.
    case refusedAuthentication(String)
    /// SCRAM failed, including the server failing to prove itself.
    case scram(ScramError)
    /// The server said no -- a wrong password, a missing table, a violated
    /// constraint. Carries everything it said.
    case server(PostgresErrorFields)
    /// A value that cannot be sent, such as SQL holding a NUL.
    case unsendable
}

// MARK: - Startup

/// What the caller should do after handing the machine a message.
public enum PostgresStep: Equatable, Sendable {
    /// Nothing to send; wait for the next message.
    case wait
    /// Write these bytes, then wait for the next message.
    case send([UInt8])
    /// The session is ready for queries.
    case ready
}

public struct PostgresStartup {

    /// How this client will authenticate. SCRAM only, unless told otherwise.
    ///
    /// A server that answers the startup message by asking for the password
    /// in cleartext when the real server does SCRAM is the standard way to
    /// harvest a password: the client obligingly sends it, and whatever was
    /// listening has it. So cleartext is refused unless allowed, and refused
    /// even then unless the connection is encrypted -- a password sent in the
    /// clear over plaintext is sent to everyone on the path. MD5 is not a
    /// choice at all: see `authentication`.
    public struct Policy: Sendable {
        public var allowCleartext = false
        public var encrypted = false
        public init() {}
    }

    let user: String
    let password: String
    let database: String?
    let policy: Policy
    private var scram: ScramSHA256Client? = nil
    /// Set once the server's SCRAM signature has verified.
    private var scramVerified = false
    private var authenticated = false
    public private(set) var parameters: [String: String] = [:]
    public private(set) var processID: Int32 = 0
    public private(set) var secretKey: Int32 = 0

    public init(user: String, password: String, database: String?, policy: Policy = Policy(),
                nonce: String? = nil) {
        self.user = user
        self.password = password
        self.database = database
        self.policy = policy
        if let nonce { scram = ScramSHA256Client(password: password, nonce: nonce) }
    }

    /// The startup message.
    public func start() throws(PostgresError) -> [UInt8] {
        var out = ByteBuffer(capacity: 128)
        defer { out.destroy() }
        guard PostgresFrontend.startup(user: user, database: database, into: &out) else {
            throw .unsendable
        }
        return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    /// Handles one message.
    public mutating func receive(_ type: UInt8, _ body: PostgresReader) throws(PostgresError) -> PostgresStep {
        do {
            switch type {
            case UInt8(ascii: "R"):
                return try authentication(try PostgresBackend.authentication(body))
            case UInt8(ascii: "S"):
                let (name, value) = try PostgresBackend.parameterStatus(body)
                parameters[name] = value
                return .wait
            case UInt8(ascii: "K"):
                (processID, secretKey) = try PostgresBackend.backendKeyData(body)
                return .wait
            case UInt8(ascii: "Z"):
                // Ready only after authenticating. A server announcing it is
                // ready for queries before any authentication has concluded
                // has skipped the part that says who it is.
                guard authenticated else { throw PostgresError.unexpectedMessage(type) }
                _ = try PostgresBackend.readyForQuery(body)
                return .ready
            case UInt8(ascii: "E"):
                throw PostgresError.server(try PostgresBackend.errorFields(body))
            case UInt8(ascii: "N"):
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

    private mutating func authentication(_ request: PostgresAuthentication) throws(PostgresError) -> PostgresStep {
        switch request {
        case .ok:
            // Once SCRAM has begun, "ok" is believed only after the server
            // has proved it knows the password. Otherwise an impostor relays
            // the exchange up to the proof and then simply says ok.
            if scramStarted && !scramVerified {
                throw .refusedAuthentication("the server skipped proving itself")
            }
            authenticated = true
            return .wait

        case .cleartextPassword:
            guard policy.allowCleartext, policy.encrypted else {
                throw .refusedAuthentication("cleartext password")
            }
            var out = ByteBuffer(capacity: 64)
            defer { out.destroy() }
            guard PostgresFrontend.password(password, into: &out) else { throw .unsendable }
            return .send(Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes)))

        case .md5Password:
            // Never implemented, and refused whatever the policy says: MD5
            // authentication is deprecated in PostgreSQL and its verifier is
            // the password's equivalent.
            throw .refusedAuthentication("md5 password")

        case .sasl(let mechanisms):
            guard mechanisms.contains(ScramSHA256Client.mechanism) else {
                throw .refusedAuthentication("no mechanism in common: \(mechanisms)")
            }
            if scram == nil { scram = ScramSHA256Client(password: password) }
            scramStarted = true
            var out = ByteBuffer(capacity: 128)
            defer { out.destroy() }
            PostgresFrontend.saslInitialResponse(mechanism: ScramSHA256Client.mechanism,
                                                 data: scram!.clientFirstMessage, into: &out)
            return .send(Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes)))

        case .saslContinue(let data):
            guard scramStarted, var client = scram else { throw .unexpectedMessage(UInt8(ascii: "R")) }
            let final: [UInt8]
            do {
                final = try client.respond(toServerFirst: data)
            } catch {
                throw .scram(error)
            }
            scram = client
            var out = ByteBuffer(capacity: 256)
            defer { out.destroy() }
            PostgresFrontend.saslResponse(final, into: &out)
            return .send(Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes)))

        case .saslFinal(let data):
            guard scramStarted, let client = scram else { throw .unexpectedMessage(UInt8(ascii: "R")) }
            do {
                try client.verify(serverFinal: data)
            } catch {
                throw .scram(error)
            }
            scramVerified = true
            return .wait
        }
    }

    private var scramStarted = false
}

// MARK: - Queries

/// A result, owned: every value is copied out of the connection's buffer.
public struct PostgresRows: Sendable {
    public private(set) var columns: [PostgresColumn] = []
    /// Every cell's bytes, back to back.
    var storage: [UInt8] = []
    /// Each cell's range in `storage`, row by row, or nil for NULL.
    var cells: [Range<Int>?] = []
    /// The command tag: `SELECT 3`, `INSERT 0 1`.
    public private(set) var tag = ""

    public var count: Int { columns.isEmpty ? 0 : cells.count / columns.count }

    /// The text of a cell, or nil for NULL.
    public func text(row: Int, column: Int) -> String? {
        guard let range = cells[row * columns.count + column] else { return nil }
        return String(decoding: storage[range], as: UTF8.self)
    }

    /// A cell's bytes as the server sent them, in the column's format, or nil
    /// for NULL.
    public func bytes(row: Int, column: Int) -> ArraySlice<UInt8>? {
        guard let range = cells[row * columns.count + column] else { return nil }
        return storage[range]
    }

    /// The number the tag ends with -- rows returned or affected.
    public var affected: Int {
        Int(tag.split(separator: " ").last ?? "") ?? 0
    }

    mutating func setColumns(_ columns: [PostgresColumn]) { self.columns = columns }
    mutating func setTag(_ tag: String) { self.tag = tag }
    mutating func append(_ body: PostgresReader, _ ranges: [Range<Int>?]) {
        for range in ranges {
            guard let range else {
                cells.append(nil)
                continue
            }
            let start = storage.count
            storage.append(contentsOf: UnsafeBufferPointer(start: body.base + range.lowerBound,
                                                           count: range.count))
            cells.append(start..<storage.count)
        }
    }
}

/// One statement through the extended query protocol.
///
/// Values go in their own message, never into the SQL: `$1` in the statement
/// and the value beside it, so no value can become part of what is run,
/// whatever it contains.
public struct PostgresQuery {
    let sql: String
    let values: [PostgresValue]
    /// The prepared statement this runs as: "" for the unnamed one.
    let statement: String
    /// Whether to parse `sql` into `statement` first, or use it as it stands.
    let prepare: Bool
    /// A format per result column, or empty for all text.
    let resultFormats: [Int16]
    /// Statements to close before this one runs.
    let closing: [String]
    public private(set) var rows = PostgresRows()
    /// Whether the server parsed the statement. A prepared statement exists
    /// from then on, whatever happens to the rest of the query.
    public private(set) var parsed = false
    /// What the server's ReadyForQuery said: whether the session is left
    /// inside a transaction, and whether that transaction has failed.
    public private(set) var transactionStatus: PostgresTransactionStatus = .idle
    private var error: PostgresErrorFields? = nil
    private var scratch: [Range<Int>?] = []
    /// The row limit a result may reach before the query is failed. Rows are
    /// copied as they arrive, so an unbounded SELECT is an unbounded buffer.
    let maxRows: Int

    public init(_ sql: String, _ values: [PostgresValue] = [], maxRows: Int = 1_000_000,
                statement: String = "", prepare: Bool = true, resultFormats: [Int16] = [],
                closing: [String] = []) {
        self.sql = sql
        self.values = values
        self.statement = statement
        self.prepare = prepare
        self.resultFormats = resultFormats
        self.closing = closing
        self.maxRows = maxRows
    }

    /// Close what is evicted, parse unless the statement is already prepared,
    /// then bind, describe, execute and sync, as one write.
    ///
    /// The portal is described every time, even for a statement described
    /// before: the description is what says which format each column came
    /// in, and a column renamed since would otherwise decode by its old name.
    public func messages() throws(PostgresError) -> [UInt8] {
        var out = ByteBuffer(capacity: 256)
        defer { out.destroy() }
        for name in closing {
            guard PostgresFrontend.close(statement: name, into: &out) else { throw .unsendable }
        }
        // Types are declared only when a value is binary, and then only for
        // that value: 0 leaves the rest to the server to infer, as before.
        let types = values.contains { $0.declaredType != 0 } ? values.map(\.declaredType) : []
        guard !prepare || PostgresFrontend.parse(name: statement, sql: sql, parameterTypes: types, into: &out),
              PostgresFrontend.bind(portal: "", statement: statement, values: values,
                                    resultFormats: resultFormats, into: &out),
              PostgresFrontend.describe(portal: "", into: &out),
              PostgresFrontend.execute(portal: "", into: &out) else {
            throw .unsendable
        }
        PostgresFrontend.sync(into: &out)
        return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    /// Handles one message. Returns true once the query has finished, after
    /// which `result()` says how.
    ///
    /// An error does not finish it. The server discards everything up to the
    /// Sync and then says it is ready, and until that ReadyForQuery arrives
    /// the connection is still mid-query: handing it to the next caller early
    /// would give that caller this query's leftovers.
    public mutating func receive(_ type: UInt8, _ body: PostgresReader) throws(PostgresError) -> Bool {
        do {
            switch type {
            case UInt8(ascii: "1"):
                parsed = true
                return false
            case UInt8(ascii: "2"), UInt8(ascii: "3"), UInt8(ascii: "n"),
                 UInt8(ascii: "N"), UInt8(ascii: "S"), UInt8(ascii: "I"):
                return false
            case UInt8(ascii: "T"):
                rows.setColumns(try PostgresBackend.rowDescription(body))
                return false
            case UInt8(ascii: "D"):
                try PostgresBackend.dataRow(body, into: &scratch)
                // A row that does not match the description is a server that
                // does not agree with itself about what it is sending.
                guard scratch.count == rows.columns.count else {
                    throw PostgresError.unexpectedMessage(type)
                }
                guard rows.count < maxRows else {
                    if error == nil {
                        var fields = PostgresErrorFields()
                        fields.code = "54000"
                        fields.message = "result has more than \(maxRows) rows"
                        error = fields
                    }
                    return false
                }
                rows.append(body, scratch)
                return false
            case UInt8(ascii: "C"):
                rows.setTag(try PostgresBackend.commandComplete(body))
                return false
            case UInt8(ascii: "E"):
                error = try PostgresBackend.errorFields(body)
                return false
            case UInt8(ascii: "Z"):
                transactionStatus = try PostgresBackend.readyForQuery(body)
                return true
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

    /// How the finished query went.
    public func result() -> Result<PostgresRows, PostgresError> {
        if let error { return .failure(.server(error)) }
        return .success(rows)
    }
}

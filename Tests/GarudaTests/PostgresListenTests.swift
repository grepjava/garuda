import Testing
import CAvian
import AvianCore
import GarudaPostgres
@testable import Garuda

// LISTEN and NOTIFY: the message a notification arrives in, how a channel name
// becomes an identifier, and what a query does when told something mid-flight.

@Suite("PostgreSQL notifications")
struct PostgresListenTests {
    /// An `A` message: the sender's process ID, the channel, the payload.
    @Test func notificationMessagesAreRead() throws {
        func message(pid: Int32, _ channel: String, _ payload: String) -> [UInt8] {
            var out: [UInt8] = []
            withUnsafeBytes(of: pid.bigEndian) { out.append(contentsOf: $0) }
            out.append(contentsOf: Array(channel.utf8))
            out.append(0)
            out.append(contentsOf: Array(payload.utf8))
            out.append(0)
            return out
        }
        var body = message(pid: 4_242, "jobs", "42")
        let read = try body.withUnsafeBufferPointer { buffer in
            try PostgresBackend.notification(PostgresReader(buffer.baseAddress!, buffer.count))
        }
        #expect(read == PostgresNotification(channel: "jobs", payload: "42", senderProcessID: 4_242))

        // No payload is an empty one, which is what NOTIFY without one sends.
        var empty = message(pid: 1, "jobs", "")
        let none = try empty.withUnsafeBufferPointer { buffer in
            try PostgresBackend.notification(PostgresReader(buffer.baseAddress!, buffer.count))
        }
        #expect(none.payload == "")

        // Truncated, and with bytes left over: refused rather than guessed at.
        var short: [UInt8] = [0, 0, 1]
        #expect(throws: PostgresProtocolError.truncated) {
            try short.withUnsafeBufferPointer { buffer in
                try PostgresBackend.notification(PostgresReader(buffer.baseAddress!, buffer.count))
            }
        }
        var unterminated = Array(message(pid: 1, "jobs", "x").dropLast())
        #expect(throws: PostgresProtocolError.unterminated) {
            try unterminated.withUnsafeBufferPointer { buffer in
                try PostgresBackend.notification(PostgresReader(buffer.baseAddress!, buffer.count))
            }
        }
        var extra = message(pid: 1, "jobs", "x") + [0]
        #expect(throws: PostgresProtocolError.trailingBytes) {
            try extra.withUnsafeBufferPointer { buffer in
                try PostgresBackend.notification(PostgresReader(buffer.baseAddress!, buffer.count))
            }
        }
        _ = (body.count, empty.count, short.count, unterminated.count, extra.count)
    }

    /// A notification can land between a statement and its ReadyForQuery. The
    /// query collects it and finishes, rather than failing on a message it did
    /// not expect.
    @Test func aQueryKeepsGoingWhenToldSomething() throws {
        var query = PostgresQuery("select 1")
        var notification: [UInt8] = []
        withUnsafeBytes(of: Int32(7).bigEndian) { notification.append(contentsOf: $0) }
        notification.append(contentsOf: Array("jobs".utf8) + [0] + Array("go".utf8) + [0])
        let finishedOnNotification = try notification.withUnsafeBufferPointer { buffer in
            try query.receive(UInt8(ascii: "A"), PostgresReader(buffer.baseAddress!, buffer.count))
        }
        #expect(!finishedOnNotification)
        var ready: [UInt8] = [UInt8(ascii: "I")]
        let finished = try ready.withUnsafeBufferPointer { buffer in
            try query.receive(UInt8(ascii: "Z"), PostgresReader(buffer.baseAddress!, buffer.count))
        }
        #expect(finished)
        #expect(query.notifications == [PostgresNotification(channel: "jobs", payload: "go",
                                                             senderProcessID: 7)])
        _ = ready.count
    }

    /// `LISTEN` takes no parameters, so the channel is an identifier in the
    /// statement: quoted, and any quote in it doubled.
    @Test func channelNamesAreQuotedIdentifiers() throws {
        #expect(quotedIdentifier("jobs") == #""jobs""#)
        #expect(quotedIdentifier("Jobs Waiting") == #""Jobs Waiting""#)
        #expect(quotedIdentifier(#"a"b"#) == #""a""b""#, "the quote is doubled, not escaped")
        #expect(quotedIdentifier("") == #""""#)
        // What an injection would have to survive: the quote that would end
        // the identifier is doubled, so the rest stays part of the name.
        #expect(quotedIdentifier(#"x"; drop table users; --"#) == #""x""; drop table users; --""#)
    }
}

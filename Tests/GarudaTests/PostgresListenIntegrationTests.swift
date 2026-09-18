import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// LISTEN and NOTIFY against a real server: a listener on its own connection,
// notifications from another session and from its own, channels added and
// dropped, and a notification that waits for its transaction to commit.
//
// Opt-in through GARUDA_POSTGRES, like the driver's other integration tests.

private let listenTarget: PostgresConfiguration? = {
    guard let raw = av_getenv("GARUDA_POSTGRES") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

private struct Refuse: Error {}

private final class Heard: @unchecked Sendable {
    var payloads: [String] = []
    var starts = 0
}

@Suite("PostgreSQL notifications round trip", .serialized)
struct PostgresListenIntegrationTests {
    @Test(.enabled(if: listenTarget != nil, "set GARUDA_POSTGRES to run"))
    func notificationsReachAListener() throws {
        let configuration = listenTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            do {
                let pool = db.value
                let channel = "garuda_jobs"
                // A name that has to be quoted to survive being an identifier.
                let odd = #"garuda "odd" channel"#
                let listener = try await pool.listen(channel)
                defer { listener.close() }
                var out: [String] = []

                // From another session, through the pool.
                try await pool.notify(channel, "42")
                if let heard = try await listener.next(timeoutMilliseconds: 2_000) {
                    out.append("\(heard.channel == channel) \(heard.payload) "
                                   + "\(heard.senderProcessID != listener.processID)")
                } else {
                    out.append("none")
                }
                out.append(try await listener.next(timeoutMilliseconds: 50) == nil ? "quiet" : "more")

                // Its own, which the server sends while its own statement is
                // still running: waiting no time at all still finds it.
                try await listener.notify(channel, "self")
                if let mine = try await listener.next(timeoutMilliseconds: 0) {
                    out.append("\(mine.payload) \(mine.senderProcessID == listener.processID)")
                } else {
                    out.append("none")
                }

                // A channel added later, and a name that needs quoting.
                try await listener.listen(odd)
                try await pool.notify(odd, "quoted")
                if let heard = try await listener.next(timeoutMilliseconds: 2_000) {
                    out.append("\(heard.channel == odd) \(heard.payload)")
                } else {
                    out.append("none")
                }
                out.append(listener.channels.count == 2 ? "two" : listener.channels.joined(separator: ","))

                // Dropped: what is sent on it is no longer heard.
                try await listener.unlisten(channel)
                try await pool.notify(channel, "after")
                out.append(try await listener.next(timeoutMilliseconds: 300) == nil ? "deaf" : "heard")

                // The listener's connection is its own: the pool counts one,
                // the one its own statements used.
                out.append("\(pool.counts.open)")

                // A payload just inside what the server takes, and one past it
                // -- which is the server's refusal, not a broken listener.
                try await pool.notify(odd, String(repeating: "x", count: 7_000))
                out.append("\(try await listener.next(timeoutMilliseconds: 2_000)?.payload.count ?? 0)")
                do {
                    try await pool.notify(odd, String(repeating: "x", count: 8_001))
                    out.append("accepted")
                } catch let error as PostgresClientError {
                    out.append(error.sqlState ?? "\(error)")
                }
                out.append("\(listener.isOpen)")
                return out.joined(separator: "|")
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let text = try client.get("/run").text
        #expect(text == "true 42 true|quiet|self true|true quoted|two|deaf|1|7000|22023|true", "\(text)")
    }

    /// A notification sent in a transaction is news of what that transaction
    /// did: it arrives when the transaction commits, and never if it does not.
    @Test(.enabled(if: listenTarget != nil, "set GARUDA_POSTGRES to run"))
    func aTransactionsNotificationWaitsForItsCommit() throws {
        let configuration = listenTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            do {
                let pool = db.value
                let channel = "garuda_orders"
                let listener = try await pool.listen(channel)
                defer { listener.close() }
                var out: [String] = []

                // Rolled back, so it was never sent.
                do {
                    try await pool.transaction { tx in
                        try await tx.notify(channel, "rolled back")
                        throw Refuse()
                    }
                    out.append("committed")
                } catch is Refuse {
                    out.append("rolled back")
                }
                out.append(try await listener.next(timeoutMilliseconds: 300) == nil ? "silent" : "leaked")

                // Committed, so it was -- and not before.
                try await pool.transaction { tx in
                    try await tx.notify(channel, "committed")
                    let early = try await listener.next(timeoutMilliseconds: 200)
                    out.append(early == nil ? "not yet" : "early")
                }
                out.append(try await listener.next(timeoutMilliseconds: 2_000)?.payload ?? "none")
                return out.joined(separator: "|")
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let text = try client.get("/run").text
        #expect(text == "rolled back|silent|not yet|committed", "\(text)")
    }

    /// `app.listen`: the worker listens for as long as it serves, and hands
    /// each notification to the handler.
    @Test(.enabled(if: listenTarget != nil, "set GARUDA_POSTGRES to run"))
    func aWorkerListensForAsLongAsItServes() throws {
        let heard = Heard()
        let configuration = listenTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/tick") { "tick" }
        app.get("/send") { (db: State<PostgresPool>) async throws -> String in
            try await db.value.notify("garuda_app", "sent")
            return "sent"
        }
        app.listen("garuda_app", reconnectAfter: 0.05,
                   whenListening: { _ in heard.starts += 1 }) { notification, start in
            // The worker's own state is there, as it is in a handler.
            _ = try start.state(PostgresPool.self)
            heard.payloads.append(notification.payload)
        }
        let client = app.test
        client.timeoutMillis = 20_000
        waitFor(client) { heard.starts >= 1 }
        #expect(heard.starts == 1, "it starts once the worker serves: \(heard.starts)")
        #expect(try client.get("/send").text == "sent")
        waitFor(client) { !heard.payloads.isEmpty }
        #expect(heard.payloads == ["sent"])
        // Still the one connection: it listened, it did not reconnect.
        #expect(heard.starts == 1, "\(heard.starts)")
    }

    /// A notification the handler cannot deal with is logged, and the next one
    /// is handled as usual.
    @Test(.enabled(if: listenTarget != nil, "set GARUDA_POSTGRES to run"))
    func aHandlerThatThrowsDoesNotEndTheListening() throws {
        let heard = Heard()
        let configuration = listenTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/tick") { "tick" }
        app.get("/send/:payload") { (payload: Path<String>, db: State<PostgresPool>) async throws -> String in
            try await db.value.notify("garuda_app", payload.value)
            return "sent"
        }
        app.listen("garuda_app", reconnectAfter: 0.05,
                   whenListening: { _ in heard.starts += 1 }) { notification, _ in
            heard.payloads.append(notification.payload)
            if notification.payload == "bad" { throw Refuse() }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        waitFor(client) { heard.starts >= 1 }
        _ = try client.get("/send/bad")
        waitFor(client) { heard.payloads.count >= 1 }
        _ = try client.get("/send/good")
        waitFor(client) { heard.payloads.count >= 2 }
        #expect(heard.payloads == ["bad", "good"])
        #expect(heard.starts == 1, "the listener survived the throw: \(heard.starts)")
    }

    /// Turns the loop until `done`. A request is what drives a test client's
    /// loop, so a listener needs one too.
    private func waitFor(_ client: TestClient, turns: Int = 4_000, _ done: () -> Bool) {
        for _ in 0..<turns {
            if done() { return }
            _ = try? client.get("/tick")
        }
    }
}

//===----------------------------------------------------------------------===//
// LISTEN and NOTIFY: PostgreSQL telling a worker that something happened,
// without the worker asking.
//
//     let listener = try await pool.listen("jobs")
//     while let notification = try await listener.next(timeoutMilliseconds: 5_000) {
//         print(notification.channel, notification.payload)
//     }
//
//     try await pool.notify("jobs", "42")
//
// A listener holds a connection of its own, which the pool does not count: a
// session that has listened is told at any moment, so it cannot be handed to
// the next statement, and `LISTEN` on a pooled connection registers interest
// that goes back into the pool with it.
//
// Notifications are not a queue. The server holds none for a session that is
// not connected, so a listener that reconnects has missed whatever was sent
// while it was away, and the recipe for that is to read the work from a table
// once on reconnect and let the notification only say there is work. Nothing
// here pretends otherwise.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaPostgres

/// A session listening for `NOTIFY`, on a connection of its own.
public final class PostgresListener: @unchecked Sendable {
    private let connection: PostgresConnection
    /// Notifications that arrived while a statement of this listener's own
    /// was in flight, oldest first.
    private var pending: [PostgresNotification] = []
    private var pendingHead = 0
    /// The channels listened to, in the order they were added.
    public private(set) var channels: [String] = []

    init(connection: PostgresConnection) {
        self.connection = connection
        connection.collectsNotifications = true
    }

    deinit {
        // Only from the worker that owns the connection: closing a socket
        // from another thread is not the engine's to do.
        if av_worker_current() == UnsafeMutableRawPointer(connection.socket.worker) {
            connection.close()
        }
    }

    /// Whether the connection is still there. It goes false when the server
    /// restarts or the network drops, and every channel has to be listened to
    /// again on a new listener.
    public var isOpen: Bool { connection.isOpen }

    /// The next notification, waiting at most `timeoutMilliseconds`; nil when
    /// none came in time. Throws once the connection has gone.
    ///
    /// Nothing else may run on this listener while a call is waiting.
    public func next(timeoutMilliseconds: UInt64 = 1_000) async throws(PostgresClientError) -> PostgresNotification? {
        // What arrived while this listener's own statements ran comes first,
        // in the order it came.
        collect()
        if pendingHead < pending.count {
            let notification = pending[pendingHead]
            pendingHead += 1
            if pendingHead == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingHead = 0
            }
            return notification
        }
        return try await connection.nextNotification(milliseconds: timeoutMilliseconds)
    }

    /// Listens on more channels, which are listening before this returns.
    public func listen(_ channels: String...) async throws(PostgresClientError) {
        try await listen(channels)
    }

    public func listen(_ channels: [String]) async throws(PostgresClientError) {
        for channel in channels {
            _ = try await connection.query("listen " + quotedIdentifier(channel))
            if !self.channels.contains(channel) { self.channels.append(channel) }
        }
        collect()
    }

    /// Stops listening on channels. A notification already on its way still
    /// arrives, so a channel unlistened is not a channel silenced at once.
    public func unlisten(_ channels: String...) async throws(PostgresClientError) {
        for channel in channels {
            _ = try await connection.query("unlisten " + quotedIdentifier(channel))
            self.channels.removeAll { $0 == channel }
        }
        collect()
    }

    /// Sends a notification on this listener's own connection, which is also
    /// how a listener hears its own: `senderProcessID` says whose it was.
    public func notify(_ channel: String, _ payload: String = "") async throws(PostgresClientError) {
        _ = try await connection.query("select pg_notify($1, $2)",
                                       values: [PostgresValue(channel), PostgresValue(payload)])
        collect()
    }

    /// The process ID the server gave this session, which is what a
    /// notification this listener sent itself carries as its sender.
    public var processID: Int32 { connection.processID }

    /// Ends the listening and closes its connection.
    public func close() {
        connection.close()
    }

    private func collect() {
        pending.append(contentsOf: connection.takeNotifications())
    }
}

// MARK: - The pool

extension PostgresPool {
    /// Listens for `NOTIFY` on a connection of its own, which the pool does
    /// not count: a listener holds its connection for as long as it lasts.
    /// The channels are listening before this returns.
    public func listen(_ channels: String...) async throws -> PostgresListener {
        try await listen(channels)
    }

    public func listen(_ channels: [String]) async throws -> PostgresListener {
        precondition(!channels.isEmpty, "listen to at least one channel")
        guard let worker = currentWorker else { throw PostgresClientError.cancelled }
        let connection = try await PostgresConnection.connect(worker, configuration)
        let listener = PostgresListener(connection: connection)
        do {
            try await listener.listen(channels)
        } catch {
            connection.close()
            throw error
        }
        return listener
    }

    /// Sends a notification, through `pg_notify` so that the channel and the
    /// payload are values rather than part of the statement.
    ///
    /// Only a session listening at the time is told. A payload of 8,000 bytes
    /// or more is refused by the server, so what a notification carries is a
    /// key, not a document.
    public func notify(_ channel: String, _ payload: String = "") async throws {
        try await execute("select pg_notify($1, $2)", channel, payload)
    }
}

extension PostgresTransaction {
    /// Sends a notification when this transaction commits, and not at all if
    /// it rolls back -- so the work and the news of it are one decision.
    public func notify(_ channel: String, _ payload: String = "") async throws {
        try await execute("select pg_notify($1, $2)", channel, payload)
    }
}

// MARK: - A worker listening

extension Application {
    /// Listens for `NOTIFY` in each worker, for as long as that worker serves,
    /// and hands every notification to `handle`.
    ///
    /// ```swift
    /// app.listen("jobs") { notification, start in
    ///     try await start.state(Jobs.self).run(notification.payload)
    /// }
    /// ```
    ///
    /// The listener runs on the worker's own thread, with the worker's state,
    /// on a connection of its own. **Every worker hears every notification**,
    /// which is what pub/sub is for -- a cache to drop, a setting that
    /// changed. Work that must be done once, however many workers are
    /// running, wants `onWorker: 0` and a claim in the database besides: see
    /// the caveat on `app.every`.
    ///
    /// A connection that goes -- the server restarted, the network dropped --
    /// is logged and made again after `reconnectAfter` seconds, with the same
    /// channels. Whatever was sent while there was no listener is gone: the
    /// server keeps nothing for a session that is not connected. That is what
    /// `whenListening` is for: it runs once the channels are listening, on the
    /// first connection and on every reconnection, and is where a handler
    /// sweeps the table for work it may have missed. A notification then says
    /// only that there is something to look at.
    ///
    /// - Parameters:
    ///   - channels: the channels to listen on. At least one.
    ///   - onWorker: the only worker index that listens, or nil for all.
    ///   - reconnectAfter: seconds before a lost connection is made again.
    ///   - pool: which pool to take the connection from, the state's
    ///     `PostgresPool` by default.
    ///   - whenListening: work to do each time the channels start listening.
    ///     A throw is logged, and the listener is made again.
    ///   - handle: what to do with a notification. A throw is logged, and the
    ///     next notification is handled as usual: one that cannot be dealt
    ///     with does not end the listening.
    public func listen(_ channels: String..., onWorker: Int? = nil, reconnectAfter: Double = 1,
                       pool: @escaping @Sendable (_ start: WorkerStartup) throws -> PostgresPool = {
                           try $0.state(PostgresPool.self)
                       },
                       whenListening: (@Sendable (_ start: WorkerStartup) async throws -> Void)? = nil,
                       _ handle: @escaping @Sendable (_ notification: PostgresNotification,
                                                      _ start: WorkerStartup) async throws -> Void) {
        precondition(!channels.isEmpty, "listen to at least one channel")
        precondition(reconnectAfter > 0, "a lost connection is made again after a positive wait")
        let names = channels
        // A scheduled job whose run is the listening itself: it returns when
        // the connection goes, and the interval is what it waits before
        // trying again. Jitter keeps every worker from reconnecting at once
        // when the server comes back.
        every(reconnectAfter, jitter: 0.25, firstAfter: 0, onWorker: onWorker) { start in
            let listener: PostgresListener
            do {
                listener = try await pool(start).listen(names)
            } catch PostgresClientError.cancelled {
                return
            } catch {
                log(names, "could not listen", error)
                return
            }
            defer { listener.close() }
            if let whenListening {
                do {
                    try await whenListening(start)
                } catch {
                    log(names, "could not do the work its listening starts with", error)
                    return
                }
            }
            while listener.isOpen, !Task.isCancelled {
                let notification: PostgresNotification?
                do {
                    // In slices, so that a worker draining is noticed
                    // without waiting for something to be sent.
                    notification = try await listener.next(timeoutMilliseconds: 250)
                } catch PostgresClientError.cancelled {
                    // The worker is draining, which is not a failure.
                    return
                } catch {
                    log(names, "lost its connection", error)
                    return
                }
                guard let notification else { continue }
                do {
                    try await handle(notification, start)
                } catch {
                    AppLog.error("a notification was not handled",
                                 ["channel": .string(notification.channel),
                                  "error": .string(String(describing: error))])
                }
            }
        }
    }
}

/// One line for a listener that cannot go on, naming its channels.
private func log(_ channels: [String], _ what: String, _ error: any Error) {
    AppLog.error("a listener " + what,
                 ["channels": .string(channels.joined(separator: ",")),
                  "error": .string(String(describing: error))])
}

/// A name as an identifier in a statement, quoted, with any quote inside it
/// doubled: `LISTEN` takes no parameters, so the channel cannot be a value.
///
/// PostgreSQL cuts an identifier at 63 bytes, here and in `NOTIFY` alike, so
/// two names that agree that far are one channel.
func quotedIdentifier(_ identifier: String) -> String {
    var out = "\""
    for character in identifier {
        if character == "\"" { out.append(character) }
        out.append(character)
    }
    out.append("\"")
    return out
}

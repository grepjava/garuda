//===----------------------------------------------------------------------===//
// `app.listen`: PostgreSQL's NOTIFY, heard in every shard.
//===----------------------------------------------------------------------===//

import Garuda
import VegaPostgres

extension Application {
    /// Listens for `NOTIFY` in each shard, for as long as that shard serves,
    /// and hands every notification to `handle`.
    ///
    /// ```swift
    /// app.listen("jobs") { notification, shard in
    ///     try await shard.state(Jobs.self).run(notification.payload)
    /// }
    /// ```
    ///
    /// The listener is a task on the shard's runtime, on a connection of its
    /// own. **Every shard hears every notification**, which is what pub/sub
    /// is for -- a cache to drop, a setting that changed. Work that must be
    /// done once, however many shards are running, wants `onShard: 0` and a
    /// claim in the database besides: see the caveat on `app.every`.
    ///
    /// A connection that goes -- the server restarted, the network dropped --
    /// is logged and made again after `reconnectAfter`, with the same
    /// channels. Whatever was sent while there was no listener is gone: the
    /// server keeps nothing for a session that is not connected. That is what
    /// `whenListening` is for: it runs once the channels are listening, on the
    /// first connection and on every reconnection, and is where a handler
    /// sweeps the table for work it may have missed. A notification then says
    /// only that there is something to look at.
    ///
    /// - Parameters:
    ///   - channels: the channels to listen on. At least one.
    ///   - onShard: the only shard index that listens, or nil for all.
    ///   - reconnectAfter: the wait before a lost connection is made again.
    ///   - pool: which pool to take the connection from, the state's
    ///     `PostgresPool` by default.
    ///   - whenListening: work to do each time the channels start listening.
    ///     A throw is logged, and the listener is made again.
    ///   - handle: what to do with a notification. A throw is logged, and the
    ///     next notification is handled as usual: one that cannot be dealt
    ///     with does not end the listening.
    public func listen(_ channels: String..., onShard: Int? = nil, reconnectAfter: Duration = .seconds(1),
                       pool: @escaping @Sendable (_ shard: ShardContext) throws -> PostgresPool = {
                           try $0.state(PostgresPool.self)
                       },
                       whenListening: (@Sendable (_ shard: ShardContext) async throws -> Void)? = nil,
                       _ handle: @escaping @Sendable (_ notification: PostgresNotification,
                                                      _ shard: ShardContext) async throws -> Void) {
        precondition(!channels.isEmpty, "listen to at least one channel")
        precondition(reconnectAfter > .zero, "a lost connection is made again after a positive wait")
        let names = channels
        // A scheduled job whose run is the listening itself: it returns when
        // the connection goes, and the interval is what it waits before
        // trying again. Jitter keeps every shard from reconnecting at once
        // when the server comes back.
        every(reconnectAfter, jitter: 0.25, firstAfter: .zero, onShard: onShard) { shard in
            let listener: PostgresListener
            do {
                listener = try await pool(shard).listen(names)
            } catch {
                if Task.isCancelled { return }
                logListener(names, "could not listen", error)
                return
            }
            defer { listener.close() }
            if let whenListening {
                do {
                    try await whenListening(shard)
                } catch {
                    logListener(names, "could not do the work its listening starts with", error)
                    return
                }
            }
            while listener.isOpen, !Task.isCancelled {
                let notification: PostgresNotification?
                do {
                    notification = try await listener.next(timeout: .seconds(1))
                } catch {
                    // The shard stopping is not a failure.
                    if Task.isCancelled { return }
                    logListener(names, "lost its connection", error)
                    return
                }
                guard let notification else { continue }
                do {
                    try await handle(notification, shard)
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
private func logListener(_ channels: [String], _ what: String, _ error: any Error) {
    AppLog.error("a listener " + what,
                 ["channels": .string(channels.joined(separator: ",")),
                  "error": .string(String(describing: error))])
}

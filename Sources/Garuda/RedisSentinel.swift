//===----------------------------------------------------------------------===//
// Sentinel: a master, its replicas, and a quorum of sentinels that promote a
// replica when the master goes.
//
//     let sentinels = [RedisConfiguration(host: "s1", port: 26379),
//                      RedisConfiguration(host: "s2", port: 26379)]
//     var server = RedisConfiguration(host: "", password: secret)   // the master's own auth
//     app.state { _ in
//         RedisSentinelPool(RedisSentinelConfiguration(sentinels: sentinels,
//                                                      master: "cache", server: server))
//     }
//
// Where the master is is not configuration: it is asked of the sentinels, and
// it changes. So this is a pool whose address is discovered, kept while it
// works, and asked for again the moment it stops -- when the connection goes,
// or when the server answers READONLY, which is what a master that has been
// demoted says to a write.
//
// A sentinel can be behind the times and name a node that is no longer the
// master, so what it names is asked `ROLE` before anything is sent to it.
// Nothing is taken on trust that one round trip can settle.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaRedis

/// Which sentinels watch which master, and how to talk to the master itself.
public struct RedisSentinelConfiguration: Sendable {
    /// Where the sentinels are. A sentinel has its own password, if any, and
    /// is not the master: what it says here is only where to go.
    public var sentinels: [RedisConfiguration]
    /// The name the sentinels know this master by.
    public var master: String
    /// How to talk to the master once it is found: its password, its TLS, its
    /// timeouts. The host and port in it are ignored -- the sentinels say
    /// those.
    public var server: RedisConfiguration

    public init(sentinels: [RedisConfiguration], master: String, server: RedisConfiguration) {
        precondition(!sentinels.isEmpty, "a sentinel pool needs at least one sentinel to ask")
        precondition(!master.isEmpty, "a sentinel pool needs the name the master is monitored under")
        self.sentinels = sentinels
        self.master = master
        self.server = server
    }
}

/// A pool to whichever server the sentinels call the master.
public final class RedisSentinelPool: RedisCommandSender, @unchecked Sendable {
    public let configuration: RedisSentinelConfiguration
    public let maxConnections: Int
    public let acquireTimeoutMilliseconds: UInt64
    /// How many times a command is tried against a freshly found master
    /// before it gives up: a failover takes a moment, and during it there is
    /// no master to be had.
    public let maxAttempts: Int

    private var pool: RedisPool? = nil
    private var found: String? = nil
    /// The sentinel that answered last, asked first next time.
    private var preferred = 0

    /// What may be sent to the new master when the old one failed with the
    /// command already written. Reads, by default: a failover is exactly when
    /// a write's fate is least knowable.
    public let replay: RedisReplay

    public init(_ configuration: RedisSentinelConfiguration, maxConnections: Int = 8,
                acquireTimeoutMilliseconds: UInt64? = nil, maxAttempts: Int = 4,
                replay: RedisReplay = .reads) {
        precondition(maxAttempts > 0, "a command is tried at least once")
        self.configuration = configuration
        self.maxConnections = maxConnections
        self.acquireTimeoutMilliseconds = acquireTimeoutMilliseconds
            ?? configuration.server.timeoutMilliseconds
        self.maxAttempts = maxAttempts
        self.replay = replay
    }

    /// Where the master was last found, as `host:port`, or nil before anyone
    /// has asked.
    public var masterAddress: String? { found }

    // MARK: Commands

    public func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue {
        try await send(command, timeoutMilliseconds: nil)
    }

    /// Sends one command, waiting up to `timeoutMilliseconds` for its reply.
    public func send(_ command: RedisCommand,
                     timeoutMilliseconds: UInt64?) async throws(RedisClientError) -> RedisValue {
        try await attempting([command]) { pool throws(RedisClientError) in
            try await pool.send(command, timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    /// Sends every command in one write to the master, and reads every reply.
    ///
    /// A failover can land in the middle of a batch: the commands before it
    /// are answered and the writes after it are refused with READONLY. Only
    /// the refused ones go to the new master. A refusal is proof that the
    /// command did not run, and an answer is proof that it did -- sending the
    /// whole batch again would repeat everything that already happened.
    public func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        guard !commands.isEmpty else { return [] }
        var replies = [RedisValue](repeating: .null, count: commands.count)
        var outstanding = Array(commands.indices)
        var attempt = 0
        while true {
            attempt += 1
            let batch = outstanding.map { commands[$0] }
            do throws(RedisClientError) {
                let pool = try await master()
                let answers = try await pool.pipeline(batch)
                guard answers.count == batch.count else { throw RedisClientError.unexpectedReply(.array(answers)) }
                var again: [Int] = []
                for (n, index) in outstanding.enumerated() {
                    replies[index] = answers[n]
                    if isFailover(answers[n]) { again.append(index) }
                }
                guard !again.isEmpty, attempt < maxAttempts else { return replies }
                outstanding = again
            } catch {
                guard attempt < maxAttempts, isFailover(error),
                      replay.allows(error, batch) else { throw error }
            }
            // Either the master has gone or it is not the master any more.
            // Both are answered by asking the sentinels.
            forget()
            await pause(milliseconds: 100 * UInt64(attempt))
        }
    }

    /// Runs the commands as one transaction on the master.
    public func transaction(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        try await attempting([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")]) { pool throws(RedisClientError) in
            try await pool.transaction(commands)
        }
    }

    /// Runs `body` with one connection to the master: for WATCH, then reading,
    /// then a transaction that only runs if nothing watched changed.
    ///
    /// A failover in the middle of a session is the session's to deal with,
    /// not this pool's: what it has read may be from a server that is no
    /// longer the master, so it is reported rather than tried again.
    public func session<Result>(_ body: (RedisSession) async throws -> Result) async throws -> Result {
        try await master().session(body)
    }

    /// Subscribes on a connection of its own to the master.
    public func subscribe(channels: [String] = [],
                          patterns: [String] = []) async throws(RedisClientError) -> RedisSubscription {
        try await master().subscribe(channels: channels, patterns: patterns)
    }

    /// Asks the sentinels again, whatever the last answer was.
    @discardableResult
    public func refresh() async throws(RedisClientError) -> String {
        forget()
        _ = try await master()
        return found ?? ""
    }

    /// Closes the master's idle connections. For `app.state`'s shutdown.
    public func close() {
        forget()
    }

    // MARK: Finding the master

    private func attempting<R>(_ commands: [RedisCommand],
                               _ body: (RedisPool) async throws(RedisClientError) -> R) async throws(RedisClientError) -> R {
        var attempt = 0
        while true {
            attempt += 1
            let pool = try await master()
            do {
                return try await body(pool)
            } catch {
                guard attempt < maxAttempts, isFailover(error),
                      replay.allows(error, commands) else { throw error }
                // Either the master has gone or it is not the master any
                // more. Both are answered by asking the sentinels.
                forget()
                await pause(milliseconds: 100 * UInt64(attempt))
            }
        }
    }

    private func master() async throws(RedisClientError) -> RedisPool {
        if let pool { return pool }
        var last: RedisClientError? = nil
        for i in 0..<configuration.sentinels.count {
            let index = (preferred + i) % configuration.sentinels.count
            do {
                let address = try await ask(configuration.sentinels[index])
                let candidate = RedisPool(settings(for: address), maxConnections: maxConnections,
                                          acquireTimeoutMilliseconds: acquireTimeoutMilliseconds)
                do {
                    // A sentinel can be behind and name a node that has been
                    // demoted. The node itself is the authority on that.
                    let role = try await candidate.send(RedisCommand("ROLE"))
                    guard RedisSentinelPool.isMaster(role) else {
                        candidate.close()
                        last = .server(RedisServerError("ERR \(address) is not the master any more"))
                        continue
                    }
                } catch {
                    candidate.close()
                    last = error
                    continue
                }
                preferred = index
                pool = candidate
                found = address
                return candidate
            } catch {
                last = error
                continue
            }
        }
        throw last ?? .closed
    }

    /// `SENTINEL get-master-addr-by-name <name>`: a host and a port, or a null
    /// array for a master this sentinel does not watch.
    private func ask(_ sentinel: RedisConfiguration) async throws(RedisClientError) -> String {
        let asking = RedisPool(sentinel, maxConnections: 1)
        defer { asking.close() }
        let reply = try await asking.send(RedisCommand("SENTINEL", "get-master-addr-by-name",
                                                       configuration.master))
        guard let address = RedisSentinelPool.parseAddress(reply) else { throw .unexpectedReply(reply) }
        return address
    }

    /// The two-element reply as `host:port`, or nil when it is not one.
    static func parseAddress(_ reply: RedisValue) -> String? {
        guard let parts = reply.array, parts.count == 2,
              let host = parts[0].string, !host.isEmpty,
              let port = parts[1].string, let number = UInt16(port), number > 0 else { return nil }
        return "\(host):\(number)"
    }

    /// `ROLE`: the first element is `master` on one, `slave` on a replica.
    static func isMaster(_ reply: RedisValue) -> Bool {
        guard let parts = reply.array, let role = parts.first?.string else { return false }
        return role == "master"
    }

    private func settings(for address: String) -> RedisConfiguration {
        var settled = configuration.server
        settled.unixSocketPath = nil
        guard let colon = address.lastIndex(of: ":") else {
            settled.host = address
            return settled
        }
        settled.host = String(address[address.startIndex..<colon])
        settled.port = UInt16(address[address.index(after: colon)...]) ?? settled.port
        return settled
    }

    private func forget() {
        pool?.close()
        pool = nil
        found = nil
    }

    /// Whether a failure means the master has moved rather than the command
    /// being wrong.
    private func isFailover(_ error: RedisClientError) -> Bool {
        switch error.cause {
        case .connect, .closed, .timedOut, .poolTimedOut:
            return true
        case .server(let error):
            // READONLY: this was the master and is now a replica. MASTERDOWN
            // and LOADING: it is not ready to be one.
            return error.code == "READONLY" || error.code == "MASTERDOWN" || error.code == "LOADING"
        default:
            return false
        }
    }

    /// The same, for a reply among a pipeline's rather than a throw.
    private func isFailover(_ reply: RedisValue) -> Bool {
        guard case .error(let error) = reply else { return false }
        return error.code == "READONLY" || error.code == "MASTERDOWN" || error.code == "LOADING"
    }

    private func pause(milliseconds: UInt64) async {
        guard let worker = currentWorker else { return }
        _ = await Worker.waitTimed(worker, milliseconds: milliseconds, register: { _ in })
    }
}

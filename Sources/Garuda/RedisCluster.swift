//===----------------------------------------------------------------------===//
// Redis Cluster: many servers, one key space, split into 16,384 slots.
//
//     app.state { _ in RedisCluster(seeds: [RedisConfiguration(host: "redis-1")]) }
//
//     app.get("/visits/:page") { (page: Path<String>, redis: State<RedisCluster>) async throws in
//         String(try await redis.value.incr("visits:\(page.value)"))
//     }
//
// A cluster is a `RedisCommandSender`, so every typed command a pool has it
// has too, aimed at the node that owns the key. It keeps a pool per node,
// each built the way `RedisPool` builds one, and a map of which node owns
// which slots, learned from the cluster itself.
//
// The map is how a command is aimed; it is never how correctness is decided.
// A command that reaches the wrong node is answered `MOVED`, and that answer
// is followed: the map is corrected and the command sent again. So a map that
// is out of date -- a node added, a slot migrated, a replica promoted --
// costs a round trip, not a wrong answer. The same goes for `ASK`, which is
// what a slot half-migrated says: that one key is somewhere else for now,
// without the map changing at all.
//
// What a cluster cannot do is touch keys in different slots at once. Redis
// refuses that with CROSSSLOT, and the answer is a hash tag: `user:{42}:name`
// and `user:{42}:email` share a slot because what is between the braces is
// what is hashed.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaRedis

/// Several Redis servers sharing one key space.
public final class RedisCluster: RedisCommandSender, @unchecked Sendable {
    /// The nodes to ask for the map, when none is known yet. One is enough;
    /// more is one less thing to go wrong when a node is down.
    public let seeds: [RedisConfiguration]
    public let maxConnectionsPerNode: Int
    public let acquireTimeoutMilliseconds: UInt64
    /// How many times a command is aimed again before it gives up: a
    /// redirect, a node that has gone, a slot being moved.
    public let maxAttempts: Int

    /// A pool per node, by `host:port`.
    private var pools: [String: RedisPool] = [:]
    /// Which node owns which slots, as ranges sorted by where they start.
    private var ranges: [SlotRange] = []
    /// Set when a redirect showed the map to be out of date, so the next
    /// command loads it again rather than following redirect after redirect.
    private var mapIsStale = true

    struct SlotRange {
        let from: Int
        let to: Int
        let address: String
    }

    public init(seeds: [RedisConfiguration], maxConnectionsPerNode: Int = 8,
                acquireTimeoutMilliseconds: UInt64? = nil, maxAttempts: Int = 5) {
        precondition(!seeds.isEmpty, "a cluster needs at least one node to ask")
        precondition(maxAttempts > 0, "a command is sent at least once")
        self.seeds = seeds
        self.maxConnectionsPerNode = maxConnectionsPerNode
        self.acquireTimeoutMilliseconds = acquireTimeoutMilliseconds
            ?? seeds[0].acquireTimeoutDefault
        self.maxAttempts = maxAttempts
    }

    /// One node to start from.
    public convenience init(_ seed: RedisConfiguration, maxConnectionsPerNode: Int = 8,
                            acquireTimeoutMilliseconds: UInt64? = nil, maxAttempts: Int = 5) {
        self.init(seeds: [seed], maxConnectionsPerNode: maxConnectionsPerNode,
                  acquireTimeoutMilliseconds: acquireTimeoutMilliseconds, maxAttempts: maxAttempts)
    }

    // MARK: Commands

    public func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue {
        try await send(command, timeoutMilliseconds: nil)
    }

    /// Sends one command, waiting up to `timeoutMilliseconds` for its reply.
    public func send(_ command: RedisCommand,
                     timeoutMilliseconds: UInt64?) async throws(RedisClientError) -> RedisValue {
        let replies = try await route([command], slot: RedisKeys.slot(of: command),
                                      timeoutMilliseconds: timeoutMilliseconds)
        if case .error(let error) = replies[0] { throw .server(error) }
        return replies[0]
    }

    /// Sends the commands and returns a reply for each, in order.
    ///
    /// One write per slot: commands that belong together go together, and a
    /// batch that spans slots becomes one batch per slot rather than a node
    /// redirecting half of it. Commands are answered in the order they were
    /// given whichever node answered them.
    public func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        guard !commands.isEmpty else { return [] }
        var groups: [Int: [Int]] = [:]
        // -1 for the commands that belong to no slot, which any node answers.
        for (i, command) in commands.enumerated() {
            groups[RedisKeys.slot(of: command) ?? -1, default: []].append(i)
        }
        if groups.count == 1, let slot = groups.keys.first {
            return try await route(commands, slot: slot < 0 ? nil : slot, timeoutMilliseconds: nil)
        }
        var replies = [RedisValue](repeating: .null, count: commands.count)
        for (slot, indices) in groups {
            let answers = try await route(indices.map { commands[$0] },
                                          slot: slot < 0 ? nil : slot, timeoutMilliseconds: nil)
            guard answers.count == indices.count else { throw .unexpectedReply(.array(answers)) }
            for (i, index) in indices.enumerated() { replies[index] = answers[i] }
        }
        return replies
    }

    /// Runs the commands as one transaction on the node that owns their slot.
    /// They must all belong to the same slot: a transaction is one node's.
    public func transaction(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        let slot = slot(of: commands)
        let replies = try await route([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")],
                                      slot: slot, timeoutMilliseconds: nil)
        guard let results = try transactionReplies(replies, commands: commands.count) else {
            throw .unexpectedReply(.null)
        }
        return results
    }

    /// Runs `body` with one connection to the node that owns `key`'s slot:
    /// for WATCH, then reading, then a transaction that only runs if nothing
    /// watched changed. Everything it touches must be in that slot.
    public func session<Result>(for key: String,
                                _ body: (RedisSession) async throws -> Result) async throws -> Result {
        let pool = try await poolForSlot(RedisSlots.slot(of: key))
        return try await pool.session(body)
    }

    /// Subscribes on a connection of its own, to any node: an ordinary
    /// channel reaches every subscriber in the cluster, whichever node it is
    /// attached to.
    public func subscribe(channels: [String] = [],
                          patterns: [String] = []) async throws(RedisClientError) -> RedisSubscription {
        let pool = try await anyPool()
        return try await pool.subscribe(channels: channels, patterns: patterns)
    }

    /// Subscribes to sharded channels, on the node that owns their slot.
    ///
    /// A sharded channel is routed like a key -- it belongs to a slot -- so a
    /// message crosses no more of the cluster than it must, and every channel
    /// here has to be in one slot. `SPUBLISH` sends to one.
    public func subscribeSharded(channels: [String]) async throws(RedisClientError) -> RedisSubscription {
        precondition(!channels.isEmpty, "subscribe to at least one channel")
        let slots = Set(channels.map { RedisSlots.slot(of: $0) })
        guard slots.count == 1, let slot = slots.first else {
            throw .server(RedisServerError(
                "CROSSSLOT Sharded channels in request don't hash to the same slot"))
        }
        let pool = try await poolForSlot(slot)
        return try await pool.subscribeSharded(channels: channels)
    }

    /// Closes every node's idle connections. For `app.state`'s shutdown.
    public func close() {
        for pool in pools.values { pool.close() }
        pools.removeAll()
        ranges.removeAll()
        mapIsStale = true
    }

    // MARK: What is known about the cluster

    /// The nodes the map names, as `host:port`, in slot order.
    public var addresses: [String] {
        var seen: [String] = []
        for range in ranges where !seen.contains(range.address) { seen.append(range.address) }
        return seen
    }

    /// Which slots each node owns, for a health page or a test.
    public var slotRanges: [(from: Int, to: Int, address: String)] {
        ranges.map { ($0.from, $0.to, $0.address) }
    }

    /// Loads the map from the cluster, whatever the last one said. Called on
    /// its own only by something that wants the map now -- a readiness check,
    /// a test; a command does it for itself when it is told to.
    public func refresh() async throws(RedisClientError) {
        try await loadMap()
    }

    // MARK: Routing

    /// Sends `commands` to the node that owns `slot`, following what the
    /// cluster says about where they should have gone.
    private func route(_ commands: [RedisCommand], slot: Int?,
                       timeoutMilliseconds: UInt64?) async throws(RedisClientError) -> [RedisValue] {
        var attempt = 0
        // Where a redirect said to go instead, and whether it was an ASK --
        // which is for this command only and does not change the map.
        var redirect: String? = nil
        var asking = false
        while true {
            attempt += 1
            let pool: RedisPool
            if let redirect {
                pool = poolFor(address: redirect)
            } else if let slot {
                pool = try await poolForSlot(slot)
            } else {
                pool = try await anyPool()
            }
            do {
                let sent = asking ? [RedisCommand("ASKING")] + commands : commands
                var replies = try await pool.pipeline(sent, timeoutMilliseconds: timeoutMilliseconds)
                if asking { replies.removeFirst() }
                // A redirect comes back as the first error among the replies:
                // one node cannot answer some of a batch and redirect the rest.
                if let move = replies.compactMap({ Redirect($0) }).first, attempt < maxAttempts {
                    switch move.kind {
                    case .moved:
                        // The map was wrong. Correct this slot now so this
                        // command goes straight there, and load the whole map
                        // before the next one is aimed.
                        remember(slot: move.slot, at: move.address)
                        mapIsStale = true
                        redirect = move.address
                        asking = false
                    case .ask:
                        // This key has already moved, the rest of the slot has
                        // not. ASKING says "I know" to the node taking it on.
                        redirect = move.address
                        asking = true
                    }
                    continue
                }
                // A slot being moved with more than one key in the command, or
                // a cluster that has not settled: both say to come back.
                if let again = replies.compactMap({ retryable($0) }).first, attempt < maxAttempts {
                    if again == .clusterDown { mapIsStale = true }
                    await pause(milliseconds: 20 * UInt64(attempt))
                    redirect = nil
                    asking = false
                    continue
                }
                return replies
            } catch {
                // The node is gone, or will not answer. Whoever owns the slot
                // now is in a fresh map.
                guard attempt < maxAttempts, isWorthAnotherNode(error) else { throw error }
                forget(address: pool.address)
                mapIsStale = true
                redirect = nil
                asking = false
                await pause(milliseconds: 20 * UInt64(attempt))
            }
        }
    }

    /// The one slot a batch belongs to. A batch spanning slots is aimed at the
    /// first key's node, where Redis answers CROSSSLOT -- which is the right
    /// answer, and says what to do about it.
    private func slot(of commands: [RedisCommand]) -> Int? {
        for command in commands {
            if let slot = RedisKeys.slot(of: command) { return slot }
        }
        return nil
    }

    private func poolForSlot(_ slot: Int) async throws(RedisClientError) -> RedisPool {
        if mapIsStale || ranges.isEmpty { try await loadMap() }
        guard let address = owner(of: slot) else { return try await anyPool() }
        return poolFor(address: address)
    }

    /// Binary search of the ranges, which are sorted and do not overlap.
    private func owner(of slot: Int) -> String? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if slot < range.from {
                high = middle - 1
            } else if slot > range.to {
                low = middle + 1
            } else {
                return range.address
            }
        }
        return nil
    }

    private func poolFor(address: String) -> RedisPool {
        if let pool = pools[address] { return pool }
        let pool = RedisPool(configuration(for: address), maxConnections: maxConnectionsPerNode,
                             acquireTimeoutMilliseconds: acquireTimeoutMilliseconds)
        pools[address] = pool
        return pool
    }

    /// Any node that is known: a seed when nothing is, for a command that
    /// belongs to no slot.
    private func anyPool() async throws(RedisClientError) -> RedisPool {
        if let address = addresses.first { return poolFor(address: address) }
        return poolFor(address: address(of: seeds[0]))
    }

    /// The seeds' configuration, pointed at one node. Credentials, TLS and
    /// timeouts are the cluster's; only where to connect differs.
    private func configuration(for address: String) -> RedisConfiguration {
        var settled = seeds[0]
        let (host, port) = split(address)
        settled.host = host
        settled.port = port
        settled.unixSocketPath = nil
        return settled
    }

    /// Points one slot at a node, which is what a `MOVED` teaches. Internal
    /// rather than private so that a test can make the map wrong on purpose
    /// and watch the cluster put it right.
    func remember(slot: Int, at address: String) {
        // One slot, exactly: the rest of the map is loaded before the next
        // command, and guessing more from one redirect would be guessing.
        var kept: [SlotRange] = []
        for range in ranges {
            if slot < range.from || slot > range.to {
                kept.append(range)
                continue
            }
            if range.from < slot { kept.append(SlotRange(from: range.from, to: slot - 1, address: range.address)) }
            if range.to > slot { kept.append(SlotRange(from: slot + 1, to: range.to, address: range.address)) }
        }
        kept.append(SlotRange(from: slot, to: slot, address: address))
        ranges = kept.sorted { $0.from < $1.from }
    }

    private func forget(address: String) {
        pools[address]?.close()
        pools.removeValue(forKey: address)
    }

    /// Asks a node for the map. Every node knows the whole of it, so the
    /// first that answers settles it.
    private func loadMap() async throws(RedisClientError) {
        var asked: [String] = []
        var last: RedisClientError? = nil
        for address in addresses + seeds.map(address(of:)) where !asked.contains(address) {
            asked.append(address)
            do {
                let reply = try await poolFor(address: address).send(RedisCommand("CLUSTER", "SLOTS"))
                guard let found = RedisCluster.parseSlots(reply), !found.isEmpty else {
                    last = .unexpectedReply(reply)
                    continue
                }
                ranges = found.sorted { $0.from < $1.from }
                mapIsStale = false
                // Nodes the map no longer names keep nothing open.
                for (open, pool) in pools where !addresses.contains(open) && !asked.contains(open) {
                    pool.close()
                    pools.removeValue(forKey: open)
                }
                return
            } catch {
                last = error
                continue
            }
        }
        throw last ?? .closed
    }

    /// `CLUSTER SLOTS`: a range per shard, as `from`, `to`, then the master
    /// and its replicas, each `host`, `port` and an ID. Only the master is
    /// kept: a replica answers a read nobody sent it with MOVED.
    static func parseSlots(_ reply: RedisValue) -> [SlotRange]? {
        guard let shards = reply.array else { return nil }
        var found: [SlotRange] = []
        for shard in shards {
            guard let parts = shard.array, parts.count >= 3,
                  case .integer(let from) = parts[0], case .integer(let to) = parts[1],
                  let master = parts[2].array, master.count >= 2,
                  case .integer(let port) = master[1],
                  let host = master[0].string,
                  from >= 0, to >= from, to < Int64(RedisSlots.count),
                  port > 0, port <= Int64(UInt16.max) else { return nil }
            // A node that has not been told its own address -- which is what
            // an empty host means -- is the one that answered.
            found.append(SlotRange(from: Int(from), to: Int(to),
                                   address: "\(host.isEmpty ? "?" : host):\(port)"))
        }
        return found
    }

    // MARK: Replies that mean "somewhere else" or "again"

    struct Redirect {
        enum Kind: Equatable { case moved, ask }
        let kind: Kind
        let slot: Int
        let address: String

        /// `MOVED 3999 127.0.0.1:6381`, or `ASK` with the same shape.
        init?(_ reply: RedisValue) {
            guard case .error(let error) = reply else { return nil }
            let words = error.message.split(separator: " ")
            guard words.count >= 3, let slot = Int(words[1]), slot >= 0, slot < RedisSlots.count else {
                return nil
            }
            switch words[0] {
            case "MOVED": kind = .moved
            case "ASK": kind = .ask
            default: return nil
            }
            // The address may be an IPv6 literal, and the port is after the
            // last colon whatever the host looks like.
            let target = String(words[2])
            guard target.lastIndex(of: ":") != nil else { return nil }
            self.slot = slot
            self.address = target
        }
    }

    private enum Again: Equatable { case tryAgain, clusterDown }

    private func retryable(_ reply: RedisValue) -> Again? {
        guard case .error(let error) = reply else { return nil }
        switch error.code {
        case "TRYAGAIN": return .tryAgain
        case "CLUSTERDOWN": return .clusterDown
        default: return nil
        }
    }

    /// Whether a failure is worth another node rather than the caller's
    /// attention: the connection, not the command.
    private func isWorthAnotherNode(_ error: RedisClientError) -> Bool {
        switch error {
        case .connect, .closed, .timedOut, .poolTimedOut: return true
        default: return false
        }
    }

    /// Waits on the worker's own timer, so a retry does not spin.
    private func pause(milliseconds: UInt64) async {
        guard let worker = currentWorker else { return }
        _ = await Worker.waitTimed(worker, milliseconds: milliseconds, register: { _ in })
    }

    private func address(of configuration: RedisConfiguration) -> String {
        "\(configuration.host):\(configuration.port)"
    }

    private func split(_ address: String) -> (String, UInt16) {
        guard let colon = address.lastIndex(of: ":") else { return (address, 6_379) }
        let host = String(address[address.startIndex..<colon])
        let port = UInt16(address[address.index(after: colon)...]) ?? 6_379
        return (host, port)
    }
}

extension RedisConfiguration {
    /// What a pool would use when no acquire timeout is given.
    var acquireTimeoutDefault: UInt64 { timeoutMilliseconds }
}

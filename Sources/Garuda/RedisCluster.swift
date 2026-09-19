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
    /// What may be sent again when a node fails with the command already
    /// written and no reply back. Reads, by default: aiming an `INCR` at
    /// another node when the first may already have counted is how a retry
    /// turns into a second write.
    public let replay: RedisReplay

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
                acquireTimeoutMilliseconds: UInt64? = nil, maxAttempts: Int = 5,
                replay: RedisReplay = .reads) {
        precondition(!seeds.isEmpty, "a cluster needs at least one node to ask")
        precondition(maxAttempts > 0, "a command is sent at least once")
        self.seeds = seeds
        self.maxConnectionsPerNode = maxConnectionsPerNode
        self.acquireTimeoutMilliseconds = acquireTimeoutMilliseconds
            ?? seeds[0].acquireTimeoutDefault
        self.maxAttempts = maxAttempts
        self.replay = replay
    }

    /// One node to start from.
    public convenience init(_ seed: RedisConfiguration, maxConnectionsPerNode: Int = 8,
                            acquireTimeoutMilliseconds: UInt64? = nil, maxAttempts: Int = 5,
                            replay: RedisReplay = .reads) {
        self.init(seeds: [seed], maxConnectionsPerNode: maxConnectionsPerNode,
                  acquireTimeoutMilliseconds: acquireTimeoutMilliseconds, maxAttempts: maxAttempts,
                  replay: replay)
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
    ///
    /// The slots go in the order their first command comes, one after the
    /// other. When one fails, what the slots before it answered is not lost:
    /// the error is `incomplete`, with those replies, rather than a failure
    /// that reads as though nothing ran.
    public func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        guard !commands.isEmpty else { return [] }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        // -1 for the commands that belong to no slot, which any node answers.
        for (i, command) in commands.enumerated() {
            let slot = RedisKeys.slot(of: command) ?? -1
            if groups[slot] == nil { order.append(slot) }
            groups[slot, default: []].append(i)
        }
        if order.count == 1 {
            return try await route(commands, slot: order[0] < 0 ? nil : order[0], timeoutMilliseconds: nil)
        }
        var replies = [RedisValue?](repeating: nil, count: commands.count)
        for slot in order {
            let indices = groups[slot] ?? []
            do throws(RedisClientError) {
                let answers = try await route(indices.map { commands[$0] },
                                              slot: slot < 0 ? nil : slot, timeoutMilliseconds: nil)
                guard answers.count == indices.count else { throw .unexpectedReply(.array(answers)) }
                for (i, index) in indices.enumerated() { replies[index] = answers[i] }
            } catch {
                var failure = error
                if case .incomplete(let got, let inner) = error, got.count == indices.count {
                    for (i, index) in indices.enumerated() { replies[index] = got[i] }
                    failure = inner
                }
                throw .settled(replies, failure)
            }
        }
        return replies.map { $0 ?? .null }
    }

    /// Runs the commands as one transaction on the node that owns their slot.
    /// They must all belong to the same slot: a transaction is one node's.
    public func transaction(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        let slot = slot(of: commands)
        let replies: [RedisValue]
        do throws(RedisClientError) {
            replies = try await route([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")],
                                      slot: slot, timeoutMilliseconds: nil, atomic: true)
        } catch {
            throw error.withoutReplies
        }
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

    /// Where a command is going next.
    private struct Aim: Equatable {
        /// The node a redirect named, or nil for wherever the map says the
        /// slot is.
        var address: String? = nil
        /// Whether `ASKING` goes in front, which is for this send only and
        /// says nothing about the map.
        var asking = false
    }

    /// Commands that stand or fall together, and where they are going.
    private struct Unit {
        /// Their places in the batch, which is also where their replies go.
        var indices: [Int]
        var aim = Aim()
        var attempts = 0
        /// How long to wait before going again, for a slot that is moving.
        var pauseMilliseconds: UInt64 = 0
    }

    /// Sends `commands` to the node that owns `slot`, following what the
    /// cluster says about where they should have gone.
    ///
    /// A pipeline is not one thing. One node can answer some of a batch and
    /// redirect the rest -- which is exactly what a slot half migrated does,
    /// where a key that has moved gets `ASK` and a key that has not is
    /// answered -- so each command is followed on its own. What was answered
    /// is kept, and only what was refused goes again. Sending the whole batch
    /// again would repeat every write that had already happened in it.
    ///
    /// A transaction *is* one thing, and says so with `atomic`. A command
    /// refused while it was being queued makes Redis abort the whole
    /// transaction, so none of it ran and all of it goes again together.
    private func route(_ commands: [RedisCommand], slot: Int?,
                       timeoutMilliseconds: UInt64?,
                       atomic: Bool = false) async throws(RedisClientError) -> [RedisValue] {
        var replies = [RedisValue?](repeating: nil, count: commands.count)
        var pending: [Unit] = atomic
            ? [Unit(indices: Array(commands.indices))]
            : commands.indices.map { Unit(indices: [$0]) }
        do throws(RedisClientError) {
            while let first = pending.first {
                // One write holds everything that is going to the same place.
                let aim = first.aim
                let going = pending.indices.filter { pending[$0].aim == aim }
                if let wait = going.map({ pending[$0].pauseMilliseconds }).max(), wait > 0 {
                    await pause(milliseconds: wait)
                }
                let pool: RedisPool
                if let address = aim.address {
                    pool = poolFor(address: address)
                } else if let slot {
                    pool = try await poolForSlot(slot)
                } else {
                    pool = try await anyPool()
                }
                // ASKING is for the next command, so a unit that needs it
                // carries its own. A unit is one command unless it is a
                // transaction, and a transaction is asked for once, in front
                // of its MULTI.
                var sending: [RedisCommand] = []
                for i in going {
                    if aim.asking { sending.append(RedisCommand("ASKING")) }
                    for index in pending[i].indices { sending.append(commands[index]) }
                }
                let kept = pending.indices.filter { !going.contains($0) }.map { pending[$0] }
                let units = going.map { pending[$0] }
                var again: [Unit] = []
                do throws(RedisClientError) {
                    let answers = try await pool.pipeline(sending, timeoutMilliseconds: timeoutMilliseconds)
                    guard answers.count == sending.count else {
                        throw RedisClientError.unexpectedReply(.array(answers))
                    }
                    again = absorb(units, answers.map { Optional($0) }, asking: aim.asking, into: &replies).again
                } catch {
                    // What the node answered before it failed is settled --
                    // run, or refused -- and only what it did not answer is
                    // in question. A transaction is never part-answered.
                    var failure = error
                    var unanswered = units
                    if !atomic, case .incomplete(let got, let inner) = error, got.count == sending.count {
                        let taken = absorb(units, got, asking: aim.asking, into: &replies)
                        again = taken.again
                        unanswered = taken.unanswered
                        failure = inner
                    } else {
                        failure = error.withoutReplies
                    }
                    // The node is gone, or will not answer. Whoever owns the
                    // slot now is in a fresh map -- but only what can go again
                    // goes.
                    let written = unanswered.flatMap { $0.indices }.map { commands[$0] }
                    guard isWorthAnotherNode(failure), replay.allows(failure, written) else { throw failure }
                    forget(address: pool.address)
                    mapIsStale = true
                    for var unit in unanswered {
                        unit.attempts += 1
                        guard unit.attempts < maxAttempts else { throw failure }
                        unit.aim = Aim()
                        unit.pauseMilliseconds = 20 * UInt64(unit.attempts)
                        again.append(unit)
                    }
                }
                pending = kept + again
            }
        } catch {
            // Answered earlier in this batch -- before a redirect, or before
            // the node that failed -- and not to be lost with the rest.
            throw .settled(replies, error)
        }
        return replies.map { $0 ?? .null }
    }

    /// Takes what a node said to each unit, in the order they were sent: an
    /// answer settles the unit into `replies`, a redirect or "come back"
    /// sends it again, and a unit with no reply at all -- the connection
    /// failed first -- is handed back as unanswered.
    private func absorb(_ units: [Unit], _ answers: [RedisValue?], asking: Bool,
                        into replies: inout [RedisValue?]) -> (again: [Unit], unanswered: [Unit]) {
        var again: [Unit] = []
        var unanswered: [Unit] = []
        var at = 0
        for var unit in units {
            if asking { at += 1 }
            let got = Array(answers[at..<(at + unit.indices.count)])
            at += unit.indices.count
            guard got.allSatisfy({ $0 != nil }) else {
                unanswered.append(unit)
                continue
            }
            let mine = got.map { $0! }
            unit.attempts += 1
            unit.pauseMilliseconds = 0
            if unit.attempts < maxAttempts, let move = mine.compactMap({ Redirect($0) }).first {
                switch move.kind {
                case .moved:
                    // The map was wrong. Correct this slot now so the command
                    // goes straight there, and load the whole map before the
                    // next one is aimed.
                    remember(slot: move.slot, at: move.address)
                    mapIsStale = true
                    unit.aim = Aim(address: move.address, asking: false)
                case .ask:
                    // This key has already moved, the rest of the slot has
                    // not. ASKING says "I know" to the node taking it on.
                    unit.aim = Aim(address: move.address, asking: true)
                }
                again.append(unit)
                continue
            }
            // A slot being moved with more than one key in the command, or a
            // cluster that has not settled: both say to come back.
            if unit.attempts < maxAttempts, let retry = mine.compactMap({ retryable($0) }).first {
                if retry == .clusterDown { mapIsStale = true }
                unit.aim = Aim()
                unit.pauseMilliseconds = 20 * UInt64(unit.attempts)
                again.append(unit)
                continue
            }
            // Answered, or out of attempts and keeping what it was told,
            // which the caller sees as the error it is.
            for (n, index) in unit.indices.enumerated() { replies[index] = mine[n] }
        }
        return (again, unanswered)
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
    /// attention: the connection, not the command. Whether the command may
    /// be sent to that node is `replay`'s question, not this one's.
    private func isWorthAnotherNode(_ error: RedisClientError) -> Bool {
        switch error.cause {
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

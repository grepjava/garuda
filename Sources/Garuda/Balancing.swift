//===----------------------------------------------------------------------===//
// Sharing connections fairly among workers (--balance).
//
// Workers are processes and share nothing while they serve, which is what
// keeps a request's path free of locks -- and what leaves nobody to notice
// that one worker has more than its share. With a listener per worker
// (SO_REUSEPORT) the kernel places each connection by a hash of its addresses,
// blind to load, and a handful of long-lived connections can land three on
// one worker and thirteen on another. The busiest worker sets the tail.
//
// Two tiers even that out, and each acts only when the load is uneven:
//
//   * Placement. Every worker watches one shared listener, registered so that
//     the kernel wakes one waiting worker per connection (EPOLLEXCLUSIVE) --
//     and only a worker with nothing to do is waiting. A worker that is
//     clearly ahead of the others stops watching until it is not.
//
//   * Moving. When one worker stays ahead anyway -- its connections are busier
//     than the others', say -- it hands some of its idle HTTP/1 connections to
//     the least busy worker: the descriptor goes over a unix socket
//     (SCM_RIGHTS) and the other worker carries on as if it had accepted it.
//     A connection moves only between requests, with nothing buffered and
//     nothing in flight, so the client never knows.
//
// A TLS connection can move only when the kernel encrypts it both ways
// (kernel TLS): an OpenSSL session is memory in this process, and cannot go
// with the descriptor. HTTP/2, WebSocket and streaming connections never move.
//
// Every worker publishes its load to a page all of them can read
// (avian_load.h): how much of the last stretch its loop spent working, and
// how many connections it holds. The decisions below read that and nothing
// else, and are pure so they can be tested on their own.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// How connections are shared among workers (--balance).
public enum BalanceMode: Sendable, Equatable {
    /// One shared listener that wakes a worker with time for the connection,
    /// and idle connections moved off a worker that stays behind.
    case adaptive
    /// The shared listener only.
    case accept
    /// A listener per worker, and the kernel's hash decides.
    case reuseport
}

/// Whether the kernel does TLS's encryption once OpenSSL has done the
/// handshake (--ktls, --no-ktls).
public enum KernelTLS: Sendable, Equatable {
    /// Wherever OpenSSL and the kernel both can.
    case auto
    /// Asked for, with a warning where it cannot be had.
    case on
    case off
}

/// One worker's load, as the decisions see it.
struct WorkerLoad: Equatable {
    /// Thousandths of the last stretch its loop spent working.
    var busy: Int
    var conns: Int
    /// The hand-off channel it receives on.
    var channel: Int = -1
    /// Watching the shared listener, so that a connection left to it will be
    /// taken.
    var accepting = true
    /// How long a request arriving now would wait there, in microseconds.
    var wait = 0
    /// On one loop turn so long that its readings are stale: not free,
    /// whatever it last said.
    var stalled = false
}

enum BalancePolicy {
    /// How much busier than the least busy worker counts as ahead, and the
    /// least busy a worker must be to be ahead on that count at all: below
    /// it, everyone has time to spare.
    static let busyMargin = 250
    static let busyFloor = 500
    /// How long a worker must stay ahead before it moves anything, so that a
    /// moment's burst is not taken for a trend.
    static let sustainMs: UInt64 = 100
    /// After a move, time for every worker's reading to reflect it.
    static let moveCooldownMs: UInt64 = 100
    /// How long a connection that moved stays put.
    static let settleMs: UInt64 = 1_000
    static let maxMovesPerRound = 8
    /// The longest a busier worker leaves the listener to the others,
    /// whatever the readings say, so that none can go deaf.
    static let rearmMs: UInt64 = 50
    /// How long a worker with more connections than a peer steps back: a
    /// turn, long enough for the others to take what is waiting. Counts of
    /// connections that come and go by the thousand move by the
    /// millisecond, and a worker that stayed back over one would soon be
    /// deferring to a peer that had moved on.
    static let stepBackUs: UInt64 = 200

    /// How many more connections than the fewest count as ahead: a few for a
    /// few connections, an eighth more for many. Not fewer: connections that
    /// come and go by the thousand leave every count jittering by one or two.
    static func connectionMargin(_ fewest: Int) -> Int { max(3, fewest / 8) }

    /// Where a worker stands against the others.
    enum Standing: Equatable {
        case even
        /// More connections than a peer about as free as it.
        case moreConnections
        /// Busier than the idlest by a clear margin.
        case busier
    }

    /// Whether a worker with load `me` should leave new connections to the
    /// others.
    static func isAhead<C: Collection>(_ me: WorkerLoad, _ others: C) -> Bool
    where C.Element == WorkerLoad {
        standing(me, others) != .even
    }

    /// Only workers watching the listener are compared against: one that is
    /// not will not take what is left to it, and workers each deferring to
    /// another that had just done the same would leave connections queued
    /// with every one of them idle.
    static func standing<C: Collection>(_ me: WorkerLoad, _ others: C) -> Standing
    where C.Element == WorkerLoad {
        var idlest = Int.max
        // Connections are compared only with workers about as free as this
        // one: a worker holding fewer because it is flat out with them is no
        // reason to leave new ones to it -- and taking it as the yardstick
        // would let this worker take every connection there is.
        var fewest = Int.max
        for other in others where other.accepting && !other.stalled {
            idlest = min(idlest, other.busy)
            if other.busy <= me.busy + busyMargin / 2 { fewest = min(fewest, other.conns) }
        }
        if idlest == Int.max { return .even }
        // Busier than the idlest by a clear margin, and busy enough to matter.
        if me.busy >= busyFloor && me.busy > idlest + busyMargin { return .busier }
        // More connections than a peer by a clear margin.
        if fewest != Int.max && me.conns > fewest + connectionMargin(fewest) {
            return .moreConnections
        }
        return .even
    }

    /// The worker to hand idle connections to, and how many, or nil when
    /// nothing should move. `capacity` is each worker's connection limit.
    ///
    /// Only busyness moves connections. A connection moved to a worker that
    /// is as busy as this one waits there as long as it would have here, and
    /// pays for the move besides; uneven counts alone are the listener's to
    /// even out, as connections come and go.
    static func moveTarget<C: Collection>(_ me: WorkerLoad, _ others: C,
                                          capacity: Int) -> (target: WorkerLoad, count: Int)?
    where C.Element == WorkerLoad {
        // One connection is the costliest, which never goes.
        guard me.conns >= 2, me.wait >= waitFloorUs else { return nil }
        guard let target = others.filter({ $0.conns < capacity && $0.channel >= 0 && !$0.stalled })
                .min(by: { ($0.wait, $0.conns) < ($1.wait, $1.conns) }) else { return nil }
        guard me.wait > 2 * target.wait + waitMarginUs else { return nil }
        return (target, min(maxMovesPerRound, max(1, me.conns / 4), capacity - target.conns))
    }

    /// Below this wait nothing is worth moving, and a move must at least
    /// halve it and save this much besides: a move costs a hop, and readings
    /// that close are noise.
    static let waitFloorUs = 100
    static let waitMarginUs = 100

    /// How long a request arriving now waits before its worker gets to it,
    /// in microseconds.
    ///
    /// A worker serves in turns: it collects what is ready, works through
    /// all of it, and waits again. A request that arrives mid-turn waits for
    /// the rest of that turn, and one that arrives while the worker waits is
    /// served at once. So the wait is the share of time spent working times
    /// the mean remaining length of a turn, ρ·E[T²] / (2·E[T]). The second
    /// moment is the point: it is long both where one request takes
    /// milliseconds and where many quick ones arrive together, and two
    /// workers equally busy differ by exactly that.
    static func expectedWait(busy: Int, meanTurn: Double, meanTurnSquared: Double) -> Int {
        guard meanTurn > 0 else { return 0 }
        let rho = min(Double(busy) / 1000, 1)
        let residual = meanTurnSquared / (2 * meanTurn)
        return Int(min(rho * residual, 10_000_000).rounded())
    }
}

/// What a worker passes along with a connection's descriptor: what the other
/// worker could not otherwise know about it.
struct HandoffNote: Equatable {
    static let version: UInt8 = 1
    static let size = 64

    var kernelTLS: Bool
    var port: UInt16
    var requestCount: UInt32
    /// The peer's address as text, as accept reported it.
    var address: [UInt8]

    func encode(into p: UnsafeMutablePointer<UInt8>) -> Int {
        let length = min(address.count, HandoffNote.size - 9)
        p[0] = HandoffNote.version
        p[1] = kernelTLS ? 1 : 0
        p[2] = UInt8(truncatingIfNeeded: port >> 8)
        p[3] = UInt8(truncatingIfNeeded: port)
        p[4] = UInt8(truncatingIfNeeded: requestCount >> 24)
        p[5] = UInt8(truncatingIfNeeded: requestCount >> 16)
        p[6] = UInt8(truncatingIfNeeded: requestCount >> 8)
        p[7] = UInt8(truncatingIfNeeded: requestCount)
        p[8] = UInt8(length)
        for i in 0..<length { p[9 + i] = address[i] }
        return 9 + length
    }

    static func decode(_ p: UnsafePointer<UInt8>, _ n: Int) -> HandoffNote? {
        guard n >= 9, p[0] == version, p[1] <= 1 else { return nil }
        let length = Int(p[8])
        guard n == 9 + length else { return nil }
        let port = UInt16(p[2]) << 8 | UInt16(p[3])
        let count = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        return HandoffNote(kernelTLS: p[1] == 1, port: port, requestCount: count,
                           address: Array(UnsafeBufferPointer(start: p + 9, count: length)))
    }
}

/// What the supervisor gives a worker for balancing.
struct BalanceSetup {
    /// The listener is one socket every worker accepts from.
    var sharedListener = false
    /// Its slot on the load page, or -1 when there is none.
    var loadSlot = -1
    var channel = -1
    var receiveFD: Int32 = -1
    var sendFDs: [Int32] = []
}

/// A worker's part in balancing. Inert -- and costing one branch per loop
/// turn -- unless the supervisor started it.
struct Balancer {
    /// Whether this worker publishes its load and reads the others'.
    var active = false
    /// This worker's slot on the load page.
    var loadSlot: Int32 = -1
    /// The listener is shared with the other workers and registered
    /// exclusively, so it is armed by adding it and disarmed by removing it.
    var sharedListener = false
    var listenerArmed = false
    /// When the listener was last left to the others, and, when that was for
    /// a turn only, when to take it back.
    var disarmedAt: UInt64 = 0
    var backAtUs: UInt64 = 0
    /// Moving connections: the channel this worker receives them on, and one
    /// to send on for each worker slot. Empty unless --balance adaptive.
    var receiveFD: Int32 = -1
    var sendFDs: [Int32] = []
    var channel = -1

    /// The load reading: time working and waiting since the window opened,
    /// and a smoothed share of it, in thousandths.
    var windowStart: UInt64 = 0
    var workedUs: UInt64 = 0
    var waitedUs: UInt64 = 0
    var lastWake: UInt64 = 0
    var busy = 0
    static let windowUs: UInt64 = 10_000

    /// Loop turns in this window, with how long each worked summed and
    /// squared; and the smoothed means of both, from which the expected wait
    /// is worked out. Kept only where connections move.
    var turns = 0
    var turnSum: Double = 0
    var turnSquares: Double = 0
    var meanTurn: Double = 0
    var meanTurnSquared: Double = 0
    var wait = 0

    /// Since when this worker has been ahead, or 0; and when it last moved
    /// connections away.
    var aheadSince: UInt64 = 0
    var lastMove: UInt64 = 0
    var lastTick: UInt64 = 0

    /// The page as last read, and the other workers in it: kept from one
    /// reading to the next, so that reading allocates nothing.
    var views: [av_load_view] = []
    var others: [WorkerLoad] = []

    var moves: Bool { receiveFD >= 0 }
}

extension Worker {

    /// Joins the load page and, with channels, starts taking connections
    /// from the other workers. Called once, before the loop.
    mutating func startBalancing(loadSlot: Int, channel: Int,
                                 receiveFD: Int32, sendFDs: [Int32],
                                 sharedListener: Bool) {
        guard av_load_enabled() != 0 else { return }
        balancer.active = true
        balancer.loadSlot = Int32(loadSlot)
        balancer.channel = channel
        balancer.sharedListener = sharedListener
        balancer.sendFDs = sendFDs
        balancer.views = [av_load_view](repeating: av_load_view(), count: Int(av_load_slots()))
        balancer.others.reserveCapacity(balancer.views.count)
        let now = av_monotonic_us()
        balancer.windowStart = now
        balancer.lastWake = now
        if receiveFD >= 0, poller.add(receiveFD, .read, token: PollToken.handoff) {
            balancer.receiveFD = receiveFD
        }
        av_load_join(Int32(loadSlot), Int32(channel))
        // Watched exclusively until now (see armListener), and not yet said to
        // be accepting.
        if balancer.listenerArmed {
            disarmListener()
            armListener()
        }
    }

    /// Stops being offered anything: the drain. Connections already sent this
    /// way wait in the channel for the worker that replaces this one.
    mutating func stopBalancing() {
        guard balancer.active else { return }
        av_load_draining(balancer.loadSlot)
        if balancer.receiveFD >= 0 {
            _ = poller.remove(balancer.receiveFD, last: .read)
            balancer.receiveFD = -1
        }
    }

    /// The worker is exiting.
    mutating func leaveBalancing() {
        guard balancer.active else { return }
        av_load_leave(balancer.loadSlot)
        balancer.active = false
    }

    // MARK: - The listener

    /// Starts watching the listener.
    ///
    /// A shared listener no worker ever steps back from is watched
    /// exclusively, so that the kernel wakes one worker per connection rather
    /// than all of them; the one woken takes everything waiting. With the
    /// gate on it is not: the kernel tells a waiting connection only to the
    /// worker it woke, and one that then stepped back would leave the rest of
    /// the queue waiting for the next connection to wake someone else. Every
    /// idle worker is woken instead, and the ones behind take what is there.
    @discardableResult
    mutating func armListener() -> Bool {
        guard listenFD >= 0 else { return false }
        let ok = balancer.sharedListener && !balancer.active
            ? poller.addExclusive(listenFD, .read, token: PollToken.listener)
            : poller.add(listenFD, .read, token: PollToken.listener)
        if ok {
            balancer.listenerArmed = true
            if balancer.active && balancer.sharedListener { av_load_accepting(balancer.loadSlot, 1) }
        }
        return ok
    }

    /// Stops watching the listener, for a while or for good.
    mutating func disarmListener() {
        guard listenFD >= 0, balancer.listenerArmed else { return }
        _ = poller.remove(listenFD, last: .read)
        balancer.listenerArmed = false
        if balancer.active { av_load_accepting(balancer.loadSlot, 0) }
    }

    // MARK: - The load reading

    /// Around the wait for events: the time since the last one was work, and
    /// a worker that is waiting says since when.
    @inline(__always)
    mutating func loadBeforeWait() {
        let now = av_monotonic_us()
        let worked = now &- balancer.lastWake
        balancer.workedUs &+= worked
        if balancer.moves {
            let turn = Double(min(worked, 1_000_000))
            balancer.turns += 1
            balancer.turnSum += turn
            balancer.turnSquares += turn * turn
        }
        av_load_waiting(balancer.loadSlot, now)
        balancer.lastWake = now
    }

    @inline(__always)
    mutating func loadAfterWait() {
        let now = av_monotonic_us()
        balancer.waitedUs &+= now &- balancer.lastWake
        balancer.lastWake = now
        av_load_awake(balancer.loadSlot, now)
        if now &- balancer.windowStart >= Balancer.windowUs { closeLoadWindow(now) }
    }

    mutating func closeLoadWindow(_ now: UInt64) {
        let total = balancer.workedUs &+ balancer.waitedUs
        let share = total > 0 ? Int(balancer.workedUs &* 1000 / total) : 0
        // A quarter of each new window: a reading that follows the load
        // within a few windows, and does not jump at one busy moment.
        balancer.busy = (balancer.busy * 3 + share) / 4
        balancer.workedUs = 0
        balancer.waitedUs = 0
        balancer.windowStart = now
        if balancer.moves {
            if balancer.turns > 0 {
                let n = Double(balancer.turns)
                balancer.meanTurn = (balancer.meanTurn * 3 + balancer.turnSum / n) / 4
                balancer.meanTurnSquared =
                    (balancer.meanTurnSquared * 3 + balancer.turnSquares / n) / 4
                balancer.turns = 0
                balancer.turnSum = 0
                balancer.turnSquares = 0
            }
            balancer.wait = BalancePolicy.expectedWait(busy: balancer.busy,
                                                       meanTurn: balancer.meanTurn,
                                                       meanTurnSquared: balancer.meanTurnSquared)
            av_load_publish_wait(balancer.loadSlot, UInt32(balancer.wait))
        }
        publishLoad()
    }

    /// Writes this worker's reading to the page. The count goes up with every
    /// connection taken and closed, not once a window: connections that live
    /// a millisecond would otherwise leave every other worker comparing its
    /// own count against readings of moments that are gone.
    @inline(__always)
    func publishLoad() {
        av_load_publish(balancer.loadSlot, UInt32(balancer.busy), UInt32(table.liveCount))
    }

    /// Reads every other active worker's load into `balancer.others`, and
    /// returns this worker's own.
    mutating func readLoads(now: UInt64) -> WorkerLoad {
        let capacity = balancer.views.count
        let n = Int(av_load_snapshot(&balancer.views, Int32(capacity), now))
        balancer.others.removeAll(keepingCapacity: true)
        for i in 0..<n where balancer.views[i].slot != balancer.loadSlot {
            let view = balancer.views[i]
            balancer.others.append(WorkerLoad(busy: Int(view.busy), conns: Int(view.conns),
                                              channel: Int(view.channel),
                                              accepting: view.accepting != 0,
                                              wait: Int(view.wait_us),
                                              stalled: view.stalled != 0))
        }
        return WorkerLoad(busy: balancer.busy, conns: table.liveCount, channel: balancer.channel,
                          wait: balancer.wait)
    }

    /// Whether to take the next connection off the shared listener. A worker
    /// ahead of one that is accepting leaves it to that one: for a turn when
    /// it only holds more connections, until it is no longer busier when it
    /// is busier. Every idle worker is woken for a connection, so the one
    /// this worker leaves is taken.
    mutating func mayAccept(accepted: Int) -> Bool {
        guard balancer.active, balancer.sharedListener else { return true }
        // The others are read once a pass: they change little in the
        // microseconds it lasts, and reading them costs a cache miss a worker.
        // This worker's own count is always the live one.
        let me = accepted == 0
            ? readLoads(now: av_monotonic_us())
            : WorkerLoad(busy: balancer.busy, conns: table.liveCount, channel: balancer.channel)
        let standing = BalancePolicy.standing(me, balancer.others)
        if standing == .even { return true }
        disarmListener()
        balancer.disarmedAt = av_monotonic_ms()
        balancer.backAtUs = standing == .moreConnections
            ? av_monotonic_us() &+ BalancePolicy.stepBackUs : 0
        Metrics.add(AV_M_ACCEPTS_DEFERRED)
        return false
    }

    /// How long the loop may wait: not long while the listener is left to the
    /// others, so that it is taken back promptly.
    @inline(__always)
    func balanceTimeout(_ timeout: Int32) -> Int32 {
        balancer.sharedListener && !balancer.listenerArmed && !draining ? min(timeout, 1) : timeout
    }

    /// Once a loop turn: takes the listener back once this worker is no
    /// longer ahead, and moves connections away when it stays ahead.
    mutating func balanceTick() {
        let nowMs = av_monotonic_ms()
        let rearming = balancer.sharedListener && !balancer.listenerArmed && !acceptSuspended
            && !draining
        // Every turn while off the listener, so that it is back the moment it
        // is no longer ahead; otherwise every few milliseconds.
        if !rearming && nowMs &- balancer.lastTick < 2 { return }
        balancer.lastTick = nowMs
        if draining { return }
        guard rearming || balancer.moves else { return }
        let nowUs = av_monotonic_us()
        if rearming && balancer.backAtUs != 0 {
            // Stepped back for a turn: back once it is over, whatever the
            // counts say by then.
            if nowUs >= balancer.backAtUs {
                balancer.backAtUs = 0
                armListener()
            }
            if !balancer.moves { return }
        }
        let me = readLoads(now: nowUs)
        if rearming && balancer.backAtUs == 0 && !balancer.listenerArmed {
            if BalancePolicy.standing(me, balancer.others) != .busier
                || nowMs &- balancer.disarmedAt >= BalancePolicy.rearmMs {
                armListener()
            }
        }
        guard balancer.moves else { return }
        guard let plan = BalancePolicy.moveTarget(me, balancer.others,
                                                  capacity: config.maxConnections) else {
            balancer.aheadSince = 0
            return
        }
        if balancer.aheadSince == 0 { balancer.aheadSince = nowMs }
        guard nowMs &- balancer.aheadSince >= BalancePolicy.sustainMs,
              nowMs &- balancer.lastMove >= BalancePolicy.moveCooldownMs,
              plan.target.channel < balancer.sendFDs.count else { return }
        let moved = handOff(count: plan.count, to: balancer.sendFDs[plan.target.channel], now: nowMs)
        if moved > 0 {
            balancer.lastMove = nowMs
            balancer.aheadSince = 0
        }
    }

    // MARK: - Moving connections

    /// Whether the connection in `slot` could be carried on by another worker
    /// right now: an HTTP/1 connection between requests, with nothing read,
    /// nothing to write and nothing waiting on it, whose TLS -- if any -- the
    /// kernel can carry.
    func isMovable(_ slot: Int, now: UInt64) -> Bool {
        let c = table[slot]
        guard c.pointee.state == .readingHead, c.pointee.fd >= 0,
              c.pointee.read.readableBytes == 0, c.pointee.write.isEmpty,
              c.pointee.fileFD < 0, c.pointee.heldBodyEnd == 0,
              c.pointee.contState == .none, c.pointee.h2 == nil,
              c.pointee.bodyStream == nil,
              now >= c.pointee.movableAfter else { return false }
        let blocking: ConnFlags = [.peerClosed, .tlsHandshake, .alpnH2, .flushQueued,
                                   .websocketMode, .handedOff]
        guard c.pointee.flags.contains(.servedRequest),
              c.pointee.flags.isDisjoint(with: blocking) else { return false }
        if let tls = c.pointee.tls {
            return av_tls_ktls_send(tls) != 0 && av_tls_ktls_recv(tls) != 0
                && av_tls_pending(tls) == 0 && av_tls_wants_write(tls) == 0
        }
        return true
    }

    /// A request on `slot` has been answered: what it cost joins the
    /// connection's reading, each request weighing a quarter.
    mutating func noteCost(_ slot: Int) {
        let c = table[slot]
        let spent = min(av_monotonic_us() &- c.pointee.requestStartUs, 60_000_000)
        c.pointee.costUs = UInt32((UInt64(c.pointee.costUs) * 3 + spent) / 4)
    }

    /// Hands up to `count` idle connections to the worker receiving on
    /// `chan`, the cheapest first. Returns how many went.
    ///
    /// The costliest connection this worker holds never goes. Moving it
    /// would move the load rather than share it -- the other worker would be
    /// the busy one, and hand it back -- where moving the cheap ones out from
    /// behind it is what shortens their wait.
    mutating func handOff(count: Int, to chan: Int32, now: UInt64) -> Int {
        var candidates: [(slot: Int, cost: UInt32)] = []
        var costliest: UInt32 = 0
        var scan = 0
        while scan < table.initialized {
            let c = table[scan]
            if c.pointee.state != .free && !c.pointee.isStream {
                costliest = max(costliest, c.pointee.costUs)
                if isMovable(scan, now: now) { candidates.append((scan, c.pointee.costUs)) }
            }
            scan += 1
        }
        candidates.sort { $0.cost < $1.cost }
        if let last = candidates.last, last.cost >= costliest {
            candidates.removeLast()
        }
        var moved = 0
        var note = [UInt8](repeating: 0, count: HandoffNote.size)
        for (slot, _) in candidates where moved < count {
            let c = table[slot]
            // The session goes to the kernel first; if that is refused, the
            // connection is not the kernel's to carry and stays.
            if let tls = c.pointee.tls {
                guard av_tls_release_to_kernel(tls) != 0 else { continue }
                c.pointee.tls = nil
                c.pointee.flags.insert(.kernelTLS)
            }
            let facts = HandoffNote(
                kernelTLS: c.pointee.flags.contains(.kernelTLS),
                port: c.pointee.remotePort,
                requestCount: c.pointee.requestCount,
                address: Array(UnsafeBufferPointer(start: c.pointee.remoteAddr.readPointer,
                                                   count: c.pointee.remoteAddr.readableBytes)))
            let length = note.withUnsafeMutableBufferPointer { facts.encode(into: $0.baseAddress!) }
            let sent = note.withUnsafeBufferPointer {
                av_send_fd(chan, c.pointee.fd, $0.baseAddress!, length)
            }
            // The other worker is behind with its hand-offs: this connection
            // stays -- as the kernel's alone, if its session was just given up
            // -- and so do the rest.
            guard sent == length else { break }
            c.pointee.flags.insert(.handedOff)
            closeConnection(slot)
            Metrics.add(AV_M_CONNECTIONS_HANDED_OFF)
            moved += 1
        }
        return moved
    }

    /// Takes over the connections other workers have handed to this one.
    mutating func receiveHandoffs() {
        guard balancer.receiveFD >= 0 else { return }
        var note = [UInt8](repeating: 0, count: HandoffNote.size)
        for _ in 0..<64 {
            var fd: Int32 = -1
            let n = note.withUnsafeMutableBufferPointer {
                av_recv_fd(balancer.receiveFD, &fd, $0.baseAddress!, HandoffNote.size)
            }
            if n < 0 { return }
            guard fd >= 0 else { continue }
            let facts = note.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n) }
            guard let facts, draining == false else {
                // Not ours to understand, or arriving as this worker stops:
                // the client sees a keep-alive connection closed between
                // requests, which it expects to happen.
                _ = av_close(fd)
                continue
            }
            takeOver(fd, facts)
        }
    }

    mutating func takeOver(_ fd: Int32, _ facts: HandoffNote) {
        // Never an empty array, so there is always a pointer to pass.
        let address = facts.address + [0]
        let slot = address.withUnsafeBufferPointer {
            adoptConnection(fd, address: $0.baseAddress!, addressLength: facts.address.count,
                            port: facts.port, arrival: facts.kernelTLS ? .kernelTLS : .plain)
        }
        guard slot >= 0 else { return }
        let c = table[slot]
        c.pointee.requestCount = facts.requestCount
        c.pointee.flags.insert(.servedRequest)
        c.pointee.movableAfter = av_monotonic_ms() &+ BalancePolicy.settleMs
        Metrics.add(AV_M_CONNECTIONS_TAKEN_OVER)
    }
}

/// How a connection came to this worker.
enum Arrival {
    /// Accepted here.
    case accepted
    /// Handed over by another worker, in the clear...
    case plain
    /// ...or with its TLS in the kernel.
    case kernelTLS
}

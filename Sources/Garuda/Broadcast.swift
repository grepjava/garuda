//===----------------------------------------------------------------------===//
// Topics: messages published on any shard, heard on every shard.
//
//     struct Said: Codable { var text: String }
//     let lobby = Topic("room/lobby")
//
//     app.post("/say") { (said: Body<Said>) in
//         try lobby.publish(said.value.text, event: "said")
//         return HTTPStatus.noContent
//     }
//
//     app.get("/events") { (last: LastEventID) in
//         EventStream { events in
//             try await events.forward(lobby, after: last)
//         }
//     }
//
// Shards are processes, and the clients of one topic are spread across all
// of them, so a message goes through a ring in a shared region every shard
// maps (garuda_bus.h, `--broadcast-size`). Each shard has one thread that
// sleeps on the ring and hands what is published to the subscribers that
// shard holds; the shard that published a message hears it the same way.
//
// Every message has a number, which rises by one per message and is the `id`
// of the event `forward` sends. A client that reconnects with it as
// Last-Event-ID is sent what it missed, from the ring, on whichever shard it
// lands on -- as far back as the ring still holds. A gap the ring cannot
// fill, and messages a subscriber fell too far behind to keep, arrive as
// `.missed` in their place, so the application can start that client over
// rather than have it silently diverge.
//
// A subscription lasts until it is cancelled or let go of, and one made for
// an event stream ends with the stream: its waits throw once the client has
// gone. One task at a time waits on a subscription.
//===----------------------------------------------------------------------===//

import CGarudaShared
import Synchronization
import Vega
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A named stream of messages. Anyone may publish on it and any request may
/// subscribe to it, on any shard.
public struct Topic: Sendable, Hashable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// Publishes `text` to every subscriber, on every shard, and returns its
    /// number. `event` names the kind of message, as an event stream's
    /// `event:` field does.
    @discardableResult
    public func publish(_ text: String, event: String? = nil) throws(BroadcastError) -> BroadcastID {
        try publish(Array(text.utf8), event: event)
    }

    /// Publishes `bytes` to every subscriber, on every shard.
    @discardableResult
    public func publish(_ bytes: [UInt8], event: String? = nil) throws(BroadcastError) -> BroadcastID {
        try TopicBus.current().publish(name, event: event, bytes)
    }
}

/// A message's number: rising by one per message, across every topic and
/// every shard, and above every number a server started earlier gave out.
public struct BroadcastID: Sendable, Hashable, Comparable, LosslessStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Reads the decimal digits `description` holds, and nothing else.
    public init?(_ description: String) {
        guard !description.isEmpty, description.utf8.count <= 20,
              description.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = UInt64(description) else { return nil }
        rawValue = value
    }

    public var description: String { String(rawValue) }

    public static func < (a: BroadcastID, b: BroadcastID) -> Bool { a.rawValue < b.rawValue }
}

/// One published message.
public struct BroadcastMessage: Sendable, Equatable {
    public let id: BroadcastID
    public let topic: String
    /// The kind of message it was published as, or nil.
    public let event: String?
    public let data: [UInt8]

    /// The data as UTF-8, with anything that is not replaced.
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// What a subscription hands over next.
public enum BroadcastEvent: Sendable, Equatable {
    case message(BroadcastMessage)
    /// Messages were published that this subscription will not be given: it
    /// fell behind by more than `--broadcast-queue`, its shard fell behind by
    /// more than the ring holds, or what it asked to be sent again is no
    /// longer there.
    case missed
}

/// Why a message could not be published or subscribed to. Thrown out of a
/// handler, it is answered 503 or 413.
public enum BroadcastError: ResponseError, Equatable, Sendable {
    /// There is no ring to publish into: `--broadcast-size 0`.
    case unavailable
    /// The message, topic and event name together, is larger than a quarter
    /// of `--broadcast-size`.
    case tooLarge

    public var status: HTTPStatus {
        self == .unavailable ? .serviceUnavailable : .contentTooLarge
    }

    public var reason: String? {
        self == .unavailable ? "broadcast is turned off" : "the message is larger than the broadcast ring takes"
    }
}

/// The number a reconnecting event-stream client says it last saw, from its
/// `Last-Event-ID` header. Never refuses a request: a first connection has none.
public struct LastEventID: RequestExtractor, Sendable {
    public var value: String?

    public init(_ value: String?) {
        self.value = value
    }

    /// The value as a broadcast message's number, when it is one.
    public var broadcastID: BroadcastID? { value.flatMap { BroadcastID($0) } }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Self {
        LastEventID(request.header("last-event-id"))
    }
}

// MARK: - Subscriptions

/// Messages on some topics, until `cancel`, until it is let go of, or --
/// made for an event stream -- until the stream ends.
public final class Subscription: Sendable {
    let state: SubscriptionState
    let bus: TopicBus
    public let topics: [Topic]

    init(bus: TopicBus, state: SubscriptionState, topics: [Topic]) {
        self.bus = bus
        self.state = state
        self.topics = topics
    }

    deinit {
        cancel()
    }

    /// The next message, or `.missed`, waiting for one to be published.
    /// Throws once whoever subscribed has gone, or the subscription has been
    /// cancelled.
    public func next() async throws(HandlerWaitError) -> BroadcastEvent {
        while true {
            if let event = try await next(until: nil) { return event }
        }
    }

    /// The next message, or `.missed`, waiting at most `milliseconds` for
    /// one. Nil when none came in time.
    public func next(timeoutMilliseconds milliseconds: UInt64) async throws(HandlerWaitError) -> BroadcastEvent? {
        try await next(until: monotonicNanos() &+ milliseconds &* 1_000_000)
    }

    private func next(until deadline: UInt64?) async throws(HandlerWaitError) -> BroadcastEvent? {
        if let event = try state.take(bus) { return event }
        await state.wait(bus, deadline: deadline ?? 0)
        if Task.isCancelled { throw .cancelled }
        return try state.take(bus)
    }

    /// Stops delivery. Messages already queued are dropped, and a wait in
    /// progress throws `cancelled`.
    public func cancel() {
        if state.cancel() { bus.remove(state) }
    }

    public var isCancelled: Bool { state.isCancelled }
}

/// A subscription's queue, shared by the task that waits on it and the
/// shard's listener thread that fills it.
final class SubscriptionState: @unchecked Sendable {
    let topics: [String]
    /// Messages from this number on are delivered as they are published;
    /// those before it, from `replayNext`, are read back out of the ring.
    let liveFrom: UInt64
    /// Whether whoever subscribed is still there.
    let alive: @Sendable () -> Bool

    private let lock = Mutex<Void>(())
    // Under `lock`.
    private var replayNext: UInt64
    private var queue: [BroadcastEvent] = []
    private var queueHead = 0
    private var queuedBytes = 0
    private var waiter: UnsafeContinuation<Void, Never>?
    /// When the wait in progress gives up, in monotonic nanoseconds; 0 for
    /// never.
    private(set) var deadline: UInt64 = 0
    private var cancelled = false
    private var taskCancelled = false

    init(topics: [String], liveFrom: UInt64, replayFrom: UInt64, alive: @escaping @Sendable () -> Bool) {
        self.topics = topics
        self.liveFrom = liveFrom
        self.alive = alive
        replayNext = replayFrom
    }

    var isCancelled: Bool { lock.withLock { _ in cancelled } }

    /// Marks it cancelled and wakes a wait; true the first time.
    func cancel() -> Bool {
        let (first, waiter) = lock.withLock { _ -> (Bool, UnsafeContinuation<Void, Never>?) in
            guard !cancelled else { return (false, nil) }
            cancelled = true
            queue.removeAll()
            queueHead = 0
            queuedBytes = 0
            let w = self.waiter
            self.waiter = nil
            return (true, w)
        }
        waiter?.resume()
        return first
    }

    /// What is next without waiting: messages read back from the ring first,
    /// then those delivered since subscribing.
    func take(_ bus: TopicBus) throws(HandlerWaitError) -> BroadcastEvent? {
        let event = try lock.withLock { _ throws(HandlerWaitError) -> BroadcastEvent? in
            if cancelled { throw .cancelled }
            if replayNext < liveFrom, let event = replay(bus) { return event }
            guard queueHead < queue.count else { return nil }
            let event = queue[queueHead]
            queueHead += 1
            if case .message(let message) = event { queuedBytes -= SubscriptionState.cost(message) }
            if queueHead == queue.count {
                queue.removeAll(keepingCapacity: true)
                queueHead = 0
            } else if queueHead >= 64 && queueHead * 2 >= queue.count {
                queue.removeFirst(queueHead)
                queueHead = 0
            }
            return event
        }
        if event == nil && !alive() { throw .cancelled }
        return event
    }

    /// Under the lock.
    private func replay(_ bus: TopicBus) -> BroadcastEvent? {
        while replayNext < liveFrom {
            let oldest = gb_bus_oldest(bus.handle)
            if replayNext < oldest {
                replayNext = min(oldest, liveFrom)
                return .missed
            }
            switch bus.read(replayNext) {
            case .message(let message):
                replayNext += 1
                if topics.contains(message.topic) { return .message(message) }
            case .notYet:
                replayNext = liveFrom
            case .gone:
                // Written over since `oldest` was read.
                replayNext = max(replayNext + 1, min(gb_bus_oldest(bus.handle), liveFrom))
                return .missed
            }
        }
        return nil
    }

    /// Waits for something to be queued, the deadline, cancellation, or the
    /// listener to find whoever subscribed gone.
    func wait(_ bus: TopicBus, deadline: UInt64) async {
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (c: UnsafeContinuation<Void, Never>) in
                let ready = lock.withLock { _ -> Bool in
                    if cancelled || taskCancelled || queueHead < queue.count { return true }
                    waiter = c
                    self.deadline = deadline
                    return false
                }
                if ready {
                    c.resume()
                } else if deadline != 0 {
                    bus.wakeBy(deadline)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { _ -> UnsafeContinuation<Void, Never>? in
                taskCancelled = true
                let w = self.waiter
                self.waiter = nil
                return w
            }
            waiter?.resume()
        }
    }

    /// Queues `event`, and hands back the wait to resume for it, if there is
    /// one. On the listener thread.
    func enqueue(_ event: BroadcastEvent, limit: Int, byteLimit: Int) -> UnsafeContinuation<Void, Never>? {
        lock.withLock { _ in
            if cancelled { return nil }
            let pending = queue.count - queueHead
            let lastMissed = pending > 0 && queue[queue.count - 1] == .missed
            switch event {
            case .missed:
                if lastMissed { return nil }
                queue.append(.missed)
            case .message(let message):
                let cost = SubscriptionState.cost(message)
                if pending >= limit || queuedBytes + cost > byteLimit {
                    if lastMissed { return nil }
                    queue.append(.missed)
                } else {
                    queue.append(event)
                    queuedBytes += cost
                }
            }
            let w = waiter
            waiter = nil
            return w
        }
    }

    /// Ends a wait whose deadline has passed, or whose subscriber has gone.
    /// On the listener thread. Returns the deadline still ahead, or 0.
    func sweep(now: UInt64) -> (UnsafeContinuation<Void, Never>?, UInt64) {
        let (due, ahead, waiting) = lock.withLock { _ -> (UnsafeContinuation<Void, Never>?, UInt64, Bool) in
            guard let w = waiter else { return (nil, 0, false) }
            if deadline != 0 && now >= deadline {
                waiter = nil
                return (w, 0, false)
            }
            return (nil, deadline, true)
        }
        if due != nil { return (due, 0) }
        // Asked outside the lock: it may take the stream's.
        if waiting && !alive() {
            return (lock.withLock { _ in
                let w = waiter
                waiter = nil
                return w
            }, 0)
        }
        return (nil, ahead)
    }

    static func cost(_ message: BroadcastMessage) -> Int {
        message.data.count + message.topic.utf8.count + 64
    }
}

// MARK: - The ring

/// This process's side of the ring: the subscribers it holds, and the
/// thread that hands them what is published.
final class TopicBus: @unchecked Sendable {
    let handle: OpaquePointer
    let maxMessage: Int
    /// --broadcast-queue.
    let queueLimit: Int
    let byteLimit: Int

    private let lock = Mutex<Void>(())
    // Under `lock`.
    private var subscribers: [String: [SubscriptionState]] = [:]
    private var all: [ObjectIdentifier: SubscriptionState] = [:]
    private var slot: Int32 = -1
    private var listening = false
    /// When the listener, asleep, means to wake, in monotonic nanoseconds;
    /// 0 while it is awake.
    private var plannedWake: UInt64 = 0
    /// A wait with a deadline began since the listener last looked.
    private var deadlineAdded = false

    // The listener thread's.
    private var cursor: UInt64 = 0
    private var buffer: [UInt8]

    /// The ring in `region`, laid out as `regionSize` says.
    init?(region: UnsafeMutableRawBufferPointer, ringBytes: Int, slots: Int, queueLimit: Int) {
        guard let handle = gb_bus_attach(region.baseAddress, region.count, UInt64(ringBytes), UInt32(slots)) else {
            return nil
        }
        self.handle = handle
        maxMessage = Int(gb_bus_max_message(handle))
        self.queueLimit = max(1, queueLimit)
        // Room for that many of a few kilobytes each, and at least a few of
        // the largest.
        byteLimit = max(self.queueLimit * 4096, maxMessage * 4)
        buffer = [UInt8](repeating: 0, count: max(1, maxMessage))
    }

    static func regionSize(_ config: ServerConfig) -> Int? {
        guard config.broadcastSizeMiB > 0 else { return nil }
        return gb_bus_region_size(UInt64(config.broadcastSizeMiB) << 20, UInt32(slots(config)))
    }

    /// Twice as many as there are shards, so a shard and the replacement
    /// overlapping it each have their own, and a few to spare.
    static func slots(_ config: ServerConfig) -> Int {
        #if os(Windows)
        let cpus = 1
        #else
        let cpus = Int(sysconf(Int32(_SC_NPROCESSORS_CONF)))
        #endif
        return max(16, 2 * (config.shards ?? max(1, cpus)) + 4)
    }

    convenience init?(region: UnsafeMutableRawBufferPointer, config: ServerConfig) {
        self.init(region: region, ringBytes: config.broadcastSizeMiB << 20, slots: TopicBus.slots(config),
                  queueLimit: config.broadcastQueue)
    }

    // MARK: Which ring

    private enum Installed { case unset, off, on(TopicBus) }
    private static let installed = Mutex<Installed>(.unset)

    /// What `Topic` publishes into: the server's ring, or -- in a process
    /// that is not serving, a test's -- one of its own, made when first asked.
    static func current() throws(BroadcastError) -> TopicBus {
        let bus = installed.withLock { state -> TopicBus? in
            switch state {
            case .on(let bus): return bus
            case .off: return nil
            case .unset:
                let config = ServerConfig()
                guard let size = regionSize(config) else {
                    state = .off
                    return nil
                }
                let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 64)
                memory.initializeMemory(as: UInt8.self, repeating: 0)
                guard let bus = TopicBus(region: memory, config: config) else {
                    state = .off
                    return nil
                }
                state = .on(bus)
                return bus
            }
        }
        guard let bus else { throw .unavailable }
        return bus
    }

    /// The server's ring, or nil for --broadcast-size 0.
    static func install(_ bus: TopicBus?) {
        installed.withLock { $0 = bus.map { .on($0) } ?? .off }
    }

    // MARK: Publishing and reading

    func publish(_ topic: String, event: String?, _ bytes: [UInt8]) throws(BroadcastError) -> BroadcastID {
        var topic = topic
        var event = event ?? ""
        guard topic.utf8.count + event.utf8.count + bytes.count <= maxMessage else { throw .tooLarge }
        let sequence = topic.withUTF8 { t in
            event.withUTF8 { e in
                bytes.withUnsafeBufferPointer { d in
                    gb_bus_publish(handle, t.baseAddress, UInt32(t.count), e.baseAddress, UInt32(e.count),
                                   d.baseAddress, UInt32(d.count))
                }
            }
        }
        guard sequence != 0 else { throw .tooLarge }
        return BroadcastID(sequence)
    }

    enum Read { case message(BroadcastMessage), notYet, gone }

    /// Message `sequence`, copied out of the ring. Any thread.
    func read(_ sequence: UInt64) -> Read {
        var capacity = 4096
        while true {
            var out = gb_bus_message()
            var message: BroadcastMessage? = nil
            let rc = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity) { buffer -> Int32 in
                let rc = gb_bus_read(handle, sequence, buffer.baseAddress, UInt32(capacity), &out)
                if rc == 1 { message = TopicBus.message(out, UnsafeBufferPointer(buffer)) }
                return rc
            }
            switch rc {
            case 1: return .message(message!)
            case 0: return .notYet
            case -2: capacity = Int(out.data_len)
            default: return .gone
            }
        }
    }

    static func message(_ m: gb_bus_message, _ buffer: UnsafeBufferPointer<UInt8>) -> BroadcastMessage {
        let t = Int(m.topic_len)
        let e = Int(m.event_len)
        let base = buffer.baseAddress!
        let topic = String(decoding: UnsafeBufferPointer(start: base, count: t), as: UTF8.self)
        let event = e == 0 ? nil : String(decoding: UnsafeBufferPointer(start: base + t, count: e), as: UTF8.self)
        let data = Array(UnsafeBufferPointer(start: base + t + e, count: Int(m.data_len)))
        return BroadcastMessage(id: BroadcastID(m.sequence), topic: topic, event: event, data: data)
    }

    // MARK: Subscribing

    func subscribe(_ topics: [Topic], after: BroadcastID?,
                   alive: @escaping @Sendable () -> Bool) throws(BroadcastError) -> Subscription {
        var names: [String] = []
        for topic in topics where !names.contains(topic.name) { names.append(topic.name) }
        let start = try lock.withLock { _ throws(BroadcastError) -> Bool in
            if !listening {
                slot = gb_bus_claim_slot(handle)
                guard slot >= 0 else {
                    Log.error("every broadcast slot is taken; is another server sharing the ring?")
                    throw .unavailable
                }
                listening = true
                cursor = gb_bus_next(handle)
                return true
            }
            return false
        }
        if start {
            let context = Unmanaged.passRetained(self).toOpaque()
            guard gb_thread_start({ TopicBus.listen(Unmanaged<TopicBus>.fromOpaque($0!).takeRetainedValue()) },
                                  context) == 0 else {
                Unmanaged<TopicBus>.fromOpaque(context).release()
                Log.error("cannot start the broadcast listener")
                throw .unavailable
            }
        }
        // Numbers below this the listener may already be past: those come
        // out of the ring instead.
        let state = lock.withLock { _ -> SubscriptionState in
            let liveFrom = gb_bus_next(handle)
            let replayFrom = after.map { $0.rawValue &+ 1 } ?? liveFrom
            let state = SubscriptionState(topics: names, liveFrom: liveFrom,
                                          replayFrom: replayFrom == 0 ? liveFrom : min(replayFrom, liveFrom),
                                          alive: alive)
            for name in names { subscribers[name, default: []].append(state) }
            all[ObjectIdentifier(state)] = state
            return state
        }
        return Subscription(bus: self, state: state, topics: topics)
    }

    func remove(_ state: SubscriptionState) {
        lock.withLock { _ in
            guard all.removeValue(forKey: ObjectIdentifier(state)) != nil else { return }
            for name in state.topics {
                guard var list = subscribers[name], let at = list.firstIndex(where: { $0 === state }) else { continue }
                list.remove(at: at)
                subscribers[name] = list.isEmpty ? nil : list
            }
        }
    }

    /// A wait gives up at `deadline`: has the listener look by then.
    func wakeBy(_ deadline: UInt64) {
        let poke = lock.withLock { _ -> Bool in
            deadlineAdded = true
            guard deadline < plannedWake else { return false }
            plannedWake = 0
            return true
        }
        if poke { gb_bus_poke(handle, slot) }
    }

    // MARK: The listener

    /// How long the listener sleeps at most: how soon a subscriber that has
    /// gone, without anything published, is noticed.
    private static let sweepNanos: UInt64 = 250_000_000

    private static func listen(_ bus: TopicBus) {
        var sweepAt: UInt64 = 0
        while true {
            bus.deliver()
            let now = monotonicNanos()
            let added = bus.lock.withLock { _ in
                let added = bus.deadlineAdded
                bus.deadlineAdded = false
                return added
            }
            if added || now >= sweepAt {
                sweepAt = min(now &+ sweepNanos, bus.sweep(now: now))
            }
            if gb_bus_arm(bus.handle, bus.slot, bus.cursor) != 0 { continue }
            // A wait that began since the sweep is looked at first; one that
            // begins from here on pokes the slot if it is due sooner.
            let sleep = bus.lock.withLock { _ -> Bool in
                guard !bus.deadlineAdded else { return false }
                bus.plannedWake = sweepAt
                return true
            }
            guard sleep else { continue }
            let before = monotonicNanos()
            if sweepAt > before { gb_bus_wait(bus.handle, bus.slot, sweepAt - before) }
            bus.lock.withLock { _ in bus.plannedWake = 0 }
        }
    }

    /// Hands what has been published since the last look to the subscribers.
    private func deliver() {
        let next = gb_bus_next(handle)
        if lock.withLock({ _ in all.isEmpty }) {
            cursor = next
            return
        }
        var woken: [UnsafeContinuation<Void, Never>] = []
        while cursor < next {
            var out = gb_bus_message()
            let rc = buffer.withUnsafeMutableBufferPointer {
                gb_bus_read(handle, cursor, $0.baseAddress, UInt32($0.count), &out)
            }
            if rc == 1 {
                let topic = buffer.withUnsafeBufferPointer {
                    String(decoding: UnsafeBufferPointer(rebasing: $0[..<Int(out.topic_len)]), as: UTF8.self)
                }
                let sequence = cursor
                lock.withLock { _ in
                    guard let list = subscribers[topic] else { return }
                    var built: BroadcastMessage? = nil
                    for state in list where state.liveFrom <= sequence {
                        let message = built ?? buffer.withUnsafeBufferPointer { TopicBus.message(out, $0) }
                        built = message
                        if let w = state.enqueue(.message(message), limit: queueLimit, byteLimit: byteLimit) {
                            woken.append(w)
                        }
                    }
                }
                cursor += 1
            } else if rc == 0 {
                break
            } else {
                // This shard fell further behind than the ring holds. Every
                // subscriber has missed whatever was on its topics.
                let sequence = cursor
                lock.withLock { _ in
                    for state in all.values where state.liveFrom <= sequence {
                        if let w = state.enqueue(.missed, limit: queueLimit, byteLimit: byteLimit) {
                            woken.append(w)
                        }
                    }
                }
                cursor = max(cursor + 1, min(gb_bus_oldest(handle), next))
            }
        }
        for w in woken { w.resume() }
    }

    /// Ends waits that are due or whose subscribers have gone; returns the
    /// nearest deadline still ahead.
    private func sweep(now: UInt64) -> UInt64 {
        let states = lock.withLock { _ in Array(all.values) }
        var nearest = UInt64.max
        for state in states {
            let (w, deadline) = state.sweep(now: now)
            if let w { w.resume() } else if deadline != 0 { nearest = min(nearest, deadline) }
        }
        return nearest
    }
}

// MARK: - Subscribing

extension Response {
    /// Subscribes to `topics`: a long poll, or a stream written some other
    /// way. With `after`, messages published since that one are delivered
    /// first, as far as the ring still holds them. Lasts until cancelled or
    /// let go of.
    public func subscribe(_ topics: Topic..., after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try TopicBus.current().subscribe(topics, after: after) { true }
    }
}

extension EventSink {
    /// Subscribes the stream to `topics`. With `after` -- a reconnecting
    /// client's Last-Event-ID -- what was published since is delivered first.
    /// Its waits throw once the stream has ended.
    public func subscribe(_ topics: Topic..., after: LastEventID = LastEventID(nil)) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: LastEventID = LastEventID(nil)) throws(BroadcastError) -> Subscription {
        let channel = body.channel
        return try TopicBus.current().subscribe(topics, after: after.broadcastID) { channel.isOpen }
    }

    /// Sends a published message as an event: its number as the `id`, its
    /// event name as the `event`, its data as text.
    public func send(_ message: BroadcastMessage) async throws(HandlerWaitError) {
        try await send(message.text, event: message.event, id: message.id.description)
    }

    /// Sends every message published on `topics` as an event, until the
    /// client goes away, when it throws. A reconnecting client's
    /// Last-Event-ID, passed as `after`, has it sent what it missed first.
    ///
    /// A gap -- messages this stream will not be sent -- goes to `onMissed`,
    /// which by default sends an event named `missed`, so the client can load
    /// afresh whatever the messages were keeping current.
    public func forward(_ topics: Topic..., after: LastEventID = LastEventID(nil),
                        onMissed: (@Sendable (EventSink) async throws -> Void)? = nil) async throws {
        let subscription = try subscribe(topics, after: after)
        defer { subscription.cancel() }
        while true {
            switch try await subscription.next() {
            case .message(let message):
                try await send(message)
            case .missed:
                if let onMissed {
                    try await onMissed(self)
                } else {
                    try await send("missed", event: "missed")
                }
            }
        }
    }
}

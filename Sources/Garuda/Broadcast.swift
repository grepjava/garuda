//===----------------------------------------------------------------------===//
// Broadcast: messages published on any worker, heard on every worker.
//
//     struct Said: Codable { var text: String }
//     let lobby = Topic("room/lobby")
//
//     app.post("/say") { (said: Body<Said>) in
//         try lobby.publish(said.value.text, event: "said")
//         return HTTPStatus.noContent
//     }
//
//     app.get("/events") { (last: LastEventID) async in
//         EventStream { events in
//             try await events.forward(lobby, after: last)
//         }
//     }
//
//     app.webSocket("/chat") { (ws: WebSocket) async throws in
//         let messages = try ws.subscribe(lobby)
//         while true {
//             if case .message(let m) = try await messages.next() { try await ws.send(m.text) }
//         }
//     }
//
// Workers are processes, and the clients of one topic are spread across all of
// them, so a message goes through the ring every worker maps (avian_bus.h,
// `--broadcast-size`). The worker that published it reads it back like every
// other, and each hands it to the subscribers it holds.
//
// Every message has a number, which rises by one per message and is the `id`
// of the event `forward` sends. A client that reconnects with it as
// Last-Event-ID is sent what it missed, from the ring, on whichever worker it
// lands on -- as far back as the ring still holds. A gap the ring cannot fill,
// and messages a subscriber fell too far behind to keep, arrive as `.missed`
// in their place, so the application can start that client over rather than
// have it silently diverge.
//
// A subscription belongs to the request or WebSocket it was made from, and
// ends with it: its waits throw once the client has gone, and the worker
// forgets it. A subscriber waits on the worker's own loop, as every other wait
// on the engine does, and only one wait at a time per request.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// A named stream of messages. Anyone may publish on it and any request or
/// WebSocket may subscribe to it, on any worker.
public struct Topic: Sendable, Hashable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// Publishes `text` to every subscriber, on every worker, and returns its
    /// number. `event` names the kind of message, as an event stream's
    /// `event:` field does.
    @discardableResult
    public func publish(_ text: String, event: String? = nil) throws(BroadcastError) -> BroadcastID {
        try publish(Array(text.utf8), event: event)
    }

    /// Publishes `bytes` to every subscriber, on every worker.
    @discardableResult
    public func publish(_ bytes: [UInt8], event: String? = nil) throws(BroadcastError) -> BroadcastID {
        guard av_bus_enabled() != 0 else { throw .unavailable }
        var name = self.name
        var event = event ?? ""
        guard name.utf8.count + event.utf8.count + bytes.count <= Int(av_bus_max_message()) else {
            throw .tooLarge
        }
        // A publisher on a worker's thread reads the ring there next, without
        // a wake; one anywhere else -- a blocking pool thread -- is woken like
        // any other worker.
        let worker = currentWorker
        let sequence = name.withUTF8 { t in
            event.withUTF8 { e in
                bytes.withUnsafeBufferPointer { d in
                    av_bus_publish(t.baseAddress, UInt32(t.count), e.baseAddress, UInt32(e.count),
                                   d.baseAddress, UInt32(d.count), worker == nil ? 1 : 0)
                }
            }
        }
        guard sequence != 0 else { throw .tooLarge }
        worker?.pointee.broadcastPending = true
        return BroadcastID(sequence)
    }
}

/// A message's number: rising by one per message, across every topic and
/// every worker, and above every number a server started earlier gave out.
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
    /// fell behind by more than `--broadcast-queue`, its worker fell behind by
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

/// Messages on some topics, for as long as the request or WebSocket that
/// subscribed lasts, or until `cancel`.
public final class Subscription: @unchecked Sendable {
    enum Owner {
        case request(slot: Int, generation: UInt32, requestId: UInt32)
        case webSocket(WSChannel)
    }

    let worker: UnsafeMutablePointer<Worker>
    let owner: Owner
    public let topics: [Topic]
    /// Messages from this number on are delivered as they are published;
    /// those before it, from `replayNext`, are read back out of the ring.
    let liveFrom: UInt64
    var replayNext: UInt64
    var queue: [BroadcastEvent] = []
    var queueHead = 0
    var queuedBytes = 0
    /// The timed wait a WebSocket's subscriber is parked in, or -1.
    var waitID: Int32 = -1
    /// Whether a request's task is parked on its slot for this subscription.
    var waitingTask = false
    var wakeQueued = false
    public private(set) var isCancelled = false

    init(worker: UnsafeMutablePointer<Worker>, owner: Owner, topics: [Topic],
         liveFrom: UInt64, replayFrom: UInt64) {
        self.worker = worker
        self.owner = owner
        self.topics = topics
        self.liveFrom = liveFrom
        replayNext = replayFrom
    }

    /// The next message, or `.missed`, waiting for one to be published.
    /// Throws once the request or WebSocket has ended, or the subscription
    /// has been cancelled.
    public func next() async throws -> BroadcastEvent {
        while true {
            if let event = try await next(timeoutMilliseconds: 3_600_000) { return event }
        }
    }

    /// The next message, or `.missed`, waiting at most `milliseconds` for one.
    /// Nil when none came in time.
    public func next(timeoutMilliseconds milliseconds: UInt64) async throws -> BroadcastEvent? {
        onWorker()
        try checkOwner()
        if let event = take() { return event }
        try await wait(milliseconds)
        try checkOwner()
        return take()
    }

    /// Stops delivery. Messages already queued are dropped, and a wait in
    /// progress throws `CancellationError`.
    public func cancel() {
        onWorker()
        guard !isCancelled else { return }
        isCancelled = true
        worker.pointee.broadcast?.remove(self)
        queue.removeAll()
        queueHead = 0
        queuedBytes = 0
        wake()
    }

    /// Whether whoever subscribed is still there to be given messages.
    var isLive: Bool {
        if isCancelled { return false }
        switch owner {
        case .request(let slot, let generation, let requestId):
            return worker.pointee.stillHolds(slot, generation: generation, requestId: requestId)
        case .webSocket(let channel):
            return !channel.gone
        }
    }

    func matches(_ topic: String) -> Bool {
        topics.contains { $0.name == topic }
    }

    private func checkOwner() throws {
        if isCancelled { throw CancellationError() }
        switch owner {
        case .request(let slot, let generation, let requestId):
            if !worker.pointee.stillHolds(slot, generation: generation, requestId: requestId) {
                throw HandlerWaitError.cancelled
            }
        case .webSocket(let channel):
            if channel.gone { throw WebSocketError.closed }
        }
    }

    /// What is next without waiting: messages read back from the ring first,
    /// then those delivered since subscribing.
    private func take() -> BroadcastEvent? {
        if replayNext < liveFrom, let hub = worker.pointee.broadcast, let event = replay(hub) {
            return event
        }
        guard queueHead < queue.count else { return nil }
        let event = queue[queueHead]
        queueHead += 1
        if case .message(let message) = event { queuedBytes -= Subscription.cost(message) }
        if queueHead == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
        } else if queueHead >= 64 && queueHead * 2 >= queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
        return event
    }

    private func replay(_ hub: BroadcastHub) -> BroadcastEvent? {
        while replayNext < liveFrom {
            let oldest = av_bus_oldest()
            if replayNext < oldest {
                replayNext = min(oldest, liveFrom)
                return .missed
            }
            var message = av_bus_message()
            let rc = hub.read(replayNext, &message)
            if rc == 1 {
                replayNext += 1
                let topic = hub.topic(message)
                if matches(topic) { return .message(hub.message(message, topic: topic)) }
            } else if rc == 0 {
                replayNext = liveFrom
            } else {
                // Written over since `oldest` was read.
                replayNext = max(replayNext + 1, min(av_bus_oldest(), liveFrom))
                return .missed
            }
        }
        return nil
    }

    /// Queues `event` for the subscriber, and says whether it is waiting to
    /// be woken for it.
    func enqueue(_ event: BroadcastEvent, limit: Int) -> Bool {
        let pending = queue.count - queueHead
        let lastMissed = pending > 0 && queue[queue.count - 1] == .missed
        switch event {
        case .missed:
            if lastMissed { return false }
            queue.append(.missed)
        case .message(let message):
            let cost = Subscription.cost(message)
            if pending >= limit || queuedBytes + cost > Subscription.byteLimit(limit) {
                if lastMissed { return false }
                queue.append(.missed)
            } else {
                queue.append(event)
                queuedBytes += cost
            }
        }
        return waitID >= 0 || waitingTask
    }

    static func cost(_ message: BroadcastMessage) -> Int {
        message.data.count + message.topic.utf8.count + 64
    }

    /// A queue of `limit` messages may hold this many bytes: room for that
    /// many of a few kilobytes each, and at least a few of the largest.
    static func byteLimit(_ limit: Int) -> Int {
        max(limit * 4096, Int(av_bus_max_message()) * 4)
    }

    /// Ends the subscriber's wait, if it is in one. It runs when the worker
    /// next drains its tasks.
    func wake() {
        if waitID >= 0 {
            let id = waitID
            waitID = -1
            worker.pointee.wakeTimed(id)
        } else if waitingTask, case .request(let slot, let generation, let requestId) = owner {
            waitingTask = false
            worker.pointee.wakeTaskWait(slot, generation: generation, requestId: requestId)
        }
    }

    private func wait(_ milliseconds: UInt64) async throws {
        switch owner {
        case .request(let slot, let generation, let requestId):
            let worker = self.worker
            let index = try worker.pointee.armTaskWait(slot, generation: generation,
                                                       requestId: requestId,
                                                       milliseconds: milliseconds)
            waitingTask = true
            let completed = await withUnsafeContinuation {
                worker.pointee.handlerTasks!.park(index, $0)
            }
            waitingTask = false
            if !completed { throw HandlerWaitError.cancelled }
        case .webSocket(let channel):
            try Task.checkCancellation()
            var id: Int32 = -1
            let outcome = await Worker.waitTimed(worker, milliseconds: milliseconds) { registered in
                id = registered
                self.waitID = registered
                channel.sleeps.append(registered)
            }
            waitID = -1
            channel.sleeps.removeAll { $0 == id }
            if outcome == .cancelled || channel.gone { throw WebSocketError.closed }
        }
    }

    @inline(__always)
    private func onWorker() {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a subscription was used off its worker's thread; use a task group, not Task { }")
    }
}

/// A worker's side of the ring: where it has read to, and who it reads for.
final class BroadcastHub {
    let fd: Int32
    /// The number of the next message this worker has yet to deliver.
    var cursor: UInt64
    var subscribers: [String: [Subscription]] = [:]
    var count = 0
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int

    init(fd: Int32) {
        self.fd = fd
        cursor = av_bus_next()
        capacity = max(1, Int(av_bus_max_message()))
        buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    func read(_ sequence: UInt64, _ message: inout av_bus_message) -> Int32 {
        av_bus_read(sequence, buffer, UInt32(capacity), &message)
    }

    func topic(_ message: av_bus_message) -> String {
        String(decoding: UnsafeBufferPointer(start: buffer, count: Int(message.topic_len)), as: UTF8.self)
    }

    func message(_ message: av_bus_message, topic: String) -> BroadcastMessage {
        let t = Int(message.topic_len)
        let e = Int(message.event_len)
        let event = e == 0 ? nil
            : String(decoding: UnsafeBufferPointer(start: buffer + t, count: e), as: UTF8.self)
        let data = Array(UnsafeBufferPointer(start: buffer + t + e, count: Int(message.data_len)))
        return BroadcastMessage(id: BroadcastID(message.sequence), topic: topic, event: event, data: data)
    }

    func add(_ subscription: Subscription) {
        var seen: [String] = []
        for topic in subscription.topics where !seen.contains(topic.name) {
            seen.append(topic.name)
            subscribers[topic.name, default: []].append(subscription)
        }
        count += 1
    }

    func remove(_ subscription: Subscription) {
        var found = false
        var seen: [String] = []
        for topic in subscription.topics where !seen.contains(topic.name) {
            seen.append(topic.name)
            guard var list = subscribers[topic.name],
                  let at = list.firstIndex(where: { $0 === subscription }) else { continue }
            found = true
            list.remove(at: at)
            subscribers[topic.name] = list.isEmpty ? nil : list
        }
        if found { count -= 1 }
    }
}

extension Worker {
    /// The worker's side of the ring, attached the first time something
    /// subscribes.
    mutating func broadcastHub() throws(BroadcastError) -> BroadcastHub {
        if let hub = broadcast { return hub }
        guard av_bus_enabled() != 0 else { throw .unavailable }
        let fd = av_bus_attach(UInt32(busSlot))
        guard fd >= 0 else {
            Log.error("cannot attach to the broadcast ring")
            throw .unavailable
        }
        // A test client turns the loop itself and looks at the ring each turn.
        if pollsBroadcast {
            guard poller.add(fd, .read, token: PollToken.broadcast) else {
                Log.error("cannot watch the broadcast ring")
                throw .unavailable
            }
        }
        let hub = BroadcastHub(fd: fd)
        broadcast = hub
        return hub
    }

    static func subscribe(_ worker: UnsafeMutablePointer<Worker>, _ topics: [Topic],
                          owner: Subscription.Owner, after: BroadcastID?) throws(BroadcastError) -> Subscription {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "subscribe was called off the worker's thread")
        let hub = try worker.pointee.broadcastHub()
        let liveFrom = av_bus_next()
        if hub.count == 0 { hub.cursor = liveFrom }
        let replayFrom = after.map { $0.rawValue &+ 1 } ?? liveFrom
        let subscription = Subscription(worker: worker, owner: owner, topics: topics,
                                        liveFrom: liveFrom,
                                        replayFrom: replayFrom == 0 ? liveFrom : min(replayFrom, liveFrom))
        hub.add(subscription)
        if av_bus_arm(hub.cursor) != 0 { worker.pointee.broadcastPending = true }
        return subscription
    }

    /// The ring's descriptor became readable.
    mutating func handleBroadcastWake() {
        av_bus_clear()
        deliverBroadcasts()
    }

    /// Hands what has been published since the last look to this worker's
    /// subscribers, and wakes those waiting.
    mutating func deliverBroadcasts() {
        broadcastPending = false
        guard let hub = broadcast else { return }
        if hub.count == 0 {
            hub.cursor = av_bus_next()
            return
        }
        var woken: [Subscription] = []
        var stale: [Subscription] = []
        let limit = config.broadcastQueue
        while true {
            let next = av_bus_next()
            while hub.cursor < next {
                var message = av_bus_message()
                let rc = hub.read(hub.cursor, &message)
                if rc == 1 {
                    let topic = hub.topic(message)
                    if let list = hub.subscribers[topic] {
                        var built: BroadcastMessage? = nil
                        for subscription in list where subscription.liveFrom <= hub.cursor {
                            guard subscription.isLive else {
                                stale.append(subscription)
                                continue
                            }
                            let delivered = built ?? hub.message(message, topic: topic)
                            built = delivered
                            if subscription.enqueue(.message(delivered), limit: limit) && !subscription.wakeQueued {
                                subscription.wakeQueued = true
                                woken.append(subscription)
                            }
                        }
                    }
                    hub.cursor += 1
                } else if rc == 0 {
                    break
                } else {
                    // This worker fell further behind than the ring holds.
                    // Every subscriber has missed whatever was on its topics.
                    for (_, list) in hub.subscribers {
                        for subscription in list where subscription.liveFrom <= hub.cursor {
                            if subscription.enqueue(.missed, limit: limit) && !subscription.wakeQueued {
                                subscription.wakeQueued = true
                                woken.append(subscription)
                            }
                        }
                    }
                    hub.cursor = max(hub.cursor + 1, min(av_bus_oldest(), next))
                }
            }
            if av_bus_arm(hub.cursor) == 0 { break }
        }
        for subscription in stale { hub.remove(subscription) }
        for subscription in woken {
            subscription.wakeQueued = false
            subscription.wake()
        }
        if !woken.isEmpty { runHandlerTasks() }
    }

    /// Ends a request task's wait on its slot early, as its timer would have.
    mutating func wakeTaskWait(_ slot: Int, generation: UInt32, requestId: UInt32) {
        let c = table[slot]
        guard c.pointee.state != .free, c.pointee.generation == generation,
              c.pointee.requestId == requestId, c.pointee.contKind == .task,
              c.pointee.contState == .waiting, c.pointee.contTask >= 0 else { return }
        let opIndex = Int(c.pointee.contOp)
        if opIndex >= 0 && opIndex < asyncOps.capacity {
            let op = asyncOps[opIndex]
            if Int(op.pointee.slot) == slot && op.pointee.generation == c.pointee.contOpGeneration {
                timerHeap.remove(opIndex: opIndex, from: &asyncOps)
                asyncOps.free(opIndex)
            }
        }
        c.pointee.contOp = -1
        c.pointee.contState = .none
        handlerTasks?.resume(Int(c.pointee.contTask))
    }
}

// MARK: - Subscribing

extension Response {
    /// Subscribes the request to `topics`, for as long as it lasts: a long
    /// poll, or a stream written some other way. With `after`, messages
    /// published since that one are delivered first, as far as the ring
    /// still holds them.
    public func subscribe(_ topics: Topic..., after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try Worker.subscribe(worker, topics,
                             owner: .request(slot: slot, generation: generation, requestId: requestId),
                             after: after)
    }
}

extension EventSink {
    /// Subscribes the stream to `topics`. With `after` -- a reconnecting
    /// client's Last-Event-ID -- what was published since is delivered first.
    public func subscribe(_ topics: Topic..., after: LastEventID = LastEventID(nil)) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: LastEventID = LastEventID(nil)) throws(BroadcastError) -> Subscription {
        try Worker.subscribe(body.worker, topics,
                             owner: .request(slot: body.slot, generation: body.generation,
                                             requestId: body.requestId),
                             after: after.broadcastID)
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
                        onMissed: ((EventSink) async throws -> Void)? = nil) async throws {
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

extension WebSocket {
    /// Subscribes the WebSocket to `topics`, until it closes. With `after`,
    /// messages published since that one are delivered first.
    public func subscribe(_ topics: Topic..., after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        try subscribe(topics, after: after)
    }

    public func subscribe(_ topics: [Topic], after: BroadcastID? = nil) throws(BroadcastError) -> Subscription {
        onWorker()
        return try Worker.subscribe(worker, topics, owner: .webSocket(channel), after: after)
    }
}

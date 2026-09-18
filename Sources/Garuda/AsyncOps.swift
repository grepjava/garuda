//===----------------------------------------------------------------------===//
// Worker-owned async substrate: pooled ops, timer heap, ready queue.
//
// Sync dispatch stays a normal call. When a handler must wait, it arms an op
// on this pool and parks a small continuation on the connection slot. Resume
// requires matching requestId (and op generation): connection generation alone
// is not enough across keep-alive.
//
// No Task, no work-stealing. One worker thread owns every op for its life.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

public enum ContState: UInt8 {
    case none
    case waiting
    case ready
}

public enum ContKind: UInt8 {
    case none
    /// Resumes by calling the handler stored in `Connection.contHandler`.
    case handler
    /// The request belongs to an async handler's task (HandlerTasks.swift):
    /// running on it, waiting on the engine for it, or queued for one.
    case task
}

public enum OpKind: UInt8 {
    case timer
    /// A route's deadline for the whole request, armed at dispatch. It is not
    /// the request's continuation -- the handler may be running, or waiting on
    /// a timer of its own -- so it is reached through `Connection.deadlineOp`
    /// rather than `contOp`, and `completeTimerOp` has to recognise it before
    /// deciding there is nothing to resume.
    case deadline
    /// Bounds an outbound connection coming up (Outbound.swift). Its `slot` is
    /// an index into the outbound table, not the connection table, so it has
    /// to be recognised before anything reads a connection with it.
    case outbound
    /// Bounds a `Worker.waitTimed` (TimedWait.swift). Its `slot` is the
    /// wait's id, not a connection.
    case timedWait
}

public struct AsyncOp {
    public var nextFree: Int32 = -1
    public var generation: UInt32 = 0
    public var slot: Int32 = -1
    public var requestId: UInt32 = 0
    public var kind: OpKind = .timer
    /// `av_monotonic_us`. Not the coarse millisecond clock: a deadline taken
    /// from a reading up to a tick stale can expire up to a tick early.
    public var deadlineUs: UInt64 = 0
    public var cancelled = false
    /// Index in the timer heap, or -1 when not armed as a timer.
    public var heapIndex: Int32 = -1

    @inlinable public init() {}
}

/// Bounded free-list slab of async operations, one per worker.
public struct AsyncOpPool {
    @usableFromInline var slots: UnsafeMutablePointer<AsyncOp>
    public let capacity: Int
    @usableFromInline var firstFree: Int32
    public private(set) var liveCount: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots = UnsafeMutablePointer<AsyncOp>.allocate(capacity: capacity)
        slots.initialize(repeating: AsyncOp(), count: capacity)
        var i = 0
        while i < capacity {
            slots[i].nextFree = Int32(i + 1 < capacity ? i + 1 : -1)
            i += 1
        }
        firstFree = 0
    }

    @inlinable
    public subscript(index: Int) -> UnsafeMutablePointer<AsyncOp> {
        slots + index
    }

    public mutating func allocate(slot: Int, requestId: UInt32, kind: OpKind,
                                  deadlineUs: UInt64) -> (index: Int, generation: UInt32)? {
        let index = Int(firstFree)
        if index < 0 { return nil }
        firstFree = slots[index].nextFree
        slots[index].nextFree = -1
        slots[index].generation &+= 1
        slots[index].slot = Int32(slot)
        slots[index].requestId = requestId
        slots[index].kind = kind
        slots[index].deadlineUs = deadlineUs
        slots[index].cancelled = false
        slots[index].heapIndex = -1
        liveCount += 1
        return (index, slots[index].generation)
    }

    public mutating func free(_ index: Int) {
        precondition(index >= 0 && index < capacity)
        slots[index].slot = -1
        slots[index].requestId = 0
        slots[index].cancelled = true
        slots[index].heapIndex = -1
        slots[index].deadlineUs = 0
        slots[index].nextFree = firstFree
        firstFree = Int32(index)
        liveCount -= 1
    }

    /// Marks the op cancelled if generation still matches. Does not free it;
    /// the completer or cancelOps path frees after unlinking from the heap.
    @discardableResult
    public mutating func cancel(index: Int, generation: UInt32) -> Bool {
        guard index >= 0 && index < capacity else { return false }
        let op = slots + index
        guard op.pointee.generation == generation, op.pointee.slot >= 0 else { return false }
        op.pointee.cancelled = true
        return true
    }

    public func destroy() {
        slots.deallocate()
    }
}

/// Min-heap of timer deadlines. Entries carry op index + generation so a
/// recycled op cannot be fired from a stale heap node.
public struct TimerHeap {
    public struct Entry {
        public var deadlineUs: UInt64
        public var opIndex: Int32
        public var opGeneration: UInt32
    }

    @usableFromInline var storage: UnsafeMutablePointer<Entry>
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = UnsafeMutablePointer<Entry>.allocate(capacity: capacity)
    }

    public var isEmpty: Bool { count == 0 }

    public var nextDeadlineUs: UInt64? {
        count > 0 ? storage[0].deadlineUs : nil
    }

    public mutating func push(_ entry: Entry, into pool: inout AsyncOpPool) {
        precondition(count < capacity)
        var i = count
        count += 1
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[parent].deadlineUs <= entry.deadlineUs { break }
            storage[i] = storage[parent]
            pool[Int(storage[i].opIndex)].pointee.heapIndex = Int32(i)
            i = parent
        }
        storage[i] = entry
        pool[Int(entry.opIndex)].pointee.heapIndex = Int32(i)
    }

    /// Removes the heap entry for this op if it is still linked.
    public mutating func remove(opIndex: Int, from pool: inout AsyncOpPool) {
        let op = pool[opIndex]
        let hi = Int(op.pointee.heapIndex)
        if hi < 0 || hi >= count { return }
        op.pointee.heapIndex = -1
        count -= 1
        if hi == count { return }
        let moved = storage[count]
        storage[hi] = moved
        pool[Int(moved.opIndex)].pointee.heapIndex = Int32(hi)
        siftDown(hi, pool: &pool)
        siftUp(hi, pool: &pool)
    }

    public mutating func popDue(nowUs: UInt64, from pool: inout AsyncOpPool) -> Entry? {
        while count > 0 {
            let top = storage[0]
            if top.deadlineUs > nowUs { return nil }
            let op = pool[Int(top.opIndex)]
            // Stale heap node: op was recycled or unlinked.
            if op.pointee.heapIndex != 0
                || op.pointee.generation != top.opGeneration
                || op.pointee.slot < 0 {
                removeRoot(pool: &pool)
                continue
            }
            op.pointee.heapIndex = -1
            removeRoot(pool: &pool)
            return top
        }
        return nil
    }

    private mutating func removeRoot(pool: inout AsyncOpPool) {
        count -= 1
        if count == 0 { return }
        storage[0] = storage[count]
        pool[Int(storage[0].opIndex)].pointee.heapIndex = 0
        siftDown(0, pool: &pool)
    }

    private mutating func siftUp(_ start: Int, pool: inout AsyncOpPool) {
        var i = start
        let entry = storage[i]
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[parent].deadlineUs <= entry.deadlineUs { break }
            storage[i] = storage[parent]
            pool[Int(storage[i].opIndex)].pointee.heapIndex = Int32(i)
            i = parent
        }
        storage[i] = entry
        pool[Int(entry.opIndex)].pointee.heapIndex = Int32(i)
    }

    private mutating func siftDown(_ start: Int, pool: inout AsyncOpPool) {
        var i = start
        let entry = storage[i]
        while true {
            let left = i * 2 + 1
            if left >= count { break }
            var child = left
            let right = left + 1
            if right < count && storage[right].deadlineUs < storage[left].deadlineUs {
                child = right
            }
            if storage[child].deadlineUs >= entry.deadlineUs { break }
            storage[i] = storage[child]
            pool[Int(storage[i].opIndex)].pointee.heapIndex = Int32(i)
            i = child
        }
        storage[i] = entry
        pool[Int(entry.opIndex)].pointee.heapIndex = Int32(i)
    }

    public func destroy() {
        storage.deallocate()
    }
}

// MARK: - Worker integration

/// A continuation made runnable. The slot alone is not an identity: the entry
/// may outlive its request, so it records who it was queued for.
public struct ReadyEntry {
    public var slot: Int32
    public var generation: UInt32
    public var requestId: UInt32
    /// Which ready transition queued it. A request armed again after becoming
    /// ready keeps its slot, generation and request id, so without this two
    /// entries could both claim it.
    public var ticket: UInt32
}

extension ReadyEntry {
    /// Whether the entry still names its connection's current ready
    /// continuation. At most one queued entry per slot can.
    @inline(__always)
    func isRunnable(in table: ConnectionTable) -> Bool {
        let c = table[Int(slot)]
        return c.pointee.state != .free
            && c.pointee.generation == generation
            && c.pointee.requestId == requestId
            && c.pointee.contState == .ready
            && c.pointee.contTicket == ticket
    }
}

/// Bounded FIFO of runnable continuations. One worker owns it and only that
/// thread touches it, so there is nothing atomic here. Capacity is a power of
/// two so the indices wrap with a mask.
public struct ReadyQueue {
    var storage: UnsafeMutablePointer<ReadyEntry>
    public let capacity: Int
    let mask: Int
    var head = 0
    public private(set) var count = 0

    public init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = UnsafeMutablePointer<ReadyEntry>.allocate(capacity: size)
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == capacity }

    /// The entry `position` places behind the head.
    public subscript(position: Int) -> ReadyEntry {
        precondition(position >= 0 && position < count)
        return storage[(head &+ position) & mask]
    }

    /// Appends at the tail. False when full.
    public mutating func push(_ entry: ReadyEntry) -> Bool {
        if count == capacity { return false }
        storage[(head &+ count) & mask] = entry
        count += 1
        return true
    }

    public mutating func pop() -> ReadyEntry? {
        if count == 0 { return nil }
        let entry = storage[head]
        head = (head &+ 1) & mask
        count -= 1
        return entry
    }

    /// Drops the entries `keep` rejects, in place and in order. Linear in
    /// `count`, so it is for a full queue, not the steady state.
    @discardableResult
    public mutating func compact(keeping keep: (ReadyEntry) -> Bool) -> Int {
        var kept = 0
        var i = 0
        while i < count {
            let entry = storage[(head &+ i) & mask]
            if keep(entry) {
                storage[(head &+ kept) & mask] = entry
                kept += 1
            }
            i += 1
        }
        let removed = count - kept
        count = kept
        return removed
    }

    public func destroy() {
        storage.deallocate()
    }
}

extension Worker {
    mutating func clearContinuation(_ slot: Int) {
        cancelOps(slot: slot)
    }

    /// Cancels and frees the op this connection slot is parked on.
    ///
    /// Runs on every request start and keep-alive completion, so it must not
    /// depend on pool capacity: a request holds at most one op, reached through
    /// `contOp`. Supporting several ops per request means a per-request op
    /// list, not a pool scan.
    mutating func cancelOps(slot: Int) {
        let c = table[slot]
        let opIndex = Int(c.pointee.contOp)
        if opIndex >= 0 && opIndex < asyncOps.capacity {
            let op = asyncOps[opIndex]
            if Int(op.pointee.slot) == slot
                && op.pointee.generation == c.pointee.contOpGeneration {
                timerHeap.remove(opIndex: opIndex, from: &asyncOps)
                asyncOps.free(opIndex)
            }
        }
        // Only a handler continuation holds a closure, and only a task one a
        // task, so a request that never waited releases nothing here.
        if c.pointee.contKind == .handler {
            c.pointee.contHandler = nil
        } else if c.pointee.contKind == .task {
            cancelTask(slot)
        }
        // The writers waiting for room in a response that is over, and the
        // handlers waiting to hear that it is over.
        wakeWriters(slot, drained: false)
        wakeCancelWaiters(slot)
        c.pointee.contOp = -1
        c.pointee.contState = .none
        c.pointee.contKind = .none
    }

    /// Arms a timer op and parks the connection continuation. Returns false
    /// when the op pool is exhausted.
    @discardableResult
    mutating func armDelay(_ slot: Int, ms: UInt64, kind: ContKind = .handler) -> Bool {
        clearContinuation(slot)
        return armTimer(slot, ms: ms, kind: kind)
    }

    /// Arms a timer op without clearing the continuation first, which a task
    /// keeps across its wait. Returns false when the op pool is exhausted.
    mutating func armTimer(_ slot: Int, ms: UInt64, kind: ContKind) -> Bool {
        let c = table[slot]
        // The clock reads truncated microseconds; one more keeps the deadline
        // from landing before the full duration.
        let deadline = av_monotonic_us() &+ 1 &+ max(1, ms) &* 1000
        guard let (index, generation) = asyncOps.allocate(
            slot: slot, requestId: c.pointee.requestId, kind: .timer,
            deadlineUs: deadline) else {
            return false
        }
        timerHeap.push(
            TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(index),
                            opGeneration: generation),
            into: &asyncOps)
        c.pointee.contState = .waiting
        c.pointee.contKind = kind
        c.pointee.contOp = Int32(index)
        c.pointee.contOpGeneration = generation
        return true
    }

    /// Arms a route's deadline for the request on `slot`, beside whatever the
    /// handler goes on to wait for itself. It is deliberately not the
    /// request's continuation: the handler may be running, or parked on a
    /// timer of its own, and the deadline has to outlast either.
    ///
    /// A full op pool arms nothing and says nothing. A deadline is a safety
    /// net, and refusing to serve a request because the net could not be hung
    /// would be a worse failure than the one it guards against.
    mutating func armDeadline(_ slot: Int, ms: UInt64) {
        disarmDeadline(slot)
        let c = table[slot]
        let deadline = av_monotonic_us() &+ 1 &+ max(1, ms) &* 1000
        guard let (index, generation) = asyncOps.allocate(
            slot: slot, requestId: c.pointee.requestId, kind: .deadline,
            deadlineUs: deadline) else {
            return
        }
        timerHeap.push(
            TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(index),
                            opGeneration: generation),
            into: &asyncOps)
        c.pointee.deadlineOp = Int32(index)
        c.pointee.deadlineOpGeneration = generation
    }

    /// Frees the deadline op for `slot`, if it still owns one. Runs at every
    /// request boundary: a deadline belongs to one request, and an op left
    /// armed would fire into whatever took the slot next.
    mutating func disarmDeadline(_ slot: Int) {
        let c = table[slot]
        let index = Int(c.pointee.deadlineOp)
        let generation = c.pointee.deadlineOpGeneration
        c.pointee.deadlineOp = -1
        c.pointee.deadlineOpGeneration = 0
        guard index >= 0 && index < asyncOps.capacity else { return }
        let op = asyncOps[index]
        guard Int(op.pointee.slot) == slot, op.pointee.generation == generation else { return }
        timerHeap.remove(opIndex: index, from: &asyncOps)
        asyncOps.free(index)
    }

    mutating func fireDueTimers() {
        let now = av_monotonic_us()
        while let entry = timerHeap.popDue(nowUs: now, from: &asyncOps) {
            completeTimerOp(index: Int(entry.opIndex), generation: entry.opGeneration)
        }
    }

    mutating func completeTimerOp(index: Int, generation: UInt32) {
        guard index >= 0 && index < asyncOps.capacity else { return }
        let op = asyncOps[index]
        guard op.pointee.generation == generation, op.pointee.slot >= 0 else { return }
        let slot = Int(op.pointee.slot)
        let requestId = op.pointee.requestId
        let cancelled = op.pointee.cancelled
        // Read before the op is freed and recycled under us.
        let kind = op.pointee.kind
        asyncOps.free(index)

        if cancelled { return }
        if kind == .timedWait {
            timedWaitExpired(Int32(slot))
            return
        }
        if kind == .outbound {
            // `slot` indexes the outbound table. Reading a connection with it
            // would be reading an unrelated request.
            //
            // The handle goes first: this op has just been freed, and `free`
            // does not bump its generation, so a disarm still holding this
            // index would match and free it a second time.
            if let table = outbound, slot >= 0, slot < table.capacity {
                table[slot].pointee.timerOp = -1
                table[slot].pointee.timerOpGeneration = 0
            }
            settleOutbound(slot, .timedOut)
            return
        }
        let c = table[slot]
        if c.pointee.state == .free { return }
        if c.pointee.requestId != requestId { return }
        if kind == .deadline {
            // Not the request's continuation, so none of the checks below
            // apply: the handler may be running rather than waiting, which is
            // the case a deadline exists for.
            guard c.pointee.deadlineOp == Int32(index) else { return }
            c.pointee.deadlineOp = -1
            c.pointee.deadlineOpGeneration = 0
            deadlineFired(slot, generation: c.pointee.generation, requestId: requestId)
            return
        }
        if c.pointee.contState != .waiting { return }
        if c.pointee.contOp != Int32(index) {
            // Cont already moved on; nothing to resume.
            return
        }
        c.pointee.contOp = -1
        enqueueReady(slot)
    }

    mutating func enqueueReady(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.contState == .waiting else { return }
        c.pointee.contState = .ready
        readySerial &+= 1
        if readySerial == 0 { readySerial = 1 }
        c.pointee.contTicket = readySerial
        let entry = ReadyEntry(slot: Int32(slot), generation: c.pointee.generation,
                               requestId: c.pointee.requestId, ticket: readySerial)
        if readyQueue.push(entry) { return }
        // Full. Each slot has at most one runnable entry, this slot's is not
        // queued yet, and the queue has room for every slot, so some queued
        // entry is stale. Shedding those keeps this resume on the queue, under
        // the drain budget, rather than running it inline here.
        let table = self.table
        readyQueue.compact { $0.isRunnable(in: table) }
        let pushed = readyQueue.push(entry)
        precondition(pushed, "ready queue full of runnable entries")
    }

    /// Resumes up to the budget's worth of continuations. Stale entries cost a
    /// check each and do not spend it.
    mutating func drainReadyQueue() {
        var budget = Worker.readyDrainBudget
        while budget > 0, let entry = readyQueue.pop() {
            if resumeContinuation(entry) { budget -= 1 }
        }
    }

    /// Resumes a queued continuation if it is still its connection's current
    /// one, and says whether it ran. Cancellation does not remove queue
    /// entries, so by the time an entry drains its slot may be closed and
    /// reused, or carrying a later continuation of its own.
    @discardableResult
    mutating func resumeContinuation(_ entry: ReadyEntry) -> Bool {
        guard entry.isRunnable(in: table) else { return false }
        let slot = Int(entry.slot)
        let c = table[slot]
        let kind = c.pointee.contKind
        c.pointee.contState = .none
        c.pointee.contKind = .none
        c.pointee.contOp = -1
        switch kind {
        case .handler:
            // Taken off the slot before it runs: the handler may wait again,
            // storing the next one where this one was.
            if let handler = c.pointee.contHandler {
                c.pointee.contHandler = nil
                runHandler(slot, handler)
            }
        case .task:
            // Still the task's request: only the wait is over.
            c.pointee.contKind = .task
            handlerTasks?.wake(Int(c.pointee.contTask))
        case .none:
            break
        }
        return true
    }
}

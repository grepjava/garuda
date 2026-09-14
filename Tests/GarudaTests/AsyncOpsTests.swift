import Testing
import GarudaCore
@testable import GarudaServer

/// A worker with no listener, driven by hand. Continuations are parked with
/// kind `.none`, so resuming one changes state without writing a response.
private func makeWorker(connections: Int) -> Worker {
    var config = ServerConfig()
    config.maxConnections = connections
    return Worker(config: config, listenFD: -1, poller: Poller()!)
}

/// Claims a slot and starts a request on it, as `beginRequest` would.
private func openRequest(_ worker: inout Worker) -> Int {
    let slot = worker.table.allocate()
    worker.table[slot].pointee.state = .dispatching
    worker.table[slot].pointee.requestId &+= 1
    return slot
}

/// Expires the slot's timer now, as `fireDueTimers` would at its deadline.
private func expireTimer(_ worker: inout Worker, _ slot: Int) {
    let c = worker.table[slot]
    // `popDue` unlinks the heap node before completing the op.
    worker.timerHeap.remove(opIndex: Int(c.pointee.contOp), from: &worker.asyncOps)
    worker.completeTimerOp(index: Int(c.pointee.contOp),
                           generation: c.pointee.contOpGeneration)
}

/// Parks a request on a timer and expires it, queueing its resume.
private func makeReady(_ worker: inout Worker, _ slot: Int) {
    worker.armDelay(slot, ms: 1, kind: .none)
    expireTimer(&worker, slot)
}

private func entry(_ slot: Int32) -> ReadyEntry {
    ReadyEntry(slot: slot, generation: 1, requestId: 1, ticket: UInt32(slot) &+ 1)
}

/// `#expect` cannot take a mutating call, so the queue is driven through these.
private func push(_ queue: inout ReadyQueue, _ slot: Int32) -> Bool {
    queue.push(entry(slot))
}

private func popSlot(_ queue: inout ReadyQueue) -> Int32? {
    queue.pop()?.slot
}

@Suite("Async ops")
struct AsyncOpsTests {

    @Test("ready queue wraps in FIFO order and refuses a push when full")
    func readyQueueWraparound() {
        var queue = ReadyQueue(minimumCapacity: 3)
        defer { queue.destroy() }
        #expect(queue.capacity == 4)
        for i in Int32(0)..<3 { #expect(push(&queue, i)) }
        #expect(popSlot(&queue) == 0)
        #expect(popSlot(&queue) == 1)
        // The head sits at 2, so the tail wraps past the end of storage.
        for i in Int32(3)..<6 { #expect(push(&queue, i)) }
        #expect(queue.isFull)
        let overflowed = push(&queue, 6)
        #expect(overflowed == false)
        #expect(queue.count == 4)
        #expect(queue[3].slot == 5)
        for i in Int32(2)..<6 { #expect(popSlot(&queue) == i) }
        #expect(popSlot(&queue) == nil)
        #expect(queue.isEmpty)
    }

    @Test("compaction drops entries in place and keeps order across the wrap")
    func readyQueueCompaction() {
        var queue = ReadyQueue(minimumCapacity: 4)
        defer { queue.destroy() }
        for i in Int32(0)..<2 { _ = queue.push(entry(i)) }
        _ = queue.pop()
        _ = queue.pop()
        for i in Int32(2)..<6 { _ = queue.push(entry(i)) }
        #expect(queue.isFull)

        let removed = queue.compact { $0.slot % 2 == 0 }
        #expect(removed == 2)
        #expect(queue.count == 2)
        #expect(queue[0].slot == 2)
        #expect(queue[1].slot == 4)
        for i in Int32(6)..<8 { #expect(push(&queue, i)) }
        #expect(queue.isFull)
        for expected: Int32 in [2, 4, 6, 7] { #expect(popSlot(&queue) == expected) }
    }

    @Test("a queued resume does not complete a reused slot's waiting request")
    func queuedResumeAfterSlotReuse() {
        var worker = makeWorker(connections: 8)
        defer { worker.destroy() }
        let slot = openRequest(&worker)
        makeReady(&worker, slot)
        #expect(worker.readyQueue.count == 1)

        // The connection closes before the entry drains, and a new connection
        // takes the slot and parks on a timer of its own.
        worker.cancelOps(slot: slot)
        worker.table.release(slot)
        #expect(openRequest(&worker) == slot)
        worker.armDelay(slot, ms: 60_000, kind: .none)

        worker.drainReadyQueue()
        #expect(worker.readyQueue.isEmpty)
        #expect(worker.table[slot].pointee.contState == .waiting)
        #expect(worker.table[slot].pointee.contOp >= 0)
        #expect(worker.asyncOps.liveCount == 1)
        worker.cancelOps(slot: slot)
        #expect(worker.asyncOps.liveCount == 0)
    }

    @Test("a queued resume does not complete the next keep-alive request")
    func queuedResumeAcrossKeepAlive() {
        var worker = makeWorker(connections: 8)
        defer { worker.destroy() }
        let slot = openRequest(&worker)
        makeReady(&worker, slot)
        let stale = worker.readyQueue[0]

        // Request B on the same connection is already ready too.
        worker.clearContinuation(slot)
        worker.table[slot].pointee.requestId &+= 1
        makeReady(&worker, slot)
        #expect(worker.readyQueue.count == 2)

        let resumedStale = worker.resumeContinuation(stale)
        #expect(resumedStale == false)
        #expect(worker.table[slot].pointee.contState == .ready)
        worker.drainReadyQueue()
        #expect(worker.table[slot].pointee.contState == .none)
        #expect(worker.readyQueue.isEmpty)
    }

    @Test("a request armed again after becoming ready has one runnable entry")
    func rearmedReadyRequest() {
        var worker = makeWorker(connections: 4)
        defer { worker.destroy() }
        let slot = openRequest(&worker)
        makeReady(&worker, slot)
        let first = worker.readyQueue[0]
        // Same slot, generation and request id: only the ticket differs.
        makeReady(&worker, slot)
        #expect(worker.readyQueue.count == 2)

        let resumedFirst = worker.resumeContinuation(first)
        #expect(resumedFirst == false)
        #expect(worker.table[slot].pointee.contState == .ready)
        let resumedSecond = worker.resumeContinuation(worker.readyQueue[1])
        #expect(resumedSecond)
        #expect(worker.table[slot].pointee.contState == .none)
    }

    @Test("a full ready queue sheds stale entries instead of resuming inline")
    func fullQueueShedsStale() {
        var worker = makeWorker(connections: 4)
        defer { worker.destroy() }
        #expect(worker.readyQueue.capacity == 4)

        // One entry goes stale when its connection closes and the slot is
        // reused; the reused slot and two others are then runnable.
        let reused = openRequest(&worker)
        makeReady(&worker, reused)
        worker.cancelOps(slot: reused)
        worker.table.release(reused)
        #expect(openRequest(&worker) == reused)
        makeReady(&worker, reused)
        let second = openRequest(&worker)
        makeReady(&worker, second)
        let third = openRequest(&worker)
        makeReady(&worker, third)
        #expect(worker.readyQueue.isFull)

        let last = openRequest(&worker)
        makeReady(&worker, last)
        #expect(worker.readyQueue.count == 4)
        #expect(worker.table[last].pointee.contState == .ready)

        worker.drainReadyQueue()
        #expect(worker.readyQueue.isEmpty)
        for slot in [reused, second, third, last] {
            #expect(worker.table[slot].pointee.contState == .none)
        }
    }

    @Test("a delay never resumes before its duration")
    func delayNeverEarly() {
        var worker = makeWorker(connections: 4)
        defer { worker.destroy() }
        let slot = openRequest(&worker)
        let clock = SuspendingClock()
        // 4 ms is one coarse clock tick on common kernels, the most a deadline
        // taken from that clock could expire early by.
        for _ in 0..<10 {
            let start = clock.now
            worker.armDelay(slot, ms: 4, kind: .none)
            while worker.table[slot].pointee.contState != .ready {
                worker.fireDueTimers()
            }
            let elapsed = clock.now - start
            #expect(elapsed >= .milliseconds(4))
            worker.clearContinuation(slot)
        }
    }

    @Test("the loop does not block until a backlog drains across budgets")
    func pollTimeoutWithReadyBacklog() {
        let budget = Worker.readyDrainBudget
        let n = 2 * budget + 6
        var worker = makeWorker(connections: n * 2)
        defer { worker.destroy() }
        var slots: [Int] = []
        for _ in 0..<n {
            let slot = openRequest(&worker)
            makeReady(&worker, slot)
            slots.append(slot)
        }
        #expect(worker.readyQueue.count == n)
        #expect(worker.timerHeap.isEmpty)

        worker.drainReadyQueue()
        #expect(worker.readyQueue.count == budget + 6)
        #expect(worker.quicPollTimeout(200) == 0)
        worker.drainReadyQueue()
        #expect(worker.readyQueue.count == 6)
        #expect(worker.quicPollTimeout(200) == 0)
        worker.drainReadyQueue()
        #expect(worker.readyQueue.isEmpty)
        #expect(worker.quicPollTimeout(200) == 200)
        for slot in slots {
            #expect(worker.table[slot].pointee.contState == .none)
        }
    }

    @Test("stale entries do not spend the drain budget")
    func staleEntriesSkipBudget() {
        let budget = Worker.readyDrainBudget
        var worker = makeWorker(connections: 2 * budget)
        defer { worker.destroy() }
        let abandoned = openRequest(&worker)
        for _ in 0..<budget {
            makeReady(&worker, abandoned)
            worker.clearContinuation(abandoned)
            worker.table[abandoned].pointee.requestId &+= 1
        }
        var live: [Int] = []
        for _ in 0..<3 {
            let slot = openRequest(&worker)
            makeReady(&worker, slot)
            live.append(slot)
        }
        #expect(worker.readyQueue.count == budget + 3)

        worker.drainReadyQueue()
        #expect(worker.readyQueue.isEmpty)
        for slot in live {
            #expect(worker.table[slot].pointee.contState == .none)
        }
    }

    @Test("request cleanup frees only the slot's own op")
    func cleanupLeavesOtherOps() {
        var worker = makeWorker(connections: 8)
        defer { worker.destroy() }
        let waiting = openRequest(&worker)
        worker.armDelay(waiting, ms: 60_000, kind: .none)
        let other = openRequest(&worker)
        worker.armDelay(other, ms: 60_000, kind: .none)
        #expect(worker.asyncOps.liveCount == 2)

        worker.clearContinuation(other)
        #expect(worker.asyncOps.liveCount == 1)
        #expect(worker.timerHeap.count == 1)
        #expect(worker.table[waiting].pointee.contState == .waiting)

        // A request that never armed an op costs nothing and touches nothing.
        let plain = openRequest(&worker)
        worker.clearContinuation(plain)
        #expect(worker.asyncOps.liveCount == 1)
        #expect(worker.table[waiting].pointee.contState == .waiting)
    }

    @Test("allocate and free round-trip through the free list")
    func allocateFree() {
        var pool = AsyncOpPool(capacity: 4)
        defer { pool.destroy() }
        let a = pool.allocate(slot: 1, requestId: 1, kind: .timer, deadlineUs: 10)
        let b = pool.allocate(slot: 2, requestId: 2, kind: .timer, deadlineUs: 20)
        #expect(a != nil)
        #expect(b != nil)
        #expect(a!.index != b!.index)
        #expect(pool.liveCount == 2)
        pool.free(a!.index)
        #expect(pool.liveCount == 1)
        let c = pool.allocate(slot: 3, requestId: 3, kind: .timer, deadlineUs: 30)
        #expect(c != nil)
        #expect(c!.index == a!.index)
        #expect(c!.generation == a!.generation &+ 1)
        pool.free(b!.index)
        pool.free(c!.index)
        #expect(pool.liveCount == 0)
    }

    @Test("pool rejects allocate when full")
    func poolFull() {
        var pool = AsyncOpPool(capacity: 2)
        defer { pool.destroy() }
        #expect(pool.allocate(slot: 0, requestId: 1, kind: .timer, deadlineUs: 1) != nil)
        #expect(pool.allocate(slot: 1, requestId: 1, kind: .timer, deadlineUs: 1) != nil)
        #expect(pool.allocate(slot: 2, requestId: 1, kind: .timer, deadlineUs: 1) == nil)
    }

    @Test("timer heap pops in deadline order")
    func heapOrder() {
        var pool = AsyncOpPool(capacity: 8)
        var heap = TimerHeap(capacity: 8)
        defer {
            heap.destroy()
            pool.destroy()
        }
        let late = pool.allocate(slot: 0, requestId: 1, kind: .timer, deadlineUs: 300)!
        let early = pool.allocate(slot: 1, requestId: 1, kind: .timer, deadlineUs: 100)!
        let mid = pool.allocate(slot: 2, requestId: 1, kind: .timer, deadlineUs: 200)!
        heap.push(TimerHeap.Entry(deadlineUs: 300, opIndex: Int32(late.index),
                                  opGeneration: late.generation), into: &pool)
        heap.push(TimerHeap.Entry(deadlineUs: 100, opIndex: Int32(early.index),
                                  opGeneration: early.generation), into: &pool)
        heap.push(TimerHeap.Entry(deadlineUs: 200, opIndex: Int32(mid.index),
                                  opGeneration: mid.generation), into: &pool)
        #expect(heap.nextDeadlineUs == 100)
        let first = heap.popDue(nowUs: 150, from: &pool)!
        #expect(Int(first.opIndex) == early.index)
        let second = heap.popDue(nowUs: 250, from: &pool)!
        #expect(Int(second.opIndex) == mid.index)
        #expect(heap.popDue(nowUs: 250, from: &pool) == nil)
        let third = heap.popDue(nowUs: 400, from: &pool)!
        #expect(Int(third.opIndex) == late.index)
    }

    @Test("cancel marks the op; generation mismatch is ignored")
    func cancelGeneration() {
        var pool = AsyncOpPool(capacity: 2)
        defer { pool.destroy() }
        let a = pool.allocate(slot: 0, requestId: 7, kind: .timer, deadlineUs: 1)!
        let bad = pool.cancel(index: a.index, generation: a.generation &+ 1)
        #expect(bad == false)
        #expect(pool[a.index].pointee.cancelled == false)
        let ok = pool.cancel(index: a.index, generation: a.generation)
        #expect(ok == true)
        #expect(pool[a.index].pointee.cancelled == true)
    }

    @Test("stale requestId must not resume: heap remove after free is safe")
    func staleRequestIdentity() {
        var pool = AsyncOpPool(capacity: 4)
        var heap = TimerHeap(capacity: 4)
        defer {
            heap.destroy()
            pool.destroy()
        }
        // Request A arms a timer.
        let a = pool.allocate(slot: 0, requestId: 1, kind: .timer, deadlineUs: 50)!
        heap.push(TimerHeap.Entry(deadlineUs: 50, opIndex: Int32(a.index),
                                  opGeneration: a.generation), into: &pool)
        // Request A finishes: cancel and free before keep-alive request B.
        heap.remove(opIndex: a.index, from: &pool)
        pool.free(a.index)
        // Request B arms its own timer on the recycled op slot.
        let b = pool.allocate(slot: 0, requestId: 2, kind: .timer, deadlineUs: 50)!
        #expect(b.index == a.index)
        #expect(b.generation != a.generation)
        heap.push(TimerHeap.Entry(deadlineUs: 50, opIndex: Int32(b.index),
                                  opGeneration: b.generation), into: &pool)
        // A stale pop with A's generation must not match B.
        let due = heap.popDue(nowUs: 100, from: &pool)!
        #expect(due.opGeneration == b.generation)
        #expect(pool[Int(due.opIndex)].pointee.requestId == 2)
    }

    @Test("router matches delay path and clamps")
    func delayRouteMatch() {
        let path = Array("/delay/50".utf8)
        let route = path.withUnsafeBufferPointer {
            Router.match(method: .get, path: $0.baseAddress!, count: $0.count)
        }
        guard case .delay(let ms) = route else {
            Issue.record("expected delay route")
            return
        }
        #expect(ms == 50)

        let big = Array("/delay/99999".utf8)
        let clamped = big.withUnsafeBufferPointer {
            Router.match(method: .get, path: $0.baseAddress!, count: $0.count)
        }
        guard case .delay(let ms2) = clamped else {
            Issue.record("expected clamped delay")
            return
        }
        #expect(ms2 == 5000)

        let bad = Array("/delay/".utf8)
        let none = bad.withUnsafeBufferPointer {
            Router.match(method: .get, path: $0.baseAddress!, count: $0.count)
        }
        #expect(none == nil)
    }
}

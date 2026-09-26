//===----------------------------------------------------------------------===//
// Waiting for something the worker will say, for a bounded time.
//
// A driver's queue -- a request waiting for a pooled connection -- is woken by
// whoever gives the resource back, and by nobody else. When nobody does, the
// wait is as long as whoever holds it: a transaction that awaits a slow call,
// a handler that loops. `Worker.waitTimed` parks a task under an id that
// `wakeTimed` resumes with `.woken`, and a timer on the worker's own heap
// resumes with `.timedOut` if that comes first. Exactly one of them does: the
// id's entry is taken by whichever gets there, so the other finds nothing.
//
// The id, not the continuation, is what a queue holds. A continuation in a
// queue would be resumed a second time by the queue after its timer had
// already resumed it.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// How a timed wait ended.
enum TimedWaitOutcome {
    case woken
    case timedOut
    /// The worker is shutting down.
    case cancelled
}

/// A wait in progress: its continuation, and the timer bounding it.
struct TimedWaiter {
    var continuation: UnsafeContinuation<TimedWaitOutcome, Never>
    /// The timer op, or -1 while the op pool has had no room for one.
    var op: Int32
    var opGeneration: UInt32
    /// When the wait ends, for one without a timer (`armTimedWaits`).
    var deadlineUs: UInt64
    /// The request the wait is for, or -1 for one the worker owns: a
    /// scheduled job's sleep, a retry's pause, a WebSocket's.
    var slot: Int32 = -1
    var generation: UInt32 = 0
    var requestId: UInt32 = 0
}

extension Worker {
    /// Parks the calling task for at most `milliseconds`. `register` is given
    /// the wait's id before the task suspends -- the worker is one thread, so
    /// nothing can wake it in between -- and whoever holds that id may end
    /// the wait early with `wakeTimed`.
    ///
    /// With no room in the op pool the wait is armed without a timer, and
    /// `fireDueTimers` gives it one once there is room, or ends it itself when
    /// its time is up first. Refusing to wait at all would fail the request
    /// over the safety net rather than the thing it guards against.
    ///
    /// `forRequest` is for a wait a handler makes on behalf of its request:
    /// a pool acquisition. Such a wait is `.cancelled` when the request
    /// ends, and at once if it already has, so a client that hung up does
    /// not keep a handler waiting, and then take a connection, for nobody.
    /// It applies only on the handler's own task: a task the handler started
    /// may be meant to outlive the request.
    nonisolated(nonsending)
    static func waitTimed(_ worker: UnsafeMutablePointer<Worker>, milliseconds: UInt64,
                          forRequest: Bool = false,
                          register: (Int32) -> Void) async -> TimedWaitOutcome {
        var owner: HandlerTaskPool.Serving? = nil
        if forRequest, let request = worker.pointee.handlerTasks?.servingOnCurrentTask() {
            guard worker.pointee.isLive(request) else { return .cancelled }
            owner = request
        }
        return await withUnsafeContinuation { continuation in
            let id = worker.pointee.nextTimedWait
            worker.pointee.nextTimedWait = id == Int32.max ? 0 : id + 1
            let deadline = av_monotonic_us() &+ 1 &+ max(1, milliseconds) &* 1000
            var waiter = TimedWaiter(continuation: continuation, op: -1, opGeneration: 0,
                                     deadlineUs: deadline)
            if let (op, generation) = worker.pointee.asyncOps.allocate(
                slot: Int(id), requestId: 0, kind: .timedWait, deadlineUs: deadline) {
                worker.pointee.timerHeap.push(
                    TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(op), opGeneration: generation),
                    into: &worker.pointee.asyncOps)
                waiter.op = Int32(op)
                waiter.opGeneration = generation
            } else {
                worker.pointee.unarmedTimedWaits += 1
            }
            if let owner {
                waiter.slot = owner.slot
                waiter.generation = owner.generation
                waiter.requestId = owner.requestId
                worker.pointee.table[Int(owner.slot)].pointee.ownedTimedWaits += 1
            }
            worker.pointee.timedWaits[id] = waiter
            register(id)
        }
    }

    /// Whether the request is still the one on its slot, and not already
    /// answered for passing its deadline.
    func isLive(_ request: HandlerTaskPool.Serving) -> Bool {
        let c = table[Int(request.slot)]
        return c.pointee.state != .free && c.pointee.generation == request.generation
            && c.pointee.requestId == request.requestId && !c.pointee.flags.contains(.timedOut)
    }

    /// Whether the calling task is a handler's whose request has ended: a
    /// wait woken just before its request ended is not cancelled, and hands
    /// on what it was given rather than use it for nobody.
    var currentRequestEnded: Bool {
        guard let request = handlerTasks?.servingOnCurrentTask() else { return false }
        return !isLive(request)
    }

    /// Takes wait `id` out of everything that knows of it but its
    /// continuation, which the caller resumes.
    private mutating func takeTimedWait(_ id: Int32) -> TimedWaiter? {
        guard let waiter = timedWaits.removeValue(forKey: id) else { return nil }
        let op = Int(waiter.op)
        if op < 0 {
            unarmedTimedWaits -= 1
        } else if op < asyncOps.capacity, asyncOps[op].pointee.generation == waiter.opGeneration,
                  Int(asyncOps[op].pointee.slot) == Int(id), asyncOps[op].pointee.kind == .timedWait {
            // Not when the timer has fired: its op is freed already.
            timerHeap.remove(opIndex: op, from: &asyncOps)
            asyncOps.free(op)
        }
        if waiter.slot >= 0 {
            let c = table[Int(waiter.slot)]
            if c.pointee.generation == waiter.generation, c.pointee.requestId == waiter.requestId,
               c.pointee.ownedTimedWaits > 0 {
                c.pointee.ownedTimedWaits -= 1
            }
        }
        return waiter
    }

    /// Ends the wait `id` as woken. False when it has already ended -- timed
    /// out, cancelled, or woken before -- so a queue can move on to its next
    /// id.
    @discardableResult
    mutating func wakeTimed(_ id: Int32) -> Bool {
        guard let waiter = takeTimedWait(id) else { return false }
        waiter.continuation.resume(returning: .woken)
        return true
    }

    /// The timer for wait `id` fired. Its op is already freed.
    mutating func timedWaitExpired(_ id: Int32) {
        takeTimedWait(id)?.continuation.resume(returning: .timedOut)
    }

    /// Gives each wait armed without a timer one, now that the pool may have
    /// room, and ends those whose time is up. Without this a wait begun with
    /// the pool full had no end but a wake, and a retry's pause or a
    /// scheduled job's sleep has nobody to wake it.
    mutating func armTimedWaits(nowUs now: UInt64) {
        var expired: [Int32] = []
        var armable: [Int32] = []
        for (id, waiter) in timedWaits where waiter.op < 0 {
            if now >= waiter.deadlineUs { expired.append(id) } else { armable.append(id) }
        }
        for id in armable {
            guard let deadline = timedWaits[id]?.deadlineUs,
                  let (op, generation) = asyncOps.allocate(
                    slot: Int(id), requestId: 0, kind: .timedWait, deadlineUs: deadline) else { break }
            timerHeap.push(TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(op), opGeneration: generation),
                           into: &asyncOps)
            timedWaits[id]!.op = Int32(op)
            timedWaits[id]!.opGeneration = generation
            unarmedTimedWaits -= 1
        }
        for id in expired { timedWaitExpired(id) }
    }

    /// Ends, as cancelled, the waits the request on `slot` was in. Called
    /// wherever a request ends (`wakeCancelWaiters`).
    mutating func endOwnedTimedWaits(_ slot: Int) {
        guard table[slot].pointee.ownedTimedWaits > 0 else { return }
        table[slot].pointee.ownedTimedWaits = 0
        var owned: [Int32] = []
        for (id, waiter) in timedWaits where Int(waiter.slot) == slot { owned.append(id) }
        for id in owned { takeTimedWait(id)?.continuation.resume(returning: .cancelled) }
    }

    /// Ends every wait, for a worker shutting down.
    mutating func cancelTimedWaits() {
        for id in Array(timedWaits.keys) {
            takeTimedWait(id)?.continuation.resume(returning: .cancelled)
        }
    }
}

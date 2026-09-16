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

import CGaruda
import GarudaCore

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
    /// The timer op, or -1 when the op pool had no room for one.
    var op: Int32
    var opGeneration: UInt32
}

extension Worker {
    /// Parks the calling task for at most `milliseconds`. `register` is given
    /// the wait's id before the task suspends -- the worker is one thread, so
    /// nothing can wake it in between -- and whoever holds that id may end
    /// the wait early with `wakeTimed`.
    ///
    /// With no room in the op pool the wait is armed without a timer, as a
    /// route's deadline is: refusing to wait at all would fail the request
    /// over the safety net rather than the thing it guards against.
    static func waitTimed(_ worker: UnsafeMutablePointer<Worker>, milliseconds: UInt64,
                          register: (Int32) -> Void) async -> TimedWaitOutcome {
        await withUnsafeContinuation { continuation in
            let id = worker.pointee.nextTimedWait
            worker.pointee.nextTimedWait = id == Int32.max ? 0 : id + 1
            var waiter = TimedWaiter(continuation: continuation, op: -1, opGeneration: 0)
            let deadline = pg_monotonic_us() &+ 1 &+ max(1, milliseconds) &* 1000
            if let (op, generation) = worker.pointee.asyncOps.allocate(
                slot: Int(id), requestId: 0, kind: .timedWait, deadlineUs: deadline) {
                worker.pointee.timerHeap.push(
                    TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(op), opGeneration: generation),
                    into: &worker.pointee.asyncOps)
                waiter.op = Int32(op)
                waiter.opGeneration = generation
            }
            worker.pointee.timedWaits[id] = waiter
            register(id)
        }
    }

    /// Ends the wait `id` as woken. False when it has already ended -- timed
    /// out, or woken before -- so a queue can move on to its next id.
    @discardableResult
    mutating func wakeTimed(_ id: Int32) -> Bool {
        guard let waiter = timedWaits.removeValue(forKey: id) else { return false }
        let op = Int(waiter.op)
        if op >= 0, op < asyncOps.capacity, asyncOps[op].pointee.generation == waiter.opGeneration,
           Int(asyncOps[op].pointee.slot) == Int(id) {
            timerHeap.remove(opIndex: op, from: &asyncOps)
            asyncOps.free(op)
        }
        waiter.continuation.resume(returning: .woken)
        return true
    }

    /// The timer for wait `id` fired. Its op is already freed.
    mutating func timedWaitExpired(_ id: Int32) {
        timedWaits.removeValue(forKey: id)?.continuation.resume(returning: .timedOut)
    }

    /// Ends every wait, for a worker shutting down.
    mutating func cancelTimedWaits() {
        let waiters = timedWaits
        timedWaits.removeAll()
        for (_, waiter) in waiters {
            let op = Int(waiter.op)
            if op >= 0, op < asyncOps.capacity, asyncOps[op].pointee.generation == waiter.opGeneration {
                timerHeap.remove(opIndex: op, from: &asyncOps)
                asyncOps.free(op)
            }
            waiter.continuation.resume(returning: .cancelled)
        }
    }
}

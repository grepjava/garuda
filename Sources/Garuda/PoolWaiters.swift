//===----------------------------------------------------------------------===//
// The requests waiting for a pooled connection, and the hand-off to them.
//
// A connection released while requests wait goes straight to the oldest of
// them. Put back as idle, with that request merely woken, it went to whoever
// asked next before the woken task ran -- a new request, or the one that had
// just released it -- and the woken request found nothing, queued again at
// the back, and could lose its turn over and over. Under steady load that
// was the slowest answers taking twice as long as they needed to.
//
// The PostgreSQL and Redis pools share this. It lives on the worker's one
// thread with the pool that owns it, so nothing here is locked.
//===----------------------------------------------------------------------===//

struct PoolWaiters<Connection> {
    /// Timed-wait ids, oldest first from `head` on: the front is taken by
    /// moving `head`, not by shifting everything behind it down.
    private var ids: [Int32] = []
    private var head = 0
    /// Connections released to a wait, for it to take when its task runs.
    private var handedOver: [Int32: Connection] = [:]

    /// How many are waiting.
    var count: Int { ids.count - head }

    /// Queues the wait `id`, at the back.
    mutating func add(_ id: Int32) {
        ids.append(id)
    }

    /// Takes out a wait that timed out, wherever it is.
    mutating func remove(_ id: Int32) {
        if let at = ids[head...].firstIndex(of: id) { ids.remove(at: at) }
    }

    /// Gives `connection` to the oldest wait still waiting and wakes it.
    /// False when nobody is waiting: the caller keeps it as idle.
    mutating func handOver(_ connection: Connection, on worker: UnsafeMutablePointer<Worker>) -> Bool {
        guard let id = wakeOldest(on: worker) else { return false }
        handedOver[id] = connection
        return true
    }

    /// What was handed to the wait `id`, if anything was. Nothing means it was
    /// woken because a connection closed, and there is room to open one.
    mutating func take(_ id: Int32) -> Connection? {
        handedOver.removeValue(forKey: id)
    }

    /// Wakes the oldest wait still waiting, and returns it; nil when there is
    /// none. An id at the front may belong to a wait whose timer has fired
    /// but whose task has not yet run to take it out; waking it wakes
    /// nothing, and stopping there would leave the live wait behind it asleep.
    @discardableResult
    mutating func wakeOldest(on worker: UnsafeMutablePointer<Worker>) -> Int32? {
        while head < ids.count {
            let id = ids[head]
            head += 1
            if head == ids.count {
                ids.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64 && head * 2 >= ids.count {
                // A queue that never empties under steady load would
                // otherwise keep everything it has ever served.
                ids.removeFirst(head)
                head = 0
            }
            if worker.pointee.wakeTimed(id) { return id }
        }
        return nil
    }

    /// Every connection handed over and not yet taken, for a pool closing.
    mutating func takeAllHandedOver() -> [Connection] {
        defer { handedOver.removeAll() }
        return Array(handedOver.values)
    }
}

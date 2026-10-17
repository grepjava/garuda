//===----------------------------------------------------------------------===//
// What a connection is made of, kept for the next one.
//
// A connection needs a read buffer, an output buffer and an exchange (with
// its header table and JSON writer): a handful of allocations, and as many
// frees when it ends. Under a stream of short connections that is malloc's
// work for every one, and worse than that, a connection's task often ends on
// another thread than it began on, so its memory goes back to an arena some
// other thread is using, and the two fight over that arena's lock.
//
// So the parts are kept when a connection ends, in a short list for the
// worker thread it ended on, and the next connection on that thread takes
// them. Each list is only ever touched by its own worker, so it needs no
// lock. Parts that grew large -- a big body -- are freed instead of kept.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega

/// The memory one HTTP/1 connection uses, reused from connection to
/// connection.
struct ConnectionParts: ~Copyable {
    var input: IOBuffer
    var output: ByteBuffer
    var dates = DateCache()
    let exchange: UnsafeMutablePointer<Exchange>
    /// --request-start-header: what the kernel said of when the bytes of
    /// the read that began a request arrived, filled by that read. Its own
    /// allocation, made with the parts, because it must not move while the
    /// read waits and a pointer into these parts cannot be formed.
    let arrival: UnsafeMutablePointer<ReadArrival>
    /// When the request at the start of `input` arrived, in wall-clock
    /// microseconds, or 0 when no read has begun one since the last was
    /// served: a pipelined request was waiting before it was looked at.
    var arrived: UInt64 = 0

    init(limits: ConnectionLimits, peer: SocketPeer) {
        input = IOBuffer(capacity: limits.readBufferSize)
        output = ByteBuffer()
        output.reserve(4096)
        exchange = .allocate(capacity: 1)
        exchange.initialize(to: Exchange(maxHeaders: limits.maxHeaders, remote: peer))
        arrival = .allocate(capacity: 1)
        arrival.initialize(to: ReadArrival())
    }

    deinit {
        var output = output
        output.destroy()
        exchange.deinitialize(count: 1)
        exchange.deallocate()
        arrival.deallocate()
    }
}

/// Spare `ConnectionParts`, a list for each worker thread.
final class ConnectionCache: @unchecked Sendable {
    /// Workers beyond this many keep nothing.
    static let maxWorkers = 64
    /// Parts kept by each worker.
    static let depth = 32

    private let lists: UnsafeMutablePointer<UnsafeMutablePointer<ConnectionParts>?>
    private let counts: UnsafeMutablePointer<Int>

    init() {
        let slots = ConnectionCache.maxWorkers * ConnectionCache.depth
        lists = .allocate(capacity: slots)
        lists.initialize(repeating: nil, count: slots)
        counts = .allocate(capacity: ConnectionCache.maxWorkers)
        counts.initialize(repeating: 0, count: ConnectionCache.maxWorkers)
    }

    deinit {
        for w in 0..<ConnectionCache.maxWorkers {
            for i in 0..<counts[w] {
                if let p = lists[w * ConnectionCache.depth + i] { free(p) }
            }
        }
        lists.deallocate()
        counts.deallocate()
    }

    /// Parts for a new connection to `peer`: this worker's spare, or new.
    func take(limits: ConnectionLimits, peer: SocketPeer) -> UnsafeMutablePointer<ConnectionParts> {
        if let w = Runtime.currentWorker, w < ConnectionCache.maxWorkers, counts[w] > 0 {
            counts[w] -= 1
            let slot = w * ConnectionCache.depth + counts[w]
            if let p = lists[slot] {
                lists[slot] = nil
                // Made under other limits (a test client's): not these.
                if p.pointee.exchange.pointee.maxHeaders == limits.maxHeaders
                    && p.pointee.input.capacity >= limits.readBufferSize {
                    p.pointee.exchange.pointee.remote = peer
                    metrics?.add(.poolHits)
                    return p
                }
                free(p)
            }
        }
        metrics?.add(.poolMisses)
        let p = UnsafeMutablePointer<ConnectionParts>.allocate(capacity: 1)
        p.initialize(to: ConnectionParts(limits: limits, peer: peer))
        return p
    }

    /// --metrics-port's counters, set before the shard serves.
    nonisolated(unsafe) var metrics: MetricsPage?

    /// Takes back parts a connection is done with.
    func give(_ p: UnsafeMutablePointer<ConnectionParts>, limits: ConnectionLimits) {
        // Parts whose buffers grew past this are freed rather than kept.
        let keepUpTo = max(limits.readBufferSize, 16 * 1024) * 4
        let x = p.pointee.exchange
        let small = p.pointee.input.capacity <= keepUpTo && p.pointee.output.allocatedCapacity <= keepUpTo
            && x.pointee.decodedBody.allocatedCapacity <= keepUpTo
            && x.pointee.responseBody.allocatedCapacity <= keepUpTo
            && x.pointee.compressed.allocatedCapacity <= keepUpTo
            && x.pointee.cacheScratch.allocatedCapacity <= keepUpTo
        guard small, let w = Runtime.currentWorker, w < ConnectionCache.maxWorkers,
              counts[w] < ConnectionCache.depth else {
            free(p)
            return
        }
        p.pointee.input.clear()
        p.pointee.output.clear()
        p.pointee.arrived = 0
        p.pointee.exchange.pointee.reset()
        lists[w * ConnectionCache.depth + counts[w]] = p
        counts[w] += 1
    }

    private func free(_ p: UnsafeMutablePointer<ConnectionParts>) {
        p.deinitialize(count: 1)
        p.deallocate()
    }
}

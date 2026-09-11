//===----------------------------------------------------------------------===//
// Fixed-block buffer pool.
//
// Read buffers are the single most churned allocation in an HTTP server: one
// per connection, acquired on accept and released on close. malloc/free per
// connection shows up clearly at high connection rates, so we recycle blocks of
// exactly `blockSize` bytes through a LIFO free list -- LIFO because the most
// recently freed block is the one still in L2.
//
// The pool is per worker and workers are single-threaded, so there is no lock,
// no atomics and no thread-local indirection.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct BufferPool {
    @usableFromInline var slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    @usableFromInline var count: Int
    @usableFromInline let maxRetained: Int
    public let blockSize: Int

    /// Number of blocks handed out and not yet returned; a non-zero value at
    /// shutdown means a connection leaked a buffer.
    @usableFromInline var live: Int = 0
    public var outstanding: Int { live }

    public init(blockSize: Int, maxRetained: Int) {
        self.blockSize = blockSize
        self.maxRetained = maxRetained
        self.count = 0
        let bytes = MemoryLayout<UnsafeMutableRawPointer?>.stride * maxRetained
        guard let p = malloc(bytes) else {
            allocationFailed(bytes, "the buffer pool's free list")
        }
        self.slots = UnsafeMutableRawPointer(p)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    }

    @inlinable
    public mutating func take() -> ByteBuffer {
        live &+= 1
        if count > 0 {
            count &-= 1
            let p = slots[count].unsafelyUnwrapped
            return ByteBuffer(adopting: p, capacity: blockSize)
        }
        return ByteBuffer(capacity: blockSize)
    }

    /// Returns a buffer to the pool. Buffers that outgrew `blockSize` (a large
    /// request body, a big response) are freed outright rather than pinning
    /// their oversized allocation in the pool forever.
    @inlinable
    public mutating func give(_ buffer: consuming ByteBuffer) {
        live &-= 1
        var b = buffer
        let (p, cap) = b.release()
        guard let p else { return }
        if cap == blockSize && count < maxRetained {
            slots[count] = p
            count &+= 1
        } else {
            free(p)
        }
    }

    public mutating func drain() {
        while count > 0 {
            count &-= 1
            free(slots[count])
        }
    }

    public mutating func destroy() {
        drain()
        free(slots)
    }
}

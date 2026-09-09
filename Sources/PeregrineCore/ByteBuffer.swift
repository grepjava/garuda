//===----------------------------------------------------------------------===//
// A manually-managed byte buffer.
//
// This is deliberately NOT a class and NOT a ~Copyable type with a deinit:
//
//  * A class would put every buffer behind ARC. Connections hand buffers around
//    on every read, write and flush; that is hundreds of thousands of
//    retain/release pairs per second per core, all of them atomic.
//  * A ~Copyable struct with a deinit gives automatic cleanup, but it cannot be
//    stored in the flat connection slab (an UnsafeMutablePointer table indexed
//    by slot) without fighting the move-only checker on every partial mutation.
//
// So ByteBuffer is a trivial value type -- three words and a pointer, passed in
// registers, copied for free -- with explicit `destroy()` at exactly one place
// per buffer: connection teardown. Ownership is a documented invariant rather
// than a language-enforced one, which is the trade this server is built to make.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct ByteBuffer {
    @usableFromInline var storage: UnsafeMutablePointer<UInt8>?
    @usableFromInline var capacity: Int
    /// Index of the first unread byte.
    @usableFromInline var readerIndex: Int
    /// Index one past the last written byte.
    @usableFromInline var writerIndex: Int

    @inlinable
    public init() {
        storage = nil
        capacity = 0
        readerIndex = 0
        writerIndex = 0
    }

    @inlinable
    public init(capacity: Int) {
        if capacity > 0 {
            storage = UnsafeMutableRawPointer(malloc(capacity)!)
                .assumingMemoryBound(to: UInt8.self)
            self.capacity = capacity
        } else {
            storage = nil
            self.capacity = 0
        }
        readerIndex = 0
        writerIndex = 0
    }

    /// Adopts an existing allocation (used by the pool).
    @inlinable
    public init(adopting p: UnsafeMutableRawPointer, capacity: Int) {
        storage = p.assumingMemoryBound(to: UInt8.self)
        self.capacity = capacity
        readerIndex = 0
        writerIndex = 0
    }

    // MARK: - Geometry

    @inlinable public var readableBytes: Int { writerIndex &- readerIndex }
    /// Absolute index of the first unread byte, used to anchor parsed slices.
    @inlinable public var readerOffset: Int { readerIndex }
    @inlinable public var writableBytes: Int { capacity &- writerIndex }
    @inlinable public var isEmpty: Bool { writerIndex == readerIndex }
    @inlinable public var allocated: Bool { storage != nil }
    @inlinable public var allocatedCapacity: Int { capacity }

    /// Pointer to the first readable byte. Only valid while `readableBytes > 0`.
    @inlinable
    public var readPointer: UnsafeMutablePointer<UInt8> {
        storage.unsafelyUnwrapped + readerIndex
    }

    @inlinable
    public var writePointer: UnsafeMutablePointer<UInt8> {
        storage.unsafelyUnwrapped + writerIndex
    }

    @inlinable
    public var readableSpan: ByteSpan {
        ByteSpan(UnsafePointer(storage.unsafelyUnwrapped + readerIndex), writerIndex &- readerIndex)
    }

    @inlinable
    public func byte(at absoluteIndex: Int) -> UInt8 {
        storage.unsafelyUnwrapped[absoluteIndex]
    }

    @inlinable
    public func pointer(at absoluteIndex: Int) -> UnsafeMutablePointer<UInt8> {
        storage.unsafelyUnwrapped + absoluteIndex
    }

    // MARK: - Growth

    /// Guarantees `n` writable bytes. Uses realloc so the allocator gets the
    /// chance to extend in place instead of copying.
    @inlinable
    public mutating func reserve(_ n: Int) {
        if capacity &- writerIndex >= n { return }
        growSlow(n)
    }

    @usableFromInline
    mutating func growSlow(_ n: Int) {
        // Reclaim consumed bytes first: pipelined requests would otherwise make
        // the read buffer creep upward for the life of the connection.
        if readerIndex > 0 && capacity &- (writerIndex &- readerIndex) >= n {
            compact()
            if capacity &- writerIndex >= n { return }
        }
        var newCap = capacity == 0 ? 512 : capacity
        let need = writerIndex &+ n
        while newCap < need { newCap &*= 2 }
        if let old = storage {
            let p = realloc(old, newCap)!
            storage = UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt8.self)
        } else {
            storage = UnsafeMutableRawPointer(malloc(newCap)!)
                .assumingMemoryBound(to: UInt8.self)
        }
        capacity = newCap
    }

    /// Moves unread bytes to the front. Cheap when the buffer is nearly drained,
    /// which is the normal case between pipelined requests.
    @inlinable
    public mutating func compact() {
        let n = writerIndex &- readerIndex
        if readerIndex == 0 { return }
        if n > 0 {
            memmove(storage.unsafelyUnwrapped, storage.unsafelyUnwrapped + readerIndex, n)
        }
        readerIndex = 0
        writerIndex = n
    }

    // MARK: - Writing

    @inlinable
    public mutating func write(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if n == 0 { return }
        reserve(n)
        memcpy(storage.unsafelyUnwrapped + writerIndex, p, n)
        writerIndex &+= n
    }

    @inlinable
    public mutating func write(_ span: ByteSpan) { write(span.base, span.count) }

    @inlinable
    public mutating func writeByte(_ b: UInt8) {
        reserve(1)
        storage.unsafelyUnwrapped[writerIndex] = b
        writerIndex &+= 1
    }

    @inlinable
    public mutating func write(_ s: StaticString) {
        write(s.utf8Start, s.utf8CodeUnitCount)
    }

    @inlinable
    public mutating func writeCRLF() {
        reserve(2)
        let p = storage.unsafelyUnwrapped + writerIndex
        p[0] = cCR
        p[1] = cLF
        writerIndex &+= 2
    }

    @inlinable
    public mutating func writeDecimal(_ v: Int) {
        reserve(20)
        writerIndex &+= PeregrineCore.writeDecimal(v, storage.unsafelyUnwrapped + writerIndex)
    }

    /// Writes a lowercase hex integer (chunked framing).
    @inlinable
    public mutating func writeHex(_ v: Int) {
        reserve(16)
        if v == 0 { writeByte(cZero); return }
        var tmp = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                   UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var n = 0
        var x = v
        withUnsafeMutableBytes(of: &tmp) { raw in
            let t = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while x > 0 {
                let d = UInt8(x & 0xF)
                t[n] = d < 10 ? (cZero &+ d) : (87 &+ d)
                x >>= 4
                n &+= 1
            }
            let out = storage.unsafelyUnwrapped + writerIndex
            var i = 0
            while i < n {
                out[i] = t[n &- 1 &- i]
                i &+= 1
            }
        }
        writerIndex &+= n
    }

    /// Records bytes written directly into `writePointer` (by read(2), or by a
    /// memcpy out of Python-owned memory).
    @inlinable
    public mutating func advanceWriter(_ n: Int) { writerIndex &+= n }

    /// Reserves `n` bytes and hands back the destination so a caller can write
    /// straight into the buffer (read(2), memcpy from Python) with no staging.
    @inlinable
    public mutating func withWritableBytes(_ n: Int,
                                           _ body: (UnsafeMutablePointer<UInt8>) -> Int) {
        reserve(n)
        let produced = body(storage.unsafelyUnwrapped + writerIndex)
        writerIndex &+= produced
    }

    // MARK: - Reading

    @inlinable
    public mutating func consume(_ n: Int) {
        readerIndex &+= n
        if readerIndex == writerIndex {
            readerIndex = 0
            writerIndex = 0
        }
    }

    @inlinable
    public mutating func clear() {
        readerIndex = 0
        writerIndex = 0
    }

    /// Drops the allocation back to nothing. Call once, at teardown.
    @inlinable
    public mutating func destroy() {
        if let s = storage { free(s) }
        storage = nil
        capacity = 0
        readerIndex = 0
        writerIndex = 0
    }

    /// Releases ownership of the allocation to the caller (the pool).
    @inlinable
    public mutating func release() -> (UnsafeMutableRawPointer?, Int) {
        let p = storage
        let c = capacity
        storage = nil
        capacity = 0
        readerIndex = 0
        writerIndex = 0
        return (p.map { UnsafeMutableRawPointer($0) }, c)
    }
}

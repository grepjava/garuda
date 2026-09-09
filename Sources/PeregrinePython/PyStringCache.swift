//===----------------------------------------------------------------------===//
// Header-name to Python-object cache.
//
// Real traffic reuses the same few dozen header names forever: Host,
// User-Agent, Accept, Accept-Encoding, Cookie, Authorization. Turning
// "User-Agent" into the WSGI key "HTTP_USER_AGENT" means an allocation, a
// transform and a hash -- every request, for every header.
//
// This is a small open-addressed table keyed by the raw header-name bytes. On a
// hit, building an environ key is a hash, a memcmp and a pointer. Entries are
// interned Python strings owned by the cache for the life of the process, so
// dict insertion also skips hashing the key.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public struct PyStringCache {
    @usableFromInline
    struct Entry {
        @usableFromInline var hash: UInt32
        @usableFromInline var length: UInt16
        @usableFromInline var key: UnsafeMutablePointer<UInt8>?
        @usableFromInline var object: PyObj?

        @usableFromInline
        init(hash: UInt32, length: UInt16, key: UnsafeMutablePointer<UInt8>?, object: PyObj?) {
            self.hash = hash
            self.length = length
            self.key = key
            self.object = object
        }
    }

    @usableFromInline var entries: UnsafeMutablePointer<Entry>
    @usableFromInline let mask: Int
    @usableFromInline var count: Int
    /// Once the table is this full we stop inserting and fall back to building
    /// objects on demand. A flood of unique header names cannot grow it without
    /// bound, which would otherwise be a memory-exhaustion vector.
    @usableFromInline let limit: Int

    public init(capacityLog2: Int = 9) {
        let cap = 1 << capacityLog2
        mask = cap - 1
        limit = cap / 2
        count = 0
        entries = UnsafeMutablePointer<Entry>.allocate(capacity: cap)
        entries.initialize(repeating: Entry(hash: 0, length: 0, key: nil, object: nil),
                           count: cap)
    }

    @inlinable
    public static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
        var h: UInt32 = 2166136261
        var i = 0
        while i < n {
            h = (h ^ UInt32(asciiLower(p[i]))) &* 16777619
            i &+= 1
        }
        // Never return 0: it marks an empty slot.
        return h | 1
    }

    /// Result of a lookup. `owned` says whether the caller has to release the
    /// reference: cached entries are owned by the table and live forever, but
    /// once the table is saturated we hand back fresh objects instead of
    /// letting an attacker grow it with unique header names.
    public struct Result {
        public var object: PyObj?
        public var owned: Bool

        @inlinable
        public init(object: PyObj?, owned: Bool) {
            self.object = object
            self.owned = owned
        }
    }

    /// Looks up the object for `p[0..<n]`, creating it with `make` on a miss.
    /// `make` must return an owned reference.
    @inlinable
    public mutating func lookup(_ p: UnsafePointer<UInt8>, _ n: Int,
                                hash h: UInt32,
                                _ make: (UnsafePointer<UInt8>, Int) -> PyObj?) -> Result {
        var slot = Int(h) & mask
        while true {
            let e = entries[slot]
            guard let existing = e.object else { break }        // empty slot
            if e.hash == h, Int(e.length) == n,
               memcmp(e.key.unsafelyUnwrapped, p, n) == 0 {
                return Result(object: existing, owned: false)
            }
            slot = (slot &+ 1) & mask
        }

        guard let made = make(p, n) else { return Result(object: nil, owned: false) }
        if count >= limit || n > 0xFFFF {
            return Result(object: made, owned: true)
        }
        let keyCopy = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        memcpy(keyCopy, p, n)
        entries[slot] = Entry(hash: h, length: UInt16(n), key: keyCopy, object: made)
        count &+= 1
        return Result(object: made, owned: false)
    }

    /// Non-mutating so it can be called from the `deinit` of an owning
    /// noncopyable type, where `self` is only borrowed.
    public func destroy() {
        for i in 0...mask {
            if let k = entries[i].key { k.deallocate() }
            if let o = entries[i].object { pg_decref(o) }
        }
        entries.deallocate()
    }
}

//===----------------------------------------------------------------------===//
// Asking whether a type conforms to a protocol, once per type.
//
// `value as? any P` and `T.self is any P.Type` both ask the runtime, and the
// runtime charges about half a microsecond for the answer. On a path taken
// for every request that is more than the work it guards. The answer cannot
// change while the process runs, so it is asked once and remembered.
//
// Every thread of a shard reads the table, so a hit takes no lock: the
// table is open-addressed atomic words, each a type's metadata address with
// the answer in its low bit (metadata is pointer-aligned). A full table
// stops remembering and asks the runtime, which is slower and still right.
//===----------------------------------------------------------------------===//

import Synchronization

/// Whether types conform to one protocol, remembered as they are asked about.
final class ConformanceCache: @unchecked Sendable {
    private static let slots = 256
    private let table: UnsafeMutablePointer<Atomic<UInt>>
    private let ask: @Sendable (Any.Type) -> Bool

    /// - Parameter ask: the conformance question, such as
    ///   `{ $0 is any Validated.Type }`.
    init(_ ask: @escaping @Sendable (Any.Type) -> Bool) {
        self.ask = ask
        table = .allocate(capacity: ConformanceCache.slots)
        for i in 0..<ConformanceCache.slots { (table + i).initialize(to: Atomic(0)) }
    }

    deinit {
        table.deinitialize(count: ConformanceCache.slots)
        table.deallocate()
    }

    /// Whether `type` conforms.
    func holds(_ type: Any.Type) -> Bool {
        // A metatype is one pointer, to the type's metadata.
        let key = UInt(bitPattern: unsafeBitCast(type, to: Int.self)) & ~1
        var i = Int(truncatingIfNeeded: (key >> 4) &* 0x9E37_79B9) & (ConformanceCache.slots - 1)
        for _ in 0..<ConformanceCache.slots {
            let word = table[i].load(ordering: .acquiring)
            if word == 0 {
                let answer = ask(type)
                let (stored, found) = table[i].compareExchange(expected: 0, desired: key | (answer ? 1 : 0),
                                                               ordering: .acquiringAndReleasing)
                if stored || found & ~1 == key { return answer }
                // Another type took the slot first: keep probing.
                i = (i + 1) & (ConformanceCache.slots - 1)
                continue
            }
            if word & ~1 == key { return word & 1 == 1 }
            i = (i + 1) & (ConformanceCache.slots - 1)
        }
        return ask(type)
    }
}

/// A value remembered per type -- a conformance, say -- that every thread
/// reads without a lock. Open-addressed like `ConformanceCache`: a slot's
/// key word is the type's metadata address, published only after the value
/// beside it is written, so a reader that sees the key sees the value.
final class TypeTable<Value>: @unchecked Sendable {
    private static var slots: Int { 256 }
    private static var claimed: UInt { 1 }
    private let keys: UnsafeMutablePointer<Atomic<UInt>>
    private let values: UnsafeMutablePointer<Value?>
    private let make: @Sendable (Any.Type) -> Value?

    /// - Parameter make: the value for a type, worked out at most once per
    ///   type that finds a free slot.
    init(_ make: @escaping @Sendable (Any.Type) -> Value?) {
        self.make = make
        keys = .allocate(capacity: TypeTable.slots)
        values = .allocate(capacity: TypeTable.slots)
        for i in 0..<TypeTable.slots {
            (keys + i).initialize(to: Atomic(0))
            (values + i).initialize(to: nil)
        }
    }

    deinit {
        keys.deinitialize(count: TypeTable.slots)
        values.deinitialize(count: TypeTable.slots)
        keys.deallocate()
        values.deallocate()
    }

    /// The value for `type`.
    @inline(__always)
    func value(for type: Any.Type) -> Value? {
        let key = UInt(bitPattern: unsafeBitCast(type, to: Int.self)) & ~1
        let mask = TypeTable.slots - 1
        var i = Int(truncatingIfNeeded: (key >> 4) &* 0x9E37_79B9) & mask
        for _ in 0..<TypeTable.slots {
            let word = keys[i].load(ordering: .acquiring)
            if word == key { return values[i] }
            if word == 0 {
                // Claim the slot, fill it, then publish the key.
                if keys[i].compareExchange(expected: 0, desired: TypeTable.claimed,
                                           ordering: .acquiringAndReleasing).exchanged {
                    let found = make(type)
                    values[i] = found
                    keys[i].store(key, ordering: .releasing)
                    return found
                }
                continue // taken meanwhile: look at it again
            }
            if word == TypeTable.claimed {
                // Being filled for some type: perhaps this one. Asking costs
                // less than waiting.
                return make(type)
            }
            i = (i + 1) & mask
        }
        return make(type)
    }
}

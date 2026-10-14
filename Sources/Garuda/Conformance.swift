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

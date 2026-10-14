//===----------------------------------------------------------------------===//
// What happens when an allocation fails: a message saying which allocation
// and how large, then abort. The buffers here are value types on the request
// path, and threading a failure back out of every write would put a branch
// on every byte moved for a case Linux's overcommit does not produce.
// Vendored from aviancore's AvianCore/Allocation.swift.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// The largest a single buffer may grow to: past it doubling would overflow.
@usableFromInline
let maxBufferCapacity = Int.max / 2

@inline(never)
@usableFromInline
func allocationFailed(_ bytes: Int, _ what: StaticString) -> Never {
    fatalError("out of memory: could not allocate \(bytes) bytes for \(what)")
}

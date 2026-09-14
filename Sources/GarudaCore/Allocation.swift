//===----------------------------------------------------------------------===//
// What happens when an allocation fails.
//
// Nothing structured, and deliberately so. The buffers here are value types on
// the request path: `write` returns nothing, and threading a failure back out
// of it would put a branch on every byte this server moves, in exchange for
// handling a case that Linux's default overcommit does not produce -- the
// kernel kills the process rather than returning NULL from malloc.
//
// What is worth having is the difference between the two ways of dying. A
// force-unwrapped `malloc(n)!` aborts with no explanation, in a frame the
// backtrace attributes to whichever inlined caller happened to grow a buffer.
// This says which allocation failed and how large it was, which is the
// difference between "the server crashed" and "the server was asked for 4 GiB
// of response buffer".
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The largest a single buffer is allowed to grow to.
///
/// Not a policy limit -- the configured high water marks are that -- but the
/// point past which doubling would overflow and the growth loop would spin on
/// a wrapped capacity forever. A request for more than this is a bug or an
/// arithmetic overflow upstream, and neither is survivable by growing.
@usableFromInline
let maxBufferCapacity = Int.max / 2

@inline(never)
@usableFromInline
func allocationFailed(_ bytes: Int, _ what: StaticString) -> Never {
    Log.error { line in
        line.str("out of memory: could not allocate ")
        line.int(bytes)
        line.str(" bytes for ")
        line.str(what)
    }
    abort()
}

//===----------------------------------------------------------------------===//
// Carrying a value into a closure the compiler cannot see is safe.
//
// A worker is one process and one thread. The tasks a worker starts -- a
// start-up hook, a scheduled job, a handler -- all run on that thread, on the
// worker's own executor, so the pointer to the worker and the objects hanging
// off it are touched by one thread and never two.
//
// Swift cannot see that. Where it wants a `sending` closure, a local marked
// `nonisolated(unsafe)` is not enough: the local is still reachable from the
// scope the closure was made in, which is what the compiler objects to.
// Swift 6.3 reads the region well enough to allow several of these and 6.2
// does not, and the code is the same either way. This says the thing once,
// in a way both accept, and says it where a reader can see what is being
// claimed.
//===----------------------------------------------------------------------===//

/// A value handed to a closure that runs on the same thread it was made on.
///
/// The claim being made is not that `Value` is safe to share; it is that the
/// only two places touching it are this thread and a task pinned to it.
struct Unsafely<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// Somewhere for a closure to put an answer another closure reads, on the one
/// thread both run on.
final class UnsafelyShared<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) { self.value = value }
}

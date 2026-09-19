//===----------------------------------------------------------------------===//
// Asking whether a type conforms to a protocol, once per type.
//
// `value as? any P` and `T.self is any P.Type` both ask the runtime, and the
// runtime charges about half a microsecond for the answer. On a path taken
// once that is nothing; on one taken for every request it is more than the
// work it guards. The answer cannot change while the process runs, so it is
// asked once and remembered.
//
// The lock is never contended in practice -- a worker is one thread, and each
// worker is its own process -- so a hit is a lock, a hash and an unlock,
// tens of nanoseconds rather than hundreds.
//===----------------------------------------------------------------------===//

import Synchronization

/// Whether types conform to one protocol, remembered as they are asked about.
final class ConformanceCache: Sendable {
    private let known = Mutex<[ObjectIdentifier: Bool]>([:])
    private let ask: @Sendable (Any.Type) -> Bool

    /// - Parameter ask: the conformance question, such as
    ///   `{ $0 is any Validated.Type }`. Called at most once for each type.
    init(_ ask: @escaping @Sendable (Any.Type) -> Bool) {
        self.ask = ask
    }

    /// Whether `type` conforms.
    func holds(_ type: Any.Type) -> Bool {
        let key = ObjectIdentifier(type)
        return known.withLock { known in
            if let answer = known[key] { return answer }
            let answer = ask(type)
            known[key] = answer
            return answer
        }
    }
}

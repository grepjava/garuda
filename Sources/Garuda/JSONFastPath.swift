//===----------------------------------------------------------------------===//
// Finding a type's own JSON code, and using it.
//
// Nothing at a call site chooses between the two paths. `Body<Order>` and
// `JSON(receipt)` are written the same whether `Order` has a reader of its
// own or not; the coder asks, once per type, and takes whichever path the
// type has.
//
// Asking costs about half a microsecond -- a conformance lookup is not the
// table read it sounds like -- so the answer is remembered. What is
// remembered is the conformance itself and not just a yes or no, because
// calling through it is what the fast path needs, and a second lookup would
// undo the saving. Dispatching this way costs about 0.2 microseconds against
// the 3.5 it saves.
//===----------------------------------------------------------------------===//

import Synchronization

enum JSONFastPath {
    /// The reader a type has, or none, by type.
    private static let readers = Mutex<[ObjectIdentifier: (any JSONReadable.Type)?]>([:])
    /// Whether a type writes itself. The value is not kept: writing needs
    /// the value cast, not the type.
    private static let writers = ConformanceCache { $0 is any JSONWritable.Type }

    /// The type's own reader, or nil where it has none.
    static func reader(for type: Any.Type) -> (any JSONReadable.Type)? {
        let key = ObjectIdentifier(type)
        return readers.withLock { readers in
            if let found = readers[key] { return found }
            let answer = type as? any JSONReadable.Type
            readers[key] = answer
            return answer
        }
    }

    /// The bytes `value` writes for itself, or nil for Codable to write it.
    static func bytes(_ value: some Any) throws -> [UInt8]? {
        var output = JSONOutput()
        return try write(value, into: &output) ? output.bytes : nil
    }

    /// Reads `T` with its own reader, or returns nil for Codable to read it.
    static func read<T>(_ type: T.Type, from base: UnsafePointer<UInt8>, count: Int) throws -> T? {
        guard let reader = reader(for: T.self) else { return nil }
        return (try reader.decodeJSON(from: base, count: count) as! T)
    }

    /// Writes `value` into `output` with its own writer, or answers false
    /// for Codable to write it. The buffer belongs to the caller: a worker
    /// keeps one for every answer it writes, and nothing is shared between
    /// threads.
    static func write(_ value: some Any, into output: inout JSONOutput) throws -> Bool {
        guard writers.holds(type(of: value)), let writable = value as? any JSONWritable else {
            return false
        }
        output.reset()
        writable.write(json: &output)
        // A value that is not JSON -- an infinite Double -- is the handler's
        // mistake, and is refused rather than sent, as through Codable.
        if let problem = output.problem { throw problem }
        return true
    }
}

extension JSONReadable {
    /// Reads one of these from a whole document. Static, so that it can be
    /// called on the conformance the cache holds.
    fileprivate static func decodeJSON(from base: UnsafePointer<UInt8>,
                                       count: Int) throws -> Self {
        try JSONReader.decode(Self.self, from: base, count: count)
    }
}

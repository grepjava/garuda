//===----------------------------------------------------------------------===//
// Reading sequences and byte-like values out of Python objects.
//
// Both application interfaces hand the server "a sequence of (name, value)
// pairs", and both specifications describe that shape loosely. PEP 3333 says a
// list of tuples; the ASGI specification says an iterable of two-element
// iterables, and real frameworks emit tuples, lists and occasionally
// bytearrays. Insisting on one concrete type is the single most common source
// of "works on uvicorn, fails here" reports, so the readers here accept the
// whole documented shape and nothing wider.
//
// None of this allocates for the common case: a bytes object is viewed in
// place, and only exotic buffer types are materialised (with an owner the
// caller must release).
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// list or tuple, read positionally. Anything else is rejected by `isSequence`
/// rather than silently mis-sized -- `pg_tuple_size` on a non-tuple is
/// undefined, so the check has to come first.
public enum PySeq {

    @inlinable
    public static func isSequence(_ o: PyObj) -> Bool {
        pg_is_list(o) != 0 || pg_is_tuple(o) != 0
    }

    @inlinable
    public static func count(_ o: PyObj) -> Int {
        pg_is_list(o) != 0 ? Int(pg_list_size(o)) : Int(pg_tuple_size(o))
    }

    /// Borrowed element reference, or nil when the index is out of range.
    @inlinable
    public static func item(_ o: PyObj, _ i: Int) -> PyObj? {
        pg_is_list(o) != 0 ? pg_list_get(o, pg_ssize_t(i)) : pg_tuple_get(o, pg_ssize_t(i))
    }

    /// Unpacks a two-element list or tuple. Returns nil for anything else.
    @inlinable
    public static func pair(_ o: PyObj) -> (PyObj, PyObj)? {
        guard isSequence(o), count(o) == 2,
              let a = item(o, 0), let b = item(o, 1) else { return nil }
        return (a, b)
    }

    /// ASGI says headers are an iterable of pairs, not a list. A generator
    /// is materialised once; a list or tuple is borrowed.
    @inlinable
    public static func iterable(_ o: PyObj) -> (seq: PyObj, owned: Bool)? {
        if isSequence(o) { return (o, false) }
        guard let list = pg_as_list(o) else { return nil }
        return (list, true)
    }
}

/// A borrowed view of the bytes behind a Python object.
///
/// `bytes` and `bytearray` are viewed in place. `str` is viewed through its
/// latin-1 or UTF-8 representation, which is what PEP 3333 native strings are.
/// Anything else supporting the buffer protocol is materialised once, and
/// `release()` drops that temporary. `release()` must be called exactly once,
/// and is safe when nothing was materialised.
public struct PyBytesView {
    public var base: UnsafePointer<UInt8>
    public var count: Int
    @usableFromInline var owner: PyObj?

    @inlinable
    public init(base: UnsafePointer<UInt8>, count: Int, owner: PyObj?) {
        self.base = base
        self.count = count
        self.owner = owner
    }

    @inlinable
    public var span: ByteSpan { ByteSpan(base, count) }

    @inlinable
    public func release() { pg_release_bytes(owner) }

    /// Views `o` as bytes. Leaves a Python exception pending and returns nil
    /// when the object carries no usable byte representation.
    public static func of(_ o: PyObj) -> PyBytesView? {
        if pg_is_str(o) != 0 {
            var len: pg_ssize_t = 0
            // A native string built from request bytes is compact latin-1, so
            // this is a pointer into the existing object in the common case.
            if let raw = pg_str_latin1_data(o, &len) {
                return PyBytesView(
                    base: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self),
                    count: Int(len), owner: nil)
            }
            pg_err_clear()
            guard let raw = pg_str_utf8_data(o, &len) else { return nil }
            return PyBytesView(
                base: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self),
                count: Int(len), owner: nil)
        }
        var data: UnsafePointer<CChar>?
        var len: pg_ssize_t = 0
        var owner: PyObj?
        if pg_as_bytes(o, &data, &len, &owner) != 0 { return nil }
        guard let data else {
            pg_release_bytes(owner)
            // A zero-length bytes object can legitimately report a null
            // pointer; point at something valid rather than at nothing.
            return PyBytesView(base: emptyByte, count: 0, owner: nil)
        }
        return PyBytesView(base: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self),
                           count: Int(len), owner: owner)
    }
}

/// Static storage, so a zero-length view still has a valid base pointer.
private let emptyByteStorage: StaticString = ""
private var emptyByte: UnsafePointer<UInt8> { emptyByteStorage.utf8Start }

//===----------------------------------------------------------------------===//
// Owning and borrowed handles on Python objects.
//
// This is where the "minimise ARC" goal actually pays off. A Python object has
// its own reference count, and in a standard (non-free-threaded) CPython that
// count is a plain non-atomic increment protected by the GIL. If we wrapped
// PyObject pointers in a Swift class we would pay TWO reference counts per
// object: Swift's atomic one on top of Python's cheap one.
//
// Instead:
//   * `PyRef` is a ~Copyable struct holding a strong Python reference. Its
//     deinit calls Py_DECREF. The compiler enforces single ownership and
//     inserts the decref exactly once, on every path, with no runtime cost.
//   * `PyPtr` is a trivial borrowed pointer for arguments that outlive the
//     call. It compiles to a bare pointer in a register.
//
// Net effect: reference counting on the request path is Python's, never
// Swift's, and every Python object we create is released deterministically at
// end of scope rather than by a retain/release dance.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// CPython exposes `PyObject` as an incomplete type, so Swift imports pointers
/// to it as `OpaquePointer`.
public typealias PyObj = OpaquePointer

/// A borrowed, non-owning reference. Trivial: no ARC, no cleanup.
public struct PyPtr {
    public var raw: PyObj
    @inlinable public init(_ raw: PyObj) { self.raw = raw }
}

/// A strong reference to a Python object. Non-copyable, so the decref happens
/// exactly once and the compiler proves it.
public struct PyRef: ~Copyable {
    @usableFromInline var ptr: PyObj?

    /// Takes ownership of a reference that is already owned by the caller --
    /// the normal case for anything a `pg_*` constructor returns.
    @inlinable
    public init(stealing p: PyObj?) { ptr = p }

    /// Adds a reference to an object we only borrow.
    @inlinable
    public init(retaining p: PyObj) {
        pg_incref(p)
        ptr = p
    }

    @inlinable
    public init() { ptr = nil }

    deinit {
        if let p = ptr { pg_decref(p) }
    }

    @inlinable public var isNil: Bool { ptr == nil }

    /// Borrow the underlying pointer for the duration of a call. The reference
    /// stays owned by `self`.
    @inlinable
    public var borrowed: PyObj { ptr.unsafelyUnwrapped }

    @inlinable
    public var optional: PyObj? { ptr }

    /// Gives up ownership to the caller, who becomes responsible for the
    /// decref (or for handing it to something that steals references).
    ///
    /// Deliberately not `@inlinable`: `discard self` is not permitted in an
    /// inlinable member of a non-frozen type, and freezing PyRef would pin its
    /// layout for no benefit.
    public consuming func take() -> PyObj? {
        let p = ptr
        ptr = nil
        discard self
        return p
    }

    /// Drops the reference early.
    @inlinable
    public mutating func clear() {
        if let p = ptr {
            pg_decref(p)
            ptr = nil
        }
    }

    /// Replaces the referent, releasing the previous one.
    @inlinable
    public mutating func reset(stealing p: PyObj?) {
        let old = ptr
        ptr = p
        if let old { pg_decref(old) }
    }
}

/// Formats and logs the pending Python exception, then clears it.
///
/// Uses a stack buffer: an application traceback must never be the thing that
/// allocates during error handling.
public enum PyError {
    public static func logPending(_ context: StaticString) {
        guard pg_err_check() != 0 else { return }
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 8192) { buf in
            let n = pg_err_format(buf.baseAddress!, 8192)
            Log.error { line in
                line.str(context)
                line.str(": ")
            }
            if n > 0 {
                buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(n)) { p in
                    Log.raw(p, Int(n))
                }
            }
        }
    }

    /// Clears the pending exception without reporting it. Used where the failure
    /// is expected and already handled (a cancelled task, a closed connection).
    @inlinable
    public static func discardPending() {
        if pg_err_check() != 0 { pg_err_clear() }
    }
}

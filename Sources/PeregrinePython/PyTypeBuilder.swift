//===----------------------------------------------------------------------===//
// Defining Python types from Swift.
//
// The objects an ASGI request needs -- `send`, `receive`, and the awaitable
// they return -- are created two or three times per request. Implementing them
// in Python would mean a Python-level call for every `await send(...)`; here
// they are real C-level types whose slots are Swift `@convention(c)` functions,
// so `await send(msg)` costs a tp_call plus a tp_iternext and nothing else.
//
// Instances all share one layout (see pg_obj_* in the C shim): two context
// words, two integers, one owned object reference.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum PySlotKind: Int32 {
    case dealloc = 1
    case call = 2
    case iter = 3
    case iternext = 4
    case methods = 5
    case await_ = 6
}

public enum PyMethodKind: Int32 {
    case noArgs = 1
    case oneArg = 2
    case varArgs = 3
    case fastCall = 4
}

/// Builds a heap type. The slot array lives only for the duration of
/// `build`, because `PyType_FromSpec` copies it -- with the sole exception of
/// a `methods` slot, whose PyMethodDef array must outlive the type and is
/// therefore allocated permanently by `PyMethodTable`.
public struct PyTypeBuilder: ~Copyable {
    @usableFromInline var slots: UnsafeMutablePointer<pg_type_slot>
    @usableFromInline var n: Int
    @usableFromInline let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = capacity + 1
        self.slots = UnsafeMutablePointer<pg_type_slot>.allocate(capacity: capacity + 1)
        self.n = 0
    }

    deinit { slots.deallocate() }

    public mutating func add(_ kind: PySlotKind, _ fn: UnsafeMutableRawPointer) {
        precondition(n < capacity - 1, "PyTypeBuilder overflow")
        pg_slot_set(slots, Int32(n), kind.rawValue, fn)
        n += 1
    }

    /// Registers a method table. The table must have process lifetime.
    public mutating func addMethods(_ table: borrowing PyMethodTable) {
        add(.methods, UnsafeMutableRawPointer(table.entries))
    }

    /// Creates the type. Returns an owned reference, normally kept forever.
    public borrowing func build(_ name: UnsafePointer<CChar>) -> PyObj? {
        pg_slot_end(slots, Int32(n))
        guard let t = pg_type_new(name, slots, pg_obj_basicsize()) else {
            PyError.logPending("creating an internal Python type")
            return nil
        }
        return t
    }
}

/// A permanently-allocated PyMethodDef array. CPython keeps the pointer, so
/// this is intentionally never freed.
public struct PyMethodTable {
    public let entries: UnsafeMutablePointer<pg_method_def>
    @usableFromInline var n: Int
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity + 1
        self.entries = UnsafeMutablePointer<pg_method_def>.allocate(capacity: capacity + 1)
        self.n = 0
        pg_method_end(entries, 0)
    }

    /// `name` must be a string literal so its storage is static.
    public mutating func add(_ name: StaticString,
                             _ kind: PyMethodKind,
                             _ fn: UnsafeMutableRawPointer) {
        precondition(n < capacity - 1, "PyMethodTable overflow")
        name.utf8Start.withMemoryRebound(to: CChar.self,
                                         capacity: name.utf8CodeUnitCount + 1) { cname in
            pg_method_set(entries, Int32(n), cname, fn, kind.rawValue)
        }
        n += 1
        pg_method_end(entries, Int32(n))
    }
}

// MARK: - Slot function signatures

/// `PyObject *(*)(PyObject *self, PyObject *args, PyObject *kwargs)`
public typealias PyTernaryFn = @convention(c) (PyObj?, PyObj?, PyObj?) -> PyObj?
/// `PyObject *(*)(PyObject *self)`
public typealias PyUnaryFn = @convention(c) (PyObj?) -> PyObj?
/// `void (*)(PyObject *self)`
public typealias PyDestructorFn = @convention(c) (PyObj?) -> Void
/// `PyObject *(*)(PyObject *self, PyObject *arg)`
public typealias PyBinaryFn = @convention(c) (PyObj?, PyObj?) -> PyObj?
/// `PyObject *(*)(PyObject *self, PyObject *const *args, Py_ssize_t nargs)`
public typealias PyFastCallFn = @convention(c) (PyObj?, UnsafePointer<PyObj?>?, Int) -> PyObj?

@inlinable
public func slotFn(_ f: PyTernaryFn) -> UnsafeMutableRawPointer {
    unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
}
@inlinable
public func slotFn(_ f: PyUnaryFn) -> UnsafeMutableRawPointer {
    unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
}
@inlinable
public func slotFn(_ f: PyDestructorFn) -> UnsafeMutableRawPointer {
    unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
}
@inlinable
public func slotFn(_ f: PyBinaryFn) -> UnsafeMutableRawPointer {
    unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
}
@inlinable
public func slotFn(_ f: PyFastCallFn) -> UnsafeMutableRawPointer {
    unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
}

// MARK: - Shared "immediate awaitable"

/// An awaitable that is already complete.
///
/// `await send(message)` normally has nothing to wait for -- the bytes go
/// straight into the connection write buffer. Returning an `asyncio.Future`
/// there would allocate a Future, schedule a callback and take a full trip
/// through the event loop. This type instead raises `StopIteration(value)` on
/// the first `__next__`, so the coroutine resumes immediately without ever
/// yielding to the loop.
public enum PyImmediate {
    nonisolated(unsafe) public private(set) static var type: PyObj! = nil

    public static func register() -> Bool {
        var b = PyTypeBuilder(capacity: 4)
        b.add(.dealloc, slotFn(immediateDealloc as PyDestructorFn))
        b.add(.await_, slotFn(immediateAwait as PyUnaryFn))
        b.add(.iter, slotFn(immediateAwait as PyUnaryFn))
        b.add(.iternext, slotFn(immediateNext as PyUnaryFn))
        guard let t = b.build("peregrine.Immediate") else { return false }
        type = t
        return true
    }

    /// Wraps `value` (a borrowed reference, retained by the awaitable).
    /// Pass nil for `None`.
    @inlinable
    public static func make(_ value: PyObj?) -> PyObj? {
        guard let obj = pg_obj_alloc(type) else { return nil }
        if let value {
            pg_incref(value)
            pg_obj_set_ref(obj, value)
        }
        return obj
    }
}

private func immediateDealloc(_ selfObj: PyObj?) {
    pg_obj_free(selfObj)
}

private func immediateAwait(_ selfObj: PyObj?) -> PyObj? {
    // The awaitable is its own iterator: no second object per await.
    pg_incref(selfObj!)
    return selfObj
}

private func immediateNext(_ selfObj: PyObj?) -> PyObj? {
    // Raising StopIteration(value) is how a coroutine receives an await result.
    pg_err_set_stop_iteration(pg_obj_ref(selfObj))
    return nil
}

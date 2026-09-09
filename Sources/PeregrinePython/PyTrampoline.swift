//===----------------------------------------------------------------------===//
// A Python callable backed by a C function pointer.
//
// asyncio needs real Python callables for add_reader, call_later and
// add_done_callback. Creating those with a Python-level lambda would mean a
// Python frame on every event-loop wakeup. This type is a C-level callable:
// invoking it runs one Swift function with a context word, and nothing else.
//
// One type serves every internal callback in the server, so it is registered
// once and costs a single heap type for the process.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum PyTrampoline {
    /// `(context, argsTuple) -> result`. Returning nil with a Python error set
    /// propagates the exception; returning nil without one is treated as None.
    public typealias Fn = @convention(c) (UInt64, PyObj?) -> PyObj?

    nonisolated(unsafe) public private(set) static var type: PyObj! = nil

    public static func register() -> Bool {
        var b = PyTypeBuilder(capacity: 2)
        b.add(.dealloc, slotFn(trampolineDealloc as PyDestructorFn))
        b.add(.call, slotFn(trampolineCall as PyTernaryFn))
        guard let t = b.build("peregrine.Callback") else { return false }
        type = t
        return true
    }

    /// Creates a callable. Returns an owned reference.
    @inlinable
    public static func make(_ fn: Fn, context: UInt64) -> PyObj? {
        guard let obj = pg_obj_alloc(type) else { return nil }
        pg_obj_set_ctx(obj, unsafeBitCast(fn, to: UnsafeMutableRawPointer.self))
        pg_obj_set_i0(obj, Int64(bitPattern: context))
        return obj
    }
}

private func trampolineDealloc(_ selfObj: PyObj?) {
    pg_obj_free(selfObj)
}

private func trampolineCall(_ selfObj: PyObj?, _ args: PyObj?, _ kwargs: PyObj?) -> PyObj? {
    let raw = pg_obj_ctx(selfObj)
    let fn = unsafeBitCast(raw, to: PyTrampoline.Fn.self)
    let context = UInt64(bitPattern: pg_obj_i0(selfObj))
    if let result = fn(context, args) { return result }
    if pg_err_check() != 0 { return nil }
    let none = Interned.none!
    pg_incref(none)
    return none
}

//===----------------------------------------------------------------------===//
// start_response
//
// One C-level callable that plays both roles PEP 3333 defines:
//
//   start_response(status, headers[, exc_info])  ->  returns itself
//   write(bytes)                                 ->  the legacy write callable
//
// The two are told apart by their arguments (one bytes argument is a write,
// anything else is a start_response), which means the legacy `write` callable
// costs no second object. Almost every application ignores the return value, so
// the common path allocates nothing at all beyond this one object per request.
//
// Nothing is sent from here. The status and header list are just parked on the
// object; the server reads them after the application returns, which is what
// lets it decide framing (Content-Length vs chunked) with full information.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrinePython

public enum WSGIStartResponse {
    nonisolated(unsafe) public private(set) static var type: PyObj! = nil

    public static func register() -> Bool {
        var b = PyTypeBuilder(capacity: 3)
        b.add(.dealloc, slotFn(srDealloc as PyDestructorFn))
        b.add(.call, slotFn(srCall as PyTernaryFn))
        guard let t = b.build("peregrine.StartResponse") else { return false }
        type = t
        return true
    }

    public static func make() -> PyObj? {
        pg_obj_alloc(type)
    }

    /// Borrowed status string, or nil if the application never called us.
    @inlinable
    public static func status(_ obj: PyObj) -> PyObj? { pg_obj_ref(obj) }

    /// Borrowed header list.
    @inlinable
    public static func headers(_ obj: PyObj) -> PyObj? { pg_obj_ref2(obj) }

    /// Borrowed list of chunks passed to the legacy `write()` callable, or nil.
    @inlinable
    public static func writtenChunks(_ obj: PyObj) -> PyObj? { pg_obj_ref3(obj) }

    @inlinable
    public static func wasCalled(_ obj: PyObj) -> Bool { pg_obj_i0(obj) != 0 }

    /// Set by the server once bytes have gone out, so a later
    /// `start_response(..., exc_info)` correctly re-raises instead of
    /// rewriting headers that the client has already seen.
    @inlinable
    public static func markHeadersSent(_ obj: PyObj) { pg_obj_set_i1(obj, 1) }
}

private func srDealloc(_ selfObj: PyObj?) {
    pg_obj_free(selfObj)
}

private func srCall(_ selfObj: PyObj?, _ args: PyObj?, _ kwargs: PyObj?) -> PyObj? {
    guard let selfObj, let args else { return nil }
    let n = Int(pg_tuple_size(args))

    // ---- legacy write(data) ----
    // start_response always takes at least two arguments, so a single argument
    // is unambiguously the write callable.
    if n == 1 {
        let arg = pg_tuple_get(args, 0)!
        if pg_obj_ref3(selfObj) == nil {
            guard let list = pg_list_empty_new() else { return nil }
            pg_obj_set_ref3(selfObj, list)
        }
        guard let list = pg_obj_ref3(selfObj) else { return nil }
        if pg_list_append(list, arg) != 0 { return nil }
        let none = Interned.none!
        pg_incref(none)
        return none
    }

    // ---- start_response(status, headers[, exc_info]) ----
    if n < 2 || n > 3 {
        pg_err_set_str(pg_exc_type(), "start_response() takes 2 or 3 arguments")
        return nil
    }
    let status = pg_tuple_get(args, 0)!
    let headers = pg_tuple_get(args, 1)!

    if pg_is_str(status) == 0 {
        pg_err_set_str(pg_exc_type(), "status must be a str")
        return nil
    }

    if n == 3 {
        let excInfo = pg_tuple_get(args, 2)!
        if pg_is(excInfo, Interned.none) == 0 {
            // PEP 3333: with exc_info and headers already on the wire, the
            // server must re-raise so the failure is not silently swallowed.
            if pg_obj_i1(selfObj) != 0 {
                pg_err_restore_from_exc_info(excInfo)
                return nil
            }
        }
    } else if pg_obj_i0(selfObj) != 0 {
        pg_err_set_str(pg_exc_runtime(),
                       "start_response() called twice without exc_info")
        return nil
    }

    pg_incref(status)
    pg_obj_set_ref(selfObj, status)
    pg_incref(headers)
    pg_obj_set_ref2(selfObj, headers)
    pg_obj_set_i0(selfObj, 1)

    // Returning self is what makes this object double as the write callable.
    pg_incref(selfObj)
    return selfObj
}

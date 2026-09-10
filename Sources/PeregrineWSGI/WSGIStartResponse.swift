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
// start_response sends nothing: the status and header list are parked on the
// object, and the server reads them after the application returns, which is
// what lets it decide framing (Content-Length vs chunked) with full
// information.
//
// `write` is the opposite, and has to be. PEP 3333 provides it for frameworks
// whose output API is imperative, and requires the block to go out before the
// call returns -- an application that writes a progress line and then works for
// a second means the client to see that line during the second, not after it.
// So a write reaches the server through a sink the server installs before it
// calls the application: the first one sends the head (with no length to
// declare, so chunked), and every one after it appends and flushes. Collecting
// the blocks in a list here, which is what this did until it was measured,
// delays every byte until the application returns.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrinePython

/// Where the bytes handed to the legacy `write()` callable go.
///
/// Called with the context the server installed, the `start_response` object
/// (which carries the parked status and headers, so the sink can send the head
/// on the first write), and the block. Returns 0, or -1 with a Python exception
/// set — which surfaces inside the application, at its `write()` call, where a
/// dead client belongs.
public typealias WSGIWriteSink =
    @convention(c) (UnsafeMutableRawPointer?, PyObj?, PyObj?) -> Int32

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

    /// Installs the sink `write()` delivers to. The server does this before it
    /// calls the application; `context` must outlive that call.
    @inlinable
    public static func setSink(_ obj: PyObj, _ sink: @escaping WSGIWriteSink,
                               context: UnsafeMutableRawPointer?) {
        pg_obj_set_ctx(obj, context)
        pg_obj_set_ctx2(obj, unsafeBitCast(sink, to: UnsafeMutableRawPointer.self))
    }

    /// Unhooks the sink, which the server must do before the context behind it
    /// goes away.
    ///
    /// This object outlives the request whenever the application keeps the
    /// callable `start_response` returned -- nothing stops it storing that in a
    /// module global and calling it during some later request. The context it
    /// points at does not outlive the request: inline it is a frame that has
    /// returned, pooled it is a job that has been released. Clearing it turns
    /// such a call into a Python exception in the application that made it,
    /// which is the only place it can honestly be reported.
    @inlinable
    public static func clearSink(_ obj: PyObj) {
        pg_obj_set_ctx(obj, nil)
        pg_obj_set_ctx2(obj, nil)
    }

    /// Whether the head is already on the wire. A `write()` puts it there
    /// before the application returns; otherwise it goes out afterwards, when
    /// `start_response` can no longer be called anyway.
    @inlinable
    public static func headersSent(_ obj: PyObj) -> Bool { pg_obj_i1(obj) != 0 }

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
        if pg_obj_i0(selfObj) == 0 {
            pg_err_set_str(pg_exc_runtime(),
                           "write() before start_response()")
            return nil
        }
        if pg_is_bytes(arg) == 0 {
            pg_err_set_str(pg_exc_type(), "write() takes a bytes object")
            return nil
        }
        guard let raw = pg_obj_ctx2(selfObj) else {
            // The server installs a sink before it calls the application and
            // removes it when the response is done, so getting here means the
            // application kept the callable and called it after its request.
            pg_err_set_str(pg_exc_runtime(),
                           "write() called outside its own request")
            return nil
        }
        let sink = unsafeBitCast(raw, to: WSGIWriteSink.self)
        if sink(pg_obj_ctx(selfObj), selfObj, arg) != 0 {
            // The sink set the exception; PEP 3333 wants the application to
            // see it rather than the server to swallow it.
            return nil
        }
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

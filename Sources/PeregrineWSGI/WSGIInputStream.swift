//===----------------------------------------------------------------------===//
// wsgi.input
//
// A C-level file-like object over the buffered request body. The alternative --
// handing the application an io.BytesIO -- costs an extra object, an extra copy
// of the body, and a Python-level call for every read().
//
// The body is held as a single `bytes` object that this stream owns, so an
// application that (incorrectly) keeps wsgi.input alive past the call cannot
// read freed memory.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrinePython

public enum WSGIInputStream {
    nonisolated(unsafe) public private(set) static var type: PyObj! = nil
    nonisolated(unsafe) private static var methods = PyMethodTable(capacity: 8)

    public static func register() -> Bool {
        methods.add("read", .fastCall, slotFn(inputRead as PyFastCallFn))
        methods.add("readline", .fastCall, slotFn(inputReadline as PyFastCallFn))
        methods.add("readlines", .fastCall, slotFn(inputReadlines as PyFastCallFn))
        methods.add("close", .noArgs, slotFn(inputClose as PyBinaryFn))
        methods.add("seekable", .noArgs, slotFn(inputFalse as PyBinaryFn))
        methods.add("readable", .noArgs, slotFn(inputTrue as PyBinaryFn))
        methods.add("writable", .noArgs, slotFn(inputFalse as PyBinaryFn))

        var b = PyTypeBuilder(capacity: 5)
        b.add(.dealloc, slotFn(inputDealloc as PyDestructorFn))
        b.add(.iter, slotFn(inputIter as PyUnaryFn))
        b.add(.iternext, slotFn(inputIterNext as PyUnaryFn))
        b.addMethods(methods)
        guard let t = b.build("peregrine.Input") else { return false }
        type = t
        return true
    }

    /// `body` is a borrowed `bytes`; the stream takes its own reference.
    public static func make(body: PyObj) -> PyObj? {
        guard let obj = pg_obj_alloc(type) else { return nil }
        pg_incref(body)
        pg_obj_set_ref(obj, body)
        pg_obj_set_i0(obj, 0)                       // position
        pg_obj_set_i1(obj, Int64(pg_bytes_len(body)))
        return obj
    }
}

// MARK: - Slot implementations

/// Returns nil once `close()` has released the body, so every read path
/// degrades to "empty" instead of dereferencing a dropped reference.
@inline(__always)
private func streamBase(_ selfObj: PyObj?) -> (UnsafePointer<UInt8>, Int, Int)? {
    guard let body = pg_obj_ref(selfObj), let raw = pg_bytes_data(body) else { return nil }
    let p = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
    return (p, Int(pg_obj_i0(selfObj)), Int(pg_obj_i1(selfObj)))
}

@inline(__always)
private func emptyBytesRef() -> PyObj? {
    let empty = Interned.emptyBytes!
    pg_incref(empty)
    return empty
}

/// Reads the optional integer first argument, treating a missing value or None
/// as "everything".
@inline(__always)
private func optionalCount(_ args: UnsafePointer<PyObj?>?, _ nargs: Int) -> Int {
    guard nargs >= 1, let a = args?[0] else { return -1 }
    if pg_is(a, Interned.none) != 0 { return -1 }
    let v = pg_int_as_long(a)
    if v < 0 && pg_err_check() != 0 { return -2 }
    return v < 0 ? -1 : Int(v)
}

private func inputRead(_ selfObj: PyObj?, _ args: UnsafePointer<PyObj?>?, _ nargs: Int) -> PyObj? {
    let want = optionalCount(args, nargs)
    if want == -2 { return nil }
    guard let (p, pos, len) = streamBase(selfObj) else { return emptyBytesRef() }
    let available = len - pos
    let take = (want < 0 || want > available) ? available : want
    if take <= 0 { return emptyBytesRef() }
    pg_obj_set_i0(selfObj, Int64(pos + take))
    return p.withMemoryRebound(to: CChar.self, capacity: len) { cp in
        pg_bytes(cp + pos, pg_ssize_t(take))
    }
}

private func inputReadline(_ selfObj: PyObj?, _ args: UnsafePointer<PyObj?>?, _ nargs: Int) -> PyObj? {
    let limit = optionalCount(args, nargs)
    if limit == -2 { return nil }
    guard let (p, pos, len) = streamBase(selfObj) else { return emptyBytesRef() }
    if pos >= len { return emptyBytesRef() }
    var end = len
    let idx = findByte(p + pos, len - pos, cLF)
    if idx >= 0 { end = pos + idx + 1 }
    if limit >= 0 && end - pos > limit { end = pos + limit }
    pg_obj_set_i0(selfObj, Int64(end))
    return p.withMemoryRebound(to: CChar.self, capacity: len) { cp in
        pg_bytes(cp + pos, pg_ssize_t(end - pos))
    }
}

private func inputReadlines(_ selfObj: PyObj?, _ args: UnsafePointer<PyObj?>?, _ nargs: Int) -> PyObj? {
    let hint = optionalCount(args, nargs)
    if hint == -2 { return nil }
    guard let list = pg_list_empty_new() else { return nil }
    var produced = 0
    while true {
        guard let line = inputReadline(selfObj, nil, 0) else {
            pg_decref(list)
            return nil
        }
        let n = Int(pg_bytes_len(line))
        if n == 0 { pg_decref(line); break }
        let rc = pg_list_append(list, line)
        pg_decref(line)
        if rc != 0 { pg_decref(list); return nil }
        produced += n
        if hint >= 0 && produced >= hint { break }
    }
    return list
}

private func inputIter(_ selfObj: PyObj?) -> PyObj? {
    pg_incref(selfObj!)
    return selfObj
}

private func inputIterNext(_ selfObj: PyObj?) -> PyObj? {
    guard let line = inputReadline(selfObj, nil, 0) else { return nil }
    if pg_bytes_len(line) == 0 {
        pg_decref(line)
        return nil          // exhausted: NULL with no exception set
    }
    return line
}

private func inputClose(_ selfObj: PyObj?, _ unused: PyObj?) -> PyObj? {
    // Releasing the body early lets a large request body be reclaimed as soon
    // as the application is done with it.
    pg_obj_set_ref(selfObj, nil)
    pg_obj_set_i1(selfObj, 0)
    let none = Interned.none!
    pg_incref(none)
    return none
}

private func inputTrue(_ selfObj: PyObj?, _ unused: PyObj?) -> PyObj? {
    let v = Interned.pyTrue!
    pg_incref(v)
    return v
}

private func inputFalse(_ selfObj: PyObj?, _ unused: PyObj?) -> PyObj? {
    let v = Interned.pyFalse!
    pg_incref(v)
    return v
}

private func inputDealloc(_ selfObj: PyObj?) {
    pg_obj_free(selfObj)
}

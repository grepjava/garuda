//===----------------------------------------------------------------------===//
// --request-start-header: when the request arrived, for queue-time reporting.
//
// A request's latency has two parts, and middleware can only see one of them.
// Everything from the application being called to it returning is visible to
// a tracer running inside it. Everything before -- the worker finishing the
// request ahead of this one, a WSGI pool with no thread free, an event loop
// behind on its callbacks -- happened before any of the application's code
// ran, and is invisible to it unless the server says when it started.
//
// `X-Request-Start: t=<microseconds>` is how a proxy traditionally says so, and
// what New Relic, Datadog and Scout read to report queue time. The server adds
// it as though a proxy had, which makes those agents work without one. A proxy
// that already sends it is left alone: it saw the request first, so its time
// is the better one.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

extension Worker {

    /// Writes `t=<microseconds since the epoch>` into `out`, or returns false
    /// when the flag is off or the request already carries the header.
    ///
    /// Reads the parsed header array, so it is only valid during dispatch.
    private func requestStartStamp(_ slot: Int, _ out: inout ByteBuffer) -> Bool {
        guard config.requestStartHeader else { return false }
        let c = table[slot]
        let base = c.pointee.headBase()
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            if h.name.length == 15
                && equalsLowercased(base + Int(h.name.offset), 15, "x-request-start") {
                return false
            }
        }
        // Wall-clock already: the agent reading this compares it with its own
        // clock, and on plaintext it came from the kernel's receive timestamp.
        let started = c.pointee.headStartUs
        let at = started > 0 ? started : pg_realtime_us()
        out.write("t=")
        out.writeDecimal(Int(at))
        return true
    }

    /// HTTP_X_REQUEST_START in a WSGI environ.
    func stampRequestStart(_ slot: Int, environ: PyObj) {
        var stamp = ByteBuffer(capacity: 32)
        defer { stamp.destroy() }
        guard requestStartStamp(slot, &stamp) else { return }
        let key: StaticString = "HTTP_X_REQUEST_START"
        guard let keyObj = key.utf8Start.withMemoryRebound(
                to: CChar.self, capacity: key.utf8CodeUnitCount,
                { pg_str_latin1($0, pg_ssize_t(key.utf8CodeUnitCount)) }),
              let value = UnsafePointer(stamp.readPointer).withMemoryRebound(
                to: CChar.self, capacity: stamp.readableBytes,
                { pg_str_latin1($0, pg_ssize_t(stamp.readableBytes)) }) else {
            pg_err_clear()
            return
        }
        defer {
            pg_decref(keyObj)
            pg_decref(value)
        }
        if pg_dict_set(environ, keyObj, value) != 0 { pg_err_clear() }
    }

    /// `(b"x-request-start", b"t=...")` appended to an ASGI scope's headers.
    func stampRequestStart(_ slot: Int, scope: PyObj) {
        var stamp = ByteBuffer(capacity: 32)
        defer { stamp.destroy() }
        guard requestStartStamp(slot, &stamp),
              let list = pg_dict_get(scope, Interned[.headers]) else { return }
        let name: StaticString = "x-request-start"
        guard let nameObj = name.utf8Start.withMemoryRebound(
                to: CChar.self, capacity: name.utf8CodeUnitCount,
                { pg_bytes($0, pg_ssize_t(name.utf8CodeUnitCount)) }),
              let valueObj = UnsafePointer(stamp.readPointer).withMemoryRebound(
                to: CChar.self, capacity: stamp.readableBytes,
                { pg_bytes($0, pg_ssize_t(stamp.readableBytes)) }) else {
            pg_err_clear()
            return
        }
        defer {
            pg_decref(nameObj)
            pg_decref(valueObj)
        }
        guard let pair = pg_tuple2(nameObj, valueObj) else {
            pg_err_clear()
            return
        }
        if pg_list_append(list, pair) != 0 { pg_err_clear() }
        pg_decref(pair)
    }
}

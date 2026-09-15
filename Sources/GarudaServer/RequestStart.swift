//===----------------------------------------------------------------------===//
// --request-start-header: when the request arrived, for queue-time reporting.
//
// A request's latency has two parts, and middleware can only see one of them.
// Everything from the application being called to it returning is visible to
// a tracer running inside it. Everything before -- the worker finishing the
// requests ahead of this one, a connection waiting in the accept queue --
// happened before any of the application's code ran, and is invisible to it
// unless the server says when it started.
//
// `X-Request-Start: t=<microseconds>` is how a proxy traditionally says so, and
// what New Relic, Datadog and Scout read to report queue time. The server adds
// it as though a proxy had, which makes those agents work without one. A proxy
// that already sends it is left alone: it saw the request first, so its time
// is the better one.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

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

}

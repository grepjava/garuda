//===----------------------------------------------------------------------===//
// --request-start-header: when the request arrived, for queue-time reporting.
//
// A request's latency has two parts, and a tracer inside a handler can only
// see one of them. Everything from the handler being called to it answering is
// visible to it. Everything before -- the worker finishing the requests ahead
// of this one, a connection waiting in the accept queue, a handler that blocked
// the worker -- happened before any of the handler's code ran, and is invisible
// to it unless the server says when the request started.
//
// `X-Request-Start: t=<microseconds>` is how a proxy traditionally says so, and
// what New Relic, Datadog and Scout read to report queue time. A handler reads
// the server's time as `Request.requestStart`. A proxy's own X-Request-Start is
// still among the request's headers, and is the better time when there is one,
// because the proxy saw the request first.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

extension Worker {

    /// Wall-clock microseconds since the epoch at which the request on `slot`
    /// arrived, or nil when --request-start-header is off.
    func requestStartMicros(_ slot: Int) -> UInt64? {
        guard config.requestStartHeader else { return nil }
        // Wall-clock already: an agent compares it with its own clock, and on
        // plaintext it came from the kernel's receive timestamp.
        let started = table[slot].pointee.headStartUs
        return started > 0 ? started : av_realtime_us()
    }
}

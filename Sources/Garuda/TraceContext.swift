//===----------------------------------------------------------------------===//
// --trace-context: a W3C traceparent, recorded in the access log.
//
// A request that arrives inside a distributed trace carries `traceparent`.
// With its trace ID and parent span on the access line, the line can be found
// from the trace and the trace from the line.
//
// Recorded, never made up and never changed. The application already has the
// header among its request headers, which is where an OpenTelemetry
// propagator reads it. A traceparent the server invented would name a parent
// span that nothing ever recorded, and a trace backend would show the
// application's spans hanging from a gap.
//
// What counts as a readable traceparent is AvianHTTP's TraceContext. On
// top of that, a request carrying more than one is ignored: two traceparents
// disagree about which trace this is, and the specification has a receiver
// trust neither.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

extension Worker {

    /// Settles this request's trace context from its headers: the trace ID
    /// followed by the parent ID, 48 hex characters, or nothing. Reads the
    /// parsed header array, so it runs during dispatch.
    mutating func assignTraceContext(_ slot: Int) {
        let c = table[slot]
        c.pointee.traceContext.clear()
        let base = c.pointee.headBase()
        var value = ByteSpan(base, 0)
        var seen = false
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 11,
                  equalsLowercased(base + Int(h.name.offset), 11, "traceparent") else { continue }
            if seen { return }
            seen = true
            value = h.value.span(in: base)
        }
        guard seen, TraceContext.valid(value.base, value.count) else { return }
        c.pointee.traceContext.reserve(TraceContext.traceIDLength + TraceContext.parentIDLength)
        c.pointee.traceContext.write(value.base + TraceContext.traceIDOffset,
                                     TraceContext.traceIDLength)
        c.pointee.traceContext.write(value.base + TraceContext.parentIDOffset,
                                     TraceContext.parentIDLength)
    }
}

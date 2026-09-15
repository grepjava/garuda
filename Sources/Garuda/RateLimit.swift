//===----------------------------------------------------------------------===//
// --rate-limit: turning a client away with 429 before the application runs.
//
// The accounting lives in C, in a table every worker shares; see
// garuda_ratelimit.h for why it has to. What is here is deciding who the
// client is, and saying no.
//
// Who the client is follows the same rule as everything else about forwarded
// headers: behind a trusted proxy it is the address the proxy reports, and
// otherwise it is the peer. Keying by the peer behind a proxy would put every
// user in one bucket, and believing an untrusted X-Forwarded-For would let
// any client pick a fresh bucket per request.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

extension Worker {

    /// Charges this request to its client. Microseconds until the client may
    /// send another, or 0 when this one is allowed.
    mutating func rateLimitWait(_ slot: Int) -> UInt64 {
        let c = table[slot]
        let now = pg_monotonic_us()
        if !config.trust.isEmpty {
            let info = forwardedInfo(slot, base: c.pointee.headBase())
            if let client = info.client {
                return pg_ratelimit_check(client.base, client.count, now)
            }
        }
        let n = c.pointee.remoteAddr.readableBytes
        guard n > 0 else { return 0 }
        return pg_ratelimit_check(UnsafePointer(c.pointee.remoteAddr.readPointer), n, now)
    }

    /// 429, with `Retry-After` saying when a request would next be allowed.
    ///
    /// The connection is kept: the client is being asked to slow down, not
    /// being disconnected, and a keep-alive connection it has to reopen costs
    /// the server a handshake for nothing.
    mutating func respondRateLimited(_ slot: Int, waitUs: UInt64) {
        Metrics.add(PG_M_RATE_LIMITED)
        // Whole seconds, rounded up: rounding down would tell a client to come
        // back at a moment it would still be refused.
        let seconds = Int(max(1, (waitUs + 999_999) / 1_000_000))
        let c = table[slot]
        if c.pointee.isH3Stream {
            h3FailRequest(slot, status: 429, retryAfter: seconds)
            return
        }
        if c.pointee.isStream {
            h2FailRequest(slot, status: 429, retryAfter: seconds)
            return
        }
        logAccess(slot, status: 429)
        dates.refresh()
        let body: StaticString = "Too Many Requests\n"
        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: 429)
        HTTPResponseWriter.writeDate(&c.pointee.write, dates)
        c.pointee.write.write("Server: garuda\r\nContent-Type: text/plain; charset=utf-8\r\n")
        c.pointee.write.write("Retry-After: ")
        c.pointee.write.writeDecimal(seconds)
        c.pointee.write.writeCRLF()
        // A refusal is still an answer to log and correlate: the HTTP/2 and
        // HTTP/3 paths carry these, and so does every other HTTP/1.1 answer.
        writeServerHeaders(slot, &c.pointee.write)
        HTTPResponseWriter.writeContentLength(&c.pointee.write, body.utf8CodeUnitCount)
        HTTPResponseWriter.writeConnection(&c.pointee.write,
                                           keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&c.pointee.write)
        if !c.pointee.flags.contains(.suppressBody) { c.pointee.write.write(body) }
        c.pointee.state = .writing
        // As with the health probe, `flush` finishes the response once the
        // buffer drains, including swallowing a request body that was sent.
        _ = flush(slot)
    }
}

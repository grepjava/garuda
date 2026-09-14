//===----------------------------------------------------------------------===//
// Plain HTTP to HTTPS: the redirect port, and Strict-Transport-Security.
//
// --redirect-http PORT listens for plain HTTP beside the TLS port and answers
// every request with a redirect to the same host and path over https. Like the
// metrics port, it is a listener of its own in every worker, answered without a
// connection slot, and it shares the metrics port's few places for a request
// that has not finished arriving. A redirect is one small request and one small
// response followed by a close, so it needs nothing more than that.
//
// --hsts SECONDS reduces how often the redirect is needed at all. A browser
// that has seen Strict-Transport-Security on an https response goes straight to
// https for that long, so the plain request that could be intercepted is never
// sent. It goes on TLS responses only. A browser ignores it over plain HTTP,
// where anyone in the path could have added it.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

extension Worker {

    public mutating func registerRedirectListener() -> Bool {
        guard redirectFD >= 0 else { return true }
        guard poller.add(redirectFD, .read, token: PollToken.redirect) else {
            Log.error("failed to register the --redirect-http listener")
            return false
        }
        return true
    }

    /// Accepts what is waiting, answering or parking each one.
    mutating func acceptRedirects() {
        // Bounded, like the scrape port: a burst on the plain port must not
        // become a way to keep this loop off the request path.
        var budget = 16
        while budget > 0 {
            budget -= 1
            var port: UInt16 = 0
            var peer = [CChar](repeating: 0, count: 48)
            let fd = peer.withUnsafeMutableBufferPointer { raw in
                pg_accept(redirectFD, raw.baseAddress!, 48, &port)
            }
            if fd < 0 { return }
            beginOneShot(fd, redirect: true)
        }
    }

    /// Stops taking redirects, for a worker that has started draining.
    mutating func closeRedirectListener() {
        guard redirectFD >= 0 else { return }
        _ = poller.remove(redirectFD)
        _ = pg_close(redirectFD)
        redirectFD = -1
    }

    /// Answers one plain request with the https URL it should have used, or
    /// with 400 when it gives no usable host, and closes the connection.
    mutating func serveRedirect(_ fd: Int32, _ request: ByteBuffer) {
        defer { _ = pg_close(fd) }
        var status = 400
        var location = ByteBuffer()
        defer { location.destroy() }
        let httpsPort = config.port
        withUnsafeTemporaryAllocation(of: HTTPHeaderRef.self, capacity: 64) { headers in
            var head = HTTPRequestHead()
            let base = UnsafePointer(request.readPointer)
            let parsed = HTTPParser.parse(base, request.readableBytes,
                                          maxHeadSize: scrapeMaxRequest, maxHeaders: 64,
                                          headers: headers.baseAddress!, head: &head)
            guard case .complete = parsed else { return }
            var host: ByteSpan? = nil
            var i = 0
            while i < head.headerCount {
                let field = headers[i]
                if field.name.count == 4
                    && equalsLowercased(base + Int(field.name.offset), 4, "host") {
                    host = field.value.span(in: base)
                }
                i += 1
            }
            if HTTPSRedirect.location(host: host, target: head.target.span(in: base),
                                      httpsPort: httpsPort, into: &location) {
                status = HTTPSRedirect.status(for: head.method)
            }
        }

        dates.refresh()
        var out = ByteBuffer(capacity: 256 + location.readableBytes)
        defer { out.destroy() }
        HTTPResponseWriter.writeStatusLine(&out, status: status)
        HTTPResponseWriter.writeDate(&out, dates)
        out.write("Server: garuda\r\n")
        if status != 400 {
            out.write("Location: ")
            out.write(UnsafePointer(location.readPointer), location.readableBytes)
            out.writeCRLF()
        }
        out.write("Content-Length: 0\r\nConnection: close\r\n\r\n")
        writeOneShot(fd, UnsafePointer(out.readPointer), out.readableBytes)
    }

    /// `Strict-Transport-Security` in an HTTP/1.1 head, when --hsts asked for
    /// it. Every response on the service port is TLS once --hsts is allowed,
    /// so there is nothing to check here beyond the flag.
    @inline(__always)
    func writeHSTS(_ buf: inout ByteBuffer) {
        guard let value = config.hsts else { return }
        buf.write("Strict-Transport-Security: ")
        buf.write(value, config.hstsLength)
        buf.writeCRLF()
    }
}

//===----------------------------------------------------------------------===//
// The scrape port.
//
// A separate listener, on a separate port, answered without going anywhere
// near the request path. That is the point: the application must not be able
// to see a scrape, and a scrape must not be able to reach the application.
//
// Every worker binds it with SO_REUSEPORT, exactly as they bind the service
// port, so a scrape lands on whichever worker the kernel picks -- and it does
// not matter which, because the counters are shared and the answer is the sum
// over all of them.
//
// The handling is deliberately not a state machine. A scrape is a few dozen
// bytes in and a couple of kilobytes out, once every scrape interval, so it is
// accepted, read once, answered and closed inline. Nothing is ever waited for:
// a client that dribbles its request gets an answer anyway (the response says
// what it says regardless of the path asked for), and a client that will not
// read gets its connection closed. That is what keeps a monitoring port from
// becoming a way to stall the loop that serves requests.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

extension Worker {

    public mutating func registerMetricsListener() -> Bool {
        guard metricsFD >= 0 else { return true }
        guard poller.add(metricsFD, .read, token: PollToken.metrics) else {
            Log.error("failed to register the metrics listener")
            return false
        }
        return true
    }

    /// One scrape, start to finish, on the loop thread.
    mutating func acceptMetricsScrapes() {
        // Bounded: a burst of scrapes must not become a way to keep the loop
        // out of the request path.
        var budget = 8
        while budget > 0 {
            budget -= 1
            var port: UInt16 = 0
            var peer = [CChar](repeating: 0, count: 48)
            let fd = peer.withUnsafeMutableBufferPointer { raw in
                pg_accept(metricsFD, raw.baseAddress!, 48, &port)
            }
            if fd < 0 { return }
            serveScrape(fd)
        }
    }

    private mutating func serveScrape(_ fd: Int32) {
        defer { _ = pg_close(fd) }

        // The request is read but not parsed. This port serves one thing, and
        // a monitoring agent that asked for /metrics and one that asked for /
        // both want it; refusing the second would be a configuration error
        // waiting to happen rather than a security boundary.
        var scratch = [UInt8](repeating: 0, count: 2048)
        _ = scratch.withUnsafeMutableBufferPointer { raw in
            pg_read(fd, raw.baseAddress!, raw.count)
        }

        // This worker's own gauge, which the accept and close paths keep
        // true for every other worker.
        Metrics.set(PG_M_CONNECTIONS_ACTIVE, UInt64(table.liveCount))

        var body = ByteBuffer()
        defer { body.destroy() }
        Metrics.render(into: &body)

        var head = ByteBuffer()
        defer { head.destroy() }
        head.write("HTTP/1.1 200 OK\r\nContent-Type: ")
        // The version suffix is what tells Prometheus it may parse this as the
        // text exposition format rather than guess.
        head.write("text/plain; version=0.0.4; charset=utf-8")
        head.write("\r\nConnection: close\r\nContent-Length: ")
        head.writeDecimal(body.readableBytes)
        head.write("\r\n\r\n")

        writeAll(fd, UnsafePointer(head.readPointer), head.readableBytes)
        if body.readableBytes > 0 {
            writeAll(fd, UnsafePointer(body.readPointer), body.readableBytes)
        }
    }

    /// Writes until the socket takes it or refuses to. A scrape that cannot be
    /// delivered is dropped rather than waited for: the next one is 15 seconds
    /// away and the request path is not.
    private func writeAll(_ fd: Int32, _ p: UnsafePointer<UInt8>, _ n: Int) {
        var sent = 0
        var attempts = 16
        while sent < n && attempts > 0 {
            attempts -= 1
            let k = pg_write(fd, p + sent, n - sent)
            if k > 0 { sent += k; continue }
            let e = pg_errno()
            if pg_err_is_intr(e) != 0 { continue }
            return
        }
    }
}

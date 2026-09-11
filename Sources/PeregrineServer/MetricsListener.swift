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
// A scrape is a few dozen bytes in and a couple of kilobytes out, once every
// scrape interval, so nearly always it is accepted, read, answered and closed
// without ever going round the loop again. What stops that from being the
// whole story is that a request arriving in more than one segment is a request
// this has only half of: answering it early means closing under a peer that is
// still writing, which costs it an EPIPE on writes it had every right to make
// and can cost it the answer itself, since a close with unread bytes still
// inbound is a reset, and a reset may discard what the kernel had buffered to
// deliver.
//
// So a scrape that has not finished arriving waits -- but only in ways that
// cannot reach the request path. There are `metricsPendingCount` places to
// wait in and no more, each with a deadline and a ceiling on how much it will
// hold, and the loop is never blocked on any of them: they are poller
// registrations like anything else. A ninth concurrent scrape is answered on
// the spot from whatever it has sent, which is the old behaviour, kept for the
// case where the alternative would be to start queueing.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// A scrape whose request is still on its way.
public struct PendingScrape {
    public var fd: Int32 = -1
    public var deadlineMs: UInt64 = 0
    public var buf = ByteBuffer()
}

/// How long a half-written scrape may stay half-written.
let scrapeDeadlineMs: UInt64 = 5_000
/// The most of a scrape request that will ever be held. A request head this
/// large is not a monitoring agent.
let scrapeMaxRequest = 4096

extension Worker {

    public mutating func registerMetricsListener() -> Bool {
        guard metricsFD >= 0 else { return true }
        guard poller.add(metricsFD, .read, token: PollToken.metrics) else {
            Log.error("failed to register the metrics listener")
            return false
        }
        return true
    }

    /// Accepts what is waiting, answering or parking each one.
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
            beginScrape(fd)
        }
    }

    /// Reads what has arrived and decides whether the request is all there.
    private mutating func beginScrape(_ fd: Int32) {
        var buf = ByteBuffer()
        switch readScrape(fd, &buf) {
        case .complete:
            buf.destroy()
            serveScrape(fd)
        case .gone:
            buf.destroy()
            _ = pg_close(fd)
        case .partial:
            guard let index = freeScrapeSlot() else {
                // Nowhere to wait. Answering from a partial request is the
                // lesser of the two evils: the response does not depend on
                // what was asked for, and the alternative is a scrape that
                // silently gets nothing.
                buf.destroy()
                serveScrape(fd)
                return
            }
            guard poller.add(fd, .read, token: PollToken.metricsPending(index)) else {
                buf.destroy()
                serveScrape(fd)
                return
            }
            scrapes[index].fd = fd
            scrapes[index].deadlineMs = pg_monotonic_ms() &+ scrapeDeadlineMs
            scrapes[index].buf = buf
        }
    }

    /// More of a parked scrape's request arrived.
    mutating func handleScrapeReadable(_ index: Int) {
        guard index >= 0, index < scrapes.count, scrapes[index].fd >= 0 else { return }
        let fd = scrapes[index].fd
        var buf = scrapes[index].buf
        let outcome = readScrape(fd, &buf)
        scrapes[index].buf = buf
        switch outcome {
        case .partial:
            return
        case .complete:
            releaseScrape(index, close: false)
            serveScrape(fd)
        case .gone:
            releaseScrape(index, close: true)
        }
    }

    /// Drops parked scrapes whose peer stopped writing. Called from the sweep,
    /// so it costs a walk of eight entries once a second.
    mutating func sweepScrapes(now: UInt64) {
        var i = 0
        while i < scrapes.count {
            defer { i += 1 }
            if scrapes[i].fd < 0 { continue }
            if now < scrapes[i].deadlineMs { continue }
            // Long enough. Answer from what there is rather than hang up on a
            // monitoring agent: the response never depended on the request.
            let fd = scrapes[i].fd
            releaseScrape(i, close: false)
            serveScrape(fd)
        }
    }

    public mutating func closeScrapes() {
        var i = 0
        while i < scrapes.count {
            if scrapes[i].fd >= 0 { releaseScrape(i, close: true) }
            i += 1
        }
    }

    private func freeScrapeSlot() -> Int? {
        var i = 0
        while i < scrapes.count {
            if scrapes[i].fd < 0 { return i }
            i += 1
        }
        return nil
    }

    private mutating func releaseScrape(_ index: Int, close: Bool) {
        let fd = scrapes[index].fd
        if fd >= 0 { _ = poller.remove(fd) }
        scrapes[index].buf.destroy()
        scrapes[index].fd = -1
        scrapes[index].deadlineMs = 0
        if close && fd >= 0 { _ = pg_close(fd) }
    }

    private enum ScrapeRead {
        case complete
        case partial
        case gone
    }

    /// Drains the socket into `buf` without blocking, and says whether a whole
    /// request head is now in there.
    private func readScrape(_ fd: Int32, _ buf: inout ByteBuffer) -> ScrapeRead {
        while true {
            if buf.readableBytes >= scrapeMaxRequest { return .complete }
            buf.reserve(1024)
            let n = pg_read(fd, buf.writePointer, min(1024, buf.writableBytes))
            if n > 0 {
                buf.advanceWriter(n)
                if headEnded(buf) { return .complete }
                continue
            }
            if n == 0 {
                // The peer finished without a blank line. Whatever it meant,
                // it is not sending more, so this is as complete as it gets.
                return buf.readableBytes > 0 ? .complete : .gone
            }
            let e = pg_errno()
            if pg_err_is_intr(e) != 0 { continue }
            if pg_err_is_again(e) != 0 { return .partial }
            return .gone
        }
    }

    private func headEnded(_ buf: ByteBuffer) -> Bool {
        let n = buf.readableBytes
        if n < 4 { return false }
        let p = buf.readPointer
        var i = 0
        while i + 3 < n {
            if p[i] == cCR && p[i + 1] == cLF && p[i + 2] == cCR && p[i + 3] == cLF {
                return true
            }
            // A bare LF pair ends a head too, for a client that writes them.
            if p[i] == cLF && p[i + 1] == cLF { return true }
            i += 1
        }
        return false
    }

    /// Answers one scrape and closes it.
    ///
    /// The request is not parsed. This port serves one thing, and a monitoring
    /// agent that asked for /metrics and one that asked for / both want it;
    /// refusing the second would be a configuration error waiting to happen
    /// rather than a security boundary.
    private mutating func serveScrape(_ fd: Int32) {
        defer { _ = pg_close(fd) }

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

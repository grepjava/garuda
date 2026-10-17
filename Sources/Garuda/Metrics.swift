//===----------------------------------------------------------------------===//
// --metrics-port: counters every shard adds to, and the page they are
// scraped from.
//
//     garuda --metrics-port 9100      # then GET http://127.0.0.1:9100/metrics
//
// Counting has to be free: these counters sit on every response. Each
// worker thread of each shard has a row of its own in a region every shard
// shares (SharedMemory.swift), and is the only one that writes it -- a load,
// an add and a store, no lock, no cache line shared with another writer.
// The few counts made off the workers go to a row of their own, added to
// atomically.
//
// Scraping has to see all of it. A scrape lands on whichever shard accepts
// it, and that shard sums every row: a page with one shard's numbers would
// report a fraction that changed from scrape to scrape.
//
// The page is served on a port of its own, by a server of its own, never
// through the application: an operator's monitoring should not be able to
// reach the routes, nor the routes the monitoring.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega

/// The shared counters.
final class MetricsPage: @unchecked Sendable {
    enum Counter: Int, CaseIterable {
        case requests1xx, requests2xx, requests3xx, requests4xx, requests5xx
        case connectionsAccepted, connectionsClosed
        case poolHits, poolMisses
        case rateLimited
        case cacheHits, cacheMisses, cacheStores
        case durationCount, durationSumMicros
        case bucket0
    }

    /// Upper edges of the request-duration histogram, in microseconds: from
    /// a hello-world answer to a request that has kept a client waiting.
    static let bucketEdges: [UInt64] = [500, 1000, 2500, 5000, 10_000, 25_000, 50_000,
                                        100_000, 250_000, 500_000, 1_000_000, 2_500_000,
                                        5_000_000, 10_000_000]
    static let fields = Counter.bucket0.rawValue + bucketEdges.count
    /// A row per worker thread, padded to whole cache lines.
    static let rowSize = (fields * 8 + 63) / 64 * 64
    /// Rows per shard: its workers, and one for counts made off them.
    static let rowsPerShard = 64
    static let maxShards = 64
    static let regionSize = rowSize * rowsPerShard * maxShards

    private let base: UnsafeMutableRawPointer
    private let shard: Int

    init(region: UnsafeMutableRawBufferPointer, shard: Int) {
        precondition(region.count >= MetricsPage.regionSize)
        base = region.baseAddress!
        self.shard = min(shard, MetricsPage.maxShards - 1)
    }

    private func row(_ shard: Int, _ row: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        (base + (shard * MetricsPage.rowsPerShard + row) * MetricsPage.rowSize)
            .assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    /// Adds `n` to `counter` in the calling thread's row.
    @inline(__always)
    func add(_ counter: Counter, _ n: UInt64 = 1) {
        add(counter.rawValue, n)
    }

    private func add(_ field: Int, _ n: UInt64) {
        if let worker = Runtime.currentWorker, worker < MetricsPage.rowsPerShard - 1 {
            // This thread is the row's only writer.
            let cell = row(shard, worker) + field
            cell.pointee.store(cell.pointee.load(ordering: .relaxed) &+ n, ordering: .relaxed)
        } else {
            (row(shard, MetricsPage.rowsPerShard - 1) + field).pointee.wrappingAdd(n, ordering: .relaxed)
        }
    }

    /// One answered request: its status class, and how long it took.
    func requestFinished(status: Int, micros: UInt64?) {
        let counter: Counter
        switch status / 100 {
        case 2: counter = .requests2xx
        case 3: counter = .requests3xx
        case 4: counter = .requests4xx
        case 5: counter = .requests5xx
        default: counter = .requests1xx
        }
        add(counter)
        guard let micros else { return }
        add(.durationCount)
        add(.durationSumMicros, micros)
        // +Inf is not stored: it is the count.
        if let bucket = MetricsPage.bucketEdges.firstIndex(where: { micros <= $0 }) {
            add(Counter.bucket0.rawValue + bucket, 1)
        }
    }

    /// `counter` summed over every row of every shard.
    func sum(_ counter: Counter) -> UInt64 { sum(counter.rawValue) }

    private func sum(_ field: Int) -> UInt64 {
        var total: UInt64 = 0
        for s in 0..<MetricsPage.maxShards {
            for r in 0..<MetricsPage.rowsPerShard {
                total &+= (row(s, r) + field).pointee.load(ordering: .relaxed)
            }
        }
        return total
    }

    // MARK: - The page

    /// The Prometheus text exposition of every shard's counters.
    func render(workers: Int, cache: Bool) -> [UInt8] {
        var out = ""
        out += "# HELP garuda_requests_total Responses sent, by status class.\n"
        out += "# TYPE garuda_requests_total counter\n"
        for (label, counter) in [("1xx", Counter.requests1xx), ("2xx", .requests2xx), ("3xx", .requests3xx),
                                 ("4xx", .requests4xx), ("5xx", .requests5xx)] {
            out += "garuda_requests_total{status=\"\(label)\"} \(sum(counter))\n"
        }
        func simple(_ name: String, _ kind: String, _ help: String, _ value: UInt64) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) \(kind)\n\(name) \(value)\n"
        }
        let accepted = sum(.connectionsAccepted), closed = sum(.connectionsClosed)
        simple("garuda_connections_accepted_total", "counter", "Connections accepted.", accepted)
        simple("garuda_connections_closed_total", "counter", "Connections closed.", closed)
        simple("garuda_connections_active", "gauge", "Connections open right now.",
               accepted >= closed ? accepted - closed : 0)
        simple("garuda_buffer_pool_hits_total", "counter", "Connection buffers reused from the cache.",
               sum(.poolHits))
        simple("garuda_buffer_pool_misses_total", "counter", "Connection buffers that had to be allocated.",
               sum(.poolMisses))
        simple("garuda_requests_rate_limited_total", "counter", "Requests refused with 429 by --rate-limit.",
               sum(.rateLimited))
        if cache {
            simple("garuda_cache_hits_total", "counter", "Requests answered from the response cache.",
                   sum(.cacheHits))
            simple("garuda_cache_misses_total", "counter",
                   "Requests looked up in the response cache and not found.", sum(.cacheMisses))
            simple("garuda_cache_stores_total", "counter", "Responses stored in the response cache.",
                   sum(.cacheStores))
        }
        simple("garuda_workers", "gauge", "Shard processes sharing these counters.", UInt64(max(1, workers)))

        // Prometheus histograms are cumulative; the rows keep each bucket
        // apart, so a request touches one counter rather than fourteen.
        out += "# HELP garuda_request_duration_seconds Time from dispatch to the response being written.\n"
        out += "# TYPE garuda_request_duration_seconds histogram\n"
        var cumulative: UInt64 = 0
        for (i, edge) in MetricsPage.bucketEdges.enumerated() {
            cumulative &+= sum(Counter.bucket0.rawValue + i)
            out += "garuda_request_duration_seconds_bucket{le=\"\(seconds(edge))\"} \(cumulative)\n"
        }
        let count = sum(.durationCount)
        out += "garuda_request_duration_seconds_bucket{le=\"+Inf\"} \(count)\n"
        out += "garuda_request_duration_seconds_sum \(seconds(sum(.durationSumMicros)))\n"
        out += "garuda_request_duration_seconds_count \(count)\n"
        return Array(out.utf8)
    }

    /// Microseconds as seconds to six places, exactly: no float to round.
    private func seconds(_ micros: UInt64) -> String {
        let fraction = String(micros % 1_000_000)
        return "\(micros / 1_000_000)." + String(repeating: "0", count: 6 - fraction.count) + fraction
    }
}

/// The application the metrics port serves: the page, at /metrics and at
/// any other path, so a scraper set up with another path is answered all the
/// same. The port is never a way to the application's routes.
func metricsApplication(_ page: MetricsPage, workers: Int, cache: Bool) -> Application {
    let app = Application()
    app.get("/metrics") { _, response in
        response.addHeader("content-type", "text/plain; version=0.0.4; charset=utf-8")
        response.send(page.render(workers: workers, cache: cache))
    }
    app.fallback { _, response in
        response.addHeader("content-type", "text/plain; version=0.0.4; charset=utf-8")
        response.send(page.render(workers: workers, cache: cache))
    }
    return app
}

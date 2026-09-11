//===----------------------------------------------------------------------===//
// Metrics, and the port they are scraped from.
//
// Two problems, and they pull in opposite directions.
//
// Counting has to be free. These counters sit on the accept path and the
// response path, so anything that locks, allocates or crosses a cache line
// shared with another worker would cost more than the thing it measures. Each
// worker writes only its own slot of a shared page, with relaxed loads and
// stores -- a load, an add and a store, no lock prefix, no contention.
//
// Scraping has to see all of it. A scrape is one connection, and with
// --workers it lands on whichever worker SO_REUSEPORT gives it; a worker that
// answered with its own numbers would report a fraction that changes between
// scrapes. So the page is mapped MAP_SHARED before the fork, and whoever
// answers sums every slot. The same code covers --free-threaded, where the
// workers are threads and share the mapping because they share everything.
//
// The scrape itself is deliberately not run through the server's own request
// path: that path dispatches to the application, and an operator's monitoring
// should not be able to reach it. It is a handful of bytes accepted, read and
// answered inline on the loop thread, with no connection slot and no state
// machine -- bounded work, once every scrape interval.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum Metrics {

    /// Binds this thread to its slot of the shared page. Called once per
    /// worker before its loop starts.
    public static func bind(slot: Int) { pg_metrics_bind(Int32(slot)) }

    @inlinable
    public static var enabled: Bool { pg_metrics_enabled() != 0 }

    /// Indices arrive from C as `Int`; the conversion is a no-op the
    /// optimiser removes.
    @inlinable
    public static func add(_ index: Int, _ n: UInt64 = 1) {
        pg_metrics_add_local(Int32(index), n)
    }

    @inlinable
    public static func set(_ index: Int, _ v: UInt64) {
        pg_metrics_set_local(Int32(index), v)
    }

    @inlinable
    public static func sum(_ index: Int) -> UInt64 {
        pg_metrics_sum(Int32(index))
    }

    /// One finished request: its status class, and how long it took.
    @inlinable
    public static func requestFinished(status: Int, micros: Int) {
        let bucketed: Int
        switch status / 100 {
        case 2: bucketed = PG_M_REQUESTS_2XX
        case 3: bucketed = PG_M_REQUESTS_3XX
        case 4: bucketed = PG_M_REQUESTS_4XX
        case 5: bucketed = PG_M_REQUESTS_5XX
        default: bucketed = PG_M_REQUESTS_1XX
        }
        add(bucketed)
        if micros < 0 { return }
        let us = UInt64(micros)
        add(PG_M_DURATION_COUNT)
        add(PG_M_DURATION_SUM_US, us)
        let bucket = pg_metrics_bucket(us)
        // +Inf is not stored: it is the count, and storing it twice is one
        // more thing that can disagree with itself.
        if Int(bucket) < PG_METRIC_BUCKETS {
            add(PG_M_BUCKET0 + Int(bucket))
        }
    }

    // MARK: - Rendering

    /// Writes the Prometheus text exposition of every worker's counters.
    ///
    /// Nothing here allocates: the numbers go straight into the response
    /// buffer as decimal digits.
    public static func render(into out: inout ByteBuffer) {
        counter(&out, "peregrine_requests_total",
                "Responses sent, by status class.",
                labels: [("1xx", PG_M_REQUESTS_1XX), ("2xx", PG_M_REQUESTS_2XX),
                         ("3xx", PG_M_REQUESTS_3XX), ("4xx", PG_M_REQUESTS_4XX),
                         ("5xx", PG_M_REQUESTS_5XX)],
                label: "status")

        simple(&out, "peregrine_connections_accepted_total", "counter",
               "Connections accepted.", sum(PG_M_CONNECTIONS_ACCEPTED))
        simple(&out, "peregrine_connections_closed_total", "counter",
               "Connections closed.", sum(PG_M_CONNECTIONS_CLOSED))
        simple(&out, "peregrine_connections_rejected_total", "counter",
               "Connections refused for want of a slot or a descriptor.",
               sum(PG_M_CONNECTIONS_REJECTED))
        simple(&out, "peregrine_connections_active", "gauge",
               "Connections open right now.", sum(PG_M_CONNECTIONS_ACTIVE))
        simple(&out, "peregrine_connection_slots", "gauge",
               "Connection table capacity, summed over workers.",
               sum(PG_M_SLOTS_CAPACITY))
        simple(&out, "peregrine_buffer_pool_hits_total", "counter",
               "Read buffers taken from the pool's free list.",
               sum(PG_M_POOL_HITS))
        simple(&out, "peregrine_buffer_pool_misses_total", "counter",
               "Read buffers that had to be allocated.",
               sum(PG_M_POOL_MISSES))
        simple(&out, "peregrine_workers", "gauge",
               "Workers sharing these counters.", UInt64(pg_metrics_slots()))

        histogram(&out)
    }

    private static func simple(_ out: inout ByteBuffer, _ name: StaticString,
                               _ kind: StaticString, _ help: StaticString,
                               _ value: UInt64) {
        out.write("# HELP ")
        out.write(name)
        out.write(" ")
        out.write(help)
        out.write("\n# TYPE ")
        out.write(name)
        out.write(" ")
        out.write(kind)
        out.write("\n")
        out.write(name)
        out.write(" ")
        out.writeDecimal(Int(value))
        out.write("\n")
    }

    private static func counter(_ out: inout ByteBuffer, _ name: StaticString,
                                _ help: StaticString,
                                labels: [(StaticString, Int)],
                                label: StaticString) {
        out.write("# HELP ")
        out.write(name)
        out.write(" ")
        out.write(help)
        out.write("\n# TYPE ")
        out.write(name)
        out.write(" counter\n")
        for (value, index) in labels {
            out.write(name)
            out.write("{")
            out.write(label)
            out.write("=\"")
            out.write(value)
            out.write("\"} ")
            out.writeDecimal(Int(sum(index)))
            out.write("\n")
        }
    }

    /// Prometheus histograms are cumulative: each bucket counts everything at
    /// or below its edge. The page stores them separately -- a worker should
    /// touch one counter per request, not fourteen -- so they are added up
    /// here, where it costs one pass at scrape time.
    private static func histogram(_ out: inout ByteBuffer) {
        out.write("# HELP peregrine_request_duration_seconds ")
        out.write("Time from dispatch to the response head being queued.\n")
        out.write("# TYPE peregrine_request_duration_seconds histogram\n")

        var cumulative: UInt64 = 0
        var i = 0
        while i < PG_METRIC_BUCKETS {
            cumulative &+= sum(PG_M_BUCKET0 + i)
            out.write("peregrine_request_duration_seconds_bucket{le=\"")
            writeSeconds(&out, pg_metric_bucket_edge(Int32(i)))
            out.write("\"} ")
            out.writeDecimal(Int(cumulative))
            out.write("\n")
            i += 1
        }
        let count = sum(PG_M_DURATION_COUNT)
        out.write("peregrine_request_duration_seconds_bucket{le=\"+Inf\"} ")
        out.writeDecimal(Int(count))
        out.write("\n")
        out.write("peregrine_request_duration_seconds_sum ")
        writeSeconds(&out, sum(PG_M_DURATION_SUM_US))
        out.write("\n")
        out.write("peregrine_request_duration_seconds_count ")
        out.writeDecimal(Int(count))
        out.write("\n")
    }

    /// Microseconds as seconds, to six decimal places, without touching a
    /// float: these are exact decimals and printf would round them.
    private static func writeSeconds(_ out: inout ByteBuffer, _ micros: UInt64) {
        out.writeDecimal(Int(micros / 1_000_000))
        out.write(".")
        var frac = Int(micros % 1_000_000)
        var divisor = 100_000
        while divisor > 0 {
            out.writeByte(UInt8(48 + frac / divisor))
            frac %= divisor
            divisor /= 10
        }
    }
}

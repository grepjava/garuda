//===----------------------------------------------------------------------===//
// Metrics by route: requests by status class and a latency histogram for
// each route pattern, on the --metrics-port page.
//
//     garuda_route_requests_total{method="GET",route="/users/:id",status="2xx"} 1523
//     garuda_route_request_duration_seconds_bucket{method="GET",route="/users/:id",le="0.005"} 1490
//
// The label is the pattern the route was registered with, never the path a
// client sent, so the number of series is bounded by the number of routes:
// `/users/1` and `/users/2` are one series. A request no route matched is
// counted under `route="unmatched"`, and a fallback under the scope it
// belongs to.
//
// The counters follow the rules of the server-wide page (Metrics.swift): a
// block of shared memory mapped before the fork, a row per worker slot that
// only that worker writes, and a load, an add and a store per counter with no
// lock. Only routes that have answered something are written out, so an
// application with many routes scrapes what it uses.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import CAvian
import AvianCore
import AvianHTTP

enum RouteMetrics {
    /// Counters per route: five status classes, the duration count and sum,
    /// and one per histogram bucket.
    static let fieldsPerRoute = 7 + Int(AV_METRIC_BUCKETS)
    static let countField = 5
    static let sumField = 6
    static let bucketField = 7

    nonisolated(unsafe) static var page: UnsafeMutablePointer<UInt64>? = nil
    nonisolated(unsafe) static var slots = 0
    /// Routes, plus one row for requests no route matched, the last.
    nonisolated(unsafe) static var rows = 0
    nonisolated(unsafe) static var labels: [(method: String, route: String)] = []
    /// The application whose routes the rows are, so a request answered by
    /// another -- a test's, in the same process -- is not counted against them.
    nonisolated(unsafe) static var owner: UnsafeMutablePointer<CompiledApplication>? = nil
    nonisolated(unsafe) static var mappedBytes = 0

    /// Maps the counters for `application`'s routes and `slots` worker
    /// slots. Before any fork, like `av_metrics_init`.
    static func initialize(_ application: UnsafeMutablePointer<CompiledApplication>?, slots: Int) -> Bool {
        guard page == nil else { return true }
        var labels: [(method: String, route: String)] = []
        if let application {
            let patterns = application.pointee.routePatterns
            let methods = application.pointee.routeMethods
            for index in 0..<application.pointee.handlerCount {
                let method = index < methods.count ? methods[index].flatMap(methodLabel) ?? "*" : "*"
                let pattern = index < patterns.count ? patterns[index] : nil
                labels.append((method, pattern ?? "fallback"))
            }
        }
        labels.append(("*", "unmatched"))
        let bytes = max(1, slots) * labels.count * fieldsPerRoute * MemoryLayout<UInt64>.stride
        guard let mapped = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0),
              mapped != MAP_FAILED else { return false }
        memset(mapped, 0, bytes)
        page = mapped.bindMemory(to: UInt64.self, capacity: bytes / MemoryLayout<UInt64>.stride)
        self.slots = max(1, slots)
        rows = labels.count
        self.labels = labels
        owner = application
        mappedBytes = bytes
        return true
    }

    /// Unmaps the counters, for tests.
    static func reset() {
        if let page { munmap(UnsafeMutableRawPointer(page), mappedBytes) }
        page = nil
        owner = nil
        rows = 0
        slots = 0
        labels = []
    }

    @inline(__always)
    private static func cell(_ slot: Int, _ row: Int, _ field: Int) -> UnsafeMutablePointer<UInt64> {
        page! + ((slot * rows + row) * fieldsPerRoute + field)
    }

    /// One finished request on worker slot `slot`, for route `route` (-1 for
    /// none), with its status and duration (-1 when not timed).
    @inline(__always)
    static func record(_ application: UnsafeMutablePointer<CompiledApplication>?, slot: Int, route: Int,
                       status: Int, micros: Int) {
        guard page != nil, application == owner, slot >= 0, slot < slots else { return }
        let row = route >= 0 && route < rows - 1 ? route : rows - 1
        let statusField = switch status / 100 {
        case 2: 1
        case 3: 2
        case 4: 3
        case 5: 4
        default: 0
        }
        cell(slot, row, statusField).pointee &+= 1
        guard micros >= 0 else { return }
        let us = UInt64(micros)
        cell(slot, row, countField).pointee &+= 1
        cell(slot, row, sumField).pointee &+= us
        let bucket = Int(av_metrics_bucket(us))
        if bucket < Int(AV_METRIC_BUCKETS) { cell(slot, row, bucketField + bucket).pointee &+= 1 }
    }

    private static func sum(_ row: Int, _ field: Int) -> UInt64 {
        var total: UInt64 = 0
        for slot in 0..<slots { total &+= cell(slot, row, field).pointee }
        return total
    }

    /// Writes every route that has answered something.
    static func render(into out: inout ByteBuffer) {
        guard page != nil else { return }
        var used: [(row: Int, labels: String)] = []
        for row in 0..<rows {
            var answered: UInt64 = 0
            for field in 0..<5 { answered &+= sum(row, field) }
            guard answered > 0 else { continue }
            let (method, route) = labels[row]
            used.append((row, "method=\"\(escapeLabel(method))\",route=\"\(escapeLabel(route))\""))
        }
        guard !used.isEmpty else { return }

        out.write("# HELP garuda_route_requests_total Responses sent, by route pattern and status class.\n")
        out.write("# TYPE garuda_route_requests_total counter\n")
        let classes = ["1xx", "2xx", "3xx", "4xx", "5xx"]
        for (row, labels) in used {
            for (field, name) in classes.enumerated() {
                let value = sum(row, field)
                guard value > 0 else { continue }
                write(&out, "garuda_route_requests_total{\(labels),status=\"\(name)\"} ")
                out.writeDecimal(Int(value))
                out.write("\n")
            }
        }

        out.write("# HELP garuda_route_request_duration_seconds ")
        out.write("Time from dispatch to the response head being queued, by route pattern.\n")
        out.write("# TYPE garuda_route_request_duration_seconds histogram\n")
        for (row, labels) in used {
            let count = sum(row, countField)
            guard count > 0 else { continue }
            var cumulative: UInt64 = 0
            for bucket in 0..<Int(AV_METRIC_BUCKETS) {
                cumulative &+= sum(row, bucketField + bucket)
                write(&out, "garuda_route_request_duration_seconds_bucket{\(labels),le=\"")
                writeSeconds(&out, av_metric_bucket_edge(Int32(bucket)))
                out.write("\"} ")
                out.writeDecimal(Int(cumulative))
                out.write("\n")
            }
            write(&out, "garuda_route_request_duration_seconds_bucket{\(labels),le=\"+Inf\"} ")
            out.writeDecimal(Int(count))
            write(&out, "\ngaruda_route_request_duration_seconds_sum{\(labels)} ")
            writeSeconds(&out, sum(row, sumField))
            write(&out, "\ngaruda_route_request_duration_seconds_count{\(labels)} ")
            out.writeDecimal(Int(count))
            out.write("\n")
        }
    }

    private static func write(_ out: inout ByteBuffer, _ text: String) {
        var text = text
        text.withUTF8 { out.write($0.baseAddress!, $0.count) }
    }

    /// Microseconds as seconds with six decimals, as the server-wide page
    /// writes them.
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

    /// A label value as the exposition format escapes it.
    static func escapeLabel(_ value: String) -> String {
        var out = ""
        for c in value.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private static func methodLabel(_ method: HTTPMethod) -> String? {
        method.token.map { "\($0)" }
    }
}

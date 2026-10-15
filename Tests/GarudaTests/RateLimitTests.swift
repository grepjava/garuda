import Testing
import GarudaTesting
@testable import Garuda

// --rate-limit's table, --health-check-path, --drain-delay and the --metrics-port page.

private func limiter(_ count: Int, perMs period: UInt64, burst: Int = 0) -> RateLimiter {
    var config = ServerConfig()
    config.rateLimitCount = count
    config.rateLimitPeriodMs = period
    config.rateLimitBurst = burst
    let region = UnsafeMutableRawBufferPointer.allocate(byteCount: RateLimiter.regionSize, alignment: 64)
    region.initializeMemory(as: UInt8.self, repeating: 0)
    return RateLimiter(region: region, config: config)
}

private func check(_ limiter: RateLimiter, _ address: String, at now: UInt64) -> UInt64 {
    var address = address
    return address.withUTF8 { limiter.check($0.baseAddress!, $0.count, now: now) }
}

private func key(_ limiter: RateLimiter, _ address: String) -> UInt64? {
    var address = address
    return address.withUTF8 { limiter.key($0.baseAddress!, $0.count) }
}

@Suite("Rate limiting")
struct RateLimitTests {
    @Test func theBurstIsAllowedThenTheRate() {
        // One a second, five at once.
        let table = limiter(1, perMs: 1000, burst: 5)
        let start: UInt64 = 1_000_000_000
        for _ in 0..<5 { #expect(check(table, "10.0.0.1", at: start) == 0) }
        let wait = check(table, "10.0.0.1", at: start)
        #expect(wait > 0 && wait <= 1_000_000)
        // Another client has its own allowance.
        #expect(check(table, "10.0.0.2", at: start) == 0)
        // A second later there is room for one more.
        #expect(check(table, "10.0.0.1", at: start + 1_000_000) == 0)
        #expect(check(table, "10.0.0.1", at: start + 1_000_000) > 0)
    }

    @Test func whoTheClientIs() {
        let table = limiter(10, perMs: 1000)
        #expect(key(table, "not an address") == nil)
        #expect(key(table, "") == nil)
        #expect(key(table, "192.0.2.7") != nil)
        // An IPv4-mapped address is the IPv4 client.
        #expect(key(table, "::ffff:192.0.2.7") == key(table, "192.0.2.7"))
        // One /64 is one client, and brackets and zones are tolerated.
        #expect(key(table, "2001:db8:1:2::1") == key(table, "2001:db8:1:2:ffff::9"))
        #expect(key(table, "[2001:db8:1:2::1]") == key(table, "2001:db8:1:2::1"))
        #expect(key(table, "fe80::1%eth0") == key(table, "fe80::2"))
        #expect(key(table, "2001:db8:1:3::1") != key(table, "2001:db8:1:2::1"))
    }

    @Test func anythingButAnAddressIsLetThrough() {
        let table = limiter(1, perMs: 60_000, burst: 1)
        for _ in 0..<5 { #expect(check(table, "unix", at: 1) == 0) }
    }

    @Test func theFlagsAreParsed() {
        guard case .run(let config) = ServerConfig.parse(["garuda", "--rate-limit", "600/m",
                                                           "--rate-limit-burst", "50",
                                                           "--health-check-path", "/healthz",
                                                           "--metrics-port", "9100",
                                                           "--drain-delay", "2500"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.rateLimitCount == 600 && config.rateLimitPeriodMs == 60_000)
        #expect(config.rateLimitBurst == 50)
        #expect(config.healthCheckPath == "/healthz")
        #expect(config.metricsPort == 9100)
        #expect(config.drainDelay == .milliseconds(2500))
        for bad in [["--rate-limit", "10"], ["--rate-limit", "10/d"], ["--rate-limit", "0/s"],
                    ["--rate-limit", "x/s"], ["--health-check-path", "healthz"], ["--metrics-port", "0"],
                    ["--drain-delay", "-1"], ["--drain-delay", "2s"]] {
            if case .exit(let status) = ServerConfig.parse(["garuda"] + bad) {
                #expect(status == 2)
            } else {
                Issue.record("\(bad) parsed")
            }
        }
    }

    @Test func theMetricsPageAddsUpEveryRow() {
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: MetricsPage.regionSize, alignment: 64)
        region.initializeMemory(as: UInt8.self, repeating: 0)
        let first = MetricsPage(region: region, shard: 0)
        let second = MetricsPage(region: region, shard: 3)
        first.requestFinished(status: 200, micros: 300)
        second.requestFinished(status: 204, micros: 4000)
        second.requestFinished(status: 404, micros: nil)
        first.add(.rateLimited)
        let page = String(decoding: first.render(workers: 4, cache: false), as: UTF8.self)
        #expect(page.contains("garuda_requests_total{status=\"2xx\"} 2\n"))
        #expect(page.contains("garuda_requests_total{status=\"4xx\"} 1\n"))
        #expect(page.contains("garuda_requests_rate_limited_total 1\n"))
        #expect(page.contains("garuda_request_duration_seconds_bucket{le=\"0.000500\"} 1\n"))
        #expect(page.contains("garuda_request_duration_seconds_bucket{le=\"0.005000\"} 2\n"))
        #expect(page.contains("garuda_request_duration_seconds_count 2\n"))
        #expect(page.contains("garuda_request_duration_seconds_sum 0.004300\n"))
        #expect(page.contains("garuda_workers 4\n"))
        #expect(!page.contains("garuda_cache_hits_total"))
    }
}

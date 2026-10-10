import Testing
import CAvian
import AvianCore
@testable import Garuda
import AvianHTTP

// Metrics by route pattern on the metrics page.

@Suite("Route metrics", .serialized)
struct RouteMetricsTests {
    private func rendered() -> String {
        var out = ByteBuffer()
        defer { out.destroy() }
        RouteMetrics.render(into: &out)
        guard out.readableBytes > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: UnsafePointer(out.readPointer), count: out.readableBytes),
                      as: UTF8.self)
    }

    @Test func routesAreCountedByPatternNotPath() throws {
        #expect(av_metrics_init(2) == 0)
        let app = Application()
        app.get("/users/:id") { (id: Path<Int>) in "user \(id.value)" }
        app.post("/users") { () throws -> String in throw HTTPError(.conflict) }
        app.get("/quiet") { "never asked" }
        app.group("/files") {
            app.fallback { _, response in response.send(status: .notFound, "no file") }
        }
        let client = app.test
        let compiled = app.compile()
        RouteMetrics.reset()
        defer { RouteMetrics.reset() }
        #expect(RouteMetrics.initialize(compiled, slots: 2))

        for id in 1...3 { #expect(try client.get("/users/\(id)").status == 200) }
        #expect(try client.get("/users/nope").status == 400)
        #expect(try client.post("/users").status == 409)
        #expect(try client.get("/files/a.txt").status == 404)
        #expect(try client.get("/nowhere").status == 404)

        let text = rendered()
        #expect(text.contains(#"garuda_route_requests_total{method="GET",route="/users/:id",status="2xx"} 3"#))
        #expect(text.contains(#"garuda_route_requests_total{method="GET",route="/users/:id",status="4xx"} 1"#))
        #expect(text.contains(#"garuda_route_requests_total{method="POST",route="/users",status="4xx"} 1"#))
        #expect(text.contains(#"garuda_route_requests_total{method="*",route="fallback",status="4xx"} 1"#))
        #expect(text.contains(#"garuda_route_requests_total{method="*",route="unmatched",status="4xx"} 1"#))
        #expect(!text.contains("/quiet"))
        #expect(!text.contains("/users/1"))
        #expect(text.contains(#"garuda_route_request_duration_seconds_bucket{method="GET",route="/users/:id",le="+Inf"} 4"#))
        #expect(text.contains(#"garuda_route_request_duration_seconds_count{method="GET",route="/users/:id"} 4"#))
        #expect(text.contains("# TYPE garuda_route_request_duration_seconds histogram"))
    }

    @Test func anotherApplicationIsNotCounted() throws {
        #expect(av_metrics_init(2) == 0)
        let mine = Application()
        mine.get("/mine") { "mine" }
        let other = Application()
        other.get("/theirs") { "theirs" }
        RouteMetrics.reset()
        defer { RouteMetrics.reset() }
        #expect(RouteMetrics.initialize(mine.compile(), slots: 2))
        #expect(try other.test.get("/theirs").text == "theirs")
        #expect(rendered() == "")
        #expect(try mine.test.get("/mine").text == "mine")
        #expect(rendered().contains(#"route="/mine",status="2xx"} 1"#))
    }

    /// Runs on the calling thread, without waiting, for `ms`.
    private static func spin(milliseconds ms: UInt64) {
        let until = av_monotonic_us() &+ ms &* 1000
        while av_monotonic_us() < until {}
    }

    /// An async handler that computes past --slow-handler-ms without waiting
    /// is counted against its route, before its first wait and after one; a
    /// quick handler and a sync one are not.
    @Test func aHandlerThatHoldsItsWorkerIsCountedAgainstItsRoute() throws {
        #expect(av_metrics_init(2) == 0)
        let app = Application()
        app.onAsync(.get, "/crunch") { _, response in
            RouteMetricsTests.spin(milliseconds: 30)
            response.send("crunched")
        }
        app.onAsync(.get, "/nap-then-crunch") { _, response in
            try await response.sleep(milliseconds: 1)
            RouteMetricsTests.spin(milliseconds: 30)
            response.send("crunched")
        }
        app.onAsync(.get, "/quick") { _, response in response.send("quick") }
        app.get("/sync") { () -> String in
            RouteMetricsTests.spin(milliseconds: 30)
            return "sync"
        }
        var config = ServerConfig()
        config.maxConnections = 16
        config.slowHandlerMs = 10
        let client = app.testClient(configuration: config)
        RouteMetrics.reset()
        defer { RouteMetrics.reset() }
        #expect(RouteMetrics.initialize(app.compile(), slots: 2))

        #expect(try client.get("/crunch").text == "crunched")
        #expect(try client.get("/crunch").text == "crunched")
        #expect(try client.get("/nap-then-crunch").text == "crunched")
        #expect(try client.get("/quick").text == "quick")
        #expect(try client.get("/sync").text == "sync")

        let text = rendered()
        #expect(text.contains(#"garuda_route_slow_runs_total{method="GET",route="/crunch"} 2"#))
        #expect(text.contains(#"garuda_route_slow_runs_total{method="GET",route="/nap-then-crunch"} 1"#))
        #expect(!text.contains(#"garuda_route_slow_runs_total{method="GET",route="/quick"}"#))
        #expect(!text.contains(#"garuda_route_slow_runs_total{method="GET",route="/sync"}"#))
        #expect(text.contains("# TYPE garuda_route_slow_run_seconds_total counter"))
        #expect(text.contains(#"garuda_route_slow_run_seconds_total{method="GET",route="/crunch"} 0.0"#))
    }

    /// With the timing off, nothing is counted however long a handler runs.
    @Test func noSlowRunsAreCountedWithTheTimingOff() throws {
        #expect(av_metrics_init(2) == 0)
        let app = Application()
        app.onAsync(.get, "/crunch") { _, response in
            RouteMetricsTests.spin(milliseconds: 20)
            response.send("crunched")
        }
        var config = ServerConfig()
        config.maxConnections = 16
        config.slowHandlerMs = 0
        let client = app.testClient(configuration: config)
        RouteMetrics.reset()
        defer { RouteMetrics.reset() }
        #expect(RouteMetrics.initialize(app.compile(), slots: 2))
        #expect(try client.get("/crunch").text == "crunched")
        #expect(!rendered().contains("slow_run"))
    }

    @Test func labelValuesAreEscaped() {
        #expect(RouteMetrics.escapeLabel("a\"b\\c\n") == "a\\\"b\\\\c\\n")
    }
}

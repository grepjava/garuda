@_spi(Testing) import Garuda
import GarudaTesting
import Testing
import Vega

/// Holds the CPU for about `micros` microseconds without suspending.
func spin(micros: Int) -> UInt64 {
    let clock = ContinuousClock()
    let end = clock.now + .microseconds(micros)
    var hash: UInt64 = 1_469_598_103_934_665_603
    while clock.now < end {
        for i in 0..<256 { hash = (hash ^ UInt64(i)) &* 1_099_511_628_211 }
    }
    return hash
}

@Suite struct HeavyLaneTests {
    @Test func aRouteThatHoldsItsThreadBecomesHeavy() throws {
        let app = Application()
        app.get("/spin") { () in String(spin(micros: 2_000)) }
        app.get("/quick") { () in "quick" }
        let client = app.test
        for _ in 0..<4 { _ = try client.get("/spin") }
        for _ in 0..<40 { _ = try client.get("/quick") }
        let spun = try #require(app.routeCost(.get, "/spin"))
        #expect(spun.heavy)
        #expect(spun.average > .microseconds(1_000))
        let quick = try #require(app.routeCost(.get, "/quick"))
        #expect(!quick.heavy)
    }

    @Test func aRouteThatWaitsIsNotHeavy() throws {
        let app = Application()
        app.get("/sleep") { () async throws in
            try await Runtime.sleep(for: .milliseconds(3))
            return "slept"
        }
        let client = app.test
        for _ in 0..<5 { #expect(try client.get("/sleep").text == "slept") }
        let sleep = try #require(app.routeCost(.get, "/sleep"))
        #expect(!sleep.heavy)
        #expect(sleep.average < .microseconds(500))
    }

    @Test func aDeclaredRouteIsHeavyFromTheStart() throws {
        let app = Application()
        app.heavy.get("/report/:id") { (id: Path<Int>) in "report \(id.value)" }
        let client = app.test
        #expect(try client.get("/report/3").text == "report 3")
        #expect(try #require(app.routeCost(.get, "/report/:id")).heavy)
    }

    @Test func theThresholdComesFromTheConfiguration() throws {
        let app = Application()
        app.get("/spin") { () in String(spin(micros: 300)) }
        var config = ServerConfig()
        config.heavyThreshold = .microseconds(100)
        let client = app.testClient(configuration: config)
        for _ in 0..<4 { _ = try client.get("/spin") }
        #expect(try #require(app.routeCost(.get, "/spin")).heavy)
    }
}

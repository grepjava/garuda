import Garuda
import GarudaTesting
import Testing
import Vega

/// Waits on a read nobody will ever answer: a loopback connection whose other
/// end never writes.
func waitForever() async throws {
    let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
    let client = try await TCPStream.connect(to: SocketAddress(host: "127.0.0.1", port: listener.localPort))
    let server = try await listener.accept()
    var buffer = IOBuffer(capacity: 16)
    _ = try await client.read(into: &buffer)
    _ = server
}

@Suite struct DeadlineTests {
    @Test func aWaitPastTheDeadlineIs504() throws {
        let app = Application()
        app.deadline(.milliseconds(50)) {
            app.get("/stuck") { () async throws -> String in
                try await waitForever()
                return "unreached"
            }
        }
        let response = try app.test.get("/stuck")
        #expect(response.status == 504)
    }

    @Test func aQuickRouteIsUntouched() throws {
        let app = Application()
        app.deadline(.seconds(5)) {
            app.get("/quick") { () async throws in
                await Task.yield()
                return "quick"
            }
        }
        #expect(try app.test.get("/quick").text == "quick")
    }

    @Test func routesOutsideHaveNone() throws {
        let app = Application()
        app.deadline(.milliseconds(50)) {
            app.get("/bounded") { () in "b" }
        }
        app.get("/free") { () async throws -> String in
            try await Runtime.sleep(for: .milliseconds(120))
            return "free"
        }
        #expect(try app.test.get("/free").text == "free")
    }

    @Test func aHandlerThatCatchesTheTimeoutAnswersItself() throws {
        let app = Application()
        app.deadline(.milliseconds(50)) {
            app.get("/fallback") { () async throws -> String in
                do {
                    try await waitForever()
                    return "unreached"
                } catch let error as IOError where error == .timedOut {
                    return "cached copy"
                }
            }
        }
        let response = try app.test.get("/fallback")
        #expect(response.status == 200)
        #expect(response.text == "cached copy")
    }

    @Test func middlewareOutsideSeesThe504() throws {
        let app = Application()
        app.use { _, response, next in
            try await next()
            response.addHeader("x-status", "\(response.status.code)")
        }
        app.deadline(.milliseconds(50)) {
            app.get("/stuck") { () async throws -> String in
                try await waitForever()
                return "unreached"
            }
        }
        let response = try app.test.get("/stuck")
        #expect(response.status == 504)
        #expect(response.header("x-status") == "504")
    }

    @Test func deadlineScopesKeepPrefixesOfTheirGroup() throws {
        let app = Application()
        app.group("/api") {
            app.deadline(.seconds(1)) {
                app.get("/x") { () in "x" }
            }
        }
        #expect(try app.test.get("/api/x").text == "x")
    }
}

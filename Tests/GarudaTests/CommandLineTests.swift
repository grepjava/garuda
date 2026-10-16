#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
@testable import Garuda
import GarudaTesting
import Vega
import VegaIO

// The command line: Garuda 1's flags, and its units, on Garuda 2.

private func parsed(_ flags: [String]) -> ServerConfig? {
    guard case .run(let config) = ServerConfig.parse(["garuda"] + flags) else { return nil }
    return config
}

private func refused(_ flags: [String]) -> Bool {
    if case .exit(2) = ServerConfig.parse(["garuda"] + flags) { return true }
    return false
}

@Suite struct CommandLineTests {
    @Test func timesAreInGarudaOnesUnits() {
        guard let config = parsed(["--keep-alive", "1500", "--graceful-timeout", "1000",
                                   "--request-timeout", "2000", "--drain-delay", "250",
                                   "--sse-keep-alive", "7", "--ws-ping-interval", "3000",
                                   "--ws-ping-timeout", "4000", "--cache-ttl-max", "60"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.keepAliveTimeout == .milliseconds(1500))
        #expect(config.gracefulShutdown == .milliseconds(1000))
        // A stall mid-request, in the head or in the body, or in the answer.
        #expect(config.requestHeadTimeout == .milliseconds(2000))
        #expect(config.bodyTimeout == .milliseconds(2000))
        #expect(config.writeTimeout == .milliseconds(2000))
        #expect(config.drainDelay == .milliseconds(250))
        #expect(config.eventKeepAlive == .seconds(7))
        #expect(config.websocketPingInterval == .milliseconds(3000))
        #expect(config.websocketPingTimeout == .milliseconds(4000))
        #expect(config.cacheTTLMaxSeconds == 60)
        #expect(parsed(["--graceful-timeout", "0"])?.gracefulShutdown == .zero)
        for bad in [["--keep-alive", "0"], ["--keep-alive", "5s"], ["--graceful-timeout", "-1"],
                    ["--request-timeout", "0"], ["--request-timeout", "x"]] {
            #expect(refused(bad), "\(bad) parsed")
        }
    }

    @Test func limitsAndListeningAreParsed() {
        guard let config = parsed(["--backlog", "512", "--max-connections", "64",
                                   "--max-header-size", "8192", "--unix", "/tmp/g.sock",
                                   "--blocking-threads", "8", "--blocking-queue", "0"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.backlog == 512)
        #expect(config.maxConnections == 64)
        #expect(config.maxHeadSize == 8192)
        #expect(config.unixPath == "/tmp/g.sock")
        #expect(config.blockingThreads == 8)
        #expect(config.blockingQueue == 0)
        #expect(ServerConfig().maxConnections == nil && ServerConfig().blockingQueue == nil)
        for bad in [["--backlog", "0"], ["--max-connections", "0"], ["--max-header-size", "512"],
                    ["--unix", ""], ["--blocking-threads", "0"], ["--blocking-queue", "-1"],
                    ["--unix", "/tmp/g.sock", "--http3", "--tls-cert", "c", "--tls-key", "k"]] {
            #expect(refused(bad), "\(bad) parsed")
        }
    }

    @Test func whatTheRequestIsTakenToBeIsParsed() {
        guard let config = parsed(["--root-path", "/app/", "--scheme", "https",
                                   "--request-start-header"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.rootPath == "/app")
        #expect(config.assumeHTTPS)
        #expect(config.requestStartHeader)
        #expect(parsed(["--scheme", "http"])?.assumeHTTPS == false)
        #expect(parsed(["--root-path", "/"])?.rootPath == "")
        for bad in [["--root-path", "app"], ["--scheme", "ftp"]] {
            #expect(refused(bad), "\(bad) parsed")
        }
    }

    @Test func tlsCiphersAndReloadAreParsed() {
        guard let config = parsed(["--tls-cert", "c.pem", "--tls-key", "k.pem",
                                   "--tls-ciphers", "ECDHE+AESGCM", "--reload",
                                   "--reload-interval", "200"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.tlsCiphers == "ECDHE+AESGCM")
        #expect(config.reload)
        #expect(config.reloadInterval == .milliseconds(200))
        // Garuda 1's floor.
        #expect(parsed(["--reload-interval", "10"])?.reloadInterval == .milliseconds(50))
        for bad in [["--tls-ciphers", "ECDHE+AESGCM"], ["--reload-interval", "0"]] {
            #expect(refused(bad), "\(bad) parsed")
        }
    }

    @Test func garudaOnesEngineFlagsStartWithAWarning() {
        guard let config = parsed(["--ktls", "--no-ktls", "--sched-slice", "300",
                                   "--slow-handler-ms", "100"]) else {
            Issue.record("the flags did not parse")
            return
        }
        // --no-ktls asks for what is done anyway.
        #expect(config.ignoredFlags == ["--ktls", "--sched-slice", "--slow-handler-ms"])
        #expect(parsed(["--sched-slice", "0"]) != nil)
        for bad in [["--sched-slice", "50"], ["--slow-handler-ms", "-1"]] {
            #expect(refused(bad), "\(bad) parsed")
        }
    }
}

// What those flags do to a request.
@Suite struct GarudaOneFlagTests {
    private func app() -> Application {
        let app = Application()
        app.get("/users") { request, response in response.send("users \(request.path)") }
        app.get("/") { request, response in response.send("root \(request.path)") }
        app.get("/scheme") { request, response in response.send(request.arrivedOverHTTPS ? "https" : "http") }
        app.get("/start") { request, response in
            response.send(request.requestStart.map { "\($0)" } ?? "none")
        }
        app.get("/trace") { request, response in response.send(request.traceContext?.parentID ?? "none") }
        return app
    }

    private func client(_ change: (inout ServerConfig) -> Void) -> TestClient {
        var config = ServerConfig()
        change(&config)
        return app().testClient(configuration: config)
    }

    @Test func theRootPathIsTakenOffBeforeRouting() throws {
        let mounted = client { $0.rootPath = "/app" }
        #expect(try mounted.get("/app/users").text == "users /users")
        #expect(try mounted.get("/app").text == "root /")
        #expect(try mounted.get("/app/").text == "root /")
        // Outside the mount, as from a proxy that took the prefix off.
        #expect(try mounted.get("/users").text == "users /users")
        #expect(try mounted.get("/apple").status == .notFound)
        #expect(try client { _ in }.get("/app/users").status == .notFound)
    }

    @Test func schemeHTTPSIsWhatARequestWithoutTLSArrivedBy() throws {
        #expect(try client { $0.assumeHTTPS = true }.get("/scheme").text == "https")
        #expect(try client { _ in }.get("/scheme").text == "http")
    }

    @Test func requestStartIsTheWallClockWhenAskedFor() throws {
        let before = wallClockMicros()
        let text = try client { $0.requestStartHeader = true }.get("/start").text
        let start = UInt64(text) ?? 0
        #expect(start >= before && start <= wallClockMicros())
        #expect(try client { _ in }.get("/start").text == "none")
    }

    @Test func twoTraceparentsAreIgnored() throws {
        let traced = client { $0.traceContext = true }
        let one = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        let other = "00-0af7651916cd43dd8448eb211c80319c-1111111111111111-01"
        #expect(try traced.get("/trace", headers: [("traceparent", one)]).text == "b7ad6b7169203331")
        #expect(try traced.get("/trace", headers: [("traceparent", one), ("traceparent", other)]).text == "none")
    }

    @Test func noWebSocketsRefusesAnUpgradeWhateverTheRoute() throws {
        let upgrade = [("upgrade", "websocket"), ("connection", "Upgrade"),
                       ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="), ("sec-websocket-version", "13")]
        #expect(try client { $0.websocketsEnabled = false }.get("/", headers: upgrade).status.code == 501)
        #expect(try client { _ in }.get("/", headers: upgrade).status.code == 200)
        // An upgrade to something else is not a WebSocket's.
        #expect(try client { $0.websocketsEnabled = false }.get("/", headers: [("upgrade", "h2c")]).status.code == 200)
    }

    @Test func theHTTPSRedirectClosesTheConnection() throws {
        let response = try httpsRedirectApplication(httpsPort: 8443).testClient()
            .get("/a", headers: [("host", "example.com")])
        #expect(response.status.code == 301)
        #expect(response.header("connection") == "close")
    }

    #if !os(Windows)
    /// --blocking-queue bounds the shard's pool: with its one thread busy
    /// and no room to wait, an offloaded route is answered 503 at once.
    @Test func blockingQueueRefusesPastThreadsAndQueue() throws {
        let app = Application()
        app.offload.get("/sleep") { () -> String in
            usleep(400_000)
            return "slept"
        }
        let compiled = app.compile()
        let rt = Runtime(workers: 2, blockingThreads: 1, blockingQueue: 0)
        defer { rt.shutdown() }
        let limits = ConnectionLimits(ServerConfig())
        let replies = try rt.block { () async throws(IOError) -> [String] in
            var replies: [String] = []
            var first: Task<String, Never>? = nil
            for delay in [0, 100] {
                try? await Runtime.sleep(for: .milliseconds(delay))
                let pair = try UnixStream.pair()
                rt.spawn(with: pair.second) { stream in
                    _ = await serveHTTP1(stream, app: compiled, limits: limits, peer: .none)
                }
                var out = IOBuffer(capacity: 128)
                _ = out.append("GET /sleep HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
                try await pair.first.write(out)
                if delay == 0 {
                    // The first holds the pool's thread while the second asks.
                    first = rt.spawn(with: pair.first) { client in
                        var buffer = IOBuffer(capacity: 4096)
                        while (try? await client.read(into: &buffer)) ?? 0 > 0 {}
                        return buffer.string
                    }
                    continue
                }
                var buffer = IOBuffer(capacity: 4096)
                while try await pair.first.read(into: &buffer) > 0 {}
                replies.append(buffer.string)
            }
            if let first { replies.insert(await first.value, at: 0) }
            return replies
        }
        #expect(replies.count == 2 && replies[0].hasPrefix("HTTP/1.1 200") && replies[1].hasPrefix("HTTP/1.1 503"),
                "\(replies)")
        #expect(BlockingQueueFull().status == .serviceUnavailable)
    }
    #endif

    #if !os(Windows)
    /// A head that arrives in pieces is parsed again whole once the rest is
    /// here, and the parts parsed the first time are not counted twice: a
    /// Host seen once is not a second Host.
    @Test func aHeadThatArrivesInPiecesIsReadWhole() throws {
        let app = Application()
        app.get("/x") { _, response in response.send("x") }
        let compiled = app.compile()
        let rt = Runtime(workers: 1)
        defer { rt.shutdown() }
        let limits = ConnectionLimits(ServerConfig())
        let reply = try rt.block { () async throws(IOError) -> String in
            let pair = try UnixStream.pair()
            let client = pair.first
            rt.spawn(with: pair.second) { stream in
                _ = await serveHTTP1(stream, app: compiled, limits: limits, peer: .none)
            }
            for piece in ["GET /x HTTP/1.1\r\nHost: example.com\r\n", "Connection: close\r\n\r\n"] {
                var out = IOBuffer(capacity: 64)
                _ = out.append(piece)
                try await client.write(out)
                try? await Runtime.sleep(for: .milliseconds(50))
            }
            var buffer = IOBuffer(capacity: 4096)
            while try await client.read(into: &buffer) > 0 {}
            return buffer.string
        }
        #expect(reply.hasPrefix("HTTP/1.1 200"), "\(reply)")
    }
    #endif
}

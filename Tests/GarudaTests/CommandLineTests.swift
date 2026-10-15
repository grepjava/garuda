import Testing
@testable import Garuda

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
        // A stall mid-request, in the head or in the body.
        #expect(config.requestHeadTimeout == .milliseconds(2000))
        #expect(config.bodyTimeout == .milliseconds(2000))
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

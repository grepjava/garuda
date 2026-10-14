import Testing
import Synchronization
@testable import Garuda
import GarudaTesting

// request.log and AppLog: the request's fields, both formats, escaping, and
// the 4096-byte line. Then the access log, and the flags that turn them on.

private final class Captured: Sendable {
    let lines = Mutex<[String]>([])
    func take() -> [String] { lines.withLock { let out = $0; $0.removeAll(); return out } }
}

/// Runs `body` with application and access log lines captured, the
/// application's in `json` or text.
private func capturing(json: Bool, _ body: (Captured) throws -> Void) rethrows {
    let captured = Captured()
    let savedJSON = AppLogOutput.json
    let savedPID = Log.fixedPID
    AppLogOutput.json = json
    Log.fixedPID = 0
    AppLogOutput.capture = { line in captured.lines.withLock { $0.append(line) } }
    defer {
        AppLogOutput.capture = nil
        AppLogOutput.json = savedJSON
        Log.fixedPID = savedPID
    }
    try body(captured)
}

private let traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

@Suite("Logging", .serialized)
struct LoggingTests {

    private func app() -> Application {
        let app = Application()
        app.get("/orders/:id") { request, response in
            request.log.info("order looked up", ["order": "\(request.parameter(0))", "cents": 1250, "paid": true])
            response.send("ok")
        }
        app.get("/later") { request, response in
            let log = request.log.with(["user": "ada"])
            await Task.yield()
            log.warning("after an await")
            response.send("ok")
        }
        app.get("/quiet") { _, response in response.send("ok") }
        return app
    }

    private func client(_ app: Application, accessLog: Bool = false, json: Bool = false) -> TestClient {
        var config = ServerConfig()
        config.requestID = true
        config.traceContext = true
        config.accessLog = accessLog
        config.accessLogJSON = json
        return app.testClient(configuration: config)
    }

    @Test func aTextLineCarriesTheMessageItsFieldsAndTheRequest() throws {
        try capturing(json: false) { captured in
            let response = try client(app()).get("/orders/42", headers: [("traceparent", traceparent)])
            let id = try #require(response.header("x-request-id"))
            #expect(captured.take() == [
                "[info]  order looked up order=42 cents=1250 paid=true method=GET path=/orders/42 request_id=\(id)"
                    + " trace_id=4bf92f3577b34da6a3ce929d0e0e4736 parent_id=00f067aa0ba902b7",
            ])
        }
    }

    @Test func aJSONLineIsOneObject() throws {
        try capturing(json: true) { captured in
            let response = try client(app()).get("/orders/7")
            let id = try #require(response.header("x-request-id"))
            #expect(captured.take() == [
                #"{"level":"info","msg":"order looked up","method":"GET","path":"/orders/7","request_id":"\#(id)","order":"7","cents":1250,"paid":true}"#,
            ])
        }
    }

    @Test func aLoggerOutlivesAnAwaitAndCarriesAddedFields() throws {
        try capturing(json: false) { captured in
            _ = try client(app()).get("/later")
            let lines = captured.take()
            #expect(lines.count == 1)
            #expect(lines.first?.hasPrefix("[warn]  after an await method=GET path=/later request_id=") == true)
            #expect(lines.first?.hasSuffix(" user=ada") == true)
        }
    }

    @Test func linesBelowTheLevelAreNotWritten() throws {
        let saved = Log.level
        Log.level = .warning
        defer { Log.level = saved }
        capturing(json: false) { captured in
            AppLog.info("quiet")
            AppLog.debug("quieter")
            AppLog.error("loud")
            #expect(captured.take() == ["[error] loud"])
            #expect(!AppLog.enabled(.info))
            #expect(AppLog.enabled(.error))
        }
    }

    @Test func nothingAClientSendsCanStartANewLine() throws {
        capturing(json: false) { captured in
            AppLog.info("evil\nline\u{2028}\r\u{1b}[31m", ["path": "/a b\"c\\d=e\n", "empty": "", "a key": 1])
            #expect(captured.take() == [
                #"[info]  evil\nline\u2028\r\u001b[31m path="/a b\"c\\d=e\n" empty="" a_key=1"#,
            ])
        }
        capturing(json: true) { captured in
            AppLog.info("say \"hi\"\n\u{0}", ["tab": "a\tb", "é": "ünïcode", "inf": .double(.infinity), "half": 0.5])
            #expect(captured.take() == [
                #"{"level":"info","msg":"say \"hi\"\n\u0000","tab":"a\tb","é":"ünïcode","inf":"inf","half":0.5}"#,
            ])
        }
    }

    @Test func aLongLineIsCutAndSaysSo() throws {
        let long = String(repeating: "é", count: 5000)
        try capturing(json: true) { captured in
            AppLog.error(long, ["kept": false])
            let line = try #require(captured.take().first)
            #expect(line.utf8.count <= 4095)
            #expect(line.hasPrefix(#"{"level":"error","msg":"éé"#))
            #expect(line.hasSuffix(#"é","truncated":true}"#))
        }
        try capturing(json: false) { captured in
            AppLog.error("short", ["big": .string(long), "small": 1])
            let line = try #require(captured.take().first)
            // A field that does not fit is left out whole; the ones after it
            // that do still go in.
            #expect(line == "[error] short small=1 truncated=true")
        }
    }

    @Test func aRequestLogCarriesNoIDWithoutTheFlags() throws {
        try capturing(json: false) { captured in
            let response = try app().test.get("/orders/5", headers: [("traceparent", traceparent)])
            #expect(response.header("x-request-id") == nil)
            #expect(captured.take() == [
                "[info]  order looked up order=5 cents=1250 paid=true method=GET path=/orders/5",
            ])
        }
    }

    // MARK: The access log

    @Test func theAccessLogWritesALinePerRequest() throws {
        try capturing(json: false) { captured in
            let client = client(app(), accessLog: true)
            let response = try client.get("/quiet?full=1", headers: [("traceparent", traceparent)])
            let id = try #require(response.header("x-request-id"))
            let line = try #require(captured.take().first)
            #expect(line.hasPrefix("garuda info: GET /quiet?full=1 200 "))
            #expect(line.hasSuffix("us id=\(id) trace=4bf92f3577b34da6a3ce929d0e0e4736 span=00f067aa0ba902b7"))

            // A miss is logged too, with no ID or trace it did not carry...
            #expect(try client.get("/nowhere").status == 404)
            let miss = try #require(captured.take().first)
            #expect(miss.hasPrefix("garuda info: GET /nowhere 404 "))
            #expect(!miss.contains("trace="))
        }
    }

    @Test func theJSONAccessLogIsABareObject() throws {
        try capturing(json: false) { captured in
            let response = try client(app(), accessLog: true, json: true).get("/quiet")
            let id = try #require(response.header("x-request-id"))
            let line = try #require(captured.take().first)
            #expect(line.hasPrefix(#"{"level":"info","method":"GET","target":"/quiet","status":200,"duration_us":"#))
            #expect(line.hasSuffix(#","proto":"HTTP/1.1","request_id":"\#(id)"}"#))
        }
    }

    @Test func aLongTargetIsCutAndTheLineStillCloses() throws {
        let long = "/quiet?" + String(repeating: "q", count: 6000)
        try capturing(json: false) { captured in
            _ = try client(app(), accessLog: true, json: true).get(long)
            let line = try #require(captured.take().first)
            #expect(line.utf8.count <= 4095)
            #expect(line.contains(#""status":200"#))
            #expect(line.hasSuffix(#","truncated":true}"#))
        }
        try capturing(json: false) { captured in
            _ = try client(app(), accessLog: true).get(long)
            let line = try #require(captured.take().first)
            #expect(line.utf8.count <= 4095)
            #expect(line.contains(" 200 "))
            #expect(line.hasSuffix(" truncated=true"))
        }
    }

    @Test func peerBytesCannotBreakALine() throws {
        // A target is the client's bytes, and need not be UTF-8. The parser
        // has already refused control characters and spaces in it.
        let raw = Array("GET /quiet?a=\"\\".utf8) + [0xFF, 0xFE]
            + Array(" HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n".utf8)
        try capturing(json: false) { captured in
            let response = try client(app(), accessLog: true, json: true).send(raw: raw)
            #expect(response.status == 200)
            let line = try #require(captured.take().first)
            #expect(line.contains(#""target":"/quiet?a=\"\\\u00ff\u00fe""#))
        }
        try capturing(json: false) { captured in
            let response = try client(app(), accessLog: true).send(raw: raw)
            #expect(response.status == 200)
            let line = try #require(captured.take().first)
            #expect(line.contains(#"/quiet?a="\x5c"#))
        }
    }

    @Test func aHeadThatCannotBeReadIsLoggedWithoutOne() throws {
        try capturing(json: false) { captured in
            let response = try client(app(), accessLog: true).send(raw: Array("NOT A REQUEST\r\n\r\n".utf8))
            #expect(response.status == 505)
            let line = try #require(captured.take().first)
            #expect(line == "garuda info: - - 505 0us")
        }
    }

    @Test func theAccessLogIsQuietAboveInfo() throws {
        let saved = Log.level
        Log.level = .warning
        defer { Log.level = saved }
        try capturing(json: false) { captured in
            _ = try client(app(), accessLog: true).get("/quiet")
            #expect(captured.take().isEmpty)
        }
    }

    // MARK: Flags

    @Test func theFlagChoosesTheFormatAndTheAccessLogFollows() throws {
        func parse(_ arguments: [String]) -> ServerConfig? {
            if case .run(let config) = ServerConfig.parse(["garuda"] + arguments) { return config }
            return nil
        }
        let json = try #require(parse(["--log-format", "json"]))
        #expect(json.logJSON && json.accessLogJSON)
        let text = try #require(parse(["--log-format", "json", "--access-log-format", "text"]))
        #expect(text.logJSON && !text.accessLogJSON && text.accessLog)
        let plain = try #require(parse([]))
        #expect(!plain.logJSON && !plain.accessLogJSON && !plain.accessLog)
        if case .exit(let status) = ServerConfig.parse(["garuda", "--log-format", "xml"]) {
            #expect(status == 2)
        } else {
            Issue.record("an unknown format was accepted")
        }
    }

    @Test func theRequestFlagsAreRead() throws {
        func parse(_ arguments: [String]) -> ServerConfig? {
            if case .run(let config) = ServerConfig.parse(["garuda"] + arguments) { return config }
            return nil
        }
        let all = try #require(parse(["--request-id", "--trace-context", "--access-log",
                                      "--forwarded-allow-ips", "10.0.0.0/8, unix"]))
        #expect(all.requestID && all.traceContext && all.accessLog)
        #expect(all.trust.trustUnix && all.trust.nets.count == 1)
        if case .exit(let status) = ServerConfig.parse(["garuda", "--forwarded-allow-ips", "not-an-address"]) {
            #expect(status == 2)
        } else {
            Issue.record("a list that is not addresses was accepted")
        }
    }
}

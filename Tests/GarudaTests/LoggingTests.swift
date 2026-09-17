import Testing
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Garuda
import AvianCore

// request.log and AppLog: the request's fields, both formats, escaping, and
// the 4096-byte line.

private final class Captured: Sendable {
    let lines = Mutex<[String]>([])
    func take() -> [String] { lines.withLock { let out = $0; $0.removeAll(); return out } }
}

/// Runs `body` with application log lines captured, in `json` or text.
private func capturing(json: Bool, _ body: (Captured) throws -> Void) rethrows {
    let captured = Captured()
    let savedJSON = AppLogOutput.json
    let savedPID = Log.pid
    AppLogOutput.json = json
    Log.pid = 0
    AppLogOutput.capture = { line in captured.lines.withLock { $0.append(line) } }
    defer {
        AppLogOutput.capture = nil
        AppLogOutput.json = savedJSON
        Log.pid = savedPID
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
        app.onAsync(.get, "/later") { request, response in
            let log = request.log.with(["user": "ada"])
            await Task.yield()
            log.warning("after an await")
            response.send("ok")
        }
        return app
    }

    private func client(_ app: Application) -> TestClient {
        var config = ServerConfig()
        config.maxConnections = 16
        config.requestID = true
        config.traceContext = true
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

    @Test func theFlagChoosesTheFormatAndTheAccessLogFollows() throws {
        // The parser keeps pointers into argv, so the strings are never freed.
        func parsed(_ arguments: [String]) -> GarudaCLI.Parsed {
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 2)
            for (i, argument) in (["garuda"] + arguments).enumerated() { argv[i] = strdup(argument) }
            argv[arguments.count + 1] = nil
            return GarudaCLI.parse(argc: arguments.count + 1, argv: argv)
        }
        func parse(_ arguments: [String]) -> ServerConfig? {
            if case .run(let config) = parsed(arguments) { return config }
            return nil
        }
        let json = try #require(parse(["--log-format", "json"]))
        #expect(json.logJSON && json.accessLogJSON)
        let text = try #require(parse(["--log-format", "json", "--access-log-format", "text"]))
        #expect(text.logJSON && !text.accessLogJSON && text.accessLog)
        let plain = try #require(parse([]))
        #expect(!plain.logJSON && !plain.accessLogJSON)
        if case .exit(let status) = parsed(["--log-format", "xml"]) {
            #expect(status == 2)
        } else {
            Issue.record("an unknown format was accepted")
        }
    }
}

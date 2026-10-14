import Synchronization
import Testing
@testable import Garuda
@_spi(Testing) import GarudaTesting
import GarudaWire
import Vega
import VegaIO
import VegaTLS

// HTTP/2: the server's framing, its limits and defences, and that a stream
// reaches the application as an HTTP/1 request does. Garuda 1 tested its
// HTTP/2 server only from outside (scripts/http2-test.py); these cover the
// same ground, and the protocol violations, through the frame-level client
// in GarudaTesting.

private final class Flag: Sendable {
    let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

private final class Seen: Sendable {
    let requests = Mutex<[CompletedRequest]>([])
    func take() -> [CompletedRequest] { requests.withLock { let out = $0; $0.removeAll(); return out } }
}

private func app(_ cancelled: Flag = Flag()) -> Application {
    let app = Application()
    app.get("/") { _, response in response.send(status: .ok) }
    app.get("/user/:id") { request, response in response.send(request.parameter(0)) }
    app.post("/user") { request, response in response.send("\(request.body.count)") }
    app.post("/echo") { request, response in response.send(request.body) }
    app.get("/big/:n") { request, response in
        response.send([UInt8](repeating: 0x61, count: Int(request.parameter(0)) ?? 0))
    }
    app.get("/delay/:ms") { request, response in
        do {
            try await Runtime.sleep(for: .milliseconds(Int(request.parameter(0)) ?? 1))
        } catch {
            cancelled.set()
            throw error
        }
        response.send(status: .ok)
    }
    app.get("/version") { request, response in
        let v = request.version
        response.send("\(v.major).\(v.minor) \(request.arrivedOverHTTPS) \(request.authority ?? "-")")
    }
    app.get("/header/:name") { request, response in
        response.send(request.header(request.parameter(0)) ?? "-")
    }
    app.get("/framing") { _, response in
        response.addHeader("connection", "close")
        response.addHeader("keep-alive", "timeout=5")
        response.addHeader("transfer-encoding", "chunked")
        response.addHeader("x-kept", "yes")
        response.send("framed")
    }
    return app
}

private func config(_ change: (inout ServerConfig) -> Void = { _ in }) -> ServerConfig {
    var config = ServerConfig()
    change(&config)
    return config
}

@Suite("HTTP/2")
struct HTTP2Tests {

    // MARK: Requests and responses

    @Test func aGetIsAnsweredWithTheHTTP1Headers() throws {
        let h2 = try app().test.http2()
        let response = try h2.get("/")
        #expect(response.status == .ok)
        #expect(response.ended)
        #expect(response.header("content-length") == "0")
        #expect(response.header("server") == "garuda")
        #expect(response.header("date") != nil)
        #expect(response.body.isEmpty)
    }

    @Test func theServerSaysWhatItAllows() throws {
        let h2 = try app().test.http2()
        #expect(h2.serverSettings[H2Setting.maxConcurrentStreams.rawValue] == 128)
        #expect(h2.serverSettings[H2Setting.enablePush.rawValue] == 0)
        #expect(h2.serverSettings[H2Setting.initialWindowSize.rawValue] == UInt32(256 * 1024))
        #expect(h2.serverSettings[H2Setting.maxFrameSize.rawValue] == 16384)
    }

    @Test func thePathSurvivesHPACK() throws {
        let h2 = try app().test.http2()
        let response = try h2.get("/user/survives-hpack")
        #expect(response.status == .ok)
        #expect(response.text == "survives-hpack")
        #expect(response.header("content-length") == "14")
    }

    @Test func aStreamIsVersionTwo() throws {
        let h2 = try app().test.http2()
        #expect(try h2.get("/version").text == "2.0 false test")
    }

    @Test func connectionHeadersAreNotSent() throws {
        let h2 = try app().test.http2()
        let response = try h2.get("/framing")
        #expect(response.text == "framed")
        #expect(response.header("connection") == nil)
        #expect(response.header("keep-alive") == nil)
        #expect(response.header("transfer-encoding") == nil)
        #expect(response.header("x-kept") == "yes")
        #expect(response.header("content-length") == "6")
    }

    @Test func aHeadAnswerHasTheLengthAndNoBody() throws {
        let app = app()
        app.head("/user/:id") { request, response in response.send(request.parameter(0)) }
        let h2 = try app.test.http2()
        let response = try h2.head("/user/abc")
        #expect(response.status == .ok)
        #expect(response.header("content-length") == "3")
        #expect(response.body.isEmpty)
        #expect(response.ended)
    }

    @Test func aMissIs404AndAWrongMethod405() throws {
        let h2 = try app().test.http2()
        #expect(try h2.get("/nope").status == .notFound)
        let response = try h2.response(try h2.request("DELETE", "/user/1"))
        #expect(response.status == .methodNotAllowed)
        #expect(response.header("allow") == "GET, HEAD")
    }

    @Test func aBodyLargerThanAFrameIsTakenWhole() throws {
        let h2 = try app().test.http2()
        let payload = (0..<102_400).map { UInt8(truncatingIfNeeded: $0) }
        let response = try h2.post("/echo", body: payload)
        #expect(response.status == .ok)
        #expect(response.body == payload)
    }

    @Test func anUploadLargerThanTheWindowCompletes() throws {
        let h2 = try app().test.http2()
        let response = try h2.post("/user", body: [UInt8](repeating: 0x7A, count: 1 << 20))
        #expect(response.text == "\(1 << 20)")
    }

    @Test func aResponseLargerThanTheWindowArrivesWhole() throws {
        // A client window of 16 KiB: the server has to wait for WINDOW_UPDATE.
        let h2 = try app().test.http2(settings: [(.initialWindowSize, 16384)])
        let response = try h2.get("/big/400000")
        #expect(response.status == .ok)
        #expect(response.body.count == 400_000)
        #expect(response.body.allSatisfy { $0 == 0x61 })
    }

    @Test func aShutWindowHoldsTheBodyUntilItOpens() throws {
        let h2 = try app().test.http2(settings: [(.initialWindowSize, 0)])
        let id = try h2.request("GET", "/user/0123456789")
        // The head goes; the body waits for window.
        _ = try h2.nextFrame { $0.kind == .headers && $0.stream == id }
        #expect(h2.received(id)?.body.isEmpty == true)
        try h2.send(.windowUpdate, stream: id, payload: h2.uint32(4))
        let first = try #require(try h2.nextFrame { $0.kind == .data && $0.stream == id })
        #expect(first.payload == Array("0123".utf8))
        #expect(!first.has(.endStream))
        try h2.send(.windowUpdate, stream: id, payload: h2.uint32(100))
        #expect(try h2.response(id).text == "0123456789")
    }

    /// One SETTINGS frame may change INITIAL_WINDOW_SIZE more than once, and
    /// each value applies in turn to the streams already open.
    @Test func initialWindowSizeGivenTwiceCountsBoth() throws {
        for (updates, expected) in [([100, 100], 100), ([100, 50], 50)] {
            let h2 = try app().test.http2(settings: [(.initialWindowSize, 0)])
            // What arrives is not given back: the window is the whole story.
            h2.autoWindowUpdate = false
            let id = try h2.request("GET", "/user/" + String(repeating: "w", count: 100))
            _ = try h2.nextFrame { $0.kind == .headers && $0.stream == id }
            try h2.send(.settings, stream: 0,
                        payload: h2.settingsPayload(updates.map { (.initialWindowSize, UInt32($0)) }))
            try h2.send(.windowUpdate, stream: 0, payload: h2.uint32(1))  // something to answer
            var got = 0
            h2.timeout = .milliseconds(300)
            while let f = try? h2.nextFrame(where: { $0.kind == .data && $0.stream == id }) {
                got += f.payload.count
                if f.has(.endStream) { break }
            }
            #expect(got == expected)
        }
    }

    @Test func aHostTheSameAsTheAuthorityIsServed() throws {
        let h2 = try app().test.http2()
        let same = try h2.request("GET", "/", headers: [("host", "test")])
        let upper = try h2.request("GET", "/", headers: [("host", "TEST")])
        let answers = try h2.responses([same, upper])
        #expect(answers.map(\.status) == [.ok, .ok])
    }

    @Test func aHostThatDiffersFromTheAuthorityIsReset() throws {
        let h2 = try app().test.http2()
        let differs = try h2.response(try h2.request("GET", "/", headers: [("host", "elsewhere.example")]))
        #expect(differs.reset == H2Error.protocolError.rawValue)
        #expect(differs.status == nil)
        // An empty :authority is not the same as a Host that names something.
        let empty = try h2.response(try h2.request("GET", "/", headers: [("host", "test")], authority: ""))
        #expect(empty.reset == H2Error.protocolError.rawValue)
        // And the connection goes on.
        #expect(try h2.get("/user/after").text == "after")
    }

    @Test func cookieCrumbsAreJoined() throws {
        let h2 = try app().test.http2()
        let response = try h2.get("/header/cookie", headers: [("cookie", "a=1"), ("cookie", "b=2")])
        #expect(response.text == "a=1; b=2")
    }

    @Test func aRequestSplitAcrossContinuationsIsUnderstood() throws {
        let h2 = try app().test.http2()
        let padding = (0..<48).map { ("x-pad-\($0)", String(repeating: "v", count: 512)) }
        let response = try h2.get("/user/continued", headers: padding)
        #expect(response.text == "continued")
    }

    @Test func responseHeadersLargerThanAFrameUseContinuations() throws {
        let app = Application()
        app.get("/wide") { _, response in
            for i in 0..<40 { response.addHeader("x-wide-\(i)", String(repeating: "w", count: 1000)) }
            response.send("wide")
        }
        let h2 = try app.test.http2()
        let id = try h2.request("GET", "/wide")
        let response = try h2.response(id)
        #expect(response.text == "wide")
        #expect(response.headers(named: "x-wide-39").first?.count == 1000)
        #expect(h2.frames.contains { $0.kind == .continuation && $0.stream == id })
    }

    /// The writer's shortcuts encode exactly what the encoder does.
    @Test func cachedAndDirectFieldsEncodeAsTheEncoderDoes() {
        func bytes(_ b: borrowing ByteBuffer) -> [UInt8] {
            Array(UnsafeBufferPointer(start: b.readPointer, count: b.readableBytes))
        }
        func plain(_ name: String, _ value: String) -> [UInt8] {
            var out = ByteBuffer()
            defer { out.destroy() }
            let n = Array(name.utf8), v = Array(value.utf8) + [0]
            n.withUnsafeBufferPointer { np in
                v.withUnsafeBufferPointer { vp in
                    HPACKEncoder().encode(name: np.baseAddress!, nameLength: np.count, value: vp.baseAddress!,
                                          valueLength: vp.count - 1, into: &out)
                }
            }
            return bytes(out)
        }
        for n in [0, 1, 7, 9, 10, 33, 99, 100, 123, 999, 1000, 12345, 400_000, 1 << 40, Int.max] {
            var out = ByteBuffer()
            encodeContentLength(n, into: &out)
            #expect(bytes(out) == plain("content-length", "\(n)"), "content-length \(n)")
            out.destroy()
        }
        var cache = H2FieldCache()
        let fields = (0..<20).map { ("x-field-\($0 % 11)", String(repeating: "v", count: $0 * 9)) }
            + [("content-type", "text/plain; charset=utf-8"), ("server", "garuda"), ("x-empty", "")]
        for round in 0..<3 {
            for (name, value) in fields {
                var out = ByteBuffer()
                let n = Array(name.utf8), v = Array(value.utf8) + [0]
                n.withUnsafeBufferPointer { np in
                    v.withUnsafeBufferPointer { vp in
                        cache.encode(HPACKEncoder(), np.baseAddress!, np.count, vp.baseAddress!, vp.count - 1, into: &out)
                    }
                }
                #expect(bytes(out) == plain(name, value), "\(name) round \(round)")
                out.destroy()
            }
        }
    }

    // MARK: Multiplexing and cancellation

    @Test func streamsRunConcurrently() throws {
        let h2 = try app().test.http2()
        let began = ContinuousClock.now
        let ids = try (0..<10).map { _ in try h2.request("GET", "/delay/200") }
        let answers = try h2.responses(ids)
        #expect(answers.allSatisfy { $0.status == .ok })
        #expect(ContinuousClock.now - began < .milliseconds(1500))
    }

    @Test func aWaitingStreamDoesNotHoldUpTheOneBesideIt() throws {
        let h2 = try app().test.http2()
        let slow = try h2.request("GET", "/delay/400")
        let fast = try h2.request("GET", "/user/7")
        #expect(try h2.response(fast).text == "7")
        #expect(h2.received(slow)?.status == nil)
        #expect(try h2.response(slow).status == .ok)
    }

    /// Past its first runs a quick route is answered on the reader; the
    /// answers are the same.
    @Test func aQuickRouteAnsweredOnTheReaderAnswersTheSame() throws {
        let h2 = try app().test.http2()
        for i in 0..<40 {
            let response = try h2.get("/user/\(i)")
            #expect(response.text == "\(i)")
            #expect(response.header("content-length") == "\("\(i)".utf8.count)")
            #expect(response.header("server") == "garuda")
        }
        for n in 0..<24 { #expect(try h2.post("/user", body: [UInt8](repeating: 1, count: n)).text == "\(n)") }
        #expect(try h2.get("/nope").status == .notFound)
        #expect(try h2.get("/user/last").text == "last")
    }

    /// A route that suspends once it had been quick waits on the reader that
    /// once, and goes to a task of its own from then on.
    @Test func aRouteSeenToSuspendLeavesTheReader() throws {
        let app = Application()
        app.get("/maybe/:ms") { request, response in
            let ms = Int(request.parameter(0)) ?? 0
            if ms > 0 { try await Runtime.sleep(for: .milliseconds(ms)) }
            response.send(status: .ok)
        }
        app.get("/user/:id") { request, response in response.send(request.parameter(0)) }
        let h2 = try app.test.http2()
        for _ in 0..<20 { #expect(try h2.get("/maybe/0").status == .ok) }
        #expect(try h2.get("/maybe/50").status == .ok)
        let slow = try h2.request("GET", "/maybe/400")
        let fast = try h2.request("GET", "/user/7")
        #expect(try h2.response(fast).text == "7")
        #expect(h2.received(slow)?.status == nil)
        #expect(try h2.response(slow).status == .ok)
    }

    @Test func aResetStreamIsCancelledAndNeverAnswers() throws {
        let cancelled = Flag()
        let h2 = try app(cancelled).test.http2()
        let doomed = try h2.request("GET", "/delay/1000")
        nap(milliseconds: 100)
        try h2.reset(doomed)
        #expect(try h2.get("/user/9").text == "9")
        let deadline = ContinuousClock.now + .seconds(2)
        while !cancelled.isSet && ContinuousClock.now < deadline { nap(milliseconds: 10) }
        #expect(cancelled.isSet)
        nap(milliseconds: 100)
        _ = try h2.get("/")
        #expect(h2.received(doomed)?.status == nil)
    }

    /// A task a reset cancelled is not reused: streams after it are not
    /// born cancelled.
    @Test func streamsAfterAResetAreNotCancelled() throws {
        let cancellations = Mutex(0)
        let app = Application()
        app.get("/delay/:ms") { request, response in
            do {
                try await Runtime.sleep(for: .milliseconds(Int(request.parameter(0)) ?? 1))
            } catch {
                cancellations.withLock { $0 += 1 }
                throw error
            }
            response.send(status: .ok)
        }
        let h2 = try app.test.http2()
        for _ in 0..<5 {
            let doomed = try h2.request("GET", "/delay/1000")
            nap(milliseconds: 50)
            try h2.reset(doomed)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while cancellations.withLock({ $0 }) < 5 && ContinuousClock.now < deadline { nap(milliseconds: 10) }
        #expect(cancellations.withLock { $0 } == 5)
        let ids = try (0..<40).map { _ in try h2.request("GET", "/delay/2") }
        #expect(try h2.responses(ids).allSatisfy { $0.status == .ok })
        #expect(cancellations.withLock { $0 } == 5)
    }

    @Test func cancellingAmongCompletedRequestsIsNotPenalised() throws {
        let h2 = try app().test.http2()
        for _ in 0..<300 {
            _ = try h2.get("/")
            try h2.reset(try h2.request("GET", "/delay/5000"))
        }
        #expect(try h2.get("/").status == .ok)
    }

    /// CVE-2023-44487: streams opened and cancelled at once never reach the
    /// concurrency limit, so what is bounded is cancellations beyond answers.
    @Test func aFloodOfCancellationsIsToldToEnhanceItsCalm() throws {
        let h2 = try app().test.http2()
        var burst: [UInt8] = []
        for _ in 0..<300 {
            let id = h2.nextStream
            h2.nextStream += 2
            burst += h2.frame(H2FrameType.headers.rawValue,
                              flags: H2Flags.endHeaders.rawValue | H2Flags.endStream.rawValue, stream: id,
                              payload: h2.headerBlock([(":method", "GET"), (":scheme", "http"),
                                                       (":authority", "test"), (":path", "/delay/5000")]))
            burst += h2.frame(H2FrameType.rstStream.rawValue, stream: id, payload: h2.uint32(8))
        }
        try h2.send(raw: burst)
        #expect(try h2.goaway()?.code == H2Error.enhanceYourCalm.rawValue)
        #expect(h2.waitForClose())
        // Other connections are unaffected.
        #expect(try app().test.http2().get("/").status == .ok)
    }

    @Test func streamsPastTheLimitAreRefused() throws {
        let client = app().testClient(configuration: config { $0.h2MaxConcurrentStreams = 2 })
        let h2 = try client.http2()
        #expect(h2.serverSettings[H2Setting.maxConcurrentStreams.rawValue] == 2)
        let a = try h2.request("GET", "/delay/300"), b = try h2.request("GET", "/delay/300")
        let c = try h2.request("GET", "/delay/300")
        #expect(try h2.response(c).reset == H2Error.refusedStream.rawValue)
        #expect(try h2.responses([a, b]).map(\.status) == [.ok, .ok])
        // Room again once they are done.
        #expect(try h2.get("/").status == .ok)
    }

    // MARK: Bodies

    @Test func aBodyEndsWithTrailersOfItsDeclaredLength() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("POST", "/user", headers: [("content-length", "3")], body: Array("abc".utf8),
                                endStream: false)
        try h2.sendHeaders(stream: id, [("x-checksum", "1")])
        #expect(try h2.response(id).text == "3")
    }

    @Test func aBodyShortOfItsDeclaredLengthIsRefusedAtTheTrailers() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("POST", "/user", headers: [("content-length", "10")], body: Array("abc".utf8),
                                endStream: false)
        try h2.sendHeaders(stream: id, [("x-checksum", "1")])
        let response = try h2.response(id)
        #expect(response.reset == H2Error.protocolError.rawValue)
        #expect(response.status == nil)
        #expect(try h2.get("/user/after-reset").text == "after-reset")
    }

    @Test func aBodyLongerThanDeclaredIsRefused() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("POST", "/user", headers: [("content-length", "2")], body: Array("abc".utf8))
        #expect(try h2.response(id).reset == H2Error.protocolError.rawValue)
    }

    @Test func anEndedRequestWithADeclaredBodyIsRefused() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("POST", "/user", headers: [("content-length", "5")])
        #expect(try h2.response(id).reset == H2Error.protocolError.rawValue)
    }

    @Test func aBodyPastTheLimitIs413AndTheStreamReset() throws {
        let client = app().testClient(configuration: config { $0.maxBodySize = 1024 })
        let h2 = try client.http2()
        let id = try h2.request("POST", "/user", body: [UInt8](repeating: 0x78, count: 512), endStream: false)
        try h2.sendData(stream: id, [UInt8](repeating: 0x78, count: 512), endStream: false)
        try h2.sendData(stream: id, [UInt8](repeating: 0x78, count: 512), endStream: false)
        let response = try h2.response(id)
        #expect(response.status == .contentTooLarge)
        let reset = try #require(try h2.nextFrame { $0.kind == .rstStream && $0.stream == id })
        #expect(reset.payload == h2.uint32(H2Error.noError.rawValue))
        // A declared length past the limit is refused before the body.
        let declared = try h2.request("POST", "/user", headers: [("content-length", "4096")], endStream: false)
        #expect(try h2.response(declared).status == .contentTooLarge)
        // Under the limit, everything still works.
        #expect(try h2.post("/user", body: [UInt8](repeating: 0x79, count: 512)).text == "512")
    }

    // MARK: What the application sees

    @Test func observersSeeHTTP2() throws {
        let seen = Seen()
        let app = app()
        app.onResponse { completed in seen.requests.withLock { $0.append(completed) } }
        let h2 = try app.test.http2()
        _ = try h2.get("/user/5")
        let completed = try #require(seen.take().first)
        #expect(completed.protocolName == "HTTP/2")
        #expect(completed.route == "/user/:id")
        #expect(completed.path == "/user/5")
        #expect(completed.status == 200)
    }

    @Test func middlewareAndSendHooksRunOnStreams() throws {
        let app = app()
        app.use { request, response, next in
            response.addHeader("x-before", "1")
            try await next()
            response.onSend { outgoing in outgoing.addHeader("x-hook", "2") }
        }
        let h2 = try app.test.http2()
        let response = try h2.get("/user/1")
        #expect(response.header("x-before") == "1")
        #expect(response.header("x-hook") == "2")
    }

    @Test func requestIDsAreAssignedAndEchoed() throws {
        let client = app().testClient(configuration: config { $0.requestID = true })
        let response = try client.http2().get("/")
        #expect(response.header("x-request-id")?.isEmpty == false)
    }

    // MARK: Protocol errors

    private func expectGoaway(_ code: H2Error, _ send: (HTTP2TestConnection) throws -> Void,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let h2 = try app().test.http2()
        try send(h2)
        #expect(try h2.goaway()?.code == code.rawValue, sourceLocation: sourceLocation)
        #expect(h2.waitForClose(), sourceLocation: sourceLocation)
    }

    @Test func connectionErrorsEndWithGoaway() throws {
        try expectGoaway(.protocolError) { try $0.send(.data, stream: 0, payload: [1]) }
        try expectGoaway(.protocolError) { try $0.send(.headers, flags: .endHeaders, stream: 2, payload: []) }
        try expectGoaway(.protocolError) { try $0.send(.pushPromise, stream: 1, payload: [0, 0, 0, 2]) }
        try expectGoaway(.frameSizeError) { try $0.send(.settings, stream: 0, payload: [0, 4, 0]) }
        try expectGoaway(.protocolError) { try $0.send(.settings, stream: 1, payload: []) }
        try expectGoaway(.frameSizeError) { try $0.send(.ping, stream: 0, payload: [1, 2, 3]) }
        try expectGoaway(.protocolError) { try $0.send(.windowUpdate, stream: 0, payload: $0.uint32(0)) }
        try expectGoaway(.flowControlError) {
            try $0.send(.windowUpdate, stream: 0, payload: $0.uint32(0x7FFF_FFFF))
        }
        try expectGoaway(.frameSizeError) { try $0.send(.data, stream: 1, payload: [UInt8](repeating: 0, count: 20000)) }
        try expectGoaway(.protocolError) { h2 in
            try h2.send(.settings, stream: 0, payload: h2.settingsPayload([(.enablePush, 2)]))
        }
        try expectGoaway(.protocolError) { h2 in
            try h2.send(.settings, stream: 0, payload: h2.settingsPayload([(.maxFrameSize, 100)]))
        }
        try expectGoaway(.flowControlError) { h2 in
            try h2.send(.settings, stream: 0, payload: h2.settingsPayload([(.initialWindowSize, 0x8000_0000)]))
        }
        // A DATA frame on a stream never opened.
        try expectGoaway(.protocolError) { try $0.send(.data, stream: 9, payload: [1]) }
        // A header block interrupted by another frame.
        try expectGoaway(.protocolError) { h2 in
            let block = h2.headerBlock([(":method", "GET"), (":scheme", "http"), (":path", "/")])
            try h2.send(.headers, flags: .endStream, stream: 1, payload: block)
            try h2.send(.ping, stream: 0, payload: [UInt8](repeating: 0, count: 8))
        }
        // A stream identifier going backwards.
        try expectGoaway(.protocolError) { h2 in
            _ = try h2.get("/")
            let block = h2.headerBlock([(":method", "GET"), (":scheme", "http"), (":path", "/")])
            try h2.send(.headers, flags: [.endHeaders, .endStream], stream: 1, payload: block)
        }
        // A header block that is not HPACK.
        try expectGoaway(.compressionError) { h2 in
            try h2.send(.headers, flags: [.endHeaders, .endStream], stream: 1, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        }
        // A stream that depends on itself.
        try expectGoaway(.protocolError) { h2 in
            let block = h2.headerBlock([(":method", "GET"), (":scheme", "http"), (":path", "/")])
            try h2.send(.headers, flags: [.endHeaders, .endStream, .priority], stream: 1,
                        payload: h2.uint32(1) + [16] + block)
        }
    }

    @Test func aContinuationFloodIsCut() throws {
        try expectGoaway(.enhanceYourCalm) { h2 in
            let block = h2.headerBlock([(":method", "GET"), (":scheme", "http"), (":path", "/")])
            try h2.send(.headers, flags: .endStream, stream: 1, payload: block)
            for _ in 0..<5 { try h2.send(.continuation, stream: 1, payload: [UInt8](repeating: 0x40, count: 16000)) }
        }
    }

    @Test func malformedRequestsAreResetAndTheConnectionGoesOn() throws {
        let h2 = try app().test.http2()
        func reset(_ fields: [(String, String)]) throws -> UInt32? {
            let id = h2.nextStream
            h2.nextStream += 2
            try h2.sendHeaders(stream: id, fields)
            return try h2.response(id).reset
        }
        let base = [(":method", "GET"), (":scheme", "http"), (":authority", "test"), (":path", "/")]
        let malformed = H2Error.protocolError.rawValue
        #expect(try reset(base + [("Upper", "x")]) == malformed)
        #expect(try reset(base + [("connection", "keep-alive")]) == malformed)
        #expect(try reset(base + [("transfer-encoding", "chunked")]) == malformed)
        #expect(try reset(base + [("te", "gzip")]) == malformed)
        #expect(try reset(base + [("x-bad", " padded")]) == malformed)
        #expect(try reset([("x-first", "1")] + base) == malformed)
        #expect(try reset(base + [(":method", "GET")]) == malformed)
        #expect(try reset(base + [(":unknown", "1")]) == malformed)
        #expect(try reset(base + [(":protocol", "websocket")]) == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":authority", "test")]) == malformed)
        #expect(try reset([(":method", "GET"), (":authority", "test"), (":path", "/")]) == malformed)
        #expect(try reset([(":method", "CONNECT"), (":authority", "test:443")]) == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":authority", "test"), (":path", "")])
                == malformed)
        // "te: trailers" is the one connection-specific field allowed.
        #expect(try h2.get("/", headers: [("te", "trailers")]).status == .ok)
        #expect(try h2.get("/").status == .ok)
    }

    /// A stream's request is what HTTP/1.1 would have parsed: Host first,
    /// the fields in order, the cookie crumbs joined last; the target split
    /// into path and query.
    @Test func theRequestIsWhatHTTP1WouldHaveParsed() throws {
        let app = Application()
        app.get("/fields/:p") { request, response in
            var lines: [String] = []
            request.forEachHeader { name, value in lines.append("\(name.string)=\(value.string)") }
            let v = request.version
            response.send("\(request.method) \(request.path) [\(request.query)] \(request.parameter(0)) "
                + "\(v.major).\(v.minor) \(request.header("content-length") ?? "-") | "
                + lines.joined(separator: ","))
        }
        let h2 = try app.test.http2()
        let text = try h2.get("/fields/x%20y?a=1&b=%20", headers: [
            ("x-one", "1"), ("cookie", "a=1"), ("x-two", ""), ("cookie", "b=2"), ("accept", "*/*"),
            ("content-length", "0"), ("content-length", "0"), ("x-tab", "a\tb"),
        ]).text
        #expect(text == "get /fields/x%20y [a=1&b=%20] x%20y 2.0 0 | host=test,x-one=1,x-two=,accept=*/*,"
                + "content-length=0,content-length=0,x-tab=a\tb,cookie=a=1; b=2")
        // Host from a Host field when there is no :authority.
        let id = h2.nextStream
        h2.nextStream += 2
        try h2.sendHeaders(stream: id, [(":method", "GET"), (":scheme", "http"), (":path", "/fields/h"),
                                        ("x-before", "b"), ("host", "example.test"), ("x-after", "a")])
        #expect(try h2.response(id).text == "get /fields/h [] h 2.0 - | host=example.test,x-before=b,x-after=a")
    }

    /// What HTTP/1.1's parser would refuse is malformed on a stream too.
    @Test func whatHTTP1WouldRefuseIsMalformed() throws {
        let h2 = try app().test.http2()
        func reset(_ fields: [(String, String)]) throws -> UInt32? {
            let id = h2.nextStream
            h2.nextStream += 2
            try h2.sendHeaders(stream: id, fields)
            return try h2.response(id).reset
        }
        let base = [(":method", "GET"), (":scheme", "http"), (":authority", "test"), (":path", "/")]
        let malformed = H2Error.protocolError.rawValue
        #expect(try reset(base + [("x-control", "a\u{01}b")]) == malformed)
        #expect(try reset(base + [("x-del", "a\u{7F}b")]) == malformed)
        #expect(try reset(base + [("cookie", "a=\u{01}")]) == malformed)
        #expect(try reset([(":method", "G T"), (":scheme", "http"), (":authority", "test"), (":path", "/")])
                == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":authority", "test"), (":path", "/a b")])
                == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":authority", "te\u{7F}st"), (":path", "/")])
                == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":path", "/")]) == malformed)
        #expect(try reset([(":method", "GET"), (":scheme", "http"), (":authority", ""), (":path", "/")])
                == malformed)
        #expect(try reset(base + [("content-length", "1"), ("content-length", "2")]) == malformed)
        #expect(try reset(base + [("content-length", "x")]) == malformed)
        #expect(try reset(base + [("host", "test"), ("host", "test")]) == malformed)
        #expect(try h2.get("/user/fine").text == "fine")
    }

    @Test func dataAfterTheEndIsAStreamError() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("GET", "/delay/300")
        try h2.send(.data, stream: id, payload: [1])
        #expect(try h2.response(id).reset == H2Error.streamClosed.rawValue)
        #expect(try h2.get("/").status == .ok)
    }

    @Test func pingIsAnsweredAndUnknownFramesIgnored() throws {
        let h2 = try app().test.http2()
        try h2.send(type: 0xEE, stream: 0, payload: [1, 2, 3])
        try h2.send(.ping, stream: 0, payload: Array("pingpong".utf8))
        let pong = try #require(try h2.nextFrame { $0.kind == .ping })
        #expect(pong.has(.ack))
        #expect(pong.payload == Array("pingpong".utf8))
        // Priority is parsed and ignored.
        try h2.send(.priority, stream: 3, payload: h2.uint32(1) + [16])
        #expect(try h2.get("/").status == .ok)
    }

    @Test func settingsAreAcknowledged() throws {
        let h2 = try app().test.http2()
        _ = try h2.nextFrame { $0.kind == .settings && $0.has(.ack) }
        try h2.send(.settings, stream: 0, payload: h2.settingsPayload([(.maxFrameSize, 32768)]))
        #expect(try h2.nextFrame { $0.kind == .settings && $0.has(.ack) } != nil)
    }

    @Test func aPeerGoawayEndsTheConnectionOnceItsStreamsAreDone() throws {
        let h2 = try app().test.http2()
        let id = try h2.request("GET", "/delay/200")
        try h2.send(.goaway, stream: 0, payload: h2.uint32(0) + h2.uint32(0))
        // No new streams after it.
        #expect(try h2.response(try h2.request("GET", "/")).reset == H2Error.refusedStream.rawValue)
        #expect(try h2.response(id).status == .ok)
        #expect(h2.waitForClose())
    }

    @Test func shutdownSendsGoawayAndFinishesTheStreamsInProgress() throws {
        // A runtime of its own: shutdown is for every connection on it.
        let runtime = Runtime(workers: 2)
        let h2 = try app().test.http2(on: runtime)
        let slow = try h2.request("GET", "/delay/300")
        #expect(try h2.get("/").status == .ok)
        // What SIGTERM does to a shard's HTTP/2.
        HTTP2Service.forTesting(runtime).shutdown()
        let goaway = try #require(try h2.goaway())
        #expect(goaway.code == H2Error.noError.rawValue)
        #expect(goaway.lastStream == slow + 2)
        // Nothing new is taken; what was taken is finished.
        #expect(try h2.response(try h2.request("GET", "/")).reset == H2Error.refusedStream.rawValue)
        #expect(try h2.response(slow).status == .ok)
        #expect(h2.waitForClose())
        // A connection opened after shutdown began is told at once.
        let late = try app().test.http2(on: runtime)
        #expect(try late.goaway()?.code == H2Error.noError.rawValue)
    }

    // MARK: Opening

    @Test func aBadPrefaceIsRefused() throws {
        let h2 = try app().test.http2(handshake: false)
        try h2.send(raw: Array("PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n".utf8))
        #expect(try h2.goaway()?.code == H2Error.protocolError.rawValue)
        #expect(h2.waitForClose())
    }

    @Test func framesWithoutThePrefaceAreRefused() throws {
        let h2 = try app().test.http2(handshake: false)
        try h2.send(.settings, stream: 0)
        #expect(try h2.goaway()?.code == H2Error.protocolError.rawValue)
    }

    @Test func http1IsStillServedBesideIt() throws {
        let h2 = try app().test.http2(handshake: false)
        try h2.send(raw: Array("GET /user/old HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n".utf8))
        let text = String(decoding: try h2.readUntilClose(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.hasSuffix("\r\n\r\nold"))
    }

    @Test func http2OnlyRefusesHTTP1() throws {
        let client = app().testClient(configuration: config { $0.http2Only = true })
        let h1 = try client.http2(handshake: false)
        try h1.send(raw: Array("GET / HTTP/1.1\r\nHost: test\r\n\r\n".utf8))
        #expect(try h1.goaway()?.code == H2Error.protocolError.rawValue)
        #expect(try client.http2().get("/").status == .ok)
    }

    @Test func withHTTP2OffThePrefaceIsAnHTTP1Version() throws {
        let client = app().testClient(configuration: config { $0.http2Enabled = false })
        let h2 = try client.http2(handshake: false)
        try h2.send(raw: HTTP2.preface)
        let text = String(decoding: try h2.readUntilClose(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 505 "))
    }

    @Test func theCommandLineSwitchesHTTP2() {
        func parse(_ args: String...) -> ServerConfig? {
            if case .run(let config) = ServerConfig.parse(["garuda"] + args) { return config }
            return nil
        }
        #expect(parse()?.http2Enabled == true)
        #expect(parse("--no-http2")?.http2Enabled == false)
        #expect(parse("--http2-only")?.http2Only == true)
        #expect(Application.alpn(for: ServerConfig()) == ["h2", "http/1.1"])
        #expect(Application.alpn(for: parse("--no-http2")!) == ["http/1.1"])
    }
}

/// Waits on the test's thread, which is not one of the runtime's.
private func nap(milliseconds: Int) {
    let until = ContinuousClock.now + .milliseconds(milliseconds)
    while ContinuousClock.now < until {}
}

// MARK: - Over TLS

@Suite("HTTP/2 over TLS", .serialized)
struct HTTP2TLSTests {
    /// What a client that offers "h2" by ALPN gets back for GET /secure:
    /// the protocol chosen, the :status, and the body.
    func get(offering protocols: [String]) throws -> (alpn: String?, status: String?, body: [UInt8]) {
        let cert = try TestCertificate(["localhost"], tag: "h2-alpn")
        defer { cert.remove() }
        let store = try CertificateStore(files: [cert.files], protocols: Application.alpn, ticketKey: nil)
        let app = Application()
        app.get("/secure") { request, response in
            response.send(request.arrivedOverHTTPS && request.version.major == 2 ? "h2 https" : "other")
        }
        let compiled = app.compile()
        let limits = ConnectionLimits(ServerConfig())
        var configuration = TLSConfiguration.client(trustRoots: .system, applicationProtocols: protocols)
        configuration.verification = .none
        let client = try TLSContext(configuration)
        let rt = TLSTestRuntime.shared
        let service = HTTP2Service.forTesting(rt)
        return try rt.block { () async throws -> (String?, String?, [UInt8]) in
            let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
            let port = listener.localPort
            let server = try TCPServer.serve(listener) { stream in
                await serveTLSConnection(stream, store, handshakeTimeout: .seconds(5), app: compiled,
                                         limits: limits, http2: service)
            }
            defer { Task { await server.shutdown(gracePeriod: .seconds(1)) } }
            let tcp = try await TCPStream.connect(to: SocketAddress(host: "127.0.0.1", port: port))
            let tls = try await TLSStream.connect(tcp, serverName: "localhost", context: client)
            let alpn = tls.applicationProtocol
            guard alpn == "h2" else { return (alpn, nil, []) }
            // GET (2), https (7), :authority and :path as literals.
            let path = Array("/secure".utf8), authority = Array("localhost".utf8)
            let block: [UInt8] = [0x82, 0x87, 0x01, UInt8(authority.count)] + authority
                + [0x04, UInt8(path.count)] + path
            var bytes = HTTP2.preface + [0, 0, 0, 4, 0, 0, 0, 0, 0]
            bytes += [0, 0, UInt8(block.count), 1, 5, 0, 0, 0, 1] + block
            let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
            defer { raw.deallocate() }
            raw.copyBytes(from: bytes)
            try await tls.write(UnsafeRawBufferPointer(raw))
            var buffer = IOBuffer(capacity: 64 * 1024)
            var status: String? = nil
            var body: [UInt8] = []
            var decoder = HPACKDecoder()
            defer { decoder.destroy() }
            reading: while try await tls.read(into: &buffer) > 0 {
                var all = buffer.withUnsafeBytes { Array($0) }
                while all.count >= 9 {
                    let n = Int(all[0]) << 16 | Int(all[1]) << 8 | Int(all[2])
                    guard all.count >= 9 + n else { break }
                    let type = all[3], flags = all[4], stream = all[8]
                    let payload = Array(all[9..<(9 + n)])
                    all.removeFirst(9 + n)
                    buffer.consume(9 + n)
                    if stream != 1 { continue }
                    if type == 1 {
                        try payload.withUnsafeBufferPointer { p in
                            try decoder.decode(p.baseAddress!, p.count) { span in
                                if equalsExact(span.name, span.nameLength, ":status") {
                                    status = String(decoding: UnsafeBufferPointer(start: span.value,
                                                                                  count: span.valueLength),
                                                    as: UTF8.self)
                                }
                            }
                        }
                    }
                    if type == 0 { body += payload }
                    if flags & 1 != 0 { break reading }
                }
            }
            return (alpn, status, body)
        }
    }

    @Test func alpnChoosesHTTP2() throws {
        let answer = try get(offering: ["h2", "http/1.1"])
        #expect(answer.alpn == "h2")
        #expect(answer.status == "200")
        #expect(answer.body == Array("h2 https".utf8))
    }

    @Test func aClientOfferingOnlyHTTP1GetsIt() throws {
        #expect(try get(offering: ["http/1.1"]).alpn == "http/1.1")
    }
}

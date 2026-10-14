import Testing
import Synchronization
import GarudaTesting
@testable import Garuda

@Suite("Interim responses")
struct InterimTests {

    @Test func interimResponsesComeBeforeTheFinalOne() throws {
        let outcomes = Mutex<[String]>([])
        let app = Application()
        app.post("/hints") { _, response in
            let upload = await response.sendInterim(status: HTTPStatus(104),
                                                    headers: [("Location", "/uploads/1"),
                                                              ("Upload-Limit", "max-size=10")])
            let hints = await response.sendInterim(status: HTTPStatus(103),
                                                   headers: [("Link", "</a.css>; rel=preload")])
            let final = await response.sendInterim(status: HTTPStatus(200))
            let switching = await response.sendInterim(status: HTTPStatus(101))
            let badName = await response.sendInterim(status: HTTPStatus(104), headers: [("bad name", "x")])
            response.send(status: .created)
            let late = await response.sendInterim(status: HTTPStatus(104))
            outcomes.withLock { $0 = [upload, hints, final, switching, badName, late].map { $0 ? "sent" : "refused" } }
        }
        let response = try app.test.post("/hints")
        #expect(response.status == .created)
        #expect(outcomes.withLock { $0 } == ["sent", "sent", "refused", "refused", "refused", "refused"])
        #expect(response.interim.map { $0.status.code } == [104, 103])
        #expect(response.interim.first?.headers.first { $0.name.lowercased() == "location" }?.value == "/uploads/1")
    }

    @Test func noInterimResponseOnceTheAnswerHasStarted() throws {
        let outcomes = Mutex<[String]>([])
        let app = Application()
        app.get("/started") { _, response in
            let body = response.stream(contentType: "text/plain")
            let sent = await response.sendInterim(status: HTTPStatus(103))
            outcomes.withLock { $0.append("\(sent)") }
            try await body.write("done")
        }
        let answer = try app.test.get("/started")
        #expect(answer.text == "done")
        #expect(answer.interim.isEmpty)
        #expect(outcomes.withLock { $0 } == ["false"])
    }

    @Test func anHTTP10ClientGetsNoInterimResponse() throws {
        let app = Application()
        app.get("/hints") { _, response in
            let sent = await response.sendInterim(status: HTTPStatus(103))
            response.send(sent ? "sent" : "withheld")
        }
        let response = try app.test.send(raw: Array("GET /hints HTTP/1.0\r\nHost: x\r\n\r\n".utf8))
        #expect(response.text == "withheld")
        #expect(response.interim.isEmpty)
    }

    @Test func overHTTP2AnInterimHeadIsAHeadersFrameOfItsOwn() throws {
        let app = Application()
        app.get("/hints") { _, response in
            await response.sendInterim(status: HTTPStatus(103), headers: [("link", "</a.css>; rel=preload")])
            response.send("page")
        }
        let response = try app.test.http2().get("/hints")
        #expect(response.status == .ok)
        #expect(response.text == "page")
        #expect(response.interim.map { $0.status.code } == [103])
        #expect(response.interim.first?.headers.first { $0.name == "link" }?.value == "</a.css>; rel=preload")
    }
}

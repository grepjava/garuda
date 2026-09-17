import Testing
import CAvian
import AvianCore
@testable import Garuda

/// Where `/park` waits, so a test can wake it after its deadline has passed.
nonisolated(unsafe) private var parkedPastDeadline: UnsafeContinuation<Void, Never>? = nil
/// What `/park` saw about its own request when it woke.
nonisolated(unsafe) private var sawCancelled: Bool? = nil
/// Whether `/park` ran on past its dropped `send`, rather than trapping.
nonisolated(unsafe) private var ranPastLateSend = false

private func deadlineApp() -> Application {
    let app = Application()
    app.deadline(milliseconds: 20) {
        // Waits far longer than it is allowed.
        app.onAsync(.get, "/slow") { _, response in
            try await response.sleep(milliseconds: 5_000)
            response.send("slept")
        }
        // Answers at once, well inside.
        app.onAsync(.get, "/quick") { _, response in
            response.send("quick")
        }
        // A synchronous handler waiting on a timer of its own.
        app.get("/slow-sync") { _, response in
            response.after(milliseconds: 5_000) { _, later in
                later.send("late")
            }
        }
        // Parks where the engine cannot reach it, so the deadline fires while
        // it is still suspended and it wakes after being answered for.
        app.onAsync(.get, "/park") { _, response in
            await withUnsafeContinuation { parkedPastDeadline = $0 }
            sawCancelled = response.isCancelled
            response.send("far too late")
            ranPastLateSend = true
        }
        app.deadline(milliseconds: 5_000) {
            // Waits past the outer deadline but well inside the inner one.
            app.onAsync(.get, "/inner") { _, response in
                try await response.sleep(milliseconds: 40)
                response.send("inner")
            }
        }
    }
    // Outside every deadline block.
    app.onAsync(.get, "/unbounded") { _, response in
        try await response.sleep(milliseconds: 40)
        response.send("unbounded")
    }
    return app
}

/// One keep-alive connection, driven directly. `TestClient.get` opens and
/// closes a connection per request, and closing frees everything the request
/// held -- which hides whether the engine gives it back at the request
/// boundary, and hides whether a handler that wakes late can still reach a
/// request the slot is still holding. Both need the connection kept open.
private final class Wire {
    let client: TestClient
    let fd: Int32
    let slot: Int
    private let capacity = 16384
    private let buffer: UnsafeMutablePointer<UInt8>
    private var got = 0
    private var closed = false

    init(_ client: TestClient) throws {
        self.client = client
        let opened = try client.connect()
        fd = opened.client
        slot = opened.slot
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = av_close(fd)
    }

    func send(_ request: String) {
        var request = request
        request.withUTF8 { _ = av_write(fd, $0.baseAddress!, $0.count) }
    }

    /// Bytes waiting now, without turning the worker.
    @discardableResult
    func pending() -> Int {
        while got < capacity {
            let n = av_read(fd, buffer + got, capacity - got)
            if n <= 0 { break }
            got += n
        }
        return got
    }

    /// Turns until one whole response has arrived, then takes it out of the
    /// buffer and returns its status.
    func receiveStatus(turns: Int = 5_000) -> Int? {
        for _ in 0..<turns {
            client.turn()
            pending()
            guard let total = completeLength(), total == got else { continue }
            let code = status()
            got = 0
            return code
        }
        return nil
    }

    private func status() -> Int? {
        guard got > 12 else { return nil }
        var i = 9
        var code = 0
        while i < got, buffer[i] >= 48, buffer[i] <= 57 {
            code = code * 10 + Int(buffer[i] - 48)
            i += 1
        }
        return code > 0 ? code : nil
    }

    /// The length of the response at the start of the buffer once all of it
    /// is there. Every response here states a Content-Length.
    private func completeLength() -> Int? {
        var end = 0
        while end + 3 < got {
            if buffer[end] == 13 && buffer[end + 1] == 10
                && buffer[end + 2] == 13 && buffer[end + 3] == 10 { break }
            end += 1
        }
        guard end + 3 < got else { return nil }
        let name: StaticString = "\r\ncontent-length: "
        var i = 0
        while i < end {
            var matched = 0
            while matched < name.utf8CodeUnitCount && i + matched < end
                    && (buffer[i + matched] | (matched >= 2 ? 0x20 : 0)) == name.utf8Start[matched] {
                matched += 1
            }
            if matched == name.utf8CodeUnitCount {
                var length = 0
                var d = i + matched
                while d < end && buffer[d] >= 48 && buffer[d] <= 57 {
                    length = length * 10 + Int(buffer[d] - 48)
                    d += 1
                }
                let total = end + 4 + length
                return total <= got ? total : nil
            }
            i += 1
        }
        return nil
    }
}

/// Serialized for the same reason as the other handler suites: each client
/// turns a worker on the test's own thread.
@Suite("Route deadlines", .serialized)
struct DeadlineTests {
    @Test func aHandlerThatPassesItsDeadlineIs504() throws {
        let client = deadlineApp().test
        #expect(try client.get("/slow").status == 504)
    }

    @Test func aHandlerInsideItsDeadlineIsUntouched() throws {
        let client = deadlineApp().test
        #expect(try client.get("/quick").text == "quick")
    }

    /// A deadline bounds waiting whoever is doing it: a synchronous handler
    /// parked on `after` is cut short the same way a task is.
    @Test func aSynchronousWaitIsBoundedToo() throws {
        let client = deadlineApp().test
        #expect(try client.get("/slow-sync").status == 504)
    }

    @Test func aRouteWithNoDeadlineIsNotBounded() throws {
        let client = deadlineApp().test
        #expect(try client.get("/unbounded").text == "unbounded")
    }

    @Test func theInnermostDeadlineApplies() throws {
        let client = deadlineApp().test
        #expect(try client.get("/inner").text == "inner")
    }

    /// The deadline is the request's, not the connection's. `.timedOut` says
    /// the handler no longer speaks for the request, so it has to be cleared
    /// when the same connection carries the next one -- otherwise that
    /// request's own answer would be dropped and the client would hang.
    @Test func aTimeoutDoesNotCarryToTheNextRequestOnTheSameConnection() throws {
        let client = deadlineApp().test
        let wire = try Wire(client)
        wire.send("GET /slow HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(wire.receiveStatus() == 504)
        wire.send("GET /quick HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(wire.receiveStatus() == 200)
    }

    /// Nothing preempts a handler that is not waiting on the engine, so a
    /// deadline answers the client and leaves the handler running. When it
    /// wakes, the slot is still holding that very request on a connection
    /// that is still open -- so identity alone cannot tell it to stop, and
    /// only `.timedOut` can. Its answer must go nowhere, and quietly:
    /// answering late here is the deadline's doing, not a mistake of its own.
    @Test func aTimedOutHandlerCannotAnswerWhenItWakes() throws {
        parkedPastDeadline = nil
        sawCancelled = nil
        ranPastLateSend = false
        let client = deadlineApp().test
        let wire = try Wire(client)
        wire.send("GET /park HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(wire.receiveStatus() == 504)
        #expect(parkedPastDeadline != nil)

        client.onWorker { parkedPastDeadline.take()?.resume() }
        client.turn()
        #expect(sawCancelled == true)
        #expect(ranPastLateSend)
        // Nothing more went out on the wire.
        #expect(wire.pending() == 0)
    }

    /// A deadline is one op per request, and the request boundary is what
    /// gives it back. Closing the connection frees it too, so this has to
    /// hold the connection open to see the boundary do its job.
    @Test func aDeadlineOpIsGivenBackAtEachRequestBoundary() throws {
        let client = deadlineApp().test
        let wire = try Wire(client)
        for _ in 0..<5 {
            wire.send("GET /quick HTTP/1.1\r\nHost: test\r\n\r\n")
            #expect(wire.receiveStatus() == 200)
            #expect(client.worker.pointee.asyncOps.liveCount == 0)
        }
    }
}

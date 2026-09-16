import Testing
import CGaruda
import GarudaCore
@testable import Garuda

// `Worker.waitTimed`: a wait that whoever holds its id ends early, and that
// ends on its own at a deadline otherwise. Exactly one of the two resumes it.

/// Ids of the waits `/wait` started, oldest first.
nonisolated(unsafe) private var waitIds: [Int32] = []
/// How the last wait `/wait` started ended.
nonisolated(unsafe) private var lastOutcome: TimedWaitOutcome? = nil

private func timedWaitApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/wait/:ms") { request, response in
        let ms = UInt64(request.withParameter(0) { $0.string }) ?? 0
        let outcome = await Worker.waitTimed(request.worker, milliseconds: ms) { waitIds.append($0) }
        lastOutcome = outcome
        response.send("\(outcome)")
    }
    app.get("/wake") { request, response in
        let woke = request.worker.pointee.wakeTimed(waitIds.removeFirst())
        response.send(woke ? "woke" : "nothing")
    }
    return app
}

@Suite("Timed waits", .serialized)
struct TimedWaitTests {

    @Test func aWaitNobodyEndsTimesOut() throws {
        waitIds = []
        let client = timedWaitApp().test
        #expect(try client.get("/wait/5").text == "timedOut")
        #expect(client.worker.pointee.timedWaits.isEmpty)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    @Test func aWokenWaitEndsAtOnceAndFreesItsTimer() throws {
        waitIds = []
        let client = timedWaitApp().test
        let waiter = try TestWire(client)
        waiter.send("GET /wait/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.turn(until: { !waitIds.isEmpty }))
        #expect(client.worker.pointee.asyncOps.liveCount == 1)

        let waker = try TestWire(client)
        waker.send("GET /wake HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waker.receive()?.hasSuffix("woke") == true)
        #expect(waiter.receive()?.hasSuffix("woken") == true)
        // A timer left on the heap would fire a minute from now into a wait
        // that no longer exists, and hold an op until then.
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
        #expect(client.worker.pointee.timedWaits.isEmpty)
    }

    @Test func wakingAWaitThatTimedOutWakesNothing() throws {
        // What a queue relies on to skip the waits that gave up: resuming one
        // a second time would crash.
        waitIds = []
        let client = timedWaitApp().test
        #expect(try client.get("/wait/5").text == "timedOut")
        #expect(waitIds.count == 1)
        #expect(try client.get("/wake").text == "nothing")
    }

    @Test func aWorkerShuttingDownEndsEveryWait() throws {
        waitIds = []
        let client = timedWaitApp().test
        let waiter = try TestWire(client)
        waiter.send("GET /wait/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.turn(until: { !waitIds.isEmpty }))
        client.onWorker { client.worker.pointee.cancelTimedWaits() }
        #expect(waiter.receive()?.hasSuffix("cancelled") == true)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    @Test func aWorkerThatIsDestroyedEndsItsWaitsFirst() throws {
        // Otherwise the task in the wait is never resumed: the worker cannot
        // end it, and it holds whatever it holds for the life of the process.
        waitIds = []
        lastOutcome = nil
        do {
            let client = timedWaitApp().test
            let waiter = try TestWire(client)
            waiter.send("GET /wait/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
            #expect(waiter.turn(until: { !waitIds.isEmpty }))
        }
        #expect(lastOutcome == .cancelled)
    }
}

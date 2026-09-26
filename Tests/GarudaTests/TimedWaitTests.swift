import Testing
import CAvian
import AvianCore
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
    app.onAsync(.get, "/owned/:ms") { request, response in
        let ms = UInt64(request.withParameter(0) { $0.string }) ?? 0
        let outcome = await Worker.waitTimed(request.worker, milliseconds: ms, forRequest: true) {
            waitIds.append($0)
        }
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

    @Test func aWaitBegunWithNoRoomForATimerGetsOneWhenThereIs() throws {
        // It used to wait with no timer at all, for good: a retry's pause or
        // a scheduled job's sleep has nobody to wake it.
        waitIds = []
        let client = timedWaitApp().test
        var taken: [Int] = []
        while let op = client.worker.pointee.asyncOps.allocate(slot: 0, requestId: 0, kind: .timer,
                                                               deadlineUs: 0) {
            taken.append(op.index)
        }
        let waiter = try TestWire(client)
        waiter.send("GET /wait/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.turn(until: { !waitIds.isEmpty }))
        let id = waitIds[0]
        #expect(client.worker.pointee.timedWaits[id]?.op == -1)
        #expect(client.worker.pointee.unarmedTimedWaits == 1)
        for op in taken { client.worker.pointee.asyncOps.free(op) }
        client.turn()
        #expect(client.worker.pointee.timedWaits[id]?.op ?? -1 >= 0)
        #expect(client.worker.pointee.unarmedTimedWaits == 0)
        #expect(client.worker.pointee.asyncOps.liveCount == 1)
        client.onWorker { client.worker.pointee.cancelTimedWaits() }
        #expect(waiter.receive()?.hasSuffix("cancelled") == true)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    @Test func aWaitThatNeverGetsATimerStillEndsOnTime() throws {
        waitIds = []
        let client = timedWaitApp().test
        var taken: [Int] = []
        while let op = client.worker.pointee.asyncOps.allocate(slot: 0, requestId: 0, kind: .timer,
                                                               deadlineUs: 0) {
            taken.append(op.index)
        }
        defer { for op in taken { client.worker.pointee.asyncOps.free(op) } }
        let waiter = try TestWire(client)
        waiter.send("GET /wait/5 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.receive()?.hasSuffix("timedOut") == true)
        #expect(client.worker.pointee.timedWaits.isEmpty)
        #expect(client.worker.pointee.unarmedTimedWaits == 0)
    }

    @Test func aWaitForARequestEndsWithIt() throws {
        // A pool acquisition: the client that hung up is owed nothing, so the
        // handler is not kept waiting for a connection it would use for nobody.
        waitIds = []
        lastOutcome = nil
        let client = timedWaitApp().test
        let waiter = try TestWire(client)
        waiter.send("GET /owned/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.turn(until: { !waitIds.isEmpty }))
        #expect(client.worker.pointee.table[waiter.slot].pointee.ownedTimedWaits == 1)
        client.onWorker { client.worker.pointee.closeConnection(waiter.slot) }
        #expect(waiter.turn(until: { lastOutcome != nil }))
        #expect(lastOutcome == .cancelled)
        #expect(client.worker.pointee.timedWaits.isEmpty)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
        // Waking it now wakes nothing, so a queue hands on past it.
        #expect(client.onWorker { client.worker.pointee.wakeTimed(waitIds[0]) } == false)
    }

    @Test func aWaitTheWorkerOwnsOutlivesTheRequestThatBeganIt() throws {
        // A scheduled job's sleep, a retry's pause: not the request's to end.
        waitIds = []
        let client = timedWaitApp().test
        let waiter = try TestWire(client)
        waiter.send("GET /wait/60000 HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(waiter.turn(until: { !waitIds.isEmpty }))
        client.onWorker { client.worker.pointee.closeConnection(waiter.slot) }
        for _ in 0..<5 { client.turn() }
        #expect(client.worker.pointee.timedWaits.count == 1)
        client.onWorker { client.worker.pointee.cancelTimedWaits() }
        client.turn()
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

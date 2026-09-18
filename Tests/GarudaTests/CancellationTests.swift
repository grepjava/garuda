import Testing
import CAvian
import AvianCore
@testable import Garuda

// `cancellable`: giving up on a wait the engine does not own.
//
// The waits staged here are the ones a library brings with it -- a
// continuation nothing in the engine knows about -- so a client hanging up
// says nothing to them. What the tests hold is that the handler stops waiting
// anyway, that the body is told, and that a body which pays no attention is
// counted rather than forgotten.

nonisolated(unsafe) private var cancelEvents: [String] = []

/// A wait with no engine behind it: somebody has to call `finish` or it never
/// ends, which is the whole point.
///
/// `finish` has to happen on the worker's thread, as every resumption in
/// Garuda does, so the tests below end these waits from inside a route rather
/// than from the test body -- which is also what a real library has to do,
/// and what `blocking` is for when it cannot.
private final class OutsideWait: @unchecked Sendable {
    private var wake: UnsafeContinuation<Void, Never>? = nil
    private var done = false
    /// Set when the task running the wait saw Swift cancellation.
    var wasCancelled = false

    func wait() async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            if done { continuation.resume() } else { wake = continuation }
        }
    }

    func finish() {
        done = true
        wake.take()?.resume()
    }
}

@Suite("Giving up on a wait the engine does not own", .serialized)
struct CancellationTests {

    /// Nothing wrong: the body answers and the handler carries on.
    @Test func aBodyThatFinishesFirstIsTheAnswer() throws {
        let app = Application()
        app.onAsync(.get, "/quick") { _, response in
            let value = try await response.cancellable { 42 }
            try response.send("\(value)")
        }
        let response = try app.test.get("/quick")
        #expect(response.status == 200)
        #expect(response.text == "42")
    }

    /// What it throws is what the engine's own waits throw, so a handler
    /// catching `HandlerWaitError` catches both the same way.
    @Test func aBodyThatThrowsThrowsWhatItThrew() throws {
        struct Upstream: Error, Equatable { let code: Int }
        cancelEvents = []
        let app = Application()
        app.onAsync(.get, "/bad") { _, response in
            do {
                _ = try await response.cancellable { () async throws -> Int in throw Upstream(code: 7) }
            } catch let error as Upstream {
                cancelEvents.append("threw \(error.code)")
            }
            try response.send("caught")
        }
        #expect(try app.test.get("/bad").text == "caught")
        #expect(cancelEvents == ["threw 7"])
    }

    /// The client goes away while the handler is in a wait nothing in the
    /// engine knows about. The handler must stop waiting, and the body must be
    /// told in the ordinary Swift way.
    @Test func aClientThatLeavesEndsTheWaitAndCancelsTheBody() throws {
        cancelEvents = []
        let outside = OutsideWait()
        let app = Application()
        app.onAsync(.get, "/forever") { _, response in
            do {
                try await response.cancellable {
                    await withTaskCancellationHandler {
                        await outside.wait()
                    } onCancel: {
                        outside.wasCancelled = true
                    }
                }
                cancelEvents.append("returned")
            } catch let error as HandlerWaitError {
                cancelEvents.append("\(error)")
            }
        }
        let client = app.test
        try client.abandon(Array("GET /forever HTTP/1.1\r\nHost: x\r\n\r\n".utf8), turns: 20)
        for _ in 0..<40 where cancelEvents.isEmpty { client.turn() }
        #expect(cancelEvents == ["cancelled"], "\(cancelEvents)")
        #expect(outside.wasCancelled, "the body is told, in the way Swift tells anything else")
    }

    /// A deadline is the other way a request ends without the client saying
    /// anything, and it does not go through the same path as a disconnect.
    @Test func aDeadlineEndsTheWaitToo() throws {
        cancelEvents = []
        let outside = OutsideWait()
        let app = Application()
        app.deadline(milliseconds: 40) {
            app.onAsync(.get, "/slow") { _, response in
                do {
                    try await response.cancellable { await outside.wait() }
                    cancelEvents.append("returned")
                } catch let error as HandlerWaitError {
                    cancelEvents.append("\(error)")
                }
            }
        }
        app.get("/finish") { () -> String in
            outside.finish()
            return "ok"
        }
        let client = app.test
        client.timeoutMillis = 5_000
        let response = try client.get("/slow")
        #expect(response.status == 504)
        for _ in 0..<40 where cancelEvents.isEmpty { client.turn() }
        #expect(cancelEvents == ["cancelled"], "\(cancelEvents)")
        _ = try client.get("/finish")
    }

    /// A body that pays no attention to cancellation is not lost: the worker
    /// counts it while it runs and counts it back when it ends.
    @Test func workThatOutlivesItsRequestIsCounted() throws {
        cancelEvents = []
        let outside = OutsideWait()
        let app = Application()
        app.onAsync(.get, "/stubborn") { _, response in
            // No cancellation handler: this one only ends when told.
            try? await response.cancellable { await outside.wait() }
            cancelEvents.append("gave up")
        }
        app.get("/finish") { () -> String in
            outside.finish()
            return "ok"
        }
        let client = app.test
        try client.abandon(Array("GET /stubborn HTTP/1.1\r\nHost: x\r\n\r\n".utf8), turns: 20)
        for _ in 0..<40 where cancelEvents.isEmpty { client.turn() }
        #expect(cancelEvents == ["gave up"])
        #expect(client.worker.pointee.abandonedWaits == 1,
                "still running, and the worker knows it is carrying it")
        // It finishes in its own time, and the worker stops counting it.
        _ = try client.get("/finish")
        for _ in 0..<20 where client.worker.pointee.abandonedWaits > 0 { client.turn() }
        #expect(client.worker.pointee.abandonedWaits == 0)
    }

    /// Past the limit the worker takes itself out of rotation rather than
    /// looking healthy while it queues.
    @Test func aWorkerCarryingTooMuchSaysSoOnTheHealthCheck() throws {
        var config = ServerConfig()
        config.maxAbandonedWaits = 1
        config.healthPath = UnsafePointer(strdup("/healthz")!)
        let waits = [OutsideWait(), OutsideWait()]
        let app = Application()
        app.onAsync(.get, "/hold/:n") { request, response in
            let n = Int(request.parameter(0)) ?? 0
            try? await response.cancellable { await waits[n].wait() }
        }
        app.get("/finish") { () -> String in
            for wait in waits { wait.finish() }
            return "ok"
        }
        let client = app.testClient(configuration: config)
        #expect(try client.get("/healthz").status == 200)
        for n in 0..<2 {
            try client.abandon(Array("GET /hold/\(n) HTTP/1.1\r\nHost: x\r\n\r\n".utf8), turns: 20)
        }
        for _ in 0..<40 where client.worker.pointee.abandonedWaits < 2 { client.turn() }
        #expect(client.worker.pointee.abandonedWaits == 2)
        #expect(try client.get("/healthz").status == 503, "two carried, one allowed")
        _ = try client.get("/finish")
        for _ in 0..<20 where client.worker.pointee.abandonedWaits > 0 { client.turn() }
        #expect(try client.get("/healthz").status == 200, "and back once it has caught up")
    }

    /// A typed handler takes the same thing as an extractor, since it has no
    /// response to ask.
    @Test func aTypedHandlerAsksForItAsAnExtractor() throws {
        let app = Application()
        app.get("/typed") { (upstream: Cancellation) async throws -> String in
            "\(try await upstream.running { 7 })|\(upstream.isActive)"
        }
        #expect(try app.test.get("/typed").text == "7|true")
    }
}

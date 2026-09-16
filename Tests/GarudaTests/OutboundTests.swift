import Testing
import CGaruda
import GarudaCore
@testable import Garuda

/// What the handler under test saw, read back by the test.
nonisolated(unsafe) private var outcome = ""

/// A unix socket rather than a TCP port: the shim offers no way to read back
/// the port a listener was given, so a test that wanted one would have to pick
/// a number and hope. A path has no such problem.
private let socketPath = "/tmp/garuda-outbound-test.sock"
/// A second place, so a test can prove the pool keys on the destination
/// rather than handing any idle connection to any caller.
private let otherSocketPath = "/tmp/garuda-outbound-other.sock"

private func outboundApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/connect-unix") { request, response in
        // Read before the first await: the request is a view of a slot, and
        // the worker pointer is what outlives the wait.
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 1_000)
            outcome = socket.isOpen ? "open" : "closed"
            socket.close()
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/connect-refused") { request, response in
        let worker = request.worker
        do {
            _ = try await Worker.connect(worker, host: "127.0.0.1", port: 1, milliseconds: 1_000)
            outcome = "unexpectedly open"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/connect-name") { request, response in
        let worker = request.worker
        do {
            _ = try await Worker.connect(worker, host: "localhost", port: 80, milliseconds: 1_000)
            outcome = "unexpectedly open"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // Connects and hands the connection back rather than closing it.
    app.onAsync(.get, "/pool") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 1_000)
            socket.release()
            outcome = "released"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // The same, to a different place, so the two must not share.
    app.onAsync(.get, "/pool-other") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: otherSocketPath,
                                                  milliseconds: 1_000)
            socket.release()
            outcome = "released"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/read-echo") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 1_000)
            // Parks until the peer writes, which is the only path in these
            // tests that goes round the poller: a unix connect and a refused
            // loopback connect both finish inside connect(2).
            try await socket.readable(milliseconds: 2_000)
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = try buffer.withUnsafeMutableBytes { try socket.read(into: $0) }
            outcome = "read \(String(decoding: buffer.prefix(n), as: UTF8.self))"
            socket.close()
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/read-timeout") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 1_000)
            do {
                // Nothing ever writes to this socket. The wait has to end on
                // its own; hanging here would hang the worker.
                try await socket.readable(milliseconds: 10)
                outcome = "unexpectedly readable"
            } catch {
                outcome = "\(error)"
            }
            socket.close()
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    return app
}

/// Serialized like the other handler suites: each client turns a worker on the
/// test's own thread.
@Suite("Outbound connections", .serialized)
struct OutboundTests {
    /// A listening socket that never accepts. connect(2) completes into the
    /// backlog, which is all these tests need a peer for.
    private func listen() -> Int32 {
        socketPath.withCString { pg_listen_unix($0, 16, 1) }
    }

    private func unlink() {
        _ = socketPath.withCString { pg_unlink($0) }
    }

    @Test func aUnixConnectOpensAndIsGivenBack() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        outcome = ""
        let client = outboundApp().test
        #expect(try client.get("/connect-unix").text == "open")
        // Closed by the handler, so the record is back on the free list.
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// Nothing is listening on port 1. A non-blocking connect reports this by
    /// becoming writable with SO_ERROR set, which is the path that would
    /// silently report success if the error were never read.
    @Test func aRefusedConnectFails() throws {
        outcome = ""
        let client = outboundApp().test
        let text = try client.get("/connect-refused").text
        #expect(text.hasPrefix("failed"))
        #expect(text != "unexpectedly open")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// Names are refused rather than resolved: getaddrinfo blocks, and
    /// blocking the worker is what this layer exists to avoid.
    @Test func aNameIsNotAnAddress() throws {
        outcome = ""
        let client = outboundApp().test
        #expect(try client.get("/connect-name").text == "address")
        // A name is refused before a record is taken, so the table is never
        // even made: nil here means nothing was allocated, not nothing found.
        #expect(client.worker.pointee.outbound?.liveCount ?? 0 == 0)
    }

    /// The timeout runs through the worker's own timer heap, so this also
    /// covers an outbound op reaching `completeTimerOp` without being mistaken
    /// for a connection's continuation.
    @Test func aWaitThatNeverReadiesTimesOut() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        outcome = ""
        let client = outboundApp().test
        #expect(try client.get("/read-timeout").text == "timedOut")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
        // The timer op was given back too, not leaked or double-freed.
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    /// The one test that goes round the poller. A unix connect and a refused
    /// loopback connect both finish inside connect(2), and a timeout never
    /// fires a readiness event, so without this nothing here would reach
    /// `handleOutboundEvent` at all and the poller wiring would be untested.
    @Test func aPeerThatWritesWakesTheWaitingHandler() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        outcome = ""
        let client = outboundApp().test
        let wire = try TestWire(client)
        wire.send("GET /read-echo HTTP/1.1\r\nHost: test\r\n\r\n")

        // Turn until the handler has connected and parked on readability.
        let parked = wire.turn(until: { client.worker.pointee.outbound?.liveCount == 1 })
        #expect(parked)

        // Now be the peer: accept the connection and write to it.
        var peer = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        let server = pg_accept(fd, &peer, 64, &port)
        #expect(server >= 0)
        defer { _ = pg_close(server) }
        let payload: StaticString = "hello"
        #expect(pg_write(server, payload.utf8Start, payload.utf8CodeUnitCount) == 5)

        #expect(wire.receive()?.hasSuffix("read hello") == true)
        #expect(client.worker.pointee.outbound?.liveCount == 0)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    /// The point of the pool: going back to the same place costs no socket.
    @Test func aReleasedConnectionIsUsedAgain() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        let client = outboundApp().test
        #expect(try client.get("/pool").text == "released")
        let afterFirst = client.worker.pointee.outboundOpened
        #expect(afterFirst == 1)
        #expect(client.worker.pointee.outbound?.liveCount == 1)

        for _ in 0..<5 { #expect(try client.get("/pool").text == "released") }
        // Five more requests, no more sockets: each was handed the same one.
        #expect(client.worker.pointee.outboundOpened == afterFirst)
        #expect(client.worker.pointee.outbound?.liveCount == 1)
    }

    /// Keyed by where it goes. An idle connection to one place must never be
    /// handed to a caller asking for another.
    @Test func thePoolDoesNotMixDestinations() throws {
        let first = listen()
        let second = otherSocketPath.withCString { pg_listen_unix($0, 16, 1) }
        #expect(first >= 0)
        #expect(second >= 0)
        defer {
            _ = pg_close(first); _ = pg_close(second)
            unlink(); _ = otherSocketPath.withCString { pg_unlink($0) }
        }
        let client = outboundApp().test
        #expect(try client.get("/pool").text == "released")
        #expect(try client.get("/pool-other").text == "released")
        // Two places, two sockets, and neither was reused for the other.
        #expect(client.worker.pointee.outboundOpened == 2)
        #expect(client.worker.pointee.outbound?.liveCount == 2)
        // Going back to each reuses its own.
        #expect(try client.get("/pool").text == "released")
        #expect(try client.get("/pool-other").text == "released")
        #expect(client.worker.pointee.outboundOpened == 2)
    }

    /// The oldest bug in connection pooling: the far end closed while the
    /// connection sat idle, and the next caller is handed a dead socket. It
    /// has to be noticed and dropped instead.
    @Test func aPeerThatWentAwayIsNotHandedOn() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        let client = outboundApp().test
        #expect(try client.get("/pool").text == "released")
        #expect(client.worker.pointee.outboundOpened == 1)

        // Be the far end, and go away.
        var peer = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        let server = pg_accept(fd, &peer, 64, &port)
        #expect(server >= 0)
        _ = pg_close(server)

        // The next caller must get a new connection, not the dead one.
        #expect(try client.get("/pool").text == "released")
        #expect(client.worker.pointee.outboundOpened == 2)
        #expect(client.worker.pointee.outbound?.liveCount == 1)
    }

    /// A connection nobody came back for does not sit there for ever.
    @Test func anIdleConnectionIsSweptAway() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        let client = outboundApp().test
        client.worker.pointee.outboundIdleMillis = 1
        #expect(try client.get("/pool").text == "released")
        #expect(client.worker.pointee.outbound?.liveCount == 1)

        // The sweep runs at most once a second, so let it come round.
        let started = pg_monotonic_ms()
        while pg_monotonic_ms() - started < 1_200 { client.turn() }
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// A worker that goes away with a connection still open closes it rather
    /// than leaking the descriptor.
    @Test func shutdownClosesWhatIsStillOpen() throws {
        let fd = listen()
        #expect(fd >= 0)
        defer { _ = pg_close(fd); unlink() }
        outcome = ""
        let client = outboundApp().test
        #expect(try client.get("/connect-unix").text == "open")
        // Destroying the worker is what the test client does when it goes.
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }
}

import Testing
import CAvian
import AvianCore
@testable import Garuda

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Sharing connections among workers (--balance): the decisions, the note a
// connection travels with, a connection carried on by another worker, and a
// worker that leaves a shared listener to the others while it is ahead.

private func load(_ busy: Int, _ conns: Int, _ channel: Int = 0, wait: Int = 0) -> WorkerLoad {
    WorkerLoad(busy: busy, conns: conns, channel: channel, wait: wait)
}

/// Sends `request` on `fd` and turns `client` until one whole response with a
/// Content-Length has come back.
private func exchange(_ fd: Int32, _ request: String, turning client: TestClient,
                      turns: Int = 2_000) -> String? {
    var request = request
    request.withUTF8 { _ = av_write(fd, $0.baseAddress!, $0.count) }
    var got: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    for _ in 0..<turns {
        client.turn()
        while true {
            let n = buffer.withUnsafeMutableBytes { av_read(fd, $0.baseAddress!, 4096) }
            if n <= 0 { break }
            got += buffer[0..<n]
        }
        if let text = complete(got) { return text }
    }
    return nil
}

private func complete(_ bytes: [UInt8]) -> String? {
    var end = -1
    var i = 0
    while i + 3 < bytes.count {
        if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            end = i
            break
        }
        i += 1
    }
    guard end >= 0 else { return nil }
    let head = String(decoding: bytes[0..<end], as: UTF8.self).lowercased()
    guard let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length: ") }),
          let length = Int(line.dropFirst(16)) else { return nil }
    guard bytes.count >= end + 4 + length else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

private func handoffPair() throws -> (receive: Int32, send: Int32) {
    var pair: (Int32, Int32) = (-1, -1)
    let made = withUnsafeMutableBytes(of: &pair) {
        av_handoff_pair($0.baseAddress!.assumingMemoryBound(to: Int32.self))
    }
    try #require(made == 0)
    return (pair.0, pair.1)
}

private func balancedApp() -> Application {
    let app = Application()
    app.get("/hello") { _, response in response.send("hello") }
    app.get("/scheme") { request, response in response.send("\(request.scheme)") }
    app.onAsync(.get, "/slow") { _, response in
        try await response.sleep(milliseconds: 200)
        response.send("slow")
    }
    // Holds the worker for a few milliseconds: a costly connection.
    app.get("/work") { _, response in
        let until = av_monotonic_us() + 3_000
        while av_monotonic_us() < until {}
        response.send("worked")
    }
    return app
}

private func movable(_ client: TestClient, _ slot: Int, at now: UInt64 = av_monotonic_ms()) -> Bool {
    client.worker.pointee.isMovable(slot, now: now)
}

private func live(_ client: TestClient) -> Int { client.worker.pointee.table.liveCount }

private func handOff(_ client: TestClient, _ count: Int, to chan: Int32) -> Int {
    client.onWorker { client.worker.pointee.handOff(count: count, to: chan, now: av_monotonic_ms()) }
}

@Suite("Balancing", .serialized)
struct BalancingTests {

    // MARK: - Decisions

    @Test func aWorkerIsAheadOnlyByAClearMargin() {
        // Even load: nobody is ahead.
        #expect(!BalancePolicy.isAhead(load(600, 8), [load(600, 8), load(580, 8)]))
        // Three more connections than the fewest is within the margin; four is not.
        #expect(!BalancePolicy.isAhead(load(600, 6), [load(600, 3)]))
        #expect(BalancePolicy.isAhead(load(600, 7), [load(600, 3)]))
        // The margin grows with the count: an eighth of the fewest.
        #expect(!BalancePolicy.isAhead(load(600, 112), [load(600, 100)]))
        #expect(BalancePolicy.isAhead(load(600, 113), [load(600, 100)]))
        // Busier than the idlest by more than the margin, and busy enough.
        #expect(BalancePolicy.isAhead(load(900, 4), [load(500, 4), load(600, 4)]))
        #expect(!BalancePolicy.isAhead(load(400, 4), [load(0, 4)]))
        // More connections, but the one with fewer is working much harder.
        #expect(!BalancePolicy.isAhead(load(100, 10), [load(900, 3)]))
        // ...which does not make the idle ones with fewer any less of a yardstick.
        #expect(BalancePolicy.isAhead(load(100, 41), [load(1000, 1), load(120, 3)]))
        #expect(!BalancePolicy.isAhead(load(100, 6), [load(1000, 1), load(120, 3)]))
        // Alone, a worker is never ahead.
        #expect(!BalancePolicy.isAhead(load(1000, 100), [WorkerLoad]()))
        // Busier outranks more connections: it is the one that leaves the listener.
        #expect(BalancePolicy.standing(load(900, 40), [load(100, 3)]) == .busier)
        #expect(BalancePolicy.standing(load(300, 40), [load(250, 3)]) == .moreConnections)
        #expect(BalancePolicy.standing(load(300, 4), [load(250, 3)]) == .even)
    }

    @Test func aRequestWaitsForTheRestOfTheTurnInProgress() {
        // Half busy with two-millisecond turns -- one slow request each -- a
        // request waits half a millisecond on average.
        #expect(BalancePolicy.expectedWait(busy: 500, meanTurn: 2_000,
                                           meanTurnSquared: 4_000_000) == 500)
        // Flat out with turns of 44 quick requests, 660 us each: half of one.
        #expect(BalancePolicy.expectedWait(busy: 1000, meanTurn: 660,
                                           meanTurnSquared: 660 * 660) == 330)
        // Uneven turns wait longer than even ones of the same mean length.
        #expect(BalancePolicy.expectedWait(busy: 1000, meanTurn: 660,
                                           meanTurnSquared: 2 * 660 * 660) == 660)
        // Idle, or no turn yet: no wait.
        #expect(BalancePolicy.expectedWait(busy: 0, meanTurn: 2_000,
                                           meanTurnSquared: 4_000_000) == 0)
        #expect(BalancePolicy.expectedWait(busy: 800, meanTurn: 0, meanTurnSquared: 0) == 0)
    }

    @Test func connectionsMoveToWhereTheyWouldWaitLess() throws {
        // Short waits here: nothing is worth a move.
        #expect(BalancePolicy.moveTarget(load(900, 13, wait: 90), [load(0, 3, 1)],
                                         capacity: 100) == nil)
        // Not at least halved: it stays.
        #expect(BalancePolicy.moveTarget(load(900, 13, wait: 1_000),
                                         [load(500, 3, 1, wait: 460)], capacity: 100) == nil)
        // Quick connections stuck behind slow requests go where the wait is
        // shortest -- not to the worker that is merely least busy, which is
        // half busy with slow requests of its own.
        let plan = try #require(BalancePolicy.moveTarget(
            load(950, 16, wait: 1_000),
            [load(500, 1, 1, wait: 1_000), load(900, 13, 2, wait: 150)], capacity: 100))
        #expect(plan.target.channel == 2 && plan.count == 4)
        // A worker flat out with 49 quick connections does not send them to one
        // with a slow request, however much less busy...
        #expect(BalancePolicy.moveTarget(load(990, 49, wait: 190),
                                         [load(500, 1, 1, wait: 1_000)], capacity: 100) == nil)
        // ...but does to a worker with fewer quick ones.
        let even = try #require(BalancePolicy.moveTarget(
            load(990, 49, wait: 500), [load(500, 1, 1, wait: 1_000), load(600, 13, 2, wait: 20)],
            capacity: 100))
        #expect(even.target.channel == 2 && even.count == BalancePolicy.maxMovesPerRound)
        // One connection is the costliest, which never goes.
        #expect(BalancePolicy.moveTarget(load(950, 1, wait: 1_000), [load(0, 0, 1)],
                                         capacity: 100) == nil)
        // Never more than the other has room for, and never to a worker
        // without a channel.
        let room = try #require(BalancePolicy.moveTarget(load(950, 60, wait: 1_000),
                                                         [load(100, 47, 1)], capacity: 50))
        #expect(room.count == 3)
        #expect(BalancePolicy.moveTarget(load(950, 60, wait: 1_000), [load(100, 50, 1)],
                                         capacity: 50) == nil)
        #expect(BalancePolicy.moveTarget(load(950, 13, wait: 1_000), [load(100, 3, -1)],
                                         capacity: 100) == nil)
    }

    @Test func theNoteRoundTripsAndRejectsWhatItDidNotWrite() {
        let note = HandoffNote(kernelTLS: true, port: 54_321, requestCount: 70_000,
                               address: Array("2001:db8::1".utf8))
        var bytes = [UInt8](repeating: 0, count: HandoffNote.size)
        let n = bytes.withUnsafeMutableBufferPointer { note.encode(into: $0.baseAddress!) }
        #expect(n == 9 + 11)
        #expect(bytes.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n) } == note)
        // Short, long, another version, a flag it never sets.
        #expect(bytes.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n - 1) } == nil)
        #expect(bytes.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n + 1) } == nil)
        bytes[0] = 9
        #expect(bytes.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n) } == nil)
        bytes[0] = HandoffNote.version
        bytes[1] = 2
        #expect(bytes.withUnsafeBufferPointer { HandoffNote.decode($0.baseAddress!, n) } == nil)
    }

    // MARK: - Moving a connection

    @Test func anIdleConnectionIsCarriedOnByAnotherWorker() throws {
        #expect(av_load_init(8) == 0)
        let a = balancedApp().test
        let b = balancedApp().test
        let toA = try handoffPair()
        let toB = try handoffPair()
        defer { for fd in [toA.receive, toA.send, toB.receive, toB.send] { _ = av_close(fd) } }
        a.onWorker {
            a.worker.pointee.startBalancing(loadSlot: 0, channel: 0, receiveFD: toA.receive,
                                            sendFDs: [toA.send, toB.send], sharedListener: false)
        }
        b.onWorker {
            b.worker.pointee.startBalancing(loadSlot: 1, channel: 1, receiveFD: toB.receive,
                                            sendFDs: [toA.send, toB.send], sharedListener: false)
        }
        defer {
            a.onWorker { a.worker.pointee.leaveBalancing() }
            b.onWorker { b.worker.pointee.leaveBalancing() }
        }

        let wire = try TestWire(a)
        let now = av_monotonic_ms()
        // Newly accepted, nothing served yet: the client may already have a
        // request on the wire, so it stays.
        #expect(!movable(a, wire.slot, at: now))
        let first = exchange(wire.fd, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n", turning: a)
        #expect(first?.hasSuffix("hello") == true)
        #expect(movable(a, wire.slot))
        // A second connection, whose requests hold the worker.
        let costly = try TestWire(a)
        #expect(exchange(costly.fd, "GET /work HTTP/1.1\r\nHost: x\r\n\r\n", turning: a)?
                    .hasSuffix("worked") == true)
        #expect(movable(a, costly.slot))

        // Asked for four, it sends the cheap one and keeps the costly one:
        // moving that would move the load rather than share it.
        let moved = handOff(a, 4, to: toB.send)
        #expect(moved == 1)
        #expect(live(a) == 1)
        #expect(a.worker.pointee.table[costly.slot].pointee.state != .free)

        // The same client, the same socket: the next request is answered by B.
        let second = exchange(wire.fd, "GET /scheme HTTP/1.1\r\nHost: x\r\n\r\n", turning: b)
        #expect(second?.hasSuffix("http") == true)
        #expect(live(b) == 1)
        #expect(live(a) == 1)

        // Just arrived: it settles before it may move again.
        var slot = -1
        let initialized = b.worker.pointee.table.initialized
        for s in 0..<initialized where b.worker.pointee.table[s].pointee.state != .free { slot = s }
        try #require(slot >= 0)
        #expect(!movable(b, slot))
        #expect(movable(b, slot, at: av_monotonic_ms() + BalancePolicy.settleMs + 1))
        let count = b.worker.pointee.table[slot].pointee.requestCount
        // One request before the move and one after: the count came along.
        #expect(count == 2)
    }

    @Test func aConnectionWithWorkInFlightStays() throws {
        let a = balancedApp().test
        let toB = try handoffPair()
        defer { _ = av_close(toB.receive); _ = av_close(toB.send) }

        let wire = try TestWire(a)
        #expect(exchange(wire.fd, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n", turning: a) != nil)
        // Half a request buffered.
        wire.send("GET /hel")
        for _ in 0..<20 { a.turn() }
        #expect(!movable(a, wire.slot))
        #expect(handOff(a, 4, to: toB.send) == 0)
        wire.send("lo HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(wire.receive()?.hasSuffix("hello") == true)

        // A handler waiting on a timer.
        wire.send("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
        for _ in 0..<20 { a.turn() }
        #expect(!movable(a, wire.slot))
        #expect(wire.receive()?.hasSuffix("slow") == true)
        #expect(movable(a, wire.slot))

        // A client that has half-closed.
        _ = shutdown(wire.fd, Int32(SHUT_WR))
        for _ in 0..<20 { a.turn() }
        #expect(!movable(a, wire.slot))
    }

    @Test func aReceiverThatIsNotTakingAnyMoreLeavesTheConnectionWhereItWas() throws {
        #expect(av_load_init(8) == 0)
        let a = balancedApp().test
        let toB = try handoffPair()
        let toA = try handoffPair()
        defer { _ = av_close(toA.receive); _ = av_close(toA.send) }
        // Costs are kept only where connections move.
        a.onWorker {
            a.worker.pointee.startBalancing(loadSlot: 0, channel: 0, receiveFD: toA.receive,
                                            sendFDs: [], sharedListener: false)
        }
        defer { a.onWorker { a.worker.pointee.leaveBalancing() } }
        let wire = try TestWire(a)
        #expect(exchange(wire.fd, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n", turning: a) != nil)
        let costly = try TestWire(a)
        #expect(exchange(costly.fd, "GET /work HTTP/1.1\r\nHost: x\r\n\r\n", turning: a) != nil)
        // Nobody will ever read this channel.
        _ = av_close(toB.receive)
        defer { _ = av_close(toB.send) }
        #expect(handOff(a, 1, to: toB.send) == 0)
        #expect(exchange(wire.fd, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n", turning: a)?
                    .hasSuffix("hello") == true)
    }

    // MARK: - The shared listener

    @Test func aWorkerAheadLeavesTheListenerToTheOthersAndTakesItBack() throws {
        #expect(av_load_init(8) == 0)
        let a = balancedApp().test
        let listener = av_listen_tcp("127.0.0.1", 0, 16, 0, 0)
        try #require(listener >= 0)
        var port: UInt16 = 0
        _ = av_local_addr(listener, nil, 0, &port)
        a.worker.pointee.listenFD = listener
        a.onWorker {
            a.worker.pointee.startBalancing(loadSlot: 2, channel: 0, receiveFD: -1,
                                            sendFDs: [], sharedListener: true)
            _ = a.worker.pointee.armListener()
        }
        #expect(a.worker.pointee.balancer.listenerArmed)
        // Another worker, idle.
        av_load_join(3, 1)
        av_load_publish(3, 0, 0)
        av_load_accepting(3, 1)
        defer {
            av_load_leave(3)
            a.onWorker {
                a.worker.pointee.leaveBalancing()
                a.worker.pointee.disarmListener()
            }
            a.worker.pointee.listenFD = -1
            _ = av_close(listener)
        }

        // This worker is flat out.
        a.worker.pointee.balancer.busy = 900
        var clients: [Int32] = []
        defer { for fd in clients { _ = av_close(fd) } }
        for _ in 0..<3 {
            var progress: Int32 = 0
            clients.append(av_connect_tcp("127.0.0.1", port, &progress))
        }
        // Woken, it leaves them to the idle worker, and stays off the listener.
        for _ in 0..<20 { a.turn() }
        #expect(live(a) == 0)
        #expect(!a.worker.pointee.balancer.listenerArmed)

        // Still busier, it takes the listener back all the same once the
        // longest pause is up, so that it cannot go deaf -- and, woken, leaves
        // the connections again, since the other is still there to take them.
        a.worker.pointee.balancer.disarmedAt = av_monotonic_ms() &- BalancePolicy.rearmMs
        a.worker.pointee.balancer.lastTick = 0
        a.onWorker { a.worker.pointee.balanceTick() }
        #expect(a.worker.pointee.balancer.listenerArmed)
        for _ in 0..<20 { a.turn() }
        #expect(live(a) == 0)

        // No longer busier: back at once, and it takes them.
        a.worker.pointee.balancer.busy = 0
        a.worker.pointee.balancer.lastTick = 0
        a.onWorker { a.worker.pointee.balanceTick() }
        #expect(a.worker.pointee.balancer.listenerArmed)
        for _ in 0..<50 where live(a) < 3 { a.turn() }
        #expect(live(a) == 3)

        // A worker stuck on one long turn has said nothing since it began, so
        // whatever it last said, it is not deferred to.
        a.worker.pointee.balancer.busy = 900
        av_load_awake(3, av_monotonic_us() &- UInt64(AV_LOAD_STALL_US))
        for _ in 0..<2 {
            var progress: Int32 = 0
            clients.append(av_connect_tcp("127.0.0.1", port, &progress))
        }
        for _ in 0..<50 where live(a) < 5 { a.turn() }
        #expect(live(a) == 5)
    }

    @Test func aWorkerStepsBackOnlyForAPeerThatIsAccepting() throws {
        #expect(av_load_init(8) == 0)
        let a = balancedApp().test
        let listener = av_listen_tcp("127.0.0.1", 0, 16, 0, 0)
        try #require(listener >= 0)
        var port: UInt16 = 0
        _ = av_local_addr(listener, nil, 0, &port)
        a.worker.pointee.listenFD = listener
        a.onWorker {
            a.worker.pointee.startBalancing(loadSlot: 6, channel: 0, receiveFD: -1,
                                            sendFDs: [], sharedListener: true)
            _ = a.worker.pointee.armListener()
        }
        // A peer as idle as this worker, with nothing -- and not watching the
        // listener, as a worker that has stepped back itself is not.
        av_load_join(7, 1)
        av_load_publish(7, 0, 0)
        defer {
            av_load_leave(7)
            a.onWorker {
                a.worker.pointee.leaveBalancing()
                a.worker.pointee.disarmListener()
            }
            a.worker.pointee.listenFD = -1
            _ = av_close(listener)
        }
        // Four connections already, over the margin of three.
        let held = try (0..<4).map { _ in try TestWire(a) }
        #expect(live(a) == 4 && held.count == 4)

        var clients: [Int32] = []
        defer { for fd in clients { _ = av_close(fd) } }
        func connect(_ n: Int) {
            for _ in 0..<n {
                var progress: Int32 = 0
                clients.append(av_connect_tcp("127.0.0.1", port, &progress))
            }
        }
        // Nobody else will take them, so it does.
        connect(2)
        for _ in 0..<50 where live(a) < 6 { a.turn() }
        #expect(live(a) == 6)
        #expect(a.worker.pointee.balancer.listenerArmed)

        // With the peer watching, it leaves them to the peer, for a turn.
        av_load_accepting(7, 1)
        connect(3)
        for _ in 0..<20 { a.turn() }
        #expect(live(a) == 6)
        #expect(!a.worker.pointee.balancer.listenerArmed)
        // A turn later it is back, whatever the counts say by then.
        a.worker.pointee.balancer.backAtUs = av_monotonic_us()
        a.onWorker { a.worker.pointee.balanceTick() }
        #expect(a.worker.pointee.balancer.listenerArmed)

        // When the peer stops watching, nobody else will take them, so this
        // worker does.
        av_load_accepting(7, 0)
        for _ in 0..<50 where live(a) < 9 { a.turn() }
        #expect(a.worker.pointee.balancer.listenerArmed)
        #expect(live(a) == 9)
    }
}

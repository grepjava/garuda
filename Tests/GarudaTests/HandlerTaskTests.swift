import Testing
import CAllocationCounter
import CGaruda
import GarudaCore
@testable import Garuda

private struct HandlerFailure: Error {}

/// What `/sleep/:ms` keeps across its wait.
private enum Slept: RequestContextKey {
    typealias Value = Int
}

private func asyncApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/now") { _, response in
        response.send(status: 200, "now")
    }
    app.onAsync(.get, "/sleep/:ms") { request, response in
        let ms = request.withParameter(0) { $0.integer } ?? 1
        request[context: Slept.self] = ms
        try await response.sleep(milliseconds: UInt64(ms))
        response.send("slept \(request[context: Slept.self] ?? -1)")
    }
    app.onAsync(.get, "/silent") { _, _ in }
    app.onAsync(.get, "/throw") { _, _ in
        throw HandlerFailure()
    }
    app.onAsync(.get, "/sleep-then-throw") { _, response in
        try await response.sleep(milliseconds: 1)
        throw HandlerFailure()
    }
    // Three routes that answer identically, for counting allocations.
    app.onAsync(.get, "/same") { _, response in
        response.send(status: 200, "same")
    }
    app.onAsync(.get, "/same-after-wait") { _, response in
        try await response.sleep(milliseconds: 1)
        response.send(status: 200, "same")
    }
    app.get("/same-sync") { _, response in
        response.send(status: 200, "same")
    }
    // The same answer, from a handler that allocates: the count has to see it.
    app.onAsync(.get, "/same-allocating") { _, response in
        let copy = [UInt8]("same".utf8)
        response.send(status: 200, copy)
    }
    return app
}

/// One connection to a test client's worker, written and read directly, so
/// that a test can count what the worker allocates apart from what the client
/// does.
private final class Wire {
    let client: TestClient
    let fd: Int32
    let capacity = 4096
    let buffer: UnsafeMutablePointer<UInt8>

    init(_ client: TestClient) throws {
        self.client = client
        fd = try client.connect().client
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        _ = pg_close(fd)
        buffer.deallocate()
    }

    func send(_ request: StaticString) {
        _ = pg_write(fd, request.utf8Start, request.utf8CodeUnitCount)
    }

    /// Turns the worker until one whole response has arrived, adding what the
    /// turns allocated to `allocations`, and returns its length.
    func receive(allocations: inout Int, turns: Int = 5_000) -> Int? {
        var got = 0
        for _ in 0..<turns {
            let before = garuda_test_allocations()
            client.turn()
            allocations &+= garuda_test_allocations() &- before
            while got < capacity {
                let n = pg_read(fd, buffer + got, capacity - got)
                if n <= 0 { break }
                got += n
            }
            if let length = completeLength(got) { return length }
        }
        return nil
    }

    func receive(turns: Int = 5_000) -> String? {
        var ignored = 0
        guard let length = receive(allocations: &ignored, turns: turns) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    /// The length of the response at the start of the buffer once all of it
    /// is there. Every response here states a Content-Length.
    private func completeLength(_ got: Int) -> Int? {
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

/// Serialized: each test client turns a worker on the test's own thread, and
/// the engine keeps its current worker in one per-thread slot.
@Suite("Handler tasks", .serialized)
struct HandlerTaskTests {
    @Test func anAsyncHandlerAnswersOnAReusedTask() throws {
        let client = asyncApp().test
        let first = try client.get("/now")
        #expect(first.status == 200)
        #expect(first.text == "now")
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 1)
        #expect(pool.idleCount == 1)

        for _ in 0..<20 { _ = try client.get("/now") }
        #expect(pool.count == 1)
        #expect(pool.idleCount == 1)
    }

    @Test func aWorkerWithOnlySynchronousHandlersHasNoTasks() throws {
        let client = asyncApp().test
        #expect(try client.get("/same-sync").status == 200)
        #expect(client.worker.pointee.handlerTasks == nil)
    }

    @Test func anAsyncHandlerWaitsOnTheEngine() throws {
        let client = asyncApp().test
        let response = try client.get("/sleep/5")
        #expect(response.status == 200)
        #expect(response.text == "slept 5")
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
    }

    @Test func anAsyncHandlerThatThrowsOrSaysNothingIsAnswered500() throws {
        let client = asyncApp().test
        #expect(try client.get("/silent").status == 500)
        #expect(try client.get("/throw").status == 500)
        #expect(try client.get("/sleep-then-throw").status == 500)
        #expect(try client.get("/now").status == 200)
        #expect(client.worker.pointee.handlerTasks?.count == 1)
    }

    @Test func aClosedConnectionReturnsItsTaskToThePool() throws {
        let client = asyncApp().test
        try client.abandon(Array("GET /sleep/5000 HTTP/1.1\r\nHost: test\r\n\r\n".utf8), turns: 3)
        client.turn()
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 1)
        #expect(pool.idleCount == 1)
        #expect(client.worker.pointee.asyncOps.liveCount == 0)
        #expect(try client.get("/now").text == "now")
        #expect(pool.count == 1)
    }

    @Test func requestsPastTheLimitWaitForATask() throws {
        let client = asyncApp().test
        client.worker.pointee.handlerTaskLimit = 2
        var wires: [Wire] = []
        for _ in 0..<5 {
            let wire = try Wire(client)
            wire.send("GET /sleep/5 HTTP/1.1\r\nHost: test\r\n\r\n")
            wires.append(wire)
        }
        var answered = 0
        for wire in wires where wire.receive()?.hasSuffix("slept 5") == true {
            answered += 1
        }
        #expect(answered == 5)
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 2)
        #expect(pool.idleCount == 2)
    }

    @Test(.enabled(if: garuda_test_allocations() >= 0, "allocations are counted on glibc"))
    func anAsyncHandlerAllocatesNothingOnceWarm() throws {
        // The counter sees the Swift runtime's allocations.
        let before = garuda_test_allocations()
        let array = [Int](repeating: 7, count: 64 + Int(pg_monotonic_ms() % 16))
        #expect(garuda_test_allocations() > before)
        #expect(array.count >= 64)

        let client = asyncApp().test
        let wire = try Wire(client)
        let routes: [(request: StaticString, rounds: Int, allocates: Bool)] = [
            ("GET /same-sync HTTP/1.1\r\nHost: test\r\n\r\n", 1_000, false),
            ("GET /same HTTP/1.1\r\nHost: test\r\n\r\n", 1_000, false),
            ("GET /same-after-wait HTTP/1.1\r\nHost: test\r\n\r\n", 200, false),
            ("GET /same-allocating HTTP/1.1\r\nHost: test\r\n\r\n", 100, true),
        ]
        for route in routes {
            var warming = 0
            for _ in 0..<50 {
                wire.send(route.request)
                _ = wire.receive(allocations: &warming)
            }
            var allocations = 0
            var answered = 0
            for _ in 0..<route.rounds {
                wire.send(route.request)
                if wire.receive(allocations: &allocations) != nil { answered += 1 }
            }
            #expect(answered == route.rounds, "\(route.request)")
            if route.allocates {
                #expect(allocations >= route.rounds, "\(route.request)")
            } else {
                #expect(allocations == 0, "\(route.request)")
            }
        }
    }
}

import Testing
import CAvian
import AvianCore
@testable import Garuda

private struct Person: Codable, Equatable {
    var id: Int
    var name: String
}

private struct NewPerson: Codable, Equatable {
    var name: String
    var age: Int
}

private struct Search: Codable, Equatable {
    var q: String
    var page: Int?
}

private struct Chosen: Codable, Equatable {
    var who: String
}

/// State an async handler asks for, to prove extraction reaches a task.
private final class Directory {
    let names = ["Ada", "Grace"]
    func name(_ id: Int) -> String? { names.indices.contains(id) ? names[id] : nil }
}

private func asyncRouteApp() -> Application {
    let app = Application()
    app.state { _ in Directory() }

    // Takes nothing, awaits, returns a string.
    app.get("/hello") { () async throws -> String in
        await Task.yield()
        return "hello"
    }
    // One path parameter across a wait.
    app.get("/person/:id") { (id: Path<Int>) async throws -> JSON<Person> in
        await Task.yield()
        return JSON(Person(id: id.value, name: "Ada"))
    }
    // Several extractors, in the order declared, plus state.
    app.get("/pick/:id") { (id: Path<Int>, query: Query<Search>,
                            directory: State<Directory>) async throws -> JSON<Chosen> in
        await Task.yield()
        let who = directory.value.name(id.value) ?? query.value.q
        return JSON(Chosen(who: who))
    }
    // A body decoded before the handler body runs.
    app.post("/people") { (body: Body<NewPerson>) async throws -> JSON<NewPerson> in
        await Task.yield()
        return JSON(body.value, status: .created)
    }
    // nil is the ordinary 404, from a task like anywhere else.
    app.get("/maybe/:id") { (id: Path<Int>) async throws -> JSON<Person>? in
        await Task.yield()
        return id.value == 1 ? JSON(Person(id: 1, name: "Ada")) : nil
    }
    // A conforming error thrown after a wait is still the answer, not a 500.
    app.get("/conflict") { () async throws -> String in
        await Task.yield()
        throw HTTPError(.conflict, "the name is taken")
    }
    // An error that conforms to nothing is a 500.
    app.get("/boom") { () async throws -> String in
        await Task.yield()
        throw Boom()
    }
    // The synchronous overload, spelled the same way, for the comparison.
    app.get("/sync-hello") {
        "hello"
    }
    app.get("/sync-person/:id") { (id: Path<Int>) in
        JSON(Person(id: id.value, name: "Ada"))
    }
    return app
}

private struct Boom: Error {}

/// What a handler saw about its own request when it finally resumed, and
/// whether anything was still owed. A test resets both before it runs.
nonisolated(unsafe) private var lateCancelled: Bool? = nil
nonisolated(unsafe) private var lateFinished: Bool? = nil
/// Where `/observe` parks, oldest first. The test resumes these itself,
/// which is the point: the engine knows nothing about this wait, so it
/// cannot unwind a handler sitting here.
nonisolated(unsafe) private var parked: [UnsafeContinuation<Void, Never>] = []
/// What each `/observe` handler sent, in the order they answered.
nonisolated(unsafe) private var answered: [String] = []

/// Routes that suspend on something the engine cannot unwind. A handler
/// waiting in `Response.sleep` is parked in `HandlerTaskPool.park`, so
/// cancelling the request resumes it to throw; one waiting on a continuation
/// of its own is not there to be found, so it runs on to its `send` however
/// long ago its request ended. `Task.yield` is no use for this: the executor
/// drains until its ring is empty, so a yield resumes inside the same turn.
private func parkingApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/observe/:which") { request, response in
        // Each handler answers with its own name, so a test can tell whose
        // answer reached which client.
        let mine = request.withParameter(0) { $0.string }
        await withUnsafeContinuation { parked.append($0) }
        lateCancelled = response.isCancelled
        response.send(mine)
        answered.append(mine)
        lateFinished = response.isFinished
    }
    // Waits on the engine instead, so it resumes on its own.
    app.onAsync(.get, "/live") { _, response in
        try await response.sleep(milliseconds: 1)
        lateCancelled = response.isCancelled
        response.send("live")
        lateFinished = response.isFinished
    }
    app.get("/plain") { _, response in
        response.send("plain")
    }
    return app
}

/// Holds what a C thread is to run, since a thread takes a function pointer
/// and a pointer's worth of context.
private final class ThreadBody {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// Runs `body` on a thread of its own and waits for it, so that whatever it
/// resumes is resumed from a thread no worker has ever run on. This is what
/// the runtime does to a task waiting on something the engine does not own:
/// it resumes on its own timer thread, or a pool thread, and the handler's
/// job reaches its worker from there.
private func onAnotherThread(_ body: @escaping () -> Void) {
    let context = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
    guard let thread = av_thread_start({ raw in
        Unmanaged<ThreadBody>.fromOpaque(raw!).takeRetainedValue().run()
    }, context) else {
        Unmanaged<ThreadBody>.fromOpaque(context).release()
        Issue.record("cannot start a thread")
        return
    }
    av_thread_join(thread)
}

/// One connection driven directly, so a test can leave a request parked and
/// unanswered across turns instead of waiting for a whole response.
private final class Socket {
    let client: TestClient
    let fd: Int32
    let slot: Int
    let generation: UInt32
    private let capacity = 4096
    private let buffer: UnsafeMutablePointer<UInt8>
    private var got = 0
    private var closed = false

    init(_ client: TestClient) throws {
        self.client = client
        let opened = try client.connect()
        fd = opened.client
        slot = opened.slot
        generation = opened.generation
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

    func send(_ request: StaticString) {
        _ = av_write(fd, request.utf8Start, request.utf8CodeUnitCount)
    }

    /// How many bytes have arrived so far, without waiting for any.
    @discardableResult
    func pending() -> Int {
        while got < capacity {
            let n = av_read(fd, buffer + got, capacity - got)
            if n <= 0 { break }
            got += n
        }
        return got
    }

    /// Turns until something arrives, and returns it whole.
    func receive(turns: Int = 5_000) -> String? {
        for _ in 0..<turns {
            client.turn()
            if pending() > 0 {
                return String(decoding: UnsafeBufferPointer(start: buffer, count: got), as: UTF8.self)
            }
        }
        return nil
    }
}

extension TestClient {
    /// Sends `path`, turns until its handler has parked, then goes away, so
    /// the slot is freed with the handler still suspended on it.
    func parkThenAbandon(_ path: String) throws -> Int {
        let socket = try Socket(self)
        let slot = socket.slot
        var request = [UInt8]("GET ".utf8)
        request += Array(path.utf8)
        request += Array(" HTTP/1.1\r\nHost: test\r\n\r\n".utf8)
        _ = request.withUnsafeBufferPointer { av_write(socket.fd, $0.baseAddress!, $0.count) }
        while parked.isEmpty { turn() }
        // Closing the client's end is not enough: a worker does not drop a
        // connection whose handler still holds it, so the close is forced the
        // way `TestClient.abandon` forces it. The handler stays parked.
        socket.close()
        onWorker {
            let c = worker.pointee.table[socket.slot]
            if c.pointee.state != .free && c.pointee.generation == socket.generation {
                worker.pointee.closeConnection(socket.slot)
            }
        }
        turn()
        return slot
    }
}

/// Serialized for the same reason as the handler task tests: each client turns
/// a worker on the test's own thread.
@Suite("Async routes", .serialized)
struct AsyncRouteTests {
    @Test func anAsyncHandlerTakingNothingAnswers() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/hello")
        #expect(response.status == 200)
        #expect(response.text == "hello")
    }

    @Test func anAsyncHandlerTakesAPathParameter() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/person/7")
        #expect(response.status == 200)
        #expect(try response.json(Person.self) == Person(id: 7, name: "Ada"))
    }

    @Test func anAsyncHandlerTakesSeveralExtractorsAndState() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/pick/1?q=nobody").json(Chosen.self) == Chosen(who: "Grace"))
        // Out of the directory's range, so the query string answers instead.
        #expect(try client.get("/pick/9?q=nobody").json(Chosen.self) == Chosen(who: "nobody"))
    }

    @Test func anAsyncHandlerDecodesABody() throws {
        let client = asyncRouteApp().test
        let response = try client.post("/people", body: #"{"name":"Ada","age":36}"#)
        #expect(response.status == 201)
        #expect(try response.json(NewPerson.self) == NewPerson(name: "Ada", age: 36))
    }

    @Test func anAsyncHandlerReturningNilIs404() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/maybe/1").status == 200)
        #expect(try client.get("/maybe/2").status == 404)
    }

    @Test func aBadPathParameterIs400BeforeTheHandlerRuns() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/person/not-a-number").status == 400)
    }

    @Test func aConformingErrorFromATaskIsTheAnswer() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/conflict")
        #expect(response.status == 409)
        #expect(response.text == #"{"error":"the name is taken"}"#)
    }

    @Test func anUnplannedErrorFromATaskIs500() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/boom").status == 500)
    }

    /// The overloads differ only in whether the closure awaits, so this is the
    /// test that they do not quietly trade places: a synchronous handler must
    /// never reach the pool, and an async one must.
    @Test func onlyTheAwaitingHandlersUseTasks() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/sync-hello").text == "hello")
        #expect(try client.get("/sync-person/3").status == 200)
        #expect(client.worker.pointee.handlerTasks == nil)

        #expect(try client.get("/hello").text == "hello")
        let tasks = client.worker.pointee.handlerTasks
        let pool = try #require(tasks)
        #expect(pool.count == 1)
    }

    @Test func asyncHandlersShareTheWorkersTasks() throws {
        let client = asyncRouteApp().test
        for _ in 0..<20 {
            #expect(try client.get("/person/1").status == 200)
            #expect(try client.get("/hello").status == 200)
        }
        let tasks = client.worker.pointee.handlerTasks
        let pool = try #require(tasks)
        #expect(pool.count == 1)
        #expect(pool.idleCount == 1)
    }

    /// A handler's code runs on its worker's thread, and a handler may wait
    /// on anything at all. Nothing then says the thread that resumes it is
    /// the worker's: the runtime resumes a task wherever it resumed what the
    /// task was waiting on. So the job has to reach the worker from a thread
    /// that is nobody's worker, and the answer has to come out as it always
    /// did. Resuming from a thread of the test's own is the deterministic
    /// version of what a library's timer or thread pool does by itself --
    /// which is why this went unseen until a macOS runner tripped over it
    /// where nobody could reproduce it.
    @Test func aHandlerResumedFromAnotherThreadStillAnswers() throws {
        parked = []
        answered = []
        lateCancelled = nil
        lateFinished = nil
        let client = parkingApp().test
        let socket = try Socket(client)
        socket.send("GET /observe/away HTTP/1.1\r\nHost: test\r\n\r\n")
        while parked.isEmpty { client.turn() }
        let waiting = parked.removeFirst()
        onAnotherThread { waiting.resume() }
        let response = socket.receive()
        #expect(response?.contains("away") == true)
        #expect(answered == ["away"])
        // Its request was still there, and the answer was its own to send.
        #expect(lateCancelled == false)
        #expect(lateFinished == true)
    }

    /// A handler waiting on the engine is unwound when its request is
    /// cancelled, but one waiting on anything else is not: it resumes to find
    /// the slot holding somebody else's request, still dispatching and still
    /// unanswered. That is the only window in which a late answer could reach
    /// the wrong client, so the test has to build it -- the second request is
    /// parked, not finished, when the first handler wakes. A test where the
    /// second request has already been answered proves nothing: the response
    /// sink refuses that on its own, whether or not the identity is checked.
    @Test func aLateAnswerNeverReachesTheRequestThatTookTheSlot() throws {
        lateCancelled = nil
        lateFinished = nil
        parked = []
        answered = []
        let client = parkingApp().test

        // First: parks, then its client goes away and the slot is freed.
        let freed = try client.parkThenAbandon("/observe/first")
        #expect(parked.count == 1)
        #expect(client.worker.pointee.table.liveCount == 0)

        // Second: takes the same slot -- the free list is last in, first out
        // -- and parks there, dispatching and unanswered.
        let second = try Socket(client)
        second.send("GET /observe/second HTTP/1.1\r\nHost: test\r\n\r\n")
        for _ in 0..<20 where parked.count < 2 { client.turn() }
        #expect(parked.count == 2)
        #expect(second.slot == freed)

        // Now wake the first handler, whose request is long gone.
        client.onWorker { parked.removeFirst().resume() }
        client.turn()
        #expect(lateCancelled == true)
        #expect(answered == ["first"])
        // Its answer went nowhere: the second client is still waiting.
        #expect(second.pending() == 0)

        // And the second handler still answers its own client correctly.
        client.onWorker { parked.removeFirst().resume() }
        #expect(second.receive()?.hasSuffix("second") == true)
        #expect(answered == ["first", "second"])
    }

    @Test func aHandlerWhoseRequestIsStillThereIsNotCancelled() throws {
        lateCancelled = nil
        lateFinished = nil
        let client = parkingApp().test
        #expect(try client.get("/live").text == "live")
        #expect(lateCancelled == false)
        // It answered, so nothing is owed once the send has gone through.
        #expect(lateFinished == true)
    }
}

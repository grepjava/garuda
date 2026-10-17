@_spi(Testing) import Garuda
import GarudaTesting
import Synchronization
import Vega
import Testing

final class Pool: Sendable {
    let name: String
    let closed = Atomic<Bool>(false)
    init(name: String) { self.name = name }
}

struct Settings: Sendable {
    let greeting: String
}

/// Records what ran, in order, from any thread.
final class Journal: Sendable {
    private let entries = Mutex<[String]>([])
    func note(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

@Suite struct StateTests {
    @Test func handlersGetTheShardsState() throws {
        let app = Application()
        app.state { _ in Pool(name: "main") }
        app.get("/pool") { (pool: State<Pool>) in pool.value.name }
        #expect(try app.test.get("/pool").text == "main")
    }

    @Test func factoriesMayAwaitAndReadEarlierState() throws {
        let app = Application()
        app.state { _ in Settings(greeting: "hello") }
        app.state { start async throws in
            await Task.yield()
            return Pool(name: try start.state(Settings.self).greeting + " pool")
        }
        app.get("/") { (pool: State<Pool>, settings: State<Settings>) in "\(pool.value.name), \(settings.value.greeting)" }
        #expect(try app.test.get("/").text == "hello pool, hello")
    }

    @Test func middlewareReadsStateFromTheRequest() throws {
        let app = Application()
        app.state { _ in Settings(greeting: "hi") }
        app.use { request, response, next in
            response.addHeader("x-greeting", try request.state(Settings.self).greeting)
            try await next()
        }
        app.get("/") { () in "" }
        #expect(try app.test.get("/").header("x-greeting") == "hi")
    }

    @Test func stateIsBuiltOncePerApplication() throws {
        let app = Application()
        let builds = Counter()
        app.state { _ in
            builds.increment()
            return Settings(greeting: "x")
        }
        app.get("/") { (s: State<Settings>) in s.value.greeting }
        let client = app.test
        for _ in 0..<3 { #expect(try client.get("/").text == "x") }
        #expect(try app.test.get("/").text == "x")
        #expect(builds.value == 1)
    }

    @Test func aRouteAskingForUnbuiltStateIsAProblem() {
        let app = Application()
        app.get("/pool") { (pool: State<Pool>) in pool.value.name }
        #expect(app.problems() == ["GET /pool asks for State<Pool>, and no app.state builds it"])
        app.state { _ in Pool(name: "now built") }
        #expect(app.problems().isEmpty)
    }

    @Test func anOptionalStateIsNotAProblem() {
        let app = Application()
        app.get("/maybe") { (pool: State<Pool>?) in pool?.value.name ?? "none" }
        #expect(app.problems().isEmpty)
    }

    @Test func missingStateAtRequestTimeIs500() throws {
        let app = Application()
        app.get("/") { request, response in
            _ = try request.state(Pool.self)
            response.send("unreached")
        }
        #expect(try app.test.get("/").status == 500)
    }

    @Test func aFactoryThatThrowsFailsEveryRequest() throws {
        struct NoDatabase: Error {}
        let app = Application()
        app.state { _ -> Pool in throw NoDatabase() }
        app.get("/") { () in "unreached" }
        let client = app.test
        #expect(throws: (any Error).self) { try client.get("/") }
        #expect(throws: (any Error).self) { try client.get("/") }
    }

    @Test func startHooksRunAfterStateInOrder() throws {
        let app = Application()
        let journal = Journal()
        app.state { start in
            journal.note("state \(start.shard.index)/\(start.shard.count)")
            return Settings(greeting: "x")
        }
        app.onShardStart { start in journal.note("start 1: \(try start.state(Settings.self).greeting)") }
        app.onShardStart { _ in journal.note("start 2") }
        app.get("/") { () in "" }
        _ = try app.test.get("/")
        #expect(journal.all == ["state 0/1", "start 1: x", "start 2"])
    }

    @Test func stopHooksRunInReverseThenStateShutsDownNewestFirst() throws {
        let app = Application()
        let journal = Journal()
        app.state({ _ in Settings(greeting: "s") }, shutdown: { _ in journal.note("shutdown settings") })
        app.state({ _ in Pool(name: "p") }, shutdown: { pool in
            pool.closed.store(true, ordering: .relaxed)
            journal.note("shutdown pool")
        })
        app.onShardStop { _ in journal.note("stop 1") }
        app.onShardStop { stop in journal.note("stop 2 sees \(try! stop.state(Pool.self).name)") }
        app.get("/") { () in "" }
        _ = try app.test.get("/")
        app.stopForTesting(on: Runtime(workers: 1))
        #expect(journal.all == ["stop 2 sees p", "stop 1", "shutdown pool", "shutdown settings"])
    }
}

enum CurrentUser: RequestContextKey { typealias Value = String }
enum RequestTag: RequestContextKey { typealias Value = Int }
enum K1: RequestContextKey { typealias Value = Int }
enum K2: RequestContextKey { typealias Value = Int }
enum K3: RequestContextKey { typealias Value = Int }
enum K4: RequestContextKey { typealias Value = Int }
enum K5: RequestContextKey { typealias Value = Int }
enum K6: RequestContextKey { typealias Value = Int }

@Suite struct ContextTests {
    @Test func middlewareHandsAValueToTheHandler() throws {
        let app = Application()
        app.use { request, _, next in
            request[context: CurrentUser.self] = request.header("x-user")
            try await next()
        }
        app.get("/me") { (user: Context<CurrentUser>) in "me: \(user.value)" }
        #expect(try app.test.get("/me", headers: [("x-user", "ada")]).text == "me: ada")
    }

    @Test func aMissingValueIs500() throws {
        let app = Application()
        app.get("/me") { (user: Context<CurrentUser>) in user.value }
        #expect(try app.test.get("/me").status == 500)
    }

    @Test func aResultContextSaysWhy() throws {
        let app = Application()
        app.get("/me") { (user: Result<Context<CurrentUser>, any Error>) in
            switch user {
            case .success(let user): return user.value
            case .failure(let error as HTTPError): return "refused: \(error.status.code)"
            case .failure: return "refused"
            }
        }
        #expect(try app.test.get("/me").text == "refused: 500")
    }

    @Test func anOptionalContextIsNilWhenMissing() throws {
        let app = Application()
        app.get("/me") { (user: Context<CurrentUser>?) in user?.value ?? "nobody" }
        #expect(try app.test.get("/me").text == "nobody")
    }

    @Test func valuesDoNotReachTheNextRequest() throws {
        let app = Application()
        app.get("/set") { request, response in
            request[context: RequestTag.self] = 7
            response.send("set")
        }
        app.get("/read") { request, response in
            response.send("\(request[context: RequestTag.self] ?? -1)")
        }
        let responses = try app.test.sendPipelined(raw: Array(
            "GET /set HTTP/1.1\r\nHost: t\r\n\r\nGET /read HTTP/1.1\r\nHost: t\r\n\r\n".utf8))
        #expect(responses.map(\.text) == ["set", "-1"])
    }

    @Test func moreThanFourValuesAndRemoval() throws {
        let app = Application()
        app.get("/") { request, response in
            request[context: K1.self] = 1
            request[context: K2.self] = 2
            request[context: K3.self] = 3
            request[context: K4.self] = 4
            request[context: K5.self] = 5
            request[context: K6.self] = 6
            request[context: K2.self] = nil
            request[context: K6.self] = 60
            request[context: K5.self] = nil
            let values = [request[context: K1.self], request[context: K2.self], request[context: K3.self],
                          request[context: K4.self], request[context: K5.self], request[context: K6.self]]
            response.send(values.map { $0.map(String.init) ?? "-" }.joined(separator: ","))
        }
        #expect(try app.test.get("/").text == "1,-,3,4,-,60")
    }

    @Test func aFreedSlotIsReused() throws {
        let app = Application()
        app.get("/") { request, response in
            request[context: K1.self] = 1
            request[context: K2.self] = 2
            request[context: K1.self] = nil
            request[context: K3.self] = 3
            response.send("\(request[context: K1.self] ?? -1),\(request[context: K2.self] ?? -1),\(request[context: K3.self] ?? -1)")
        }
        #expect(try app.test.get("/").text == "-1,2,3")
    }
}

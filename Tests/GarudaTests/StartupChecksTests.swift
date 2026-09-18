import Testing
@testable import Garuda

// What an application can be asked about itself before it serves: a route
// whose handler cannot be given what it declares, which used to be a 500 for
// whoever found it first.

private struct Settings: Sendable { let name: String }
private struct Pool: Sendable { let size: Int }

@Suite("Startup checks")
struct StartupChecksTests {
    @Test func anApplicationThatIsSoundHasNothingToReport() throws {
        let app = Application()
        app.state { _ in Settings(name: "x") }
        app.get("/health") { "ok" }
        app.get("/users/:id") { (id: Path<Int>) in "\(id.value)" }
        app.get("/shops/:shop/orders/:id") { (shop: Path<String>, id: Path<Int>) in "\(shop.value)\(id.value)" }
        app.get("/settings") { (settings: State<Settings>) in settings.value.name }
        // A route may take fewer parameters than its pattern has: the first
        // Path takes the first one, and ignoring the rest is a choice.
        app.get("/a/:one/b/:two") { (one: Path<String>) in one.value }
        // A raw handler takes none of them through extractors at all.
        app.on(.get, "/raw/:id") { request, response in response.send("raw") }
        #expect(app.problems().isEmpty, "\(app.problems())")
    }

    @Test func aHandlerTakingMorePathsThanThePatternHas() throws {
        let app = Application()
        app.get("/users/:id") { (id: Path<Int>, extra: Path<String>) in "\(id.value)" }
        #expect(app.problems() == ["GET /users/:id takes 2 Path extractors and its pattern has 1 parameter"])

        let none = Application()
        none.post("/orders") { (id: Path<Int>) in "\(id.value)" }
        #expect(none.problems() == ["POST /orders takes 1 Path extractor and its pattern has 0 parameters"])
    }

    @Test func thePatternIsTheWholeOneAGroupMakes() throws {
        // The parameters a group's prefix brings count as much as the
        // route's own, so a handler may take both.
        let app = Application()
        app.group("/shops/:shop") {
            app.get("/orders/:id") { (shop: Path<String>, id: Path<Int>) in "\(shop.value)\(id.value)" }
        }
        #expect(app.problems().isEmpty, "\(app.problems())")

        let short = Application()
        short.group("/shops") {
            short.get("/orders/:id") { (shop: Path<String>, id: Path<Int>) in "\(shop.value)\(id.value)" }
        }
        #expect(short.problems()
                    == ["GET /shops/orders/:id takes 2 Path extractors and its pattern has 1 parameter"])
    }

    @Test func aStateNothingRegistered() throws {
        let app = Application()
        app.get("/settings") { (settings: State<Settings>) in settings.value.name }
        #expect(app.problems() == ["GET /settings asks for State<Settings> and no app.state registered one"])

        // Registered, and it is fine -- whatever order the two happened in.
        let registered = Application()
        registered.get("/settings") { (settings: State<Settings>) in settings.value.name }
        registered.state { _ in Settings(name: "x") }
        #expect(registered.problems().isEmpty)
    }

    @Test func everyProblemIsReportedAtOnce() throws {
        // A start-up that names one problem per restart is a start-up nobody
        // wants to fix twice.
        let app = Application()
        app.get("/a/:id") { (id: Path<Int>, extra: Path<Int>, settings: State<Settings>) in "x" }
        app.get("/b") { (pool: State<Pool>) in "\(pool.value.size)" }
        #expect(app.problems() == [
            "GET /a/:id takes 2 Path extractors and its pattern has 1 parameter",
            "GET /a/:id asks for State<Settings> and no app.state registered one",
            "GET /b asks for State<Pool> and no app.state registered one",
        ])
    }

    @Test func anOptionalExtractorAsksForNothing() throws {
        // `E?` is nil where `E` would have refused, which is a route saying
        // it can do without: neither a missing parameter nor a missing state
        // is a problem for it.
        let app = Application()
        app.get("/maybe") { (settings: State<Settings>?) in settings?.value.name ?? "none" }
        app.get("/also") { (id: Path<Int>?) in "\(id?.value ?? 0)" }
        #expect(app.problems().isEmpty, "\(app.problems())")
    }

    @Test func aRouterCarriesItsRoutesProblemsIntoTheApplication() throws {
        let router = Router()
        router.get("/:id") { (id: Path<Int>, extra: Path<Int>) in "x" }
        let app = Application()
        app.nest("/things", router)
        #expect(app.problems() == ["GET /things/:id takes 2 Path extractors and its pattern has 1 parameter"])
    }

    @Test func stateIsRegisteredOnceForATypeOrNotAtAll() throws {
        // Registering twice used to run both factories in every worker: one
        // value nobody could reach and never shut down, and another shut down
        // twice.
        let app = Application()
        app.state { _ in Settings(name: "first") }
        #expect(app.problems().isEmpty)
        // The second registration is a precondition failure, which a test
        // cannot catch; what it would have done is what this documents.
        app.state { _ in Pool(size: 1) }
        #expect(app.problems().isEmpty, "a different type is a different value")
    }
}

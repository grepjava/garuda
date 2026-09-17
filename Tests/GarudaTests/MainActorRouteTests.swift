import Testing
import CAvian
import AvianCore
@testable import Garuda

// An application's routes are usually registered from `main.swift`, whose
// top-level code is on the main actor. A closure written there is isolated to
// the main actor unless the parameter it is passed to says otherwise, and a
// worker never runs the main actor: an async handler that started by hopping
// to it waited forever, and every request to it hung. Only a plain async
// route and a WebTransport one were ever seen to hang, but every parameter
// that takes an async closure had the same shape.

nonisolated(unsafe) private var mainActorApp: Application? = nil

/// Builds an application the way `main.swift` does: from main-actor code.
@MainActor
private func buildOnMainActor() {
    let app = Application()
    app.get("/typed") { () async throws -> String in "typed" }
    app.onAsync(.get, "/raw") { _, response in response.send("raw") }
    app.use { _, response in
        await Task.yield()
        response.addHeader("x-middleware", "ran")
        return nil
    }
    mainActorApp = app
}

@Suite("Routes registered on the main actor")
struct MainActorRouteTests {

    @Test func asyncRoutesAndMiddlewareFromMainActorCodeAreServed() async throws {
        await buildOnMainActor()
        let app = try #require(mainActorApp)
        let client = app.test
        let typed = try client.get("/typed")
        #expect(typed.text == "typed")
        #expect(typed.header("x-middleware") == "ran")
        #expect(try client.get("/raw").text == "raw")
    }
}

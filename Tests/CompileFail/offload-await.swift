// An offloaded handler that awaits. It runs on a pool thread, where the
// database, Redis and the HTTP client cannot be used, so it has to be
// synchronous: the work that awaits belongs in an ordinary async route.
// expect-error: to parameter expecting synchronous function type
import Garuda

func routes(_ app: Application) {
    app.offload.get("/report") { () async throws -> String in
        try await Task.sleep(nanoseconds: 1_000)
        return "report"
    }
}

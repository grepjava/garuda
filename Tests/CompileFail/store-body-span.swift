// A handler that stores the body span somewhere that outlives the closure
// lending it.
// expect-error: lifetime-dependent variable 'body' escapes its scope
import Garuda

nonisolated(unsafe) var kept: Span<UInt8>? = nil

func routes(_ app: Application) {
    app.post("/") { request, response in
        request.withBody { body in
            kept = body
        }
        response.send(status: 200)
    }
}

// A handler that reaches for the engine's own view of the body.
// expect-error: inaccessible due to 'internal' protection level
import Garuda

func routes(_ app: Application) {
    app.post("/") { request, response in
        response.send(status: request.bodyBytes.count)
    }
}

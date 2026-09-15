// A handler that keeps the request itself.
// expect-error: implicit conversion to 'Request?' is consuming
import Garuda

nonisolated(unsafe) var saved: Request? = nil

func routes(_ app: Application) {
    app.get("/") { request, response in
        saved = request
        response.send(status: 200)
    }
}

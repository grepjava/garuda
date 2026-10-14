// A handler that captures the body span in a task, which runs after the
// request's bytes may be gone.
// expect-error: lifetime-dependent variable 'body' escapes its scope
import Garuda

func routes(_ app: Application) {
    app.post("/") { request, response in
        request.withBody { body in
            Task {
                print(body.count)
            }
        }
        response.send(status: .ok)
    }
}

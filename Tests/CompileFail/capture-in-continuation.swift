// A handler that captures the body span in a continuation, which runs after
// the request's bytes may be gone.
// expect-error: lifetime-dependent variable 'body' escapes its scope
import Garuda

func routes(_ app: Application) {
    app.post("/") { request, response in
        request.withBody { body in
            response.after(milliseconds: 1) { _, later in
                later.send(status: body.count)
            }
        }
    }
}

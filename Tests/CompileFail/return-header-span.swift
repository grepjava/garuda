// A handler that returns a header span out of the closure lending it.
// expect-error: requires that 'Span<UInt8>' conform to 'Escapable'
import Garuda

func routes(_ app: Application) {
    app.get("/") { request, response in
        let value: Span<UInt8>? = request.withHeader("x-id") { $0 }
        _ = value?.count
        response.send(status: 200)
    }
}

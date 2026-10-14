// The control: every lent-bytes pattern the API is for. If this does not
// compile, the harness is broken, and the failures it reports mean nothing.
import Garuda
import Vega

enum Seen: RequestContextKey {
    typealias Value = Int
}

func routes(_ app: Application) {
    app.get("/user/:id") { request, response in
        request.withParameter(0) { response.send($0) }
    }
    app.post("/echo") { request, response in
        _ = request.withHeader("content-type") { response.addHeader("content-type", $0) }
        let size = request.withBody { $0.count }
        request[context: Seen.self] = size
        let owned = request.path
        // The request is still lent after an await: what is copied out and
        // what the context holds are both there.
        try await Runtime.sleep(for: .milliseconds(1))
        response.send("\(owned) \(request[context: Seen.self] ?? 0)")
    }
}

//===----------------------------------------------------------------------===//
// The garuda executable: the-benchmarker's contract, served through the
// handler API, so the benchmark measures what an application gets.
//
//   GET  /          200, empty body
//   GET  /user/:id  200, the id as the body
//   POST /user      200, empty body
//   GET  /delay/:ms 200 after ms (clamped 1..5000), empty body
//
// HEAD is answered wherever GET is. Anything else is 404.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda

var routes = Routes()

routes.get("/") { _, response in
    response.send(status: 200)
}

routes.get("/user/:id") { request, response in
    response.send(request.parameter(0))
}

routes.post("/user") { _, response in
    response.send(status: 200)
}

routes.get("/delay/:ms") { request, response in
    let digits = request.parameter(0)
    guard digits.count <= 5, let ms = digits.integer else {
        response.send(status: 404)
        return
    }
    response.after(milliseconds: UInt64(min(5000, max(1, ms)))) { _, response in
        response.send(status: 200)
    }
}

exit(serve(routes))

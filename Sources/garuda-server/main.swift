//===----------------------------------------------------------------------===//
// The garuda executable: the-benchmarker's contract and the workloads that
// need no database, served through the handler API, so the benchmark
// measures what an application gets.
//
//   GET  /          200, empty body
//   GET  /user/:id  200, the id as the body
//   POST /user      200, empty body
//   POST /json      an Order decoded, a Receipt encoded
//   GET  /spin/:n   n rounds of FNV-1a, answered as a decimal: CPU a request holds
//   GET  /delay/:ms 200 after ms (clamped 1..5000), empty body
//   GET  /stream    64 KiB written as 16 chunks of 4 KiB
//   POST /upload    a body read whole, and its length answered
//   GET  /download  1 MiB answered from memory
//
// Anything else is 404.
//===----------------------------------------------------------------------===//

import Garuda
import GarudaJSON
import Vega

@JSON struct Order: Codable {
    let id: Int
    let name: String
    let tags: [String]
}

@JSON struct Receipt: Codable {
    let id: Int
    let name: String
    let tags: [String]
    let count: Int
}

// The same bytes Garuda 1's workloads app answers with.
let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
let blob = [UInt8](repeating: UInt8(ascii: "y"), count: 1 << 20)

let app = Application()

app.get("/") { () in HTTPStatus.ok }

app.get("/user/:id") { (id: Path<String>) in id.value }

app.post("/user") { () in HTTPStatus.ok }

app.post("/json") { (order: Body<Order>) in
    let order = order.value
    return JSON(Receipt(id: order.id, name: order.name, tags: order.tags, count: order.tags.count))
}

app.get("/spin/:n") { (n: Path<Int>) in
    var hash: UInt64 = 1_469_598_103_934_665_603
    for i in 0..<max(0, n.value) {
        hash = (hash ^ UInt64(i & 0xff)) &* 1_099_511_628_211
    }
    return String(hash)
}

app.get("/delay/:ms") { (ms: Path<Int>) async throws in
    try await Runtime.sleep(for: .milliseconds(min(5000, max(1, ms.value))))
    return HTTPStatus.ok
}

app.get("/stream") { () async throws in
    StreamingBody(contentType: "application/octet-stream") { body in
        for _ in 0..<16 {
            try await body.write(chunk)
        }
    }
}

app.post("/upload") { request, response in
    let count = request.withBody { $0.count }
    response.send("\(count)")
}

app.get("/download") { _, response in
    response.send(bytes: blob, contentType: "application/octet-stream")
}

app.run()

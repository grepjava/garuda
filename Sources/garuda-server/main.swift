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

app.run()

//===----------------------------------------------------------------------===//
// The garuda executable: the-benchmarker's contract and the workloads,
// served through the handler API, so the benchmark measures what an
// application gets.
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
//   GET  /db/:id    one row from PostgreSQL by primary key, as JSON
//   GET  /me        an HS256 bearer token verified, its subject answered
//   GET  /relay     ORIGIN_URL fetched and streamed on as it arrives
//
// Anything else is 404. DATABASE_URL names the database, and POOL_SIZE how
// many connections it gets in all, shared out among the shards; the
// benchmark script makes the table. Without a database, /db answers 500.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda
import GarudaJSON
import GarudaPostgres
import GarudaSQL
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

@JSON @PostgresRow struct Item: Codable {
    let id: Int32
    let name: String
    let price: Int32
}

struct Claims: Codable, Sendable {
    let sub: String
    let exp: Int
}

// The same bytes Garuda 1's workloads app answers with.
let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
let blob = [UInt8](repeating: UInt8(ascii: "y"), count: 1 << 20)

func environment(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }

let databaseURL = environment("DATABASE_URL")
    ?? "postgres://garuda:garuda-secret@127.0.0.1:5432/bench?sslmode=disable"
// For the whole server: Garuda 1's script gave each of its workers a share.
let poolTotal = environment("POOL_SIZE").flatMap { Int($0) } ?? 32
// What /relay fetches: another server's /stream.
let originURL = environment("ORIGIN_URL") ?? "http://127.0.0.1:3001/stream"
// The secret the script signs its token with. At least as long as the hash.
let secret = "workloads-benchmark-secret-0123456789abcdef"

let app = Application()

// Made lazily: a pool connects on its first query, so a server without a
// database starts, and only /db fails.
app.state { shard in
    PostgresPool(try PostgresConfiguration(url: databaseURL),
                 maxConnections: max(1, (poolTotal + shard.shard.count - 1) / shard.shard.count))
} shutdown: { $0.close() }

let keys = try JWTKeys([.hmac(secret, algorithm: .HS256)])
app.jwtVerifier { _ in keys }

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

app.get("/db/:id") { (id: Path<Int32>, pool: State<PostgresPool>) async throws -> JSON<Item>? in
    try await pool.value.first(Item.self, "select id, name, price from bench_items where id = $1", id.value)
        .map { JSON($0) }
}

app.get("/me") { (jwt: JWT<Claims>) in
    "user \(jwt.claims.sub)"
}

app.get("/relay") { () async throws in
    let upstream = try await HTTPClient().stream(.get, originURL)
    return StreamingBody(contentType: "application/octet-stream") { body in
        while let piece = try await upstream.next() {
            try await body.write(piece)
        }
    }
}

app.run()

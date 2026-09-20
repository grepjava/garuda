// The requests benchmarks/workloads.sh measures, on the public API alone:
//
//   GET  /user/:id   the path parameter, as text
//   POST /json       an Order decoded, and a Receipt encoded
//   GET  /db/:id     one row from PostgreSQL, as JSON
//   GET  /stream     64 KiB written as 16 chunks of 4 KiB
//   GET  /me         an HS256 bearer token verified, and its subject answered
//   POST /upload     a body read whole, and its length answered
//   GET  /download   1 MiB answered from memory
//   GET  /relay      ORIGIN_URL fetched and streamed on as it arrives
//   GET  /spin/:n    n rounds of FNV-1a, answered as a decimal: CPU a request holds
//
// benchmarks/workloads/axum/src/main.rs answers the same requests with the
// same bytes. DATABASE_URL names the database; the script makes the table.
//
//   DATABASE_URL=postgres://garuda:garuda-secret@127.0.0.1/bench?sslmode=disable \
//       .build/release/workloads --port 3000 --workers 4

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda

struct Order: Codable {
    let id: Int
    let name: String
    let tags: [String]
}

struct Receipt: Codable {
    let id: Int
    let name: String
    let tags: [String]
    let count: Int
}

struct Item: Codable {
    let id: Int32
    let name: String
    let price: Int32
}

// The three types the JSON workloads carry read and write themselves rather
// than going through Codable. This is what `@JSON` generates; it is written
// out here because the macro is not written yet, and serde's derive on the
// axum side is the same bargain.

extension Order: JSONReadable {
    init(json reader: inout JSONReader) throws {
        var id: Int?
        var name: String?
        var tags: [String]?
        try reader.beginObject()
        while let key = try reader.nextKey() {
            if key.matches("id") {
                id = try reader.read(Int.self, named: "id")
            } else if key.matches("name") {
                name = try reader.read(String.self, named: "name")
            } else if key.matches("tags") {
                tags = try reader.read([String].self, named: "tags")
            } else {
                try reader.skipValue()
            }
        }
        guard let id else { throw JSONError.missingKey(path: "id") }
        guard let name else { throw JSONError.missingKey(path: "name") }
        guard let tags else { throw JSONError.missingKey(path: "tags") }
        self.init(id: id, name: name, tags: tags)
    }
}

extension Receipt: JSONWritable {
    func write(json output: inout JSONOutput) {
        output.beginObject()
        output.key("id")
        output.write(id)
        output.key("name")
        output.write(name)
        output.key("tags")
        output.beginArray()
        for tag in tags {
            output.element()
            output.write(tag)
        }
        output.endArray()
        output.key("count")
        output.write(count)
        output.endObject()
    }
}

extension Item: JSONWritable {
    func write(json output: inout JSONOutput) {
        output.beginObject()
        output.key("id")
        output.write(id)
        output.key("name")
        output.write(name)
        output.key("price")
        output.write(price)
        output.endObject()
    }
}

let databaseURL = getenv("DATABASE_URL").map { String(cString: $0) }
    ?? "postgres://garuda:garuda-secret@127.0.0.1:5432/bench?sslmode=disable"
// Per worker. The script runs four workers, so 32 connections in all: axum's
// pool is the same 32.
let poolSize = getenv("POOL_SIZE").flatMap { Int(String(cString: $0)) } ?? 8
let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
let blob = [UInt8](repeating: UInt8(ascii: "y"), count: 1 << 20)
// What /relay fetches: another server's /stream.
let originURL = getenv("ORIGIN_URL").map { String(cString: $0) } ?? "http://127.0.0.1:3001/stream"
// The secret the script signs its token with. At least as long as the hash.
let secret = "workloads-benchmark-secret-0123456789abcdef"

struct Claims: Codable, Sendable {
    let sub: String
    let exp: Int
}

let app = Application()

app.state { _ in
    PostgresPool(try PostgresConfiguration(url: databaseURL), maxConnections: poolSize)
} shutdown: { $0.close() }

let keys = try JWTKeys([.hmac(secret, algorithm: .HS256)])
app.jwtVerifier { _ in keys }

app.get("/user/:id") { (id: Path<String>) in
    id.value
}

app.post("/json") { (order: Body<Order>) -> JSON<Receipt> in
    let order = order.value
    return JSON(Receipt(id: order.id, name: order.name, tags: order.tags, count: order.tags.count))
}

app.get("/db/:id") { (id: Path<Int32>, pool: State<PostgresPool>) async throws -> JSON<Item>? in
    try await pool.value.first(Item.self, "select id, name, price from bench_items where id = $1", id.value)
        .map { JSON($0) }
}

app.get("/stream") { () async throws in
    StreamingBody(contentType: "application/octet-stream") { body in
        for _ in 0..<16 {
            try await body.write(chunk)
        }
    }
}

app.get("/me") { (jwt: JWT<Claims>) in
    "user \(jwt.claims.sub)"
}

app.post("/upload") { request, response in
    let count = request.withBody { $0.count }
    response.send("\(count)")
}

app.get("/download") { _, response in
    response.send(bytes: blob, contentType: "application/octet-stream")
}

app.get("/spin/:n") { (n: Path<Int>) in
    var hash: UInt64 = 1_469_598_103_934_665_603
    for i in 0..<max(0, n.value) {
        hash = (hash ^ UInt64(i & 0xff)) &* 1_099_511_628_211
    }
    return String(hash)
}

app.onAsync(.get, "/relay") { request, response in
    let client = request.client
    let upstream = try await client.stream(.get, originURL)
    let body = response.stream(contentType: "application/octet-stream")
    while let piece = try await upstream.next() {
        try await body.write(piece)
    }
}

var flags = Array(CommandLine.arguments.dropFirst())
if flags.first == "--" { flags.removeFirst() }
exit(app.run(arguments: flags))

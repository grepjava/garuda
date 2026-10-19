# Examples

Two kinds of example: eight runnable applications in [Examples/](Examples/),
and short recipes for common tasks below. Both are Garuda 2; an application
moving from Garuda 1 has what changed in [COMPATIBILITY.md](COMPATIBILITY.md).
For flags, see [CONFIG.md](CONFIG.md); for middleware in depth,
[MIDDLEWARE.md](MIDDLEWARE.md).

- [Runnable applications](#runnable-applications)
- Recipes: [a first server](#a-first-server) ·
  [a JSON API](#a-json-api) · [errors](#errors) ·
  [rules on what arrives](#rules-on-what-arrives) ·
  [groups and routers](#groups-and-routers) · [a database](#a-database) ·
  [sign-in with sessions](#sign-in-with-sessions) ·
  [who may do what](#who-may-do-what) ·
  [an extractor of your own](#an-extractor-of-your-own) ·
  [OpenAPI and Swagger UI](#openapi-and-swagger-ui) ·
  [server-sent events](#server-sent-events) · [WebSockets](#websockets) ·
  [large uploads](#large-uploads) ·
  [the shard model](#the-shard-model) ·
  [settings from the environment](#settings-from-the-environment) ·
  [testing](#testing) · [running in production](#running-in-production)

## Runnable applications

```bash
cd Examples
swift run todo -- --port 8080          # everything after -- is Garuda's own flags
swift test                             # every example, through app.test
```

| Example | What it shows | Try |
|---|---|---|
| [Todo](Examples/Sources/TodoExample/TodoApp.swift) | A JSON CRUD API on SQLite: `Path`, `Query` and `Body`, migrations, 422 and 409 with JSON reasons, an optional return for 404, paging | `curl -s localhost:8080/todos -d '{"title":"write the docs"}'` |
| [Auth](Examples/Sources/AuthExample/AuthApp.swift) | Sign-up, login and logout: PBKDF2 password hashes on the blocking pool, random tokens stored as digests, `authenticate(bearer:state:)`, and `SignedInUser`, an extractor that awaits the database | `curl -s localhost:8080/signup -d '{"username":"ada","password":"correct horse"}'` |
| [Streaming](Examples/Sources/StreamingExample/StreamingApp.swift) | `EventStream`, a CSV export written as it is produced with backpressure, uploads written to disk as they arrive | `curl -N localhost:8080/countdown?from=5` |
| [Chat](Examples/Sources/ChatExample/ChatApp.swift) | Rooms over WebSockets and server-sent events, heard across every shard through `Topic`, with replay for reconnecting clients | `swift run chat -- --shards 4`, then open two browser windows |
| [Files](Examples/Sources/FilesExample/FilesApp.swift) | Uploads that survive a dropped connection and downloads that resume: the resumable upload protocol, size limits at both ends, digests, and `--static-dir` serving the store with byte ranges | `curl -X POST --data-binary @photo.jpg -H 'Upload-Complete: ?1' localhost:8080/files` |
| [Uploads](Examples/Sources/UploadsExample/UploadsApp.swift) | Per-user photo uploads: `resumableUploads` inside `group("/users/:user")`, bearer tokens guarding the upload's own URL, `onCreate` recording the owner, types checked from the bytes, `await upload.digest()`, an answer replayed with its `Location` | `curl -X POST --data-binary @cat.png -H 'Authorization: Bearer ada-token' -H 'Content-Type: image/png' -H 'Upload-Complete: ?1' localhost:8080/users/ada/photos` |
| [WebTransport](Examples/Sources/WebTransportExample/WebTransportApp.swift) | A network probe over HTTP/3: `app.webTransport` with an extractor that refuses before a session starts, datagram round trips, download and upload tests on streams with backpressure, a server-opened stream, and a browser page trusting a self-signed certificate by its hash | `swift run webtransport -- --port 8443 --tls-cert cert.pem --tls-key key.pem`, then open `https://localhost:8443` |
| [Starter](Examples/STARTER.md) | A whole application: PostgreSQL, accounts with JWT access and refresh tokens, migrations, settings from the environment, a cleanup job, OpenAPI, health and readiness, a deployment recipe | `swift run starter serve -- --port 8080` |

Each example is a library target with one function that builds the
`Application`, plus a `main.swift` that runs it. The tests call the same
function, so they exercise exactly the routes the executable serves.
[Examples/README.md](Examples/README.md) has notes for copying them.

## A first server

```swift
// Package.swift: .package(url: "https://github.com/grepjava/garuda", from: "2.0.0")
// Sources/hello/main.swift
import Garuda

let app = Application()
app.get("/") { "Hello, world" }
app.get("/hello/:name") { (name: Path<String>) in "Hello, \(name.value)" }
app.run()
```

```bash
swift run -c release hello -- --port 8080 --shards 2
```

`app.run()` reads Garuda's command-line flags, serves until it is told to
stop, and exits: it returns `Never`. `app.run(config:)` takes a `ServerConfig`
instead. Without `--shards`, Linux runs a shard per last-level cache domain
and macOS serves in one process; a shard is a process with a worker thread
per core.

## A JSON API

```swift
import GarudaSQLite

struct Item: Codable {
    let id: Int
    let name: String
    let price: Double
}
struct NewItem: Codable {
    let name: String
    let price: Double
}
struct Page: Decodable {
    let limit: Int?
    let offset: Int?
}

app.get("/items") { (page: Query<Page>, db: State<SQLiteDatabase>) async throws in
    JSON(try await db.value.query(Item.self, "select id, name, price from items limit ? offset ?",
                                  page.value.limit ?? 20, page.value.offset ?? 0))
}

app.get("/items/:id") { (id: Path<Int>, db: State<SQLiteDatabase>) async throws -> JSON<Item>? in
    // nil is a 404
    try await db.value.first(Item.self, "select id, name, price from items where id = ?", id.value).map { JSON($0) }
}

app.post("/items") { (item: Body<NewItem>, db: State<SQLiteDatabase>) async throws -> JSON<Item> in
    guard item.value.price >= 0 else {
        throw HTTPError(.unprocessableContent, "a price is not negative")
    }
    let created = try await db.value.first(
        Item.self, "insert into items (name, price) values (?, ?) returning id, name, price",
        item.value.name, item.value.price)
    return JSON(created!, status: .created)
}
```

`State<SQLiteDatabase>` is what `app.state` built in this shard
([a database](#a-database)). Every handler is async: one that never awaits
runs straight through on the shard thread that read the request, and one that
awaits gives the thread to other requests while it waits. A body or query
that does not decode is a 400 saying which key was wrong.

## Errors

```swift
enum ShopError: ResponseError {
    case soldOut(sku: String)

    var status: HTTPStatus { .conflict }
    var reason: String? {
        switch self {
        case .soldOut(let sku): return "\(sku) is sold out"
        }
    }
}

app.post("/buy/:sku") { (sku: Path<String>) throws -> HTTPStatus in
    throw ShopError.soldOut(sku: sku.value)
}
```

Any `ResponseError` thrown from a handler, extractor or middleware becomes its
status and reason. Any other error is a 500, and its description goes to the
log, not the client.

## Rules on what arrives

Decoding says a request has the right shape. What a value is allowed to be
belongs on the type, as `Validated`:

```swift
struct NewOrder: Decodable, Validated {
    let email: String
    let quantity: Int
    let note: String?
    let items: [Line]

    func validate(_ check: inout Validation) {
        check.email("email", email)
        check.range("quantity", quantity, atLeast: 1, atMost: 100)
        check.length("note", note, atMost: 280)         // nil is absent, not wrong
        check.count("items", items, atLeast: 1)
        check.each("items", items)                      // each line's own rules
        check.require(quantity % 12 == 0, "quantity", "must be whole boxes")
    }
}

app.post("/orders") { (order: Body<NewOrder>, db: State<PostgresPool>) async throws in
    JSON(try await place(order.value, db.value), status: .created)   // already checked
}
```

`Body`, `Query` and `Form` hold what they decode to the type's rules, so there
is nothing to call at the route. Every broken rule is answered together, as 422
with the fields named:

```json
{"error": "email must look like an email address; items[0].sku must be at least 3 characters",
 "fields": [{"field": "email", "message": "must look like an email address"},
            {"field": "items[0].sku", "message": "must be at least 3 characters"}]}
```

A body that is not the type at all stays 400, and fills `fields` from the path
the decoder reports, so a form reads one answer either way. The rules are
`notEmpty`, `length`, `email`, `range`, `oneOf`, `count`, `nested`, `each` and
`require` for everything else; a field named `""` is a rule about the value as
a whole, such as "send a title, a body, or both".

What the type cannot know -- whether this address is already registered -- is
the handler's, and answers the same way:

```swift
throw ValidationError(field: "email", message: "is already registered")
```

A value that came from a queue or a file rather than a request is checked with
`try order.validated()`.

## Groups and routers

```swift
let v1 = Router()
v1.get("/status") { JSON(["ok": true]) }
v1.group("/admin") {
    v1.use { request, response, next in
        guard request.header("x-admin") != nil else { return response.send(status: .forbidden) }
        try await next()
    }
    v1.get("/stats") { "stats" }
}

app.nest("/api/v1", v1)            // /api/v1/status, /api/v1/admin/stats
app.fallback { _, response in response.send(status: .notFound, "no such page") }
```

A group's middleware covers only its routes, and a path routed for other
methods is a 405 with `Allow`. A middleware wraps what comes after it: it
answers by itself, or calls `next()` and may change the response once that
returns.

## A database

```swift
import GarudaPostgres     // and GarudaSQLite, GarudaRedis: each brings Garuda with it

// SQLite: every shard opens the same file.
app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "shop.db"))
    _ = try await db.migrate(["create table items (id integer primary key, name text not null, price real not null)"])
    return db
} shutdown: { db in
    db.close()
}

// PostgreSQL: a pool per shard, shared by its threads.
app.state { _ in
    PostgresPool(PostgresConfiguration(host: "db.internal", user: "shop", password: "secret", database: "shop"))
} shutdown: { pool in
    pool.close()
}
app.get("/count") { (db: State<PostgresPool>) async throws -> String in
    struct Count: Decodable { let n: Int }
    return "\(try await db.value.first(Count.self, "select count(*)::int as n from items")?.n ?? 0)"
}

// Redis: the same, with RedisPool.
app.state { _ in RedisPool(RedisConfiguration(host: "cache.internal")) }
```

The drivers are vega-db's, through the `GarudaPostgres`, `GarudaSQLite` and
`GarudaRedis` products; add the ones you use to the target's dependencies.
`app.state` runs in each shard as it starts, so a connection is never shared
across processes, and the shard's threads share the pool. Rows decode into
`Decodable` types by column name. [CONNECTORS.md](CONNECTORS.md) has the
configuration of each.

## Sign-in with sessions

```swift
import GarudaSQLite

struct Login: Decodable {
    let username: String
    let password: String
}

app.securityHeaders()
app.csrfProtection()
app.sessions { request in SQLiteSessionStore(try request.state(SQLiteDatabase.self)) }

app.post("/login") { (login: Form<Login>, session: Session, db: State<SQLiteDatabase>) async throws -> Redirect in
    struct Account: Decodable {
        let id: Int
        let hash: String
    }
    guard let account = try await db.value.first(
              Account.self, "select id, password_hash as hash from users where username = ?", login.value.username),
          try await Passwords.verify(login.value.password, against: account.hash) else {
        throw HTTPError(.unauthorized, "wrong username or password")
    }
    try await session.renew()
    try await session.set("user", "\(account.id)")
    return Redirect(to: "/")
}

app.get("/") { (session: Session) in
    HTML(session["user"] == nil ? "<a href=/login>Sign in</a>" : "Welcome back")
}

app.post("/logout") { (session: Session) async throws in
    try await session.destroy()
    return Redirect(to: "/")
}
```

Make the sessions table once with `SQLiteSessionStore.schema()` in a migration.
A session change is written before the call returns, so change the session
before answering. `RedisSessionStore` is in `GarudaRedis`. A
`MemorySessionStore` belongs to one shard, and the server warns about one
under more than one shard.

## Who may do what

Signing in says who is asking. What they may do is a rule with a name, written
once:

```swift
extension Policy where Value == User {
    static let admin = Policy(needs: "an administrator") { $0.role == .admin }
    static let billing = Policy(needs: "the billing role") { $0.roles.contains("billing") }
}

app.group("/invoices") {
    app.authenticate(bearer: CurrentUser.self, state: PostgresPool.self) { token, db in
        try await db.first(User.self, "select … where token_digest = $1", Tokens.digest(token))
    }
    app.authorize(CurrentUser.self, .admin.or(.billing))
    app.get("") { (db: State<PostgresPool>) async throws in JSON(try await invoices(db.value)) }
}
```

Every route in the group is guarded. A request the rule refuses is 403 saying
what would have been enough -- `{"error":"this route needs an administrator or
the billing role"}` -- and one with nobody signed in is 401. The rule is a
plain function, so a test reads it without a server:

```swift
#expect(Policy.admin(ada))
#expect(!Policy.admin.and(.billing)(grace))
```

A rule about one row needs the row, so it belongs in the handler:

```swift
app.get("/orders/:id") { (id: Path<Int64>, user: Context<CurrentUser>, db: State<PostgresPool>) async throws in
    guard let order = try await find(id.value, db.value) else { return nil as JSON<Order>? }
    guard order.customer == user.value.id else { throw AuthorizationError(needs: "the customer") }
    return JSON(order)
}
```

With tokens from an identity provider, the rule is usually a scope. Claims
conforming to `ScopedClaims` read the OAuth 2.0 `scope` claim:

```swift
app.group("/orders") {
    app.authenticate(jwt: AccessClaims.self, verifier: keys)
    app.authorize(jwt: AccessClaims.self, .scope("orders:write"))
}
```

Both `authenticate` and `authorize` add what they can answer to every route of
the scope in the OpenAPI document, so the 401, the 403 and the security scheme
are there without repeating them route by route.

## An extractor of your own

```swift
struct ApiKey: RequestExtractor {
    let value: String

    static func extract(from request: borrowing Request, parameter: inout Int) throws -> ApiKey {
        guard let key = request.header("x-api-key") else { throw HTTPError.unauthorized }
        return ApiKey(value: key)
    }
}

struct Customer: RequestExtractor {
    let id: Int

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Customer {
        let key = try ApiKey.extract(from: request, parameter: &parameter)
        let db = try request.state(SQLiteDatabase.self)
        struct Row: Decodable { let id: Int }
        guard let row = try await db.first(Row.self, "select id from customers where api_key = ?", key.value) else {
            throw HTTPError.unauthorized
        }
        return Customer(id: row.id)
    }
}

app.get("/orders/mine") { (customer: Customer) in "orders of \(customer.id)" }
app.get("/offers") { (customer: Customer?) in customer == nil ? "public offers" : "your offers" }
```

There is one protocol, `RequestExtractor`, and its `extract` may await: one
that only reads the request, like `ApiKey`, need not, and one that asks the
database, like `Customer`, does, in any route. `Customer?` is nil where
`Customer` would have refused, and `Result<Customer, any Error>` hands you
the error.

## OpenAPI and Swagger UI

```swift
app.openAPI(OpenAPIInfo(title: "Shop", version: "1.0.0", servers: ["https://api.example.com"]))
app.swaggerUI()                                  // /docs, reading /openapi.json

app.get("/items/:id") { (id: Path<Int>) -> JSON<Item>? in nil }
    .summary("An item by its id")
    .tags("items")
    .response(.notFound, "No item has that id")
```

The document is built from the routes: `Path<Int>` is an integer path
parameter, `Query<Page>` a query parameter per field, `Body<NewItem>` a JSON
body, `BearerToken` a security scheme, and `JSON<Item>` the 200 response, with
schemas read from the `Decodable` types. A type whose JSON its decoder does not
show conforms to `OpenAPISchemaDescribing`.

## Server-sent events

```swift
app.get("/clock") {
    EventStream(keepAlive: .seconds(15)) { events in
        var tick = 0
        while events.isOpen {
            tick += 1
            try await events.send("\(tick)", event: "tick", id: "\(tick)")
            try await events.sleep(for: .seconds(1))
        }
    }
}
```

Without `keepAlive`, the comment that keeps a proxy from closing a quiet
stream follows `--sse-keep-alive`. To send what happens in any shard to every
subscriber, publish to a `Topic`; the
[chat example](Examples/Sources/ChatExample/ChatApp.swift) shows it with
replay from `Last-Event-ID`.

## WebSockets

```swift
app.webSocket("/echo") { (ws: WebSocket) async throws in
    for try await message in ws {
        try await ws.send(message)
    }
}
```

The same route serves HTTP/1.1 upgrades and WebSockets over HTTP/2 and HTTP/3.
Extractors and middleware run before the upgrade, so a refused request is an
ordinary status. Pings, fragments and closing are handled by the engine.

## Large uploads

Every other route's body is collected whole before the handler runs, held to
`--max-body`. A body too large for memory is read as it arrives:

```swift
import VegaFS     // from the vega package

app.onStreamingBody(.put, "/backups/:name", maxBodySize: 1 << 30) { request, response, body in
    let path = "/var/backups/app/" + request.parameter(0)   // check the name first
    let file = try await File.create(path + ".partial", permissions: 0o600)
    var buffer = IOBuffer(capacity: 256 * 1024)
    var bytes = 0
    while try await body.read(into: &buffer) > 0 {     // waits for the client
        try await file.write(buffer)                   // waits for the disk
        bytes += buffer.count
        buffer.clear()
    }
    try await file.sync()
    try await FileSystem.rename(path + ".partial", to: path)
    response.send(status: .created, "\(bytes) bytes")
}
```

The client is let send more only as the handler reads, so the disk sets the
pace. A declared length past `maxBodySize` is 413 before the handler runs, and
a body that grows past it makes the read throw, which answers 413; one cut off
throws `RequestBodyError.incomplete`, a 400. The
[streaming example](Examples/Sources/StreamingExample/StreamingApp.swift)
removes the partial file when that happens.

An upload a client should be able to resume after a dropped connection speaks
the resumable upload protocol, from `GarudaUploads`:

```swift
import GarudaUploads

let store = try FileUploadStore(directory: "/var/lib/app/uploads")
app.resumableUploads("/files", store: store,
                     limits: UploadLimits(maxSize: 2 << 30, maxAge: 24 * 3600)) { upload in
    let destination = "/var/lib/app/files/" + upload.info.id
    try await FileSystem.rename(upload.path, to: destination)
    try? await upload.remove()
    return JSON(["id": upload.info.id, "bytes": "\(upload.length)"], status: .created)
}
```

A `POST` to `/files` makes an upload and tells the client its URL,
`/uploads/:id` (the `uploads:` parameter); a `HEAD` there says how much
arrived, and a `PATCH` sends the rest. A client that does not speak the
protocol sends an ordinary `POST` and never knows the difference. The closure
runs once, when the last byte is in, and what it returns is replayed to a
client that lost the answer. The [files](Examples/Sources/FilesExample/FilesApp.swift) and
[uploads](Examples/Sources/UploadsExample/UploadsApp.swift) examples add
digests, uploads per user and `onCreate`.

## The shard model

Garuda runs **a process per shard, each with several threads** that steal
work from one another. It is the one thing about the engine an application
has to hold in mind, and everything below follows from it.

### State belongs to a shard

```swift
app.state { start in
    // Runs in each shard as it starts. `start.shard.index` is 0, 1, 2 …
    PostgresPool(try PostgresConfiguration(url: databaseURL), maxConnections: 8)
} shutdown: { pool in
    pool.close()      // when that shard has drained
}

app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws in
    JSON(try await db.value.first(User.self, "select * from users where id = $1", id.value))
}
```

- **Nothing made before `run()` is shared between shards.** A dictionary
  built at start-up is copied into each shard and then goes its own way. Start
  no threads before `run()` either: a shard is forked, and Vega stops the
  program if another thread exists when it does. Start them in `app.state` or
  `onShardStart`.
- **A shard's threads share its state**, so an `app.state` value is
  `Sendable`. State that is only read needs nothing more; state that changes
  needs a lock:

  ```swift
  import Synchronization

  /// Requests per path, counted by every thread of the shard.
  final class Hits: Sendable {
      private let counts = Mutex<[String: Int]>([:])

      func count(_ path: String) -> Int {
          counts.withLock { counts in
              counts[path, default: 0] += 1
              return counts[path]!
          }
      }
  }

  app.state { _ in Hits() }
  ```

- **Pools multiply.** `maxConnections: 8` with `--shards 4` is 32
  connections. Size it against the database's limit, not against one number.
- **A factory that throws stops that shard's start-up**, and the supervisor
  starts it again with a back-off -- the right answer for a database that is
  not there yet.

### Start-up work that awaits

```swift
app.onShardStart { start in
    _ = try await start.state(PostgresPool.self).migrate(migrations)
    try await start.state(Caches.self).warm()
}
```

Runs in each shard after its state is built and **before it accepts a
connection**, so a request that arrives meanwhile waits in the backlog rather
than reaching a half-ready shard. A throw stops that shard's start-up, as a
factory's does. There is no timeout: bound slow work yourself. `app.test`
runs it too.

### Work on a timer

```swift
// Every shard: refresh what this process caches.
app.every(.seconds(300)) { shard in
    try await shard.state(Caches.self).refresh()
}

// One shard, hourly, starting a minute in: housekeeping nobody needs done
// four times over.
app.every(.seconds(3600), firstAfter: .seconds(60), onShard: 0) { shard in
    _ = try await SQLiteRefreshTokenStore(shard.state(SQLiteDatabase.self)).deleteExpired()
}
```

A job is a task on the shard's runtime, with the shard's state, from when the
shard has started until it stops. A throw is logged and the job runs again
next turn. `jitter` (a tenth of the interval by default) keeps four shards
from all querying on the same tick.

`onShard: 0` is "one shard of this server", **not** "once in the cluster":
another machine has its own shard 0, and a reload gives this one a new one.
For work that must happen once however many processes are running, take a
lock where they can all see it:

```swift
app.every(.seconds(3600), onShard: 0) { shard in
    let pool = try shard.state(PostgresPool.self)
    struct Got: Decodable { let locked: Bool }
    let got = try await pool.first(Got.self, "select pg_try_advisory_lock(42) as locked")
    guard got?.locked == true else { return }      // somebody else is on it
    do {
        try await sendTheNightlyReport(pool)
    } catch {
        AppLog.error("the nightly report failed", ["error": "\(error)"])
    }
    try await pool.execute("select pg_advisory_unlock(42)")
}
```

### News from the database

```swift
// Every shard hears it, on a connection of its own.
app.listen("jobs", whenListening: { shard in
    // Listening has just started, on the first connection or after a
    // reconnection: pick up whatever was sent while there was no listener.
    try await claimWaitingJobs(shard.state(PostgresPool.self))
}) { notification, shard in
    try await runJob(notification.payload, shard.state(PostgresPool.self))
}
```

A throw from the handler is logged and the next notification is handled as
usual; a connection that goes is logged and made again with the same channels.
Sending is the other half, and belongs with the work it is news of:

```swift
// Sent when, and only when, the transaction that wrote the row commits.
try await pool.transaction { tx in
    try await tx.execute("insert into jobs (payload) values ($1)", payload)
    try await tx.notify("jobs", payload)
}
```

`NOTIFY` reaches other machines, which a `Topic` does not. The server keeps
nothing for a session that is not connected, so a notification is news, not a
queue: `whenListening` is where the queue is read, and the payload -- under
8,000 bytes, or the server refuses it -- says only what to look at.

### What every shard must see

State that has to be shared does not live in a process:

| To share | Use |
|---|---|
| events (a chat message, an invalidation) | `Topic`, which reaches every shard through shared memory |
| news from another machine | PostgreSQL `LISTEN`/`NOTIFY`, through `app.listen` |
| sessions and refresh tokens | Redis, PostgreSQL or SQLite; Garuda's stores for each |
| request rates | `--rate-limit`, counted across shards already |
| counters worth scraping | `--metrics-port`, which aggregates across shards |
| anything durable | the database |

```swift
// Heard by subscribers in every shard, not only this one.
let topic = Topic("room:42")
_ = try topic.publish("ada joined")
```

### Blocking work

A shard's threads serve every connection the shard has. Work that **blocks**
its thread without computing -- a C library that waits on the network or a
lock, a synchronous file read, waiting for another program -- takes the
thread from every request it could be serving. Vega's blocking pool has
threads for that:

```swift
import Vega

app.post("/hash") { (body: Body<Credentials>) async throws -> HTTPStatus in
    let hash = try await Runtime.blocking { try expensiveHash(body.value.password) }
    …
}
```

`Passwords.hash` and `Passwords.verify` already do this, and VegaFS does it
for the file system. `--blocking-threads` sizes the pool, and
`--blocking-queue` bounds what may wait for it: `Runtime.blocking` waits
whatever the queue, and `Runtime.tryBlocking` returns nil when it is full,
for a handler to answer with `throw BlockingQueueFull()` (503).

A route whose whole handler is the blocking work can say so where it is
declared instead:

```swift
app.offload.post("/thumbnail") { (form: Multipart) throws -> Bytes in
    guard let image = form.file("image") else { throw HTTPError(.badRequest, "send an image") }
    return Bytes(resize(image.bytes), contentType: "image/png")
}
```

The extractors are taken on the shard's thread, the handler runs on the
blocking pool, and what it returns is written back on the shard, which serves
other requests meanwhile. An offloaded handler is synchronous -- it cannot
`await` the database, Redis or the HTTP client -- and what it takes and
returns must be `Sendable`. A handler that blocks *and* queries keeps the
query in an ordinary async route and wraps only the blocking part in
`Runtime.blocking { }`.

Work that **computes** for long belongs to the heavy lane, not the pool. A
route whose handler holds its thread for more than `--heavy-threshold`
(500 µs) on average runs on at most half the shard's threads, so quick
requests always have the rest. A handler that computes between awaits is not
measured that way, and is declared with `app.heavy.get(…)` and the rest.

Waiting on another program is blocking work too: `Process.waitUntilExit()`, or
`waitpid` after `posix_spawn`, holds a shard's thread until the program
exits. Launch and wait inside `Runtime.blocking { }`, and do not put a lock of
your own around it: a global lock makes three uploads that finish together
queue behind one another.

```swift
app.resumableUploads("/photos", store: store) { upload in
    // Decoded once, in this process, and both sizes made from that copy.
    // Four programs per photo -- two resizes that each decode it again, then
    // `identify` and `exiftool` -- took seconds on two vCPUs.
    let path = upload.path
    let (small, large) = try await Runtime.blocking {
        let photo = try Photo(decodingFileAt: path)
        return (try photo.resized(to: 400), try photo.resized(to: 1600))
    }
    …
}
```

Better still is not to launch anything. An image library linked into the
server -- libvips, or libjpeg-turbo and libexif directly -- decodes the file
once and reads its EXIF from the same bytes; a program started per request
pays its own start-up (Perl's, for `exiftool`) and decodes the image again
each time.

### Shutting down

```swift
app.state { _ in try Connection(to: broker) } shutdown: { $0.close() }
app.onShardStop { stop in AppLog.info("shard \(stop.shard.index) is done") }
```

`SIGTERM` drains: each shard stops accepting, finishes what is in flight
(`--graceful-timeout`, 10 s), stops its scheduled jobs, runs its `onShardStop`
hooks newest first, then shuts its state down. `--drain-delay` holds the
listener open for a load balancer to notice first. `SIGHUP` replaces the
shards one at a time -- each is stopped, then started again -- which is how a
new binary goes out; the server runs one shard short during each step.

### One-off commands

```swift
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Garuda
import GarudaPostgres
import Vega

let arguments = CommandLine.arguments
switch arguments.dropFirst().first ?? "serve" {
case "migrate":
    // One-off work, on a runtime of its own, with no server.
    let runtime = Runtime(workers: 1)
    try runtime.block {
        let pool = PostgresPool(try PostgresConfiguration(url: databaseURL))
        _ = try await pool.migrate(migrations)
        pool.close()
    }
    exit(0)
case "serve":
    var flags = Array(arguments.dropFirst(2))
    if flags.first == "--" { flags.removeFirst() }
    app.run(arguments: [arguments[0]] + flags)
default:
    exit(64)
}
```

For a `migrate`, a backfill or a seed: the work runs on a Vega runtime of its
own, which the database drivers need, and nothing listens.
`app.run(arguments:)` takes an `argv`, program name first, so
`myapp serve -- --port 8080` hands Garuda only its own flags. On macOS a shard
is a new run of the executable with the same arguments, so `main` must reach
`app.run` the same way each time. The
[starter](Examples/Sources/starter/main.swift) has `migrate`, `env` and
`serve`.

## Settings from the environment

```swift
struct Settings {
    let databaseURL: String
    let signingKey: String
    let poolSize: Int
    let signUpsOpen: Bool
}

func settings() throws -> Settings {
    var env = AppEnvironment()
    let production = env.mode == .production        // APP_ENV
    let settings = Settings(
        // A default in development; required in production.
        databaseURL: env.url("DATABASE_URL", default: production ? nil : "postgres://localhost/dev"),
        // JWT_PRIVATE_KEY, or the contents of the file JWT_PRIVATE_KEY_FILE names.
        signingKey: env.secretOrFile("JWT_PRIVATE_KEY", default: production ? nil : ""),
        poolSize: env.int("DATABASE_POOL_SIZE", default: 8, in: 1...500),
        signUpsOpen: env.bool("SIGNUPS_OPEN", default: true))
    if production && settings.signUpsOpen && settings.databaseURL.isEmpty {
        env.problem("SIGNUPS_OPEN cannot be on with no database")
    }
    try env.check()          // throws once, listing every problem
    return settings
}
```

Every reader answers with something usable and records what was wrong, so
`check()` reports the lot: a missing secret and a mistyped number are one
restart, not two. `env.summary()` is what a `myapp env` command prints, with
secrets held back and passwords taken out of URLs. Read the settings before
`app.run()`, so every shard has them. Garuda's own settings stay on the
command line; [CONFIG.md](CONFIG.md) has the readers and the flags.

## Testing

```swift
// Package.swift: the test target depends on .product(name: "GarudaTesting", package: "garuda")
import Testing
import GarudaTesting

@Test func itemsAreCreated() throws {
    let app = shopApp(databasePath: ":memory:")
    // What the routes cannot do, before a request asks: a handler taking more
    // path parameters than its pattern has, or a State nothing registers.
    #expect(app.problems().isEmpty, "\(app.problems())")

    let client = app.test
    let created = try client.post("/items", json: NewItem(name: "pen", price: 1.5))
    #expect(created.status == .created)
    #expect(try created.json(Item.self).name == "pen")
    #expect(try client.get("/items/99").status == .notFound)
}
```

`app.test` runs the application in the test process -- its state, its
`onShardStart` hooks, and requests through the real HTTP/1.1 connection over
an in-memory stream -- with no port to open. `app.test.http2()` does the same
over HTTP/2.

`post`, `put` and `patch` take `json:` and encode it with the coder the server
decodes with, so a test sends what a client of the API would rather than a
string somebody keeps in step by hand; `body:` still takes a `String` or bytes
for a request that is meant to be malformed. `response.json(T.self)` reads the
answer back.

An application whose clients are generated from its OpenAPI document has one
more thing worth asserting:

```swift
#expect(app.documentProblems(OpenAPIInfo(title: "Shop", version: "1")).isEmpty)
```

which names a schema read from a type whose decoding stopped early -- so the
schema may be missing what came after -- and two routes sharing an
`operationID`.

## Running in production

```bash
.build/release/shop \
  --port 443 --tls-cert fullchain.pem --tls-key privkey.pem --http3 \
  --compress --rate-limit 100/s \
  --access-log --log-format json --request-id \
  --health-check-path /healthz --metrics-port 9100
```

On Linux the default, `--shards auto`, sizes the server from the machine's
CPUs; `--shards N` sets the count, and `--shards 0` serves in one process.
Behind a proxy, add `--forwarded-allow-ips` with the proxy's addresses so
client addresses and HTTPS are read from its headers. Garuda 2 has no ACME
client of its own: get the certificate with certbot or another ACME client,
answer its HTTP-01 challenges with `--redirect-http 80 --acme-webroot DIR`,
and pick up renewals with `--tls-reload` or `SIGHUP`.
[INSTALLATION.md](INSTALLATION.md) and [DEPLOYMENT.md](DEPLOYMENT.md) cover
certificates and deployment.

# Examples

Two kinds of example: four runnable applications in [Examples/](Examples/),
and short recipes for common tasks below. Every recipe uses the public API and
compiles as written. For flags, see [CONFIG.md](CONFIG.md); for middleware in
depth, [MIDDLEWARE.md](MIDDLEWARE.md).

- [Runnable applications](#runnable-applications)
- Recipes: [a first server](#a-first-server) ·
  [a JSON API](#a-json-api) · [errors](#errors) ·
  [groups and routers](#groups-and-routers) · [a database](#a-database) ·
  [sign-in with sessions](#sign-in-with-sessions) ·
  [an extractor of your own](#an-extractor-of-your-own) ·
  [OpenAPI and Swagger UI](#openapi-and-swagger-ui) ·
  [server-sent events](#server-sent-events) · [WebSockets](#websockets) ·
  [the per-worker model](#the-per-worker-model) ·
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
| [Auth](Examples/Sources/AuthExample/AuthApp.swift) | Sign-up, login and logout: PBKDF2 password hashes on the blocking pool, random tokens stored as digests, `authenticate(bearer:state:)`, and `SignedInUser`, an async extractor | `curl -s localhost:8080/signup -d '{"username":"ada","password":"correct horse"}'` |
| [Streaming](Examples/Sources/StreamingExample/StreamingApp.swift) | `EventStream`, a CSV export written as it is produced with backpressure, uploads written to disk as they arrive | `curl -N localhost:8080/countdown?from=5` |
| [Chat](Examples/Sources/ChatExample/ChatApp.swift) | Rooms over WebSockets and server-sent events, heard across every worker through `Topic`, with replay for reconnecting clients | `swift run chat -- --workers 4`, then open two browser windows |
| [Starter](Examples/STARTER.md) | A whole application: PostgreSQL, accounts with JWT access and refresh tokens, migrations, settings from the environment, a cleanup job, OpenAPI, health and readiness, a deployment recipe | `swift run starter serve -- --port 8080` |

Each example is a library target with one function that builds the
`Application`, plus a `main.swift` that runs it. The tests call the same
function, so they exercise exactly the routes the executable serves.
[Examples/README.md](Examples/README.md) has notes for copying them.

## A first server

```swift
// Package.swift: .package(url: "https://github.com/grepjava/garuda", branch: "main")
// Sources/hello/main.swift
import Glibc   // Darwin on macOS
import Garuda

let app = Application()
app.get("/") { "Hello, world" }
app.get("/hello/:name") { (name: Path<String>) in "Hello, \(name.value)" }
exit(app.run())
```

```bash
swift run -c release hello -- --port 8080 --workers 4
```

`app.run()` reads Garuda's command-line flags. `app.run(configuration:)` takes
a `ServerConfig` instead.

## A JSON API

```swift
struct Item: Codable {
    let id: Int
    let name: String
    let price: Double
}
struct NewItem: Decodable {
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

A closure without `async` runs directly on the worker thread; one that awaits
runs on a task the worker keeps. A body or query that does not decode is a
400 saying which key was wrong.

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

## Groups and routers

```swift
let v1 = Router()
v1.get("/status") { JSON(["ok": true]) }
v1.group("/admin") {
    v1.use { request, _ in request.header("x-admin") == nil ? HTTPStatus.forbidden : nil }
    v1.get("/stats") { "stats" }
}

app.nest("/api/v1", v1)            // /api/v1/status, /api/v1/admin/stats
app.fallback { _, response in response.send(status: .notFound, "no such page") }
```

A group's middleware covers only its routes, and a path routed for other
methods is a 405 with `Allow`.

## A database

```swift
// SQLite: every worker opens the same file.
app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "shop.db"))
    try db.migrate(["create table items (id integer primary key, name text not null, price real not null)"])
    return db
}

// PostgreSQL: a pool per worker.
app.state { _ in
    PostgresPool(PostgresConfiguration(host: "db.internal", user: "shop", password: "secret", database: "shop"))
}
app.get("/count") { (db: State<PostgresPool>) async throws -> String in
    struct Count: Decodable { let n: Int }
    return "\(try await db.value.first(Count.self, "select count(*)::int as n from items")?.n ?? 0)"
}
```

`app.state` runs in each worker after the fork, so a connection is never
shared across processes. Rows decode into `Decodable` types by column name.
Redis works the same way, with `RedisPool`.

## Sign-in with sessions

```swift
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
before answering.

## An extractor of your own

```swift
struct ApiKey: RequestExtractor {
    let value: String

    static func extract(from request: borrowing Request, parameter: inout Int) throws -> ApiKey {
        guard let key = request.header("x-api-key") else { throw HTTPError.unauthorized }
        return ApiKey(value: key)
    }
}

struct Customer: AsyncRequestExtractor {
    let id: Int

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Customer {
        let key = try ApiKey.extract(from: request, parameter: &parameter)   // read the request first
        let db = try request.state(SQLiteDatabase.self)
        struct Row: Decodable { let id: Int }
        guard let row = try await db.first(Row.self, "select id from customers where api_key = ?", key.value) else {
            throw HTTPError.unauthorized
        }
        return Customer(id: row.id)
    }
}

app.get("/orders/mine") { (customer: Customer) async in "orders of \(customer.id)" }
app.get("/offers") { (customer: Customer?) async in customer == nil ? "public offers" : "your offers" }
```

An `AsyncRequestExtractor` needs an async handler; registering a synchronous
one stops the program at start-up. `Customer?` is nil where `Customer` would
have refused, and `Result<Customer, any Error>` hands you the error.

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
app.get("/clock") { () async in
    EventStream(keepAlive: 15_000) { events in
        var tick = 0
        while events.isOpen {
            tick += 1
            try await events.send("\(tick)", event: "tick", id: "\(tick)")
            try await events.sleep(milliseconds: 1000)
        }
    }
}
```

To send what happens on any worker to every subscriber, publish to a `Topic`;
the [chat example](Examples/Sources/ChatExample/ChatApp.swift) shows it with
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

## The per-worker model

Garuda runs **a process per worker, each with one thread**. It is the one thing
about the engine an application has to hold in mind, and everything below
follows from it.

### State belongs to a worker

```swift
app.state { worker in
    // Runs in each worker, after the fork. `worker` is 0, 1, 2 …
    PostgresPool(try PostgresConfiguration(url: databaseURL), maxConnections: 8)
} shutdown: { pool in
    pool.close()      // when that worker drains
}

app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws in
    JSON(try await db.value.first(User.self, "select * from users where id = $1", id.value))
}
```

- **Nothing made before `run()` is shared.** A dictionary built at start-up is
  copied into each worker by the fork and then goes its own way.
- **Nothing here needs a lock.** A worker is one thread, so a class in
  `app.state` is reached by one request at a time. (`MemorySessionStore` and
  the other in-memory stores lean on exactly this.)
- **Pools multiply.** `maxConnections: 8` with `--workers 4` is 32
  connections. Size it against the database's limit, not against one number.
- **A factory that throws stops that worker**, which the supervisor reports —
  the right answer for a database that is not there.

### Start-up work that awaits

```swift
app.prepare { start in
    try await start.state(PostgresPool.self).migrate(migrations)
    try await start.state(Caches.self).warm()
}
```

Runs in each worker after its state is built and **before its listening socket
is watched**, so a request that arrives meanwhile waits in the backlog rather
than reaching a half-ready worker. A throw, or more than
`timeoutMilliseconds` (30 s), stops that worker. `app.test` runs it too.

### Work on a timer

```swift
// Every worker: refresh what this process caches.
app.every(300) { start in
    try await start.state(Caches.self).refresh()
}

// One worker, hourly, starting a minute in: housekeeping nobody needs done
// four times over.
app.every(3600, firstAfter: 60, onWorker: 0) { start in
    try await SQLiteRefreshTokenStore(start.state(SQLiteDatabase.self)).deleteExpired()
}
```

A job runs on the worker's thread, with the worker's state, from the moment it
serves until it drains. A throw is logged and the job runs again next turn.
`jitter` (a tenth of the interval by default) keeps four workers from all
querying on the same tick.

`onWorker: 0` is "one worker of this process group", **not** "once in the
cluster": another machine has its own worker 0, and a reload gives this one a
new one. For work that must happen once however many processes are running,
take a lock where they can all see it:

```swift
app.every(3600, onWorker: 0) { start in
    let pool = try start.state(PostgresPool.self)
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

### What every worker must see

State that has to be shared does not live in a process:

| To share | Use |
|---|---|
| events (a chat message, an invalidation) | `Topic`, which reaches every worker through shared memory |
| sessions, tokens, rate limits across workers | Redis, PostgreSQL or SQLite; Garuda's stores for each |
| counters worth scraping | `--metrics-port`, which aggregates across workers |
| anything durable | the database |

```swift
// Heard by subscribers in every worker, not only this one.
let topic = Topic("room:42")
_ = try topic.publish("ada joined")
```

### Blocking work

```swift
app.post("/login") { (body: Body<Credentials>) async throws -> HTTPStatus in
    // 600,000 PBKDF2 iterations would hold the worker's one thread for a
    // few hundred milliseconds; the blocking pool has threads for that.
    let hash = try await blocking { try expensiveHash(body.value.password) }
    …
}
```

`Passwords.hash` and `Passwords.verify` already do this. Anything else that
computes for tens of milliseconds, or calls a blocking C library, belongs in
`blocking { }` — `--blocking-threads` sizes the pool.

### Shutting down

```swift
app.state { _ in try Connection(to: broker) } shutdown: { $0.close() }
app.onWorkerShutdown { worker in AppLog.info("worker \(worker) is done") }
```

`SIGTERM` drains: the worker stops accepting, finishes what is in flight
(`--graceful-timeout`, 10 s), stops its scheduled jobs, then tears down state.
`--drain-delay` holds the listener open for a load balancer to notice first.
`SIGHUP` replaces the workers one at a time without dropping a connection,
which is how a new binary goes out.

### One-off commands

```swift
// myapp migrate
try app.runOnce { start in
    try await start.state(PostgresPool.self).migrate(migrations)
}
```

A worker with no listening socket, built in this process: its state is made,
the work runs on its thread, the state is torn down. For a `migrate`, a
backfill or a seed. `app.run(arguments:)` then hands Garuda only the flags
that are Garuda's, so `myapp serve -- --port 8080` works.

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
secrets held back and passwords taken out of URLs. Garuda's own settings stay
on the command line; [CONFIG.md](CONFIG.md) has the readers and the flags.

## Testing

```swift
import Testing
import Garuda

@Test func itemsAreCreated() throws {
    let client = shopApp(databasePath: ":memory:").test
    let created = try client.post("/items", body: #"{"name":"pen","price":1.5}"#)
    #expect(created.status == .created)
    #expect(try created.json(Item.self).name == "pen")
    #expect(try client.get("/items/99").status == .notFound)
}
```

`app.test` runs the application on a real worker in the test process, through
the same engine and parser as the server, with no port to open.

## Running in production

```bash
.build/release/shop \
  --port 443 --tls-cert fullchain.pem --tls-key privkey.pem --http3 \
  --workers 8 --compress --rate-limit 100/s \
  --access-log --log-format json --request-id \
  --health-check-path /healthz --metrics-port 9100
```

Behind a proxy, add `--forwarded-allow-ips` with the proxy's addresses so
client addresses and HTTPS are read from its headers.
[INSTALLATION.md](INSTALLATION.md) covers certificates, ACME and deployment.

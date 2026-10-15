# Connectors

Garuda talks to other services through connectors: an HTTP client, PostgreSQL,
Redis and SQLite. The HTTP client is part of the `Garuda` module. The database
drivers come from [vega-db](https://github.com/grepjava/vega-db), the
database package of the Vega runtime Garuda runs on, and each one reaches an
application through a Garuda module of its own:

| Product | Re-exports | What Garuda adds |
|---|---|---|
| `GarudaPostgres` | `Garuda`, `VegaPostgres` (and with it `VegaPostgresProtocol` and `VegaDBTracing`) | `UUID` and `Timestamp` as `uuid` and `timestamptz`, `PostgresJSON<T>`, `app.listen`, `PostgresRefreshTokenStore` |
| `GarudaRedis` | `Garuda`, `VegaRedis` (and with it `VegaRedisProtocol` and `VegaDBTracing`) | `getJSON` and `setJSON`, `RedisSessionStore`, `RedisRefreshTokenStore` |
| `GarudaSQLite` | `Garuda`, `VegaSQLite` | `UUID` and `Timestamp` as columns, `SQLiteSessionStore`, `SQLiteRefreshTokenStore` |
| `GarudaSQL` | `GarudaPostgres` | The `@PostgresRow` macro |

One import is enough: `import GarudaPostgres` brings Garuda and the whole
PostgreSQL driver with it. The products are separate so that an application
builds only the drivers it imports, and `GarudaSQL` is apart from
`GarudaPostgres` because it is the only one that needs swift-syntax.

The network drivers are written in Swift and wrap no client library such as
libpq or hiredis. SQLite is the system's own library, loaded at run time.

A pool, a cluster or a database is made in `app.state`, so each shard -- a
process -- builds its own after it starts, and every worker thread in that
shard shares it. Nothing blocks a worker's thread: sockets wait on Vega's I/O,
and SQLite runs on Vega's blocking pool.

The PostgreSQL, Redis and SQLite pools wait alike. A statement waiting for a
connection is given the next one released, oldest waiter first, and a free
connection is taken at once only when nobody is queued, so a handler running
statements back to back cannot keep taking the connection it just gave back.
A queued wait ends early when its task is cancelled -- an HTTP/2 or HTTP/3
stream the client reset cancels its handler -- and throws `cancelled`. Under
`app.deadline`, a wait still queued when the deadline passes gives up as if
its own `acquireTimeout` had run out, with `poolTimedOut`, and a statement or
command waiting on its socket gives up with the driver's `timedOut`.

This file covers what each connector supports, what it does not, and the work
planned for each one. How to use them is in [README.md](README.md), and every
change is in [RELEASE.md](RELEASE.md).

| Connector | Not supported |
|---|---|
| [HTTP client](#http-client) | HTTP/3, proxies, streamed request bodies |
| [PostgreSQL](#postgresql) | Ranges and `hstore`, replica routing |
| [Redis](#redis) | Replica reads, client-side caching |
| [SQLite](#sqlite) | Interrupting a statement, backups, custom functions, tracing |

## HTTP client

`HTTPClient` is a value, made where it is needed. It speaks HTTP/1.1, and
HTTP/2 over TLS when the server chooses it over ALPN; plaintext is always
HTTP/1.1. It looks names up and races the addresses, verifies TLS
certificates against the system's trust store or the PEM file in `caFile`,
keeps connections for reuse, decodes compressed bodies and follows redirects
when a policy allows them.

```swift
var client = HTTPClient()
client.timeout = .seconds(2)
client.redirects = .sameOrigin()
let answer = try await client.get("https://api.example.com/v1/rates")
```

`get`, `head`, `post(_:body:contentType:headers:)` and
`send(_:_:headers:body:)` return a `ClientResponse` with the body read whole,
up to `maxBodyBytes` (8 MiB by default). `stream` returns as soon as the head
is in, and the body is read as it arrives with `next()`, `collect(limit:)`, or
`nextEvent()` for server-sent events:

```swift
let upstream = try await HTTPClient().stream(.get, "https://api.example.com/events")
while let event = try await upstream.nextEvent() {
    print(event.event, event.data)
}
```

`timeout` (10 seconds by default) bounds each wait: connecting, writing, or
waiting for more of the response. `totalTimeout`, nil by default, bounds the
whole exchange, redirects included; for `stream`, everything up to the head.
A route's `app.deadline` bounds a call made in its handler whatever these say.
Failures are `ClientError`.

Redirects are not followed by default (`RedirectPolicy.none`).
`.sameOrigin(limit:)`, `.any(limit:)` and `.matching(limit:_:)` follow them;
a redirect from https to http is never followed, and leaving the origin drops
`Authorization`, `Cookie` and `Proxy-Authorization`. `decompress`, on by
default, sends `Accept-Encoding` with the codings Garuda can decode and decodes
the body before returning it, held to `maxBodyBytes` as well.

Kept connections belong to the shard, in one pool shared by every task on
every worker thread. A connection is kept only when its response was read
whole; it is keyed by where it goes, the name its certificate was checked
against, the trust store and the ALPN offered; one that has something to say
before it is asked is closed rather than handed on; and one idle for 30
seconds is closed. Over HTTP/2, every request to the same origin shares one
connection, read by a task of its own.

Over HTTP/2 the client holds the server to the same rules the server holds
its clients to: a response head is limited to `maxHeadBytes` as it is
assembled and as HPACK expands it, each stream keeps its own `maxBodyBytes`,
a body that disagrees with its `Content-Length` is refused, and so are
misplaced or repeated pseudo-fields and a 101. Connection-specific headers
are refused before anything is sent, except `te: trailers`, which a caller
may send and gRPC needs.

When the application traces (`app.tracing`), each call is a client span under
the current one, and the trace is sent on in the request's headers.

### Not supported

- HTTP/3. The server speaks it, but the client does not.
- HTTP and SOCKS proxies.
- Streamed request bodies. A response can be read as it arrives, with
  `stream`; a request body is a `[UInt8]` held whole in memory.

### Future work

- HTTP/3, when a server advertises it with Alt-Svc.
- Proxies set in the configuration.
- Streamed request bodies.

## PostgreSQL

`PostgresPool` supports SCRAM-SHA-256 and TLS, which is required by default
(`PostgresConfiguration.tls` is `.require`; there is no "prefer"). MD5
authentication is refused, and a cleartext password is sent only when
`allowCleartextPassword` is set and only over TLS. The pool holds up to
`maxConnections` (8 by default) and waits up to `acquireTimeout` (the
configuration's `timeout`, 10 seconds, by default) for one. It keeps up to
`statementCacheCapacity` statements (256) prepared on each connection -- 0
for a transaction-pooling proxy such as PgBouncer -- reads values in binary,
and runs transactions that commit when their closure returns and roll back
when it throws. A transaction a statement has already failed is rolled back
and reported, even if the closure caught the error.

```swift
import GarudaPostgres

app.state { _ in PostgresPool(try PostgresConfiguration(url: databaseURL)) }
app.onShardStart { start in try await start.state(PostgresPool.self).migrate(migrations) }
```

`PostgresConfiguration(url:)` reads a `postgres://` or `postgresql://` URL and
understands `sslmode` (`require`, `verify-ca`, `verify-full` or `disable`;
`prefer` and `allow` are refused), `sslrootcert`, `connect_timeout` and a
`host` that names a unix socket. Other parameters are ignored.

`pool.migrate(_:table:)` brings a schema up to date: an ordered list that only
ever grows, each migration the statements it needs, run together in one
transaction and counted in a version table, `garuda_schema_version` by
default. Every shard calls it as it starts, from `app.onShardStart`; an
advisory lock means the first migrates and the rest wait and find nothing to
do. A database further ahead than the build is
`PostgresMigrationError.unknownSchemaVersion`, not a migration backwards.

Rows decode into `Decodable` types, a property from the column of its name.
`@PostgresRow`, from `GarudaSQL`, writes a reader for a type at compile time,
so that its rows skip `Codable`'s run-time machinery and read exactly as it
would have. `pool.rows` returns a result undecoded, and
`PostgresClientError.sqlState` is the SQLSTATE the server refused a statement
with.

Types: the integer types, `Double`, `Float`, `Bool`, `String` and `[UInt8]`
(`bytea`); with `GarudaPostgres`, Garuda's `UUID` and `Timestamp` for `uuid`
and `timestamptz`, and `PostgresJSON<T>` for `json` and `jsonb`, through
Garuda's JSON coder. vega-db adds `PostgresDate`, `PostgresTime`,
`PostgresInterval` and `PostgresNumeric` for `date`, `time`, `interval` and
`numeric`, and `PostgresUUID` and `PostgresTimestamp`, which are what
`GarudaPostgres` converts Garuda's types from. Each reads the binary form the
driver asks for and text as a fallback, and the four calendar and number
types bind as text the server accepts whatever its `DateStyle` or
`IntervalStyle` is. `numeric` is kept as its digits, so 1234.56 is 1234.56
rather than 1234.5599999999999. A type of the application's own reads from a
cell through `PostgresCellConvertible`.

An array is a Swift list: `[String]` for `text[]`, `[Int]` for `int[]`,
`[Timestamp?]` where NULLs are among the elements, and a list of any other
type the driver reads. A list binds as an array literal, so a parameter is an
array as readily as a column is:

```swift
let tags = ["swift", "http"]
try await pool.execute("insert into notes (tags) values ($1)", tags)
let notes = try await pool.query(Note.self, "select id, tags from notes where $1 = any(tags)", tag)
```

`[UInt8]` stays a `bytea` rather than a list of numbers, and `[[UInt8]]` is a
`bytea[]`. One dimension: PostgreSQL's arrays are rectangular and of any
dimension, which Swift's nested lists are not, so `{{1,2},{3,4}}` is refused
rather than flattened.

`pool.copyIn` and `pool.copyOut` are `COPY`, the protocol's own bulk path: a
million rows in without a million round trips, and a table out without holding
it in memory.

```swift
try await pool.copyIn("copy users (name, email) from stdin",
                      rows: people.map { [$0.name, $0.email] })

try await pool.copyOutRows("copy users to stdout") { row in
    try export(row)   // your own: each row is a [String?]
}
```

`rows:` and `copyOutRows` speak COPY's text format, which `PostgresCopyText`
writes and reads; the closure forms take and give bytes, so `csv` or `binary`
in the statement is yours to format. A `copyIn` whose closure throws tells the
server with `CopyFail`, which makes it keep none of what arrived. Both are on
a transaction too, where a load is part of it: there if it commits, gone if it
does not.

A composite type is a `PostgresRecord` -- its fields in order, since the wire
carries no names -- and binds back as one. An enum needs nothing of its own: it
arrives as its label, so a Swift enum backed by `String` reads it.

A server on the same machine is reached over its socket, which is how `peer`
authentication works:

```swift
PostgresConfiguration(unixSocketPath: "/var/run/postgresql", user: "app")
try PostgresConfiguration(url: "postgres://app@/shop?host=/var/run/postgresql")
```

TLS is off for a socket -- there is no network on it -- and asking for it
anyway fails to connect with `tlsUnavailable` rather than quietly going
without.

`LISTEN` and `NOTIFY` carry news from one process to the others, across
machines as well as shards. A listener holds a connection of its own, which
the pool does not count: a session that has listened is spoken to at any
moment, so it cannot be handed to the next statement.

```swift
app.listen("jobs") { notification, shard in           // in every shard
    try await runJob(notification.payload, shard.state(PostgresPool.self))
}

try await pool.transaction { tx in
    try await tx.execute("insert into jobs (payload) values ($1)", payload)
    try await tx.notify("jobs", payload)              // sent only if this commits
}
```

`app.listen(_:onShard:reconnectAfter:pool:whenListening:_:)` listens in every
shard, or only in the one `onShard` names. It takes its connection from the
state's `PostgresPool` unless `pool:` says otherwise, logs a lost connection
and makes it again with the same channels after `reconnectAfter` (one second,
with jitter). `whenListening` runs each time the channels start listening --
the place to sweep up what was sent while there was no listener, since the
server keeps nothing for a session that is not connected. A handler that
throws is logged, and the next notification is handled as usual.

`pool.listen` is the same thing without the shard around it: a
`PostgresListener` whose `next(timeout:)` waits for the next notification and
returns nil when none came in time. A payload of 8,000 bytes or more is
refused by the server, so a notification is a key, not a document.

When the application traces, every statement is a client span under the
current one, named for its first keyword, with its SQL as written and none of
its values. A pool made in `app.state` picks the shard's tracer up by itself;
`PostgresConfiguration.tracer` sets one by hand.

### Not supported

- Arrays of more than one dimension, and arrays of a type with no reader of
  its own, which are read as text.
- Ranges and `hstore`, which are read as text.
- `money`, `bit`, `tsvector`, PostGIS: text as well.
- MD5 authentication.
- SASLprep's NFKC step. The mapping step is done, so a non-ASCII space or a
  soft hyphen in a password is what the server made of it; a password holding
  a compatibility character -- a ligature, a full-width digit -- has to be in
  normal form already.
- Several hosts in one configuration, and sending reads to a replica. A pool
  talks to one server.

### Future work

- Ranges and `hstore` as Swift types.
- A list of hosts to try in order.
- Binary `COPY`, which today is bytes the caller formats.

## Redis

`RedisPool` speaks RESP3 through `HELLO` and falls back to RESP2 for servers
older than Redis 6. Valkey works the same. TLS is required by default
(`RedisConfiguration.tls` is `.require`). The driver supports ACL users
(`username`), databases other than 0, unix sockets, pipelines, transactions,
`WATCH` sessions and pub/sub, sharded pub/sub included. The pool holds up to
`maxConnections` (8) and waits up to `acquireTimeout` (the configuration's
`timeout`, 10 seconds) for one.

```swift
import GarudaRedis

app.state { _ in RedisPool(RedisConfiguration(host: "cache", password: secret)) }

app.get("/user/:id") { (id: Path<Int>, cache: State<RedisPool>) async throws -> String in
    try await cache.value.getJSON(User.self, "user:\(id.value)")?.name ?? "unknown"
}
```

A pool, a cluster, a sentinel pool and a session are each a
`RedisCommandSender`, which has the typed commands -- `get`, `getBytes`,
`set`, `del`, `exists`, `pexpire`, `pttl`, `incr`, the hash, list and set
commands, `publish` and `spublish` -- and `send` for any other command, with
an untyped `RedisValue` back. `GarudaRedis` adds `getJSON` and `setJSON`,
which keep a value as JSON through Garuda's coder. `RedisSessionStore` and
`RedisRefreshTokenStore` take any `RedisCommandSender`.

`pipeline` sends several commands in one write and returns a reply for each;
a command the server refused is an `.error` among the replies rather than a
throw. `transaction` is `MULTI`, the commands and `EXEC` in one round trip.
`session` lends one connection, for `watch`, reads, and a `transaction` that
returns nil when a watched key changed. `subscribe(channels:patterns:)` and
`subscribeSharded(channels:)` hold a connection of their own, which the pool
does not count, and return a `RedisSubscription` whose `next(timeout:)` waits
for the next message.

When the application traces, every round trip -- a command, a pipeline, a
transaction -- is a client span under the current one, named for its command
or `PIPELINE`, with none of its keys or values.

A cluster and a set of sentinels are each a type of their own, below.

### Cluster

`RedisCluster` is a pool per node and a map of which node owns which of the
16,384 slots, learned from the cluster with `CLUSTER SLOTS`. It is a
`RedisCommandSender`, so every typed command a pool has it has too, aimed at
the node that owns the key:

```swift
app.state { _ in RedisCluster(RedisConfiguration(host: "redis-1", password: secret)) }

app.get("/visits/:page") { (page: Path<String>, redis: State<RedisCluster>) async throws in
    String(try await redis.value.incr("visits:\(page.value)"))
}
```

`RedisCluster(seeds:)` takes several nodes to ask for the map, and both forms
take `maxConnectionsPerNode` (8), `acquireTimeout`, `maxAttempts` (5) and
`replay`. The map is how a command is aimed, never how correctness is decided:

- `MOVED` -- the slot has moved for good -- corrects the map and the command
  goes again to the node named.
- `ASK` -- this key has moved, the rest of the slot has not -- sends `ASKING`
  and the command to the node taking the slot on, and leaves the map alone.
- `TRYAGAIN` and `CLUSTERDOWN` are waited out and tried again, up to
  `maxAttempts`.
- A node that has gone is dropped, the map loaded from another, and the
  command sent to whoever owns the slot now -- if sending it again cannot
  repeat what it did; see [what may be sent again](#what-may-be-sent-again).

Each of these follows one command, not the batch it arrived in. A slot in the
middle of migrating answers the keys it still has and redirects the keys it
does not, so a pipeline comes back part answered and part redirected: what was
answered is kept and only what was refused goes again. A transaction is the
exception, and is treated as one thing, because a command refused while it was
being queued makes Redis abort all of it.

So a map that is out of date costs a round trip, not a wrong answer. Keys
touched together must share a slot, which a `{hash tag}` is for; `pipeline`
sends one write per slot and returns the replies in the order they were asked
for, while `transaction` and `session(for:_:)` are one node's and one slot's.
`subscribe` goes to any node, since an ordinary channel reaches the whole
cluster; `subscribeSharded` and `spublish` go to the shard that owns the
channel. `addresses` and `slotRanges` say what the map holds, and `refresh()`
loads it again on demand. Garuda's session and refresh-token stores work on a
cluster unchanged.

### Sentinel

`RedisSentinelPool` asks the sentinels where the master is, rather than being
told:

```swift
let sentinels = [RedisConfiguration(host: "s1", port: 26379),
                 RedisConfiguration(host: "s2", port: 26379)]
let server = RedisConfiguration(host: "", password: secret)   // the master's own auth and TLS
app.state { _ in
    RedisSentinelPool(RedisSentinelConfiguration(sentinels: sentinels, master: "cache",
                                                 server: server))
}
```

`server` says how to talk to the master once it is found -- its password, its
TLS, its timeouts -- and its host and port are ignored. Each sentinel's
configuration is its own, TLS included, which is required by default there
too.

The pool asks the sentinel that answered last first, and checks what it names
with `ROLE` before sending anything to it -- a sentinel can be behind and name
a node that has been demoted. A connection that goes, or a `READONLY`,
`MASTERDOWN` or `LOADING` reply -- `READONLY` is what a demoted master says to
a write -- means the master has moved: the sentinels are asked again and the
command tried on the new one, up to `maxAttempts` (4). `masterAddress` is where
it is now, and `refresh()` asks again on demand. A failover in the middle of a
`session` is reported rather than tried again, since what the session read
may be from a server that is no longer the master.

A failover can land in the middle of a pipeline, answering the commands before
it and refusing the writes after it with `READONLY`. Only the refused ones go
to the new master: a refusal is proof that the command did not run, and an
answer is proof that it did.

### What may be sent again

A retry is only safe when the client knows the command did not run. There are
two quite different failures behind one word:

- The command never reached the server -- the connection was refused, the pool
  timed out, the write failed on its first byte. Sending it again repeats
  nothing, so it is always sent again.
- The bytes went out and no reply came back. From here, the command having run
  and its reply having been lost look exactly the same. `SET` sent again is
  the same `SET`; `INCR` sent again counts twice, and a lost reply to `EXEC`
  does not mean the transaction was rolled back.

The second case throws `RedisClientError.unknownOutcome`, which wraps the
failure underneath -- `error.cause` is the `closed`, `timedOut` or
`cancelled` it happened to be, and `error.mayHaveRun` is true. Whether the
cluster or sentinel pool sends such a command again is `replay`:

```swift
RedisCluster(seed, replay: .reads)      // the default
RedisSentinelPool(configuration, replay: .anything)
```

- `.reads` -- the default -- sends commands that only read. A write whose
  outcome is unknown is reported, for the application to decide about: retry
  it, check the key, or fail the request.
- `.anything` sends everything, for a cache where doing a write twice costs
  nothing.
- `.nothing` reports every failure that happened after the bytes went out.

`RedisReads.only(_:)` is the table behind `.reads`. It names the commands the
driver's own API sends and the ones an application reaches for; anything it
does not recognise counts as a write, which is the safe way to be wrong.

`RedisPool` retries nothing at all, so it has no `replay` -- but it does throw
`unknownOutcome` for a failure after the bytes went out, and so does a session.

A batch can also fail part-way: a connection that answers the first commands
of a pipeline and then goes, a cluster pipeline whose second slot's node is
down after the first slot's has answered, a failover between one attempt and
the next. That throws `RedisClientError.incomplete(replies:_:)`. `replies` has
the answer to each command that was answered, at its place in the batch, and
nil for each that was not; the error inside is why the rest failed. Anything
answered ran or was refused, so the batch as a whole may not go again, and
`mayHaveRun` says so even when the error inside is one that never reached the
server:

```swift
do {
    let replies = try await redis.pipeline(commands)
    // ...
} catch RedisClientError.incomplete(let answered, let rest) {
    // answered[i] is nil for the commands still in question; `rest`
    // is unknownOutcome if they may have run.
}
```

A transaction is never part-answered: `MULTI`'s OK and a `QUEUED` are not
answers anyone asked for, and a transaction ran whole or not at all, so its
failure is the plain error or `unknownOutcome`. A cluster pipeline visits its
slots in the order their first command comes, so which slots were tried is
predictable.

### Not supported

- Reads from replicas. Every command goes to the master, or in a cluster to
  the node that owns the slot; `READONLY` and replica routing are not offered.
- `CLUSTER SHARDS`, which would replace `CLUSTER SLOTS` on Redis 7 and later.
- A sentinel's `+switch-master` event, which would say a failover has happened
  before a command finds out.
- Sharded pub/sub through a sentinel pool, which has no `subscribeSharded`.
- Deciding replay per command. `replay` is per pool; a caller who wants one
  `INCR` retried and another reported catches `unknownOutcome` and decides.
- Cluster commands across every node at once: `KEYS`, `SCAN`, `FLUSHALL` and
  `DBSIZE` go to one node and answer for it alone.

### Future work

- Replica reads, per command or per pool.
- Learning the other sentinels from one, with `SENTINEL sentinels`.

**Other work:**

- RESP3's streamed strings and aggregates, which the parser refuses today. No
  command the driver sends is answered with them.
- Client-side caching with `CLIENT TRACKING`. Today, a connection that turns
  tracking on is closed instead of being reused.
- More typed commands: sorted sets, streams and scripting. `send` runs any of
  them now, with untyped replies.

## SQLite

`SQLiteDatabase` loads the system's libsqlite3 at run time and runs every
statement on Vega's blocking pool. Each database has one connection that
writes and up to `maxReaders` (4 by default) that only read, in write-ahead-log
mode, shared by every worker thread of the shard that made it; in memory there
are no readers, since another connection would be another database. A
statement goes to a reader once SQLite has said, on the writer, that it cannot
write. Under `--shards` each shard opens the file for itself: SQLite's own
locks order the writers across processes, and readers go on while one writes.

```swift
import GarudaSQLite

app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "/var/lib/app/app.db"))
    try await db.migrate(migrations)
    return db
}
```

Rows decode into `Decodable` types; with `GarudaSQLite`, Garuda's `UUID` binds
as lowercase text and reads from text or a 16-byte blob, and `Timestamp` binds
as UTC text that sorts as the instants do and reads from text or an integer of
seconds. Transactions begin IMMEDIATE and hold the writer until they end.
`db.migrate(_:)` brings the schema up to date by `user_version`: each script
past the recorded version, in one transaction. `SQLiteConfiguration` sets the
mode, WAL, `synchronous`, foreign keys (on by default), `busyTimeout` (5
seconds), `acquireTimeout` (10 seconds), the statement cache, `maxRows` and
`maxResultBytes`. Opening the database blocks while the file is opened, so it
belongs in `app.state` rather than in a handler.

### Not supported

- Interrupting a statement. Once it is on a blocking thread it runs to the end,
  and a request cancelled or past its deadline meanwhile finds out when it
  returns.
- A vendored SQLite. The system's library decides the version and compile
  options: Ubuntu 24.04 has 3.45. A library built without thread support is
  refused with `SQLiteClientError.unavailable`.
- The online backup API, custom SQL functions, loadable extensions, `ATTACH`
  managed by the pool, and incremental blob I/O.
- Streaming a result. Rows are copied out whole, up to `maxRows` and
  `maxResultBytes`.
- Session settings changed by a statement. A `PRAGMA` run through the pool
  changes only the connection it happened to run on; settings belong in
  `SQLiteConfiguration`.
- Tracing. Statements are not spans; only PostgreSQL and Redis are traced.

### Future work

- Interrupting a statement with `sqlite3_interrupt` when its request is
  cancelled or its deadline passes.
- Backups with `sqlite3_backup`, run on the blocking pool.
- Custom SQL functions written in Swift.
- Returning rows a batch at a time, for results too large to copy at once.

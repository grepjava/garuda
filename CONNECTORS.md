# Connectors

Garuda talks to other services through connectors: an HTTP client, a PostgreSQL
driver and a Redis driver that run on the worker's poller, and SQLite on the
worker's blocking pool. Each one keeps its connections per worker process,
built after the fork, and none blocks a worker's thread. The network drivers
are written in Swift and wrap no client library such as libpq or hiredis;
SQLite is the system's own library, loaded at run time.

This file covers what each connector supports, what it does not, and the work
planned for each one. How to use them is in [README.md](README.md), and every
change is in [RELEASE.md](RELEASE.md).

| Connector | Status | Not supported |
|---|---|---|
| [HTTP client](#http-client) | Done | HTTP/3, proxies |
| [PostgreSQL](#postgresql) | Done | Ranges and `hstore`, replica routing |
| [Redis](#redis) | Done | Replica reads, client-side caching |
| [SQLite](#sqlite) | Done | Interrupting a statement, backups, custom functions |

## HTTP client

`request.client` speaks HTTP/1.1, and HTTP/2 over TLS when the server offers
it. It resolves names on the poller, verifies TLS certificates, keeps
connections for reuse, decodes compressed bodies and follows redirects when a
policy allows them.

### Not supported

- HTTP/3. The server speaks it, but the client does not.
- HTTP and SOCKS proxies.

### Future work

- HTTP/3, when a server advertises it with Alt-Svc.
- Proxies set in the configuration.
- Streamed request and response bodies. Today the client holds a whole body in
  memory, up to `maxBodyBytes`.

## PostgreSQL

The driver supports SCRAM-SHA-256 and TLS, which is required by default. It
pools connections with an acquire timeout, keeps statements prepared on each
connection, reads values in binary, and runs transactions that roll back when
their closure throws.

`pool.migrate([[String]])` brings a schema up to date: an ordered list that
only ever grows, each migration the statements it needs, run together in one
transaction and counted in a version table. Every worker calls it as it starts, from `app.prepare`;
an advisory lock means the first migrates and the rest wait and find nothing to
do.

```swift
app.state { _ in PostgresPool(try PostgresConfiguration(url: databaseURL)) }
app.prepare { start in try await start.state(PostgresPool.self).migrate(migrations) }
``` A database further ahead than the build is `unknownSchemaVersion`, not a
migration backwards.

Types: `Int`, `Double`, `Bool`, `String`, `[UInt8]` (bytea), `UUID` and
`Timestamp` (timestamptz), and `PostgresDate`, `PostgresTime`,
`PostgresInterval`, `PostgresNumeric` and `PostgresJSON<T>` for `date`,
`time`, `interval`, `numeric` and `json`/`jsonb`. Each reads the binary form
the driver asks for and text as a fallback, and binds as text the server
accepts whatever its `DateStyle` or `IntervalStyle` is. `numeric` is kept as
its digits, so 1234.56 is 1234.56 rather than 1234.5599999999999.

An array is a Swift list: `[String]` for `text[]`, `[Int]` for `int[]`,
`[Timestamp?]` where NULLs are among the elements, and a list of any other
type the driver reads. A list binds as an array literal, so a parameter is an
array as readily as a column is:

```swift
try await pool.execute("insert into notes (tags) values ($1)", ["swift", "http"])
try await pool.query(Note.self, "select id, tags from notes where $1 = any(tags)", tag)
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
    try file.write(row)
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
anyway is refused rather than quietly gone without.

`LISTEN` and `NOTIFY` carry news from one process to the others, across
machines as well as workers. A listener holds a connection of its own, which
the pool does not count: a session that has listened is spoken to at any
moment, so it cannot be handed to the next statement.

```swift
app.listen("jobs") { notification, start in          // in every worker
    try await runJob(notification.payload, start.state(PostgresPool.self))
}

try await pool.transaction { tx in
    try await tx.execute("insert into jobs (payload) values ($1)", payload)
    try await tx.notify("jobs", payload)             // sent only if this commits
}
```

`app.listen` reconnects with the same channels when the server restarts, and
`whenListening:` runs each time they start listening -- the place to sweep up
what was sent while there was no listener, since the server keeps nothing for
a session that is not connected. `pool.listen` is the same thing without the
worker around it: a `PostgresListener` whose `next(timeoutMilliseconds:)`
waits for the next notification. A payload of 8,000 bytes or more is refused
by the server, so a notification is a key, not a document.

### Not supported

- Arrays of more than one dimension, and arrays of a type with no reader of
  its own, which are read as text.
- Ranges and `hstore`, which are read as text.
- `money`, `bit`, `tsvector`, PostGIS: text as well.
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

The driver speaks RESP3 through `HELLO` and falls back to RESP2 for servers
older than Redis 6. Valkey works the same. TLS is required by default. The
driver supports ACL users, databases other than 0, unix sockets, pipelines,
transactions, `WATCH` sessions and pub/sub, sharded pub/sub included. A
cluster and a set of sentinels are each a type of their own, below.

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

The map is how a command is aimed, never how correctness is decided:

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
for, while `transaction` and `session(for:)` are one node's and one slot's.
`subscribe` goes to any node, since an ordinary channel reaches the whole
cluster; `subscribeSharded` and `spublish` go to the shard that owns the
channel. Garuda's session and refresh-token stores work on a cluster
unchanged.

### Sentinel

`RedisSentinelPool` asks the sentinels where the master is, rather than being
told:

```swift
let sentinels = [RedisConfiguration(host: "s1", port: 26379),
                 RedisConfiguration(host: "s2", port: 26379)]
app.state { _ in
    RedisSentinelPool(RedisSentinelConfiguration(sentinels: sentinels, master: "cache",
                                                 server: server))
}
```

It asks the sentinel that answered last first, and checks what it names with
`ROLE` before sending anything to it -- a sentinel can be behind and name a
node that has been demoted. A connection that goes, or a `READONLY` reply,
which is what a demoted master says to a write, means the master has moved:
the sentinels are asked again and the command tried on the new one, up to
`maxAttempts`. `masterAddress` is where it is now, and `refresh()` asks again
on demand.

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
failure underneath -- `error.cause` is the `closed` or `timedOut` it happened
to be, and `error.mayHaveRun` is true. Whether the cluster or sentinel pool
sends such a command again is `replay`:

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
    replies = try await redis.pipeline(commands)
} catch let error as RedisClientError {
    if case .incomplete(let answered, let rest) = error {
        // answered[i] is nil for the commands still in question; `rest`
        // is unknownOutcome if they may have run.
    }
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
statement on the worker's blocking pool. Each worker has one connection that
writes and up to four that read, in write-ahead-log mode. It decodes rows into
`Decodable` types, runs transactions that begin IMMEDIATE, and migrates the
schema by `user_version`.

### Not supported

- Interrupting a statement. Once it is on a blocking thread it runs to the end,
  and a request cancelled or past its deadline meanwhile finds out when it
  returns.
- A vendored SQLite. The system's library decides the version and compile
  options: Ubuntu 24.04 has 3.45. A library
  built without thread support is refused.
- The online backup API, custom SQL functions, loadable extensions, `ATTACH`
  managed by the pool, and incremental blob I/O.
- Streaming a result. Rows are copied out whole, up to `maxRows` and
  `maxResultBytes`.
- Session settings changed by a statement. A `PRAGMA` run through the pool
  changes only the connection it happened to run on; settings belong in
  `SQLiteConfiguration`.

### Future work

- Interrupting a statement with `sqlite3_interrupt` when its request is
  cancelled or its deadline passes.
- Backups with `sqlite3_backup`, run on the blocking pool.
- Custom SQL functions written in Swift.
- Returning rows a batch at a time, for results too large to copy at once.

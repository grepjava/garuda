# Examples

> **Not yet ported to Garuda 2: `files` and `uploads`.** Both need
> `GarudaUploads`, which Garuda 2 does not have yet. Their sources stay in
> `Sources/FilesExample`, `Sources/UploadsExample`, `Sources/files`,
> `Sources/uploads` and `Tests/ExampleTests/{Files,Uploads}Tests.swift`, outside
> every target, until it does.

Six applications built on Garuda's public API. Five are small enough to read
in one sitting, each showing one thing; the starter shows the shape of a whole
application and is the one to copy when beginning. They build against the
Garuda checkout this directory sits in.

| Example | Run | What it shows |
|---|---|---|
| [Todo](Sources/TodoExample/TodoApp.swift) | `swift run todo` | A JSON CRUD API on SQLite (`GarudaSQLite`): typed routes, validation answered as 422 and 409, migrations, paging |
| [Auth](Sources/AuthExample/AuthApp.swift) | `swift run auth` | Sign-up, login and logout: PBKDF2 password hashes, random session tokens stored as digests, `authenticate(bearer:state:)`, an extractor of its own that awaits |
| [Streaming](Sources/StreamingExample/StreamingApp.swift) | `swift run streaming` | Server-sent events, a CSV export written as it is produced, and uploads written to disk by an offloaded route with a body limit of its own |
| [Chat](Sources/ChatExample/ChatApp.swift) | `swift run chat` | Rooms over WebSockets and server-sent events, heard across every shard through `Topic` |
| [WebTransport](Sources/WebTransportExample/WebTransportApp.swift) | `swift run webtransport -- --tls-cert cert.pem --tls-key key.pem` | A network probe over HTTP/3: datagram round trips, download and upload throughput on streams, a stream the server opens, an extractor that refuses a session before it starts, and a browser page that trusts a self-signed certificate by its hash |
| [**Starter**](STARTER.md) | `swift run starter` | A whole application on PostgreSQL (`GarudaPostgres`): accounts with JWT access and refresh tokens, roles and admin-only routes, input rules answered as 422, migrations, configuration from the environment, OpenAPI, health and readiness, and a deployment recipe |

```bash
cd Examples
swift run chat -- --port 8080 --shards 4      # then open http://localhost:8080
swift test                                    # every example, through app.test

createdb starter
DATABASE_URL='postgres://you@127.0.0.1:5432/starter?sslmode=disable' \
    swift run starter serve -- --port 8080    # then open http://localhost:8080/docs
```

The starter has its own guide, [STARTER.md](STARTER.md): its layout,
configuration, migrations, the per-shard model, and how to deploy it. Its
database tests run against the PostgreSQL in `GARUDA_POSTGRES`, as Garuda's
own do, and are skipped without it.

Everything after `--` is Garuda's own flags ([CONFIG.md](../CONFIG.md)): TLS,
HTTP/3, shards and threads, compression, rate limits. Each `main.swift` has
`curl` commands to try.

## How each one is laid out

An example is a library target with one function that builds its
`Application`, and an executable whose `main.swift` calls it and runs it:

```swift
// Sources/todo/main.swift
todoApp(databasePath: path).run()
```

The function is what the tests call, so the tests exercise exactly the routes
the executable serves, through the real engine. Configuration an application
reads from its environment (a database path, a directory) is read in
`main.swift` and passed in.

The package depends on Garuda's products -- `Garuda`, and `GarudaSQLite`,
`GarudaPostgres` and `GarudaTesting` where an example needs them -- and on
Vega, the runtime Garuda is built on, for two things Garuda does not export:
SHA-256 (`VegaCrypto`, in the webtransport example) and a runtime for work
outside the server (`Vega`, in the starter's `withServices`).

## Notes for copying

- **State is per shard.** Garuda runs a process per shard, and each shard
  serves on several threads. `app.state` builds a database handle in each
  shard as it starts; nothing made before `run()` is shared between them, and
  what a shard's threads share is `Sendable`. What every shard must see lives
  outside the process: the SQLite file, a `Topic`.
- **SQLite with several shards** works: each shard has its own connections to
  the same file, in write-ahead-log mode, and writes wait for each other. For
  more write traffic than one file takes, use PostgreSQL; the handler code
  looks the same.
- **Passwords cost CPU on purpose.** The auth example hashes with 600,000
  iterations on Vega's blocking pool. Run it with `--rate-limit`, and behind
  TLS.
- **Blocking work goes off the shard's threads.** The streaming example's
  upload routes are `app.offload.put` and `app.offload.get`: their handlers
  block on the file system, so they run on the blocking pool.
- **Uploads** in the streaming example go to a partial file that is renamed
  when complete, and are limited in size per route with `maxBodySize`. Garuda
  2 reads a request body whole before the handler runs, so the limit is also
  what an upload may hold in memory. Serve the directory with a separate
  route or `--static-dir` if they should be downloadable.
- **WebTransport needs HTTP/3**, and so TLS. A browser trusts a self-signed
  certificate over WebTransport only through `serverCertificateHashes`, and
  only an ECDSA one valid for at most 14 days; the webtransport example's
  `main.swift` has the `openssl` line. A session lives on one shard, so
  sessions that must hear each other need something outside the shard to
  carry it, as the chat example does with `Topic`.

# Examples

Eight applications built on Garuda's public API. Seven are small enough to read
in one sitting, each showing one thing; the starter shows the shape of a whole
application and is the one to copy when beginning. They build against the
Garuda checkout this directory sits in.

| Example | Run | What it shows |
|---|---|---|
| [Todo](Sources/TodoExample/TodoApp.swift) | `swift run todo` | A JSON CRUD API on SQLite: typed routes, validation answered as 422 and 409, migrations, paging |
| [Auth](Sources/AuthExample/AuthApp.swift) | `swift run auth` | Sign-up, login and logout: PBKDF2 password hashes, random session tokens stored as digests, `authenticate(bearer:state:)` |
| [Streaming](Sources/StreamingExample/StreamingApp.swift) | `swift run streaming` | Server-sent events, a CSV export written as it is produced, uploads written to disk as they arrive |
| [Chat](Sources/ChatExample/ChatApp.swift) | `swift run chat` | Rooms over WebSockets and server-sent events, heard across every worker through `Topic` |
| [Files](Sources/FilesExample/FilesApp.swift) | `swift run files` | Uploads that survive a dropped connection and downloads that resume: the resumable upload protocol, size limits at both ends, digests, and `--static-dir` serving the store with byte ranges and a listing |
| [Uploads](Sources/UploadsExample/UploadsApp.swift) | `swift run uploads` | Per-user photo uploads: resumable uploads inside `group("/users/:user")`, bearer tokens guarding the upload's own URL, `onCreate` recording whose upload it is, image types checked from the bytes, digests hashed off the worker, and an answer replayed with its `Location` |
| [WebTransport](Sources/WebTransportExample/WebTransportApp.swift) | `swift run webtransport -- --tls-cert cert.pem --tls-key key.pem` | A network probe over HTTP/3: datagram round trips, download and upload throughput on streams, a stream the server opens, an extractor that refuses a session before it starts, and a browser page that trusts a self-signed certificate by its hash |
| [**Starter**](STARTER.md) | `swift run starter` | A whole application: PostgreSQL, accounts with JWT access and refresh tokens, roles and admin-only routes, input rules answered as 422, migrations, configuration from the environment, OpenAPI, health and readiness, and a deployment recipe |

```bash
cd Examples
swift run chat -- --port 8080 --workers 4     # then open http://localhost:8080
swift test                                    # every example, through app.test

createdb starter
DATABASE_URL='postgres://you@127.0.0.1:5432/starter?sslmode=disable' \
    swift run starter serve -- --port 8080    # then open http://localhost:8080/docs
```

The starter has its own guide, [STARTER.md](STARTER.md): its layout,
configuration, migrations, the per-worker model, and how to deploy it.

Everything after `--` is Garuda's own flags ([CONFIG.md](../CONFIG.md)): TLS,
HTTP/3, workers, compression, rate limits. Each `main.swift` has `curl`
commands to try.

## How each one is laid out

An example is a library target with one function that builds its
`Application`, and an executable whose `main.swift` calls it and runs it:

```swift
// Sources/todo/main.swift
exit(todoApp(databasePath: path).run())
```

The function is what the tests call, so the tests exercise exactly the routes
the executable serves, through the real engine. Configuration an application
reads from its environment (a database path, a directory) is read in
`main.swift` and passed in.

## Notes for copying

- **State is per worker.** Garuda runs a process per worker. `app.state`
  builds a database handle in each one after the fork; nothing made before
  `run()` is shared between them. What every worker must see lives outside the
  process: the SQLite file, a `Topic`.
- **SQLite with several workers** works: each worker has its own connections
  to the same file, in write-ahead-log mode, and writes wait for each other.
  For more write traffic than one file takes, use PostgreSQL; the handler code
  looks the same.
- **Passwords cost CPU on purpose.** The auth example hashes with 600,000
  iterations on the blocking pool. Run it with `--rate-limit`, and behind TLS.
- **Uploads** in the streaming example go to a partial file that is renamed
  when complete, and are limited in size per route. Serve the directory with a
  separate route or `--static-dir` if they should be downloadable.
- **Whose upload it is** belongs in `onCreate`, as the uploads example does.
  The request that completes a resumable upload is a later one, and its
  headers are the client's to choose; what `onCreate` returns is the server's.
  Check a file's type from its bytes, and serve it with the type you checked.
- **WebTransport needs HTTP/3**, and so TLS. A browser trusts a self-signed
  certificate over WebTransport only through `serverCertificateHashes`, and
  only an ECDSA one valid for at most 14 days; the webtransport example's
  `main.swift` has the `openssl` line. A session lives on one worker, so
  sessions that must hear each other need something outside the worker to
  carry it, as the chat example does with `Topic`.

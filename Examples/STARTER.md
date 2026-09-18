<p align="center">
  <img src="../assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# The starter application

Accounts and notes on PostgreSQL: configuration read from the environment,
migrations, JWT access tokens with rotating refresh tokens, cursor paging,
OpenAPI, health and readiness, tests, and a deployment recipe.

It is meant to be **copied**. The four other examples each show one thing; this
one shows the shape of a whole application, so the structure is the point as
much as the code.

```bash
cd Examples
createdb starter
export DATABASE_URL='postgres://garuda:secret@127.0.0.1:5432/starter?sslmode=disable'

swift run starter env              # what the environment says
swift run starter migrate          # apply migrations and exit
swift run starter serve -- --port 8080   # serve
```

```bash
curl -s localhost:8080/auth/signup -d '{"email":"ada@example.com","password":"correct horse"}'
TOKENS=$(curl -s localhost:8080/auth/login -d '{"email":"ada@example.com","password":"correct horse"}')
ACCESS=$(printf '%s' "$TOKENS" | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
REFRESH=$(printf '%s' "$TOKENS" | sed 's/.*"refresh_token":"\([^"]*\)".*/\1/')

curl -s localhost:8080/notes -H "authorization: Bearer $ACCESS" -d '{"title":"First","body":"hello"}'
curl -s "localhost:8080/notes?limit=20" -H "authorization: Bearer $ACCESS"
curl -s localhost:8080/auth/refresh -d "{\"refresh_token\":\"$REFRESH\"}"
curl -s localhost:8080/auth/logout  -d "{\"refresh_token\":\"$REFRESH\"}" -o /dev/null -w '%{http_code}\n'
```

Open <http://localhost:8080/docs> for Swagger UI over the generated document.

## The routes

| Method | Path | Needs | Answers |
|---|---|---|---|
| `POST` | `/auth/signup` | | 201 the account, 409 taken, 422 invalid, 403 closed |
| `POST` | `/auth/login` | | 200 a token pair, 401 |
| `POST` | `/auth/refresh` | | 200 a new pair, 400 `invalid_grant` |
| `POST` | `/auth/logout` | | 204, and safe to repeat |
| `POST` | `/auth/logout-all` | access token | 204 |
| `GET` | `/auth/me` | access token | 200 the account |
| `GET` | `/notes?limit=&before=` | access token | 200 a page, newest first |
| `POST` | `/notes` | access token | 201 the note, 422 |
| `GET` | `/notes/:id` | access token | 200, 404 |
| `PATCH` | `/notes/:id` | access token | 200, 404, 422 |
| `DELETE` | `/notes/:id` | access token | 204, 404 |
| `GET` | `/health` | | 200 always, while the process runs |
| `GET` | `/ready` | | 200, or 503 when the database does not answer |
| `GET` | `/docs`, `/docs/openapi.json` | | the API, documented |

## How it is laid out

| File | What lives there |
|---|---|
| [Configuration.swift](Sources/StarterExample/Configuration.swift) | every environment variable, read and checked once |
| [Services.swift](Sources/StarterExample/Services.swift) | what a worker holds: pool, keys, token issuer |
| [Schema.swift](Sources/StarterExample/Schema.swift) | migrations, append-only |
| [Accounts.swift](Sources/StarterExample/Accounts.swift) | sign-up, login, refresh, logout |
| [Notes.swift](Sources/StarterExample/Notes.swift) | what an account owns |
| [StarterApp.swift](Sources/StarterExample/StarterApp.swift) | the application: state, start-up, middleware, routes |
| [starter/main.swift](Sources/starter/main.swift) | `serve`, `migrate` and `env` |
| [StarterTests.swift](Tests/ExampleTests/StarterTests.swift) | the whole thing through `app.test` |

`starterApp(configuration)` returns the `Application`, and `main.swift` only
chooses what to do with it. That is what makes the tests exercise the same
routes the executable serves.

### One file per feature, as it grows

Two features fit in two files. Twenty need a rule, and this is the one to
copy: a feature is a function, and what it contributes is registered in one
place.

```swift
// Notes.swift: routes only, so the feature is a value.
func noteRoutes() -> Router {
    let app = Router()
    app.get("") { … }
    return app
}

// StarterApp.swift
app.nest("/notes", noteRoutes())
```

A feature that needs more than routes takes the application and registers it
all together -- there is nothing else to declare it to:

```swift
// Billing.swift
func addBilling(_ app: Application, _ configuration: StarterConfiguration) {
    app.state { _ in try StripeClient(configuration.stripeKey) }   // per worker
    app.prepare { start in try await start.state(StripeClient.self).warmUp() }
    app.every(3600, onWorker: 0) { _ in … }                        // one worker's job
    app.nest("/billing", billingRoutes())
}
```

- **Routes as a `Router`** when the feature only serves requests: it can be
  mounted under any prefix, mounted twice, and tested on an application of its
  own. `Notes.swift` is this shape.
- **A function on `Application`** when the feature also needs per-worker state,
  start-up work, a timer or middleware, because those belong to the
  application. `Accounts.swift` is this shape, since it needs the
  configuration.
- **Migrations stay in one list** ([Schema.swift](Sources/StarterExample/Schema.swift)),
  not one per feature: the order they ran in is what the version counts, and
  two lists cannot agree on an order. A feature's tables go at the end of the
  one list.
- **Shared services in one value** ([Services.swift](Sources/StarterExample/Services.swift)),
  built once per worker. Features reach it with `State<Services>` rather than
  each holding a pool of its own -- a pool per feature is connections
  multiplied by workers multiplied by features.
- **Tests per feature**, through `app.test` on the whole application, so what
  is tested is what is served. A `Router` feature can also be tested alone:
  `let app = Application(); app.merge(noteRoutes())`.

Nothing here is a framework mechanism to learn: a module is a function, and
`Router` is the value it can hand back. There is no container to register with
and no scan at start-up, so what an application is made of is what its one
file says it is.

## Configuration

Garuda's own concerns stay on the command line, because the server parses them
and [CONFIG.md](../CONFIG.md) documents them: `--port`, `--workers`, `--tls-*`,
`--rate-limit`, `--access-log`, `--max-body`. The application's concerns are
environment variables, because a deployment sets them as secrets:

| Variable | Required | Default |
|---|---|---|
| `APP_ENV` | no | `development`; `production` refuses guesses |
| `DATABASE_URL` | in production | `postgres://garuda:garuda-secret@127.0.0.1:5432/starter?sslmode=disable` |
| `JWT_PRIVATE_KEY` | in production | a key made up for the run |
| `JWT_PRIVATE_KEY_FILE` | no | read in place of `JWT_PRIVATE_KEY`, for a mounted secret |
| `ACCESS_TOKEN_SECONDS` | no | 900 |
| `REFRESH_TOKEN_DAYS` | no | 14 |
| `SESSION_DAYS` | no | 90 |
| `SIGNUPS_OPEN` | no | true |
| `DATABASE_POOL_SIZE` | no | 8, per worker |
| `DOCS_PATH` | no | `/docs`; `off` serves neither |

`AppEnvironment` (Garuda) does the reading and collects the problems;
[Configuration.swift](Sources/StarterExample/Configuration.swift) says what the
variables are, what they default to, and which combinations make no sense.
CONFIG.md has the readers.

Three things this pattern is built around:

- **Everything is read before anything is served.** `fromEnvironment` returns a
  value or throws with *every* problem listed, so a missing secret is one
  restart, not five.
- **Production is refused defaults.** No database URL, no signing key, and no
  `sslmode=disable` — each is an error rather than something guessed.
- **The checks are about sense, not just types.** An access token that outlives
  its refresh token, or a refresh token that outlives its session, is refused.

Make a signing key with:

```bash
openssl ecparam -genkey -name prime256v1 -noout -out jwt.pem
export JWT_PRIVATE_KEY_FILE=$PWD/jwt.pem
```

Keep it. It signs every access token: a new key signs out everyone.

## Migrations

[Schema.swift](Sources/StarterExample/Schema.swift) is a list that only grows.
Each entry is the statements of one migration, applied together in one
transaction, and the database records how many have run.

```swift
public let starterMigrations: [[String]] = [
    ["create table users (...)"],
    ["create table notes (...)", "create index notes_user_id on notes (user_id, id desc)"],
    PostgresRefreshTokenStore.schema(),
]
```

- **Append; never edit.** A migration that has run will not run again, so an
  edit reaches nobody's database but a new one's.
- **Two ways to run them**, and both are safe:
  - `swift run starter migrate` — for a deployment that migrates before it
    rolls out new code.
  - Every worker, as it starts, from `app.prepare`. The first to take
    PostgreSQL's advisory lock migrates; the rest wait on that lock and find
    nothing to do.
- **A database ahead of the binary is an error**, not a migration backwards. A
  rolled-back deployment does not drop columns.
- **Write migrations that suit a rolling deployment**: add a column before the
  code that writes it, stop writing a column before dropping it. Two workers,
  old and new, serve at the same time through a reload.

## The per-worker model

Garuda runs a process per worker, and each is one thread. What follows from
that, and what this application does about it:

- **State is built after the fork.** `app.state` runs in each worker, so the
  pool, the keys and the issuer exist once per process. Nothing here is shared
  between workers, and nothing needs a lock.
- **Connections multiply.** `DATABASE_POOL_SIZE` is per worker: 4 workers × 8 is
  32 connections. Size it against PostgreSQL's `max_connections`, not against
  one number in your head.
- **Start-up work goes in `app.prepare`.** It may await, it runs before the
  worker accepts anything, and a throw stops that worker rather than serving
  half-ready. Migrating and hashing the timing password happen there.
- **Shutdown goes in `app.state`'s `shutdown:`**, which closes the pool when the
  worker drains.
- **What every worker must see lives outside the process:** the database, and
  `Topic` for anything to be heard across workers (the chat example).
- **Work on a timer** is `app.every`. This application clears ended refresh
  tokens hourly with `onWorker: 0`, so four workers do not each run the
  delete. Across machines, take a lock in the database instead; EXAMPLES.md
  shows how.
- **Work repeated in every worker is work done N times.** A cache warmed in
  `prepare` is warmed per worker; a scheduled job started in every worker runs
  N times. Use `start.index == 0` to do something once, and remember that
  worker 0 is replaced on a reload.

## Deploying

### Build

```bash
swift build -c release --product starter
```

The binary needs the Swift runtime libraries and libssl, libz and libstdc++
([INSTALLATION.md](../INSTALLATION.md) lists them and how to ship them).

### A container

[deploy/Dockerfile](deploy/Dockerfile) builds from the repository root, because
`Examples/` depends on the Garuda checkout beside it:

```bash
docker build -f Examples/deploy/Dockerfile -t starter .
docker run --rm -p 8080:8080 \
    -e APP_ENV=production \
    -e DATABASE_URL='postgres://starter:secret@db:5432/starter?sslmode=require' \
    -e JWT_PRIVATE_KEY="$(cat jwt.pem)" \
    starter
```

It is a two-stage build: `swift:6.1-noble` compiles, `ubuntu:noble` runs with
the Swift runtime libraries copied in, as a non-root user, with a health check
on `/health`. `--workers 0` is one worker per CPU; under a CPU limit, set it to
that limit. `docker run ... starter migrate` applies the schema without
serving.

### systemd

[deploy/starter.service](deploy/starter.service) and
[deploy/env.example](deploy/env.example):

```bash
install -m 755 .build/release/starter /usr/local/bin/starter
install -m 644 Examples/deploy/starter.service /etc/systemd/system/
install -m 640 -o root -g starter Examples/deploy/env.example /etc/starter/env
systemctl daemon-reload && systemctl enable --now starter
```

- `ExecStartPre=starter migrate` migrates before any worker serves, so a failed
  migration fails the unit instead of the first request.
- `systemctl reload` replaces the workers one at a time without dropping a
  connection: that is how a new binary goes out.
- `TimeoutStopSec` is above `--drain-delay` plus `--graceful-timeout`.
- The unit takes away what the application does not need: no new privileges, a
  read-only system, no home, restricted address families. With
  `--acme-domain`, add a `ReadWritePaths` for the cache.

### In front of it

Bind to loopback behind a reverse proxy, and trust its headers with
`--forwarded-allow-ips`, or serve TLS directly with `--tls-cert` and
`--tls-key` or `--acme-domain`. [INSTALLATION.md](../INSTALLATION.md) covers
both, and [CONFIG.md](../CONFIG.md) every flag.

### Health, readiness and metrics

- `/health` answers while the process runs and touches no database: a
  supervisor should not restart a worker for a database outage it cannot fix.
- `/ready` takes a connection from the pool: a load balancer should stop
  sending traffic to a worker that cannot reach the database.
- `--metrics-port 9090` serves Prometheus metrics, per route since this
  release. Keep that port off the internet.
- `--access-log` writes one line per request, and `--request-id` adds an id to
  carry into your own logs.

### Before it is really production

This is a starter, not a finished service. What it deliberately leaves out:

- Email: confirming an address, and resetting a password.
- Rate limits per account. `--rate-limit` is per address, which is the floor.
- Roles, and anything an administrator does.
- Deleting an account, and exporting what it holds.
- Backups, and a tested restore.

## Testing

```bash
cd Examples
STARTER_DATABASE_URL='postgres://garuda:secret@127.0.0.1:5432/starter_test?sslmode=disable' swift test
```

The tests drive the real engine through `app.test`, against a real PostgreSQL:
sign-up and its refusals, login timing, the token rotation and reuse
detection, ownership (another account gets 404, not 403), paging, health and
the generated document. The configuration tests need no database. Without
`STARTER_DATABASE_URL` the database tests are skipped, so the suite still runs
anywhere.

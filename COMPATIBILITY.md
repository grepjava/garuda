<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Compatibility

What an application may depend on, what may change under it, and how much
notice it gets. Read this before you pin a version.

## Versions

Versions are `MAJOR.MINOR.PATCH`, as [semantic versioning](https://semver.org)
describes them, with one difference that matters until 1.0:

| | before 1.0 | from 1.0 |
|---|---|---|
| `PATCH` (0.4.1 → 0.4.2) | fixes only; nothing in [what is covered](#what-is-covered) changes | the same |
| `MINOR` (0.4.2 → 0.5.0) | **may break** what is covered, with the notice below | additions only; an application keeps building |
| `MAJOR` | — | may break what is covered, with the notice below |

Pin accordingly. Before 1.0:

```swift
.package(url: "https://github.com/grepjava/garuda", .upToNextMinor(from: "0.4.0"))
```

From 1.0, `from:` is the pin to use.

Every release's changes are listed in [RELEASE.md](RELEASE.md), and anything
that breaks is called out there under the version that breaks it.

## What is covered

These are what an application is written against, and what the policy above
applies to:

- **The public Swift API** of the `Garuda` library: every `public`
  declaration, its name, its signature and its documented behaviour.
- **Command-line flags** and their meanings ([CONFIG.md](CONFIG.md)), and the
  environment variables the server reads.
- **What goes over the wire** for a given application: status codes, the
  headers the engine adds, the shape of the error bodies it writes, the cookie
  attributes it sets, and the JSON encoding of the types Garuda serialises
  (`TokenPair`, the OpenAPI document, the metrics format).
- **The database schemas** Garuda writes for you (sessions, refresh tokens) and
  the keys the Redis stores use. A schema change is a migration, and the
  release notes say how to run it.

## What is not covered

- Anything `internal`, and anything reachable only through
  `@testable import`.
- The `AvianCore` and `AvianHTTP` modules, and the `CAvian` C layer. They are
  the engine's own; a version of Garuda names the version of
  [aviancore](https://github.com/grepjava/aviancore) it needs.
- The exact text of log lines, error messages and panics. Their fields are
  stable where [CONFIG.md](CONFIG.md) documents them; the wording is not.
- Timing, memory use and performance. A release may make something slower to
  make it correct.
- The benchmark scripts, the fuzz targets, the test suites, and the examples.
- Anything the documentation marks experimental, and anything under
  **Not supported** in the README.

## Deprecation

Nothing covered is removed without a release that still has it:

1. It is marked `@available(*, deprecated, message: "use X")`, so a build says
   so, and the release notes say what replaces it.
2. It keeps working for at least one `MINOR` release (before 1.0) or one
   `MAJOR` (from 1.0).
3. It is removed, and the release notes list the removal.

A behaviour that is wrong -- a header that should not be sent, a status that
should be different -- is fixed in a `MINOR` release and called out. Where the
old behaviour is worth keeping, the fix comes with a flag to ask for it.

A fix for a security problem can break something covered in a `PATCH` release
if there is no other way to fix it. That is the one exception, it is rare, and
the release notes say plainly what changed.

## Toolchains and platforms

- **Swift.** 6.1 or newer, as [INSTALLATION.md](INSTALLATION.md) says; the
  package is Swift 6 language mode throughout. Raising the minimum is a
  `MINOR` change and is listed in the release notes.
- **Linux.** The distributions in INSTALLATION.md, on x86-64 and arm64.
- **macOS.** Supported for development. The engine uses kqueue there, and some
  features are Linux-only ([TRANSPORT.md](TRANSPORT.md) says which).
- **Windows.** Through WSL 2 only.
- **Databases.** PostgreSQL 10 and later, which is where SCRAM-SHA-256 begins
  (tested against 16 and 18); Redis 6 and later, and Valkey (tested against
  Redis 7.4 and Valkey 8.1); and the system's SQLite, loaded at run time.
  Dropping support for a version is a `MINOR` change.

## Today

Garuda is before 1.0, and the API is still moving: the handler API's own
roadmap is in [HANDLER-API.md](HANDLER-API.md). This policy is what a `MINOR`
release will hold itself to from now on, not a claim that the API has settled.

1.0 is the point at which the public API is settled enough that breaking it
needs a major version. What has to be true first:

- The handler API's roadmap is finished.
- The connectors' **Not supported** lists ([CONNECTORS.md](CONNECTORS.md)) hold
  nothing an ordinary application runs into.
- An application can be built, configured, migrated and deployed from the
  documentation alone.

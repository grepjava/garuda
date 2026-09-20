<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Compatibility

What an application may depend on, what may change under it, and how much
notice it gets. Read this before you pin a version.

## Versions

Versions are `MAJOR.MINOR.PATCH`, as [semantic versioning](https://semver.org)
describes them:

| | |
|---|---|
| `PATCH` (1.0.0 → 1.0.1) | fixes only; nothing in [what is covered](#what-is-covered) changes |
| `MINOR` (1.0.1 → 1.1.0) | additions only; an application keeps building |
| `MAJOR` (1.1.0 → 2.0.0) | may break what is covered, with the notice below |

So `from:` is the pin to use:

```swift
.package(url: "https://github.com/grepjava/garuda", from: "1.0.0")
```

Every release's changes are in [RELEASE.md](RELEASE.md), and anything that
breaks is called out under the version that breaks it.

## What is covered

- **The public Swift API** of the `Garuda` library: every `public`
  declaration, its name, its signature and its documented behaviour.
- **Command-line flags** and their meanings ([CONFIG.md](CONFIG.md)), and the
  environment variables the server reads.
- **What goes over the wire** for a given application: status codes, the
  headers the engine adds, the shape of its error bodies, the cookie
  attributes it sets, and the JSON encoding of the types Garuda serialises
  (`TokenPair`, the OpenAPI document, the metrics format).
- **The database schemas** Garuda writes for you (sessions, refresh tokens)
  and the keys its Redis stores use. A schema change is a migration, and the
  release notes say how to run it.

## What is not covered

- Anything `internal`, and anything reachable only through `@testable import`.
- The `AvianCore` and `AvianHTTP` modules and the `CAvian` C layer. They are
  the engine's own; each Garuda version names the
  [aviancore](https://github.com/grepjava/aviancore) version it needs.
- The exact text of log lines, error messages and panics. Their fields are
  stable where [CONFIG.md](CONFIG.md) documents them; the wording is not.
- Timing, memory use and performance. A release may make something slower to
  make it correct.
- Benchmark scripts, fuzz targets, test suites and examples.
- Anything marked experimental, and anything under **Not supported** in the
  README.

## Deprecation

Nothing covered is removed without a release that still has it:

1. It is marked `@available(*, deprecated, message: "use X")`, so the build
   says so, and the release notes say what replaces it.
2. It keeps working for at least one `MAJOR` release.
3. It is removed, and the release notes list the removal.

A behaviour that is simply wrong -- a header that should not be sent, a status
that should be different -- is fixed in a `MINOR` release and called out.
Where the old behaviour is worth keeping, the fix comes with a flag to ask for
it.

A security fix may break something covered in a `PATCH` release if there is no
other way. That is the one exception, it is rare, and the release notes say
plainly what changed.

## Toolchains and platforms

- **Swift** 6.2 or newer (`swift-tools-version: 6.2`); Swift 6 language mode
  throughout. Raising the minimum is a `MAJOR` change.
- **Linux**, on x86-64 and arm64: the distributions in
  [INSTALLATION.md](INSTALLATION.md).
- **macOS** 15, for development. The engine uses kqueue there and some
  features are Linux-only ([TRANSPORT.md](TRANSPORT.md) says which).
- **Windows** through WSL 2 only.
- **Databases.** PostgreSQL 10 and later, where SCRAM-SHA-256 begins (tested
  against 16 and 18); Redis 6 and later and Valkey (tested against Redis 7.4
  and Valkey 8.1); the system's SQLite, loaded at run time. Dropping a version
  is a `MAJOR` change.

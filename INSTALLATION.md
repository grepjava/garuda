# Installing Garuda

Garuda is built from source with SwiftPM. There are no prebuilt binaries. You
either build the `garuda` executable from this repository, or add the `Garuda`
library to your own package and build your application.

Garuda 2 runs on [Vega](https://github.com/grepjava/vega), a work-stealing
runtime for Swift, and takes its database drivers from
[vega-db](https://github.com/grepjava/vega-db). SwiftPM fetches both. Garuda 1
stays on the `release/1.x` branch; [COMPATIBILITY.md](COMPATIBILITY.md) covers
moving from it.

---

## Requirements

| | |
|---|---|
| **Swift** | 6.2 or newer (`swift-tools-version: 6.2`). |
| **OS** | Linux, or macOS 26.4 or newer. Windows is experimental, single-process only (below). |
| **zlib** | Development files on Linux (`zlib1g-dev`). Vega links `libz` for gzip and deflate. macOS has it. |
| **A TLS library** | Nothing to install by default: TLS uses a BoringSSL vendored in Vega. With the `OpenSSL` trait, the system's OpenSSL 3 development files. |

Nothing else is linked:

- **Databases.** The PostgreSQL and Redis drivers are written in Swift and
  need no client libraries. SQLite is the system's `libsqlite3`, loaded when
  the first database opens, so it needs no headers to build: install
  `libsqlite3-0` where an application uses it. macOS has it.
- **brotli and zstd.** `--compress` loads `libbrotlienc` and `libzstd` at run
  time where they are installed, and offers only gzip where they are not.
- **io_uring.** Used on Linux 6.7 or later, with no library. An older kernel
  gets epoll.

macOS 26.4 is Vega's floor: its executor needs the custom-executor hooks that
release added to the Swift runtime.

### Ubuntu and Debian

Install a Swift toolchain from [swift.org/install](https://swift.org/install)
with the packages it lists, then the rest:

```bash
sudo apt-get install -y --no-install-recommends \
    binutils gcc libc6-dev libcurl4 libedit2 libncurses6 \
    libsqlite3-0 libxml2 pkg-config tzdata zlib1g-dev ca-certificates
swift --version
```

Add `libssl-dev` to build with the `OpenSSL` trait.

### macOS

```bash
xcode-select --install
```

That is all the default build needs. For the `OpenSSL` trait, install
`brew install pkg-config openssl@3` and put Homebrew's OpenSSL where
pkg-config finds it:

```bash
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"
```

### Windows

Windows support is being worked on and is experimental. It serves in one
process only: `--shards` has no effect, no signal is handled, and response
compression is not available yet. Linux and macOS are the supported
platforms.

---

## The TLS library

TLS, and every cryptographic primitive Garuda uses (signed cookies, JWT,
password hashing, QUIC's packet protection), comes from Vega's `VegaTLS` and
`VegaCrypto`, over one of two libraries chosen by a package trait:

| trait | library | |
|---|---|---|
| `BoringSSL` | BoringSSL, vendored in Vega and built with it | the default; no system library needed |
| `OpenSSL` | the system's OpenSSL 3 | needs its development files; BoringSSL wins if both are on |

```bash
swift build -c release                      # BoringSSL
swift build -c release --traits OpenSSL     # the system's OpenSSL
```

A dependent picks the trait on its dependency:

```swift
.package(url: "https://github.com/grepjava/garuda", from: "2.0.0", traits: ["OpenSSL"]),
```

There is no kernel TLS in either build.

---

## Building the executables

```bash
git clone https://github.com/grepjava/garuda
cd garuda
swift build -c release
```

| product | path | what it is |
|---|---|---|
| `garuda` | `.build/release/garuda` | the server with the benchmark application |
| `garuda-conformance` | `.build/release/garuda-conformance` | routes used by the end-to-end test suites |

Build one with `swift build -c release --product garuda`.

The binaries link the Swift runtime and zlib dynamically, and OpenSSL with the
`OpenSSL` trait. A machine that runs them needs those shared libraries.

If the checkout is on a slow file system, such as a Windows drive under WSL,
build somewhere else:

```bash
swift build -c release --scratch-path ~/garuda-build
```

### Checking the build

```bash
.build/release/garuda --version
.build/release/garuda --port 8000 &
curl -i http://127.0.0.1:8000/            # 200, empty body
curl http://127.0.0.1:8000/user/42        # 42
curl -i http://127.0.0.1:8000/nope        # 404
```

### Local checkouts of Vega and vega-db

To work on Garuda together with a Vega or vega-db change that is not released
yet, point the build at local checkouts:

```bash
GARUDA_VEGA_PATH=~/src/vega GARUDA_VEGA_DB_PATH=~/src/vega-db VEGA_PATH=~/src/vega \
    swift build
```

`VEGA_PATH` is what vega-db reads to find its own Vega; set it to the same
checkout as `GARUDA_VEGA_PATH`.

---

## Using Garuda in your application

Add the package and depend on the products you use:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "app",
    platforms: [.macOS("26.4")],
    dependencies: [
        .package(url: "https://github.com/grepjava/garuda", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(name: "app", dependencies: [
            .product(name: "Garuda", package: "garuda"),
        ]),
    ]
)
```

| product | what it adds |
|---|---|
| `Garuda` | the handler API, the server, the HTTP client, sessions, JWT and the rest of the middleware |
| `GarudaTesting` | `app.test`: requests through the real HTTP/1 connection over an in-memory stream |
| `GarudaJSON` | `@JSON`, which writes a type's JSON reading and writing out instead of leaving it to `Codable` |
| `GarudaPostgres` | vega-db's PostgreSQL driver, joined to Garuda |
| `GarudaRedis` | vega-db's Redis driver |
| `GarudaSQLite` | vega-db's SQLite driver |
| `GarudaSQL` | `@PostgresRow`, which does for a result row what `@JSON` does for JSON |

`GarudaJSON` and `GarudaSQL` are separate because they are the only parts of
Garuda that need swift-syntax: a target that does not depend on them never
builds the macro plugin, although the package is still fetched when Garuda's
dependencies are resolved. The database products are separate so that an
application builds only the drivers it imports.
[CONNECTORS.md](CONNECTORS.md) covers them. Resumable uploads (Garuda 1's
`GarudaUploads`) are coming.

`Application.run()` reads the flags in [CONFIG.md](CONFIG.md), so your binary is
started the same way as `garuda`. [README.md](README.md) has a first
application, and [HANDLER-API.md](HANDLER-API.md) the design of the API.

### An application with commands of its own

`app.run()` reads the process's command line. An application that has commands
of its own -- a `migrate` before it serves -- hands Garuda only the arguments
that are Garuda's. `app.run(arguments:)` takes an `argv`, program name first:

```swift
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Garuda
import GarudaPostgres
import Vega

let app = Application()
// … routes …
let databaseURL = "postgres://app@localhost/app?sslmode=disable"
let migrations: [[String]] = [
    ["create table orders (id bigserial primary key, total_cents bigint not null)"],
]

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

Garuda 2 has no `app.runOnce`. On macOS, a sharded server starts each shard as
a new run of the executable with the same arguments, so `main` must reach
`app.run` the same way each time.

---

## Certificates

HTTP/2 over TLS and HTTP/3 need a certificate. `--http3` without one is refused
at start-up.

For local work:

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 30 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

.build/release/garuda --port 8443 --tls-cert cert.pem --tls-key key.pem --http3
```

That serves HTTP/1.1 and HTTP/2 on TCP port 8443 and HTTP/3 on UDP port 8443.
Open the port for UDP as well as TCP. A missing UDP rule is the usual reason
HTTP/3 is never used.

Browsers do not use HTTP/3 with an untrusted certificate. For browser testing,
[`mkcert`](https://github.com/FiloSottile/mkcert) installs a local CA the
browser trusts.

**Several names.** Repeat `--tls-cert` and `--tls-key` in pairs. The client's
SNI picks the first certificate that covers the name it asks for, and the
first answers a client that names none.

**Public certificates.** Garuda 2 has no built-in ACME client. Get the
certificate with certbot or another ACME client, and let the server pick up
renewals with `--tls-reload` or a `SIGHUP`. `--redirect-http 80
--acme-webroot DIR` answers certbot's HTTP-01 challenges on port 80.
[CONFIG.md](CONFIG.md#renewing-certificates) has the details.

---

## Tests

```bash
swift test
swift build -c release
swift build -c release --product garuda-conformance
```

The database tests skip themselves unless a database is reachable. The
end-to-end suites in `scripts/` run the release binaries. The shell suites
need `curl`, and some need `openssl` or `nc`. The HTTP/2, HTTP/3 and handler
suites are Python test clients that need `h2` and `aioquic`.

---

## Troubleshooting

| symptom | cause |
|---|---|
| Linker errors naming `z` | zlib development files are missing |
| Linker errors naming `ssl` or `crypto` | built with the `OpenSSL` trait without OpenSSL's development files, or pkg-config cannot find them |
| `requires minimum platform version` on macOS | the package or the machine is below macOS 26.4 |
| HTTP/3 is never used | UDP is closed on the QUIC port, or the client does not trust the certificate |
| `--compress` only ever sends gzip | `libbrotlienc` and `libzstd` are not installed |

---

Next: [CONFIG.md](CONFIG.md) covers every flag, and
[DEPLOYMENT.md](DEPLOYMENT.md) running in production. [README.md](README.md)
describes the handler API and current status.
[ARCHITECTURE.md](ARCHITECTURE.md) explains how Garuda is built.

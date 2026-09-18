<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Installing Garuda

Garuda is built from source with SwiftPM. There are no prebuilt binaries. You
either build the `garuda` executable from this repository, or add the `Garuda`
library to your own package and build your application.

---

## Requirements

| | |
|---|---|
| **Swift** | 6.1 or newer (`swift-tools-version: 6.1`). CI uses 6.1.2. |
| **OS** | Linux, or macOS 15 or newer. Linux is the primary platform. Windows is not supported; WSL 2 works. |
| **OpenSSL** | Development files. The package links `libssl` and `libcrypto`. |
| **zlib** | Development files. The package links `libz`. |
| **CA certificates** | The system trust store, for ACME and outbound HTTPS, unless you pass `--acme-ca-bundle`. |

Nothing else is linked. The PostgreSQL and Redis drivers are written in Swift
and need no client libraries. SQLite is the system's `libsqlite3`, loaded when
the first database opens, so it needs no headers to build: install
`libsqlite3-0` (below) where an application uses it. macOS has it.

### Ubuntu and Debian

These are the packages CI installs on Ubuntu 24.04, including the Swift
toolchain's own runtime dependencies:

```bash
sudo apt-get install -y --no-install-recommends \
    binutils gcc libc6-dev libcurl4 libedit2 libncurses6 \
    libsqlite3-0 libssl-dev libxml2 pkg-config tzdata zlib1g-dev ca-certificates
```

Install a Swift toolchain from [swift.org/install](https://swift.org/install),
then check it:

```bash
swift --version
```

### macOS

```bash
xcode-select --install
brew install pkg-config openssl@3
```

Homebrew's OpenSSL is not on the default search path. Pass it to every
`swift build` and `swift test`:

```bash
OPENSSL_PREFIX=$(brew --prefix openssl@3)
swift build -c release \
    -Xcc -I"$OPENSSL_PREFIX/include" -Xlinker -L"$OPENSSL_PREFIX/lib"
```

Linux-only features, such as `--ktls`, are not available on macOS.

---

## Building the executables

```bash
git clone https://github.com/grepjava/garuda
cd garuda
swift build -c release
```

| product | path | what it is |
|---|---|---|
| `garuda` | `.build/release/garuda` | the server with a small benchmark application |
| `garuda-conformance` | `.build/release/garuda-conformance` | routes used by the end-to-end test suites |

Build one with `swift build -c release --product garuda`.

The binaries link OpenSSL, zlib and the Swift runtime dynamically. A machine
that runs them needs those shared libraries.

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

---

## Using Garuda in your application

Add the package and depend on the `Garuda` product. It includes the handler
API, the HTTP client and the PostgreSQL driver.

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "app",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/grepjava/garuda", branch: "main"),
    ],
    targets: [
        .executableTarget(name: "app", dependencies: [
            .product(name: "Garuda", package: "garuda"),
        ]),
    ]
)
```

`Application.run()` reads the flags in [CONFIG.md](CONFIG.md), so your binary is
started the same way as `garuda`. [README.md](README.md) has a first
application, and [HANDLER-API.md](HANDLER-API.md) the API's roadmap.

The system requirements above apply to your application's build too,
including the OpenSSL flags on macOS.

---

### An application with commands of its own

`app.run()` reads the process's command line. An application that has commands
of its own -- a `migrate` before it serves -- hands Garuda only the arguments
that are Garuda's:

```swift
switch CommandLine.arguments.dropFirst().first ?? "serve" {
case "migrate":
    try app.runOnce { start in
        try await start.state(PostgresPool.self).migrate(migrations)
    }
case "serve":
    var flags = Array(CommandLine.arguments.dropFirst(2))
    if flags.first == "--" { flags.removeFirst() }
    exit(app.run(arguments: flags))
default:
    exit(64)
}
```

`app.runOnce` builds a worker with no listening socket, runs the work on it and
tears the state down, so a command can migrate or backfill without serving.
[Examples/STARTER.md](Examples/STARTER.md) is a whole application built this
way.

---

## Certificates

HTTP/2 over TLS and HTTP/3 need a certificate. `--http3` without one is refused
at start-up.

### Certificate files

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

**Several names.** Repeat `--tls-cert` and `--tls-key` in pairs. The first
pair is the default. The others are chosen by SNI, using the names in each
certificate.

### ACME

Garuda can get and renew its own certificate. It answers the `tls-alpn-01`
challenge on the port it serves, so a public CA must reach it on port 443:

```bash
garuda --host 0.0.0.0 --port 443 \
    --acme-domain example.com --acme-domain www.example.com \
    --acme-email ops@example.com --acme-cache /var/lib/garuda/acme \
    --http3 --redirect-http 80
```

Use `--acme-staging` while testing. Keep `--acme-cache` on persistent storage;
it holds the account key and the certificate. [CONFIG.md](CONFIG.md#acme) has
the details.

---

## Running as a systemd service

```ini
[Unit]
Description=garuda
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/garuda --host 0.0.0.0 --port 443 --workers 0 \
    --tls-cert /etc/garuda/cert.pem --tls-key /etc/garuda/key.pem \
    --health-check-path /healthz --drain-delay 5000
ExecReload=/bin/kill -HUP $MAINPID
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

- `systemctl stop` sends `SIGTERM`, which drains. Keep `TimeoutStopSec` above
  `--drain-delay` plus `--graceful-timeout` (10 s by default).
- `systemctl reload` sends `SIGHUP`. The workers are replaced one at a time and
  read the certificate files again, without dropping a connection. Use it as
  the certbot deploy hook:

  ```bash
  certbot renew --deploy-hook 'systemctl reload garuda'
  ```

- `AmbientCapabilities=CAP_NET_BIND_SERVICE` lets a non-root user bind ports
  below 1024.
- With `--acme-domain`, make the `--acme-cache` directory writable by the
  service user.

To upgrade, `git pull`, rebuild, copy the binary into place and restart. The
only state Garuda keeps is the `--acme-cache` directory.

---

## Behind a reverse proxy

Bind to loopback or a unix socket, and trust the proxy's forwarded headers:

```bash
garuda --unix /run/garuda.sock --workers 0 --forwarded-allow-ips unix
garuda --host 127.0.0.1 --port 8000 --workers 0 --forwarded-allow-ips 127.0.0.1
```

- Without `--forwarded-allow-ips`, `X-Forwarded-For`, `X-Forwarded-Proto` and
  `Forwarded` are ignored. Handlers and the rate limiter then see the proxy's
  address.
- A proxy that talks h2c upstream, such as Envoy or Caddy, needs
  `--http2-only`.
- If the proxy mounts the application under a prefix and does not strip it,
  use `--root-path`.
- A proxy that terminates TLS stops ACME's `tls-alpn-01` challenge from
  reaching Garuda. Get the certificate at the proxy instead.

---

## Kernel TLS

`--ktls` lets `--static-dir` files go out with `sendfile` over HTTPS/1.1. It
needs Linux, the `tls` kernel module, and an OpenSSL built with kernel TLS
support.

```bash
sudo modprobe tls
echo tls | sudo tee /etc/modules-load.d/tls.conf    # load it at boot
```

If either is missing, the server logs a warning at start-up that says which,
and OpenSSL encrypts as usual.

---

## Tests

```bash
swift test
swift build -c release
swift build -c release --product garuda-conformance
```

The end-to-end suites in `scripts/` run those binaries. The shell suites need
`curl`, and some need `openssl` or `nc`. The HTTP/2, HTTP/3 and handler suites
are Python test clients that need `h2` and `aioquic`.
[README.md](README.md#tests) lists them.

---

## Troubleshooting

| symptom | cause |
|---|---|
| Linker errors naming `ssl`, `crypto` or `z` | OpenSSL or zlib development files are missing; on macOS, pass the Homebrew prefix |
| HTTP/3 is never used | UDP is closed on the QUIC port, or the client does not trust the certificate |
| ACME never issues | the CA cannot reach port 443, or the cache directory is not writable |

---

Next: [CONFIG.md](CONFIG.md) covers every flag. [README.md](README.md)
describes the handler API and current status.
[ARCHITECTURE.md](ARCHITECTURE.md) explains how Garuda is built.

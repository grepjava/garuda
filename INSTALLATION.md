<p align="center">
  <img src="assets/garuda-fiery-roaring.png" alt="garuda" width="480">
</p>

# Installing Garuda

Garuda is a single executable built from source with SwiftPM. There is no
package, installer or prebuilt binary. You clone the repository, build it, and
run `.build/release/garuda`.

The `garuda` binary serves the-benchmarker's test routes through the handler
API (see [README.md](README.md#what-the-binary-serves)). An application of your
own is built against the `Garuda` library product; that API is early and will
change ([HANDLER-API.md](HANDLER-API.md)).

---

## What you need

| | |
|---|---|
| **Swift** | 6.1 or newer (`swift-tools-version: 6.1`; CI uses 6.1.2). From [swift.org/install](https://swift.org/install) |
| **OpenSSL** | development files. The build links `libssl` and `libcrypto` |
| **zlib** | development files. The build links `libz` |
| **An OS with epoll or kqueue** | Linux is the primary platform: development, benchmarks and the end-to-end suites run there (WSL 2). macOS 14+ builds and passes the unit tests in CI. Windows is not supported |

### Ubuntu and Debian

CI (Ubuntu 24.04) installs the Swift toolchain's runtime dependencies alongside
OpenSSL and zlib:

```bash
sudo apt-get install -y --no-install-recommends \
    binutils gcc libc6-dev libcurl4 libedit2 libncurses6 \
    libsqlite3-0 libssl-dev libxml2 pkg-config tzdata zlib1g-dev
# then a Swift toolchain from https://swift.org/install
swift --version                       # expect 6.1 or newer
```

### macOS

```bash
xcode-select --install                # Swift ships with the Xcode tools
brew install pkg-config openssl@3
```

Homebrew's OpenSSL is not on the default search path, so you pass it to the
build (as CI does):

```bash
OPENSSL_PREFIX=$(brew --prefix openssl@3)
swift build -c release \
    -Xcc -I"$OPENSSL_PREFIX/include" -Xlinker -L"$OPENSSL_PREFIX/lib"
```

Linux-only features, such as `--ktls`, are not available there.

---

## Building

```bash
git clone https://github.com/grepjava/garuda
cd garuda
swift build -c release                # binary at .build/release/garuda
```

The binary links OpenSSL, zlib and the Swift runtime, and no libpython. To run
it on another machine, that machine needs those shared libraries too.

If the checkout lives on a filesystem the toolchain is slow on, such as a
Windows drive mounted into WSL, build somewhere native:

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

## Certificates, for TLS and HTTP/3

HTTP/2 over TLS and HTTP/3 both need a certificate. QUIC has no cleartext form,
so `--http3` without one is refused at startup with
`--http3 needs --tls-cert and --tls-key`.

For local work:

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 30 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

.build/release/garuda --port 8443 --tls-cert cert.pem --tls-key key.pem --http3
```

That setup serves two protocol families on port 8443. HTTP/1.1 and HTTP/2 run
over TCP, negotiated by ALPN. HTTP/3 runs over UDP, advertised to TCP clients
with an `Alt-Svc` header. `--quic-port` moves the UDP side. Whichever port it
uses has to be open for **UDP**. That is a separate firewall rule from the TCP
one, and it is the usual reason a working HTTP/3 server looks broken.

Browsers will not use HTTP/3 against a self-signed certificate. For
browser-facing local work use [`mkcert`](https://github.com/FiloSottile/mkcert),
which installs a local CA the browser trusts.

**Several names on one port.** Repeat `--tls-cert` and `--tls-key` in pairs. The
first pair is the default, and the others are chosen by SNI from the names
inside each certificate.

**Kernel TLS.** `--ktls` needs the Linux `tls` module (`modprobe tls`). With
it, `--static-dir` files are sent with `sendfile` over HTTPS as well.

### Let's Encrypt, with ACME

Garuda can obtain and renew its own certificate. It answers the tls-alpn-01
challenge on the port it is already serving, so the CA must be able to reach
that port. For a public site that means port 443:

```bash
garuda --host 0.0.0.0 --port 443 \
    --acme-domain example.com --acme-domain www.example.com \
    --acme-email ops@example.com --acme-cache /var/lib/garuda/acme \
    --http3 --redirect-http 80 --hsts 31536000
```

Use `--acme-staging` while trying this out, so you don't hit Let's Encrypt's
production rate limits. `--acme-directory` and `--acme-ca-bundle` point at
another CA. The ACME client runs in a helper process. When it writes a new
certificate, the workers are replaced exactly as on `SIGHUP`, without dropping
connections. Keep `--acme-cache` on persistent storage: it holds the account key
and the certificate.

---

## Running it as a service

Garuda runs as a supervisor process with worker children. The signals are:

- **`SIGTERM`** drains gracefully. Add `--drain-delay` behind a load balancer,
  so the health check fails before connections are refused.
- **`SIGINT` / `SIGQUIT`** stop without the drain delay.
- **`SIGHUP`** replaces the workers one at a time without refusing a
  connection, and they re-read certificates from disk.

A minimal systemd unit using those signals:

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

`systemctl reload garuda` then reloads certificates with no downtime.
systemd's default stop signal is `SIGTERM`, which is the draining one. If you
use `--drain-delay`, keep `TimeoutStopSec` above the drain delay plus
`--graceful-timeout`.

Behind a reverse proxy, bind to a unix socket or to loopback. Set
`--forwarded-allow-ips` to the proxy's address (or `unix`) so its
`X-Forwarded-*` headers are trusted. [CONFIG.md](CONFIG.md) covers the flags in
depth.

### During development

`--reload` watches the executable. Leave the server running and run
`swift build -c release` in another terminal. When the binary changes, the
supervisor execs the new one with its listening sockets kept open and replaces
the workers without dropping a connection. It does not build for you.

---

## Running the tests

```bash
swift test                                    # 203 unit tests
```

The end-to-end suites in `scripts/` default to `.build/release/garuda`, so build
the release binary first. `handler-test.py` defaults to
`.build/release/garuda-conformance` instead, which
`swift build -c release --product garuda-conformance` builds. The shell suites need `curl`, and some also need
`openssl`, `nc` or `python3`. `acme-test.sh` needs a local
[Pebble](https://github.com/letsencrypt/pebble). The HTTP/2, HTTP/3 and handler
suites use Python as a test client only:

```bash
python3 -m venv .venv && .venv/bin/pip install h2 aioquic
.venv/bin/python scripts/http2-test.py
.venv/bin/python scripts/http3-test.py
.venv/bin/python scripts/router-streams-test.py
.venv/bin/python scripts/handler-test.py
```

[README.md](README.md#tests) has the full list with check counts.

---

## When it goes wrong

**Linker errors naming `ssl`, `crypto` or `z`.** The OpenSSL or zlib
development files are missing: `libssl-dev` and `zlib1g-dev` on Debian and
Ubuntu. On macOS, pass Homebrew's OpenSSL prefix as shown [above](#macos).

**`--http3 needs --tls-cert and --tls-key`.** QUIC is encrypted from its first
packet. Give it a certificate, or use `--acme-domain`.

**HTTP/3 never gets used.** Check that UDP is open on the QUIC port, and that
the client trusts the certificate.

**`--ktls` has no effect.** Load the kernel module: `sudo modprobe tls`.

**Windows.** The I/O layer is epoll and kqueue, so there is no Windows build.
WSL 2 works and is what the project is developed on.

---

## Upgrading and removing

To upgrade, `git pull` and `swift build -c release` again. Copy the new binary
into place and restart the service. A server started with `--reload` on that
binary path picks up the rebuild itself.

To remove Garuda, delete the binary and the checkout's `.build` directory. It
installs nothing else. The only state it keeps is the `--acme-cache` directory,
if you used one.

---

Next: [CONFIG.md](CONFIG.md) covers the flags in depth. [README.md](README.md)
says what Garuda is and what it supports. [ARCHITECTURE.md](ARCHITECTURE.md)
explains how it is built. [TRANSPORT.md](TRANSPORT.md) describes what each
protocol does. [GARUDA.md](GARUDA.md) is the current status.

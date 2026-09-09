# Installing Peregrine

Peregrine embeds CPython rather than talking to it over a socket, so the server
binary is linked against one specific `libpython`. That single fact decides
everything unusual about installing it:

* **It is compiled when you install it.** The interpreter it links must be the
  interpreter it will run applications for, and only the installing environment
  knows which one that is. There is no universal wheel to download.
* **Install it into the environment it will serve.** A virtualenv's packages
  are only importable by the interpreter that virtualenv belongs to.
* **The wheel is tagged for exactly one interpreter and platform**
  (`cp312-cp312-linux_x86_64`, say). `pip` will refuse it anywhere else, which
  is the correct answer rather than a limitation: a native executable with a
  hard `libpython` dependency does not degrade gracefully.

---

## What you need

| | |
|---|---|
| **Python** | 3.9 or newer, **with its development files** — `pkg-config` must be able to find `python3-embed` |
| **Swift** | 6.1 or newer, on `PATH`. From [swift.org/install](https://swift.org/install); on Linux, `swiftly` is the least painful route |
| **OpenSSL** | development files. TLS 1.3, and QUIC's use of it, need `libssl` and `libcrypto` |
| **pkg-config** | how the build locates all of the above |
| **An OS with epoll or kqueue** | Linux, or macOS 14+. Not Windows — see [below](#windows) |

### Ubuntu and Debian

```bash
sudo apt install python3-dev libssl-dev pkg-config curl
# Swift: https://swift.org/install — swiftly installs and manages toolchains
swift --version                       # expect 6.1 or newer
```

### Fedora and RHEL

```bash
sudo dnf install python3-devel openssl-devel pkgconf-pkg-config
```

### macOS

```bash
xcode-select --install                # Swift ships with the Xcode tools
brew install pkg-config openssl@3
```

Use a python.org or Homebrew build of Python. The system Python that Apple
ships has no embeddable development files, and `pkg-config` will not find
`python3-embed` for it.

---

## Installing

Activate the environment you intend to serve with, then:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install peregrine-server
```

The Swift build runs during the install and takes a few minutes. When it
finishes:

```bash
$ peregrine --version
peregrine 0.1.0 (CPython 3.12.3)
```

That second number is read out of the built binary at runtime, not out of the
headers it was compiled against — it is the interpreter your applications will
actually run under. If it disagrees with the `python3` on your `PATH`, that is
worth resolving now rather than after a confusing `ImportError`.

### From source

```bash
git clone https://github.com/grepjava/peregrine
cd peregrine
swift build -c release                # binary at .build/release/peregrine
```

```bash
.build/release/peregrine --python-path examples --python-path python \
    --port 8000 asgi_app:app
```

The second `--python-path` is what makes `peregrine.contrib` importable from a
source checkout; an installed copy needs neither.

If the checkout lives on a filesystem the toolchain is slow on — a Windows
drive mounted into WSL, for instance — build somewhere native instead:

```bash
swift build -c release --scratch-path ~/pgbuild
```

---

## Which interpreter, and which packages

Started through the `peregrine` entry point, the launcher fills in what it can
work out and you did not say:

* `--venv` from `sys.prefix`, or from `VIRTUAL_ENV` when the binary was
  installed outside the environment. Suppress it with `--no-auto-venv`.
* `--python-path` for the working directory, because that is nearly always
  where the application is.

`sys.path` ends up in this order:

1. every `--python-path` directory, in the order you gave them
2. the working directory
3. the virtualenv's `site-packages`

Directories you named beat installed packages, which is the same rule
`PYTHONPATH` follows in an ordinary interpreter — so a checkout you point at
shadows a release of it you happen to have installed, rather than the other way
round.

`--python-home` sets `PYTHONHOME` for the embedded interpreter. It is for
relocated or unusual installations; a virtualenv does not need it.

---

## Building against free-threaded CPython

`--free-threaded` needs a CPython built without the GIL (PEP 703). That is a
different interpreter with a different ABI and a different library name —
`libpython3.14t.so`, not `libpython3.14.so` — so it is chosen at *build* time,
by which `python3-embed` the build resolves, not by a flag at runtime.

Install one:

```bash
# Debian and Ubuntu, via deadsnakes
sudo add-apt-repository ppa:deadsnakes/ppa
sudo apt install python3.14-nogil python3.14-nogil-dev

# or with uv, which ships the development files with it
uv python install 3.14t
```

Then build with `pkg-config` pointed at it:

```bash
# a system install already has it on the default search path:
python3.14t -m pip install .

# a uv-managed one has to be named:
ROOT=$(dirname $(dirname $(uv python find 3.14t)))
PKG_CONFIG_PATH=$ROOT/lib/pkgconfig swift build -c release
```

Check what came out, because this is the one thing worth being sure of:

```console
$ peregrine --version
peregrine 0.1.0 (CPython 3.14.6 free-threaded)
```

Without `free-threaded` on that line, `--free-threaded` will refuse to start —
which is deliberate. The two builds are not interchangeable in either
direction, so wheels are tagged apart (`cp314-cp314t` against `cp314-cp314`)
and `pip` will not install one where the other belongs.

Everything else is unchanged: the same source, the same options, the same
application. See [CONFIG.md](CONFIG.md#free-threaded-python) for what the mode
does once it is running.

---

## Certificates, for TLS and HTTP/3

HTTP/2 over TLS and HTTP/3 both need a certificate. QUIC has no cleartext form
at all, so `--http3` without one is refused rather than downgraded.

For local work:

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 30 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

peregrine --port 8443 --tls-cert cert.pem --tls-key key.pem \
          --http3 myapp:app
```

That serves HTTP/1.1 and HTTP/2 over TCP on 8443 — negotiated by ALPN — and
HTTP/3 over UDP on 8443 as well, advertising itself to TCP clients with an
`alt-svc` header. `--quic-port` moves the UDP side if you need it elsewhere;
whatever port it lands on has to be open for **UDP**, which is a separate
firewall rule from the TCP one and the usual reason a working HTTP/3 server
looks like a broken one.

Browsers will not use HTTP/3 against a self-signed certificate. For a
browser-facing local setup use [`mkcert`](https://github.com/FiloSottile/mkcert),
which installs a local CA the browser trusts; in production use a real
certificate.

---

## Checking the install

```bash
peregrine --port 8000 --python-path examples wsgi_app:application
curl http://127.0.0.1:8000/
```

The target is `module:attribute`, not a file path — `myapp.wsgi:application`,
never `myapp/wsgi.py:application`.

The full suites, from a checkout, want a virtualenv with `aioquic`, `h2`,
`fastapi`, `django`, `websockets` and `channels` in it:

```bash
swift test                                      # 114 unit tests
bash scripts/integration-test.sh                #  38 end-to-end checks
python3 scripts/feature-test.py                 # 102 failure-mode checks
bash scripts/framework-test.sh                  #  30 against FastAPI, Django
<venv>/bin/python scripts/http2-test.py         # 116 against `h2`
<venv>/bin/python scripts/http3-test.py         #  74 against `aioquic`
python3 scripts/contrib_test.py                 #  58 Python-only
<venv>/bin/python scripts/webtransport-test.py  # 115 including FastAPI/Django
```

---

## When it goes wrong

**`no Swift toolchain found on PATH`** — install Swift 6.1+ and make sure
`swift --version` works in the same shell `pip` runs in. `sudo pip` will not
see a toolchain installed for your user.

**`pkg-config cannot find python3-embed`** — the development files for that
interpreter are missing. `python3-dev` on Debian and Ubuntu, `python3-devel` on
Fedora. On macOS, the system Python cannot supply them at all.

**`pkg-config resolves python3-embed to Python 3.11, but this build is running
under Python 3.12`** — the build would embed one interpreter and be installed
for another. Install the development files for the version you are installing
into, or run `pip` from the interpreter you intend to serve with.

**`warning: this binary embeds Python 3.12 but you are running it from 3.13`**
— the package moved between interpreters after it was built. Reinstall it in
the environment you are running it from; until you do, the application is
served by 3.12 and will not see 3.13's packages.

**`ModuleNotFoundError` for your own application** — the server looks in the
working directory and any `--python-path`. Give it the directory that contains
the top-level package, not the package itself.

**`--http3 needs --tls-cert and --tls-key`** — QUIC is encrypted from its first
packet; there is nothing to serve without a certificate.

<a name="windows"></a>
**Windows** — the I/O layer is epoll and kqueue, so there is no Windows build.
WSL 2 works normally and is what the project is developed on.

---

## Upgrading and removing

```bash
pip install --upgrade --no-cache-dir peregrine-server
```

`--no-cache-dir` matters: a cached wheel from an earlier interpreter is exactly
the thing the version tag exists to prevent you from installing, and skipping
the cache avoids finding out the hard way.

```bash
pip uninstall peregrine-server
```

Nothing is installed outside the environment — no service files, no daemon, no
state. The binary lives in the package directory and goes with it.

---

Next: [CONFIG.md](CONFIG.md) — configuring FastAPI and Django for every
protocol the server speaks. [README.md](README.md) — what it is and what it
supports. [ARCHITECTURE.md](ARCHITECTURE.md) — how it is built.
[TRANSPORT.md](TRANSPORT.md) — what each protocol does.

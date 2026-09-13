<p align="center">
  <img src="assets/peregrine-cursive-segoe.png" alt="peregrine" width="480">
</p>

# Installing Peregrine

Peregrine runs your application in CPython directly, with no socket in
between. A wheel installs the server as `peregrine._native`, an extension
module that the `peregrine` command loads into the interpreter you installed it
into. That decides everything unusual about installing it:

* **A wheel is tagged for exactly one interpreter and platform**
  (`cp312-cp312-manylinux_2_39_x86_64`, `cp314-cp314t-...`). The server is
  compiled against one CPython ABI, so `pip` will refuse it anywhere else,
  which is the correct answer rather than a limitation.
* **When a wheel matches, Swift is not required.** The Swift runtime travels
  with the module; Python is the interpreter you install into.
* **When no wheel matches, `pip` falls back to the sdist and compiles.** That
  needs a Swift toolchain and takes a few minutes, and it builds for the
  interpreter running `pip`.
* **Install it into the environment it will serve.** A virtualenv's packages
  are only importable by the interpreter that virtualenv belongs to.

The server can also be built as a standalone executable that embeds `libpython`
instead. Both take the same options; the extension module is what the wheels
ship because it is faster — see [BENCHMARKS.md](BENCHMARKS.md).

---

## What you need

A matching Linux wheel needs the interpreter itself and the usual system
libraries (`libssl`, `libicu`). Swift is not on that list.

Building from the sdist — no wheel for your tag, a checkout, a free-threaded
interpreter that has not been built yet — still needs:

| | |
|---|---|
| **Python** | 3.9 or newer, **with its development files** — `pkg-config` must be able to find `python3` (`python3-embed` for the standalone executable) |
| **Swift** | 6.1 or newer, on `PATH`. From [swift.org/install](https://swift.org/install); on Linux, `swiftly` is the least painful route |
| **OpenSSL** | development files. TLS 1.3, and QUIC's use of it, need `libssl` and `libcrypto` |
| **pkg-config** | how the build locates all of the above |
| **patchelf** | Linux only; rewrites the server so the Swift runtime can travel with it |
| **An OS with epoll or kqueue** | Linux, or macOS 14+. Not Windows — see [below](#windows) |

### Ubuntu and Debian

```bash
sudo apt install python3-dev libssl-dev pkg-config curl patchelf
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
ships has no development files, and `pkg-config` will not find it.

---

## Installing

Activate the environment you intend to serve with, then:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install peregrine-server
```

If PyPI has a wheel for this interpreter and platform, `pip` installs it in
seconds and Swift is not required. Otherwise it falls back to the sdist, the
Swift build runs, and that takes a few minutes. The first published wheels are
tagged `manylinux_2_N` for the builder's glibc (Ubuntu 24.04 is `2_39`) —
recent Linux, not every Linux. Older distros compile from the sdist. When
it finishes:

```bash
$ peregrine --version
peregrine 1.0.0 (CPython 3.12.3)
```

That second number is read from the running interpreter, not from the headers
the server was compiled against — it is the Python your applications will
actually run under. If it disagrees with the `python3` on your `PATH`, that is
worth resolving now rather than after a confusing `ImportError`.

`peregrine` and `python -m peregrine` are the same thing.

### From source

A checkout builds either form. The extension module is what the wheels carry:

```bash
git clone https://github.com/grepjava/peregrine
cd peregrine
bash scripts/build-extension.sh       # python/peregrine/_native.cpython-312-....so
PYTHONPATH=python python3 -m peregrine --python-path examples --port 8000 asgi_app:app
```

`PYTHON=python3.13 bash scripts/build-extension.sh` builds it for another
interpreter; each gets its own file, named by that interpreter's extension
suffix, so several can sit side by side.

The standalone executable embeds `libpython` instead:

```bash
swift build -c release                # binary at .build/release/peregrine
.build/release/peregrine --python-path examples --python-path python \
    --port 8000 asgi_app:app
```

The second `--python-path` is what makes `peregrine.contrib` importable from a
source checkout; an installed copy needs neither. When both forms are present,
`python -m peregrine` runs the extension module, and `PEREGRINE_NATIVE=0` makes
it run the executable instead.

If the checkout lives on a filesystem the toolchain is slow on — a Windows
drive mounted into WSL, for instance — build somewhere native instead:

```bash
swift build -c release --scratch-path ~/pgbuild
SCRATCH=~/pgbuild-ext bash scripts/build-extension.sh
```

### Building a wheel

A checkout that already has Swift can produce the same artifact CI uploads:

```bash
sudo apt install patchelf                 # Linux; rewrites the rpath
PYTHON=python3.12 bash scripts/build-wheel.sh
```

The wheel lands in `dist/` tagged for that interpreter. It carries
`peregrine/_native` with the Swift runtime vendored beside it in
`peregrine/_swift`, and leaves Python to whoever installs it. Before packaging,
the build imports the module in a fresh interpreter with the library search
path cleared, so a Swift runtime that is only found on the build machine fails
there rather than on yours. `PEREGRINE_BUILD=binary` packages the standalone
executable instead.

GitHub Actions builds the Linux matrix from
[`.github/workflows/wheels.yml`](.github/workflows/wheels.yml)
(`gh workflow run Wheels`). Uploading the wheels and the sdist is
[DEPLOY.md](DEPLOY.md), not the workflow's optional publish input.

---

## Which interpreter, and which packages

Started through the `peregrine` entry point, the launcher fills in what it can
work out and you did not say:

* `--venv` from `sys.prefix`, or from `VIRTUAL_ENV` when the server was
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

`--python-home` sets `PYTHONHOME` for the executable's embedded interpreter. It
is for relocated or unusual installations; a virtualenv does not need it. The
extension module runs in the interpreter that started it, which already has a
home, so there the option only warns.

---

## Building against free-threaded CPython

`--free-threaded` needs a CPython built without the GIL (PEP 703). That is a
different interpreter with a different ABI — `python3.14t`, whose extension
modules are `*.cpython-314t-*.so` and whose library is `libpython3.14t.so` — so
it is chosen at *build* time, by the interpreter and headers the build uses,
not by a flag at runtime.

Install one:

```bash
# Debian and Ubuntu, via deadsnakes
sudo add-apt-repository ppa:deadsnakes/ppa
sudo apt install python3.14-nogil python3.14-nogil-dev

# or with uv, which ships the development files with it
uv python install 3.14t
```

Then build for it:

```bash
# a system install already has its headers on the default search path:
python3.14t -m pip install .

# a uv-managed one has to be named:
PY=$(uv python find 3.14t)
PKG_CONFIG_PATH=$(dirname $(dirname $PY))/lib/pkgconfig PYTHON=$PY \
    bash scripts/build-extension.sh
```

The build refuses to pair a free-threaded interpreter with GIL headers, or the
reverse, and a free-threaded build checks that importing the server leaves the
GIL off: an extension that does not say it is safe without the GIL switches it
back on for the whole process. Check what came out:

```console
$ python3.14t -m peregrine --version
peregrine 1.0.0 (CPython 3.14.6 free-threaded)
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
`fastapi`, `flask` and `websockets` in it:

```bash
swift test                                      # 150 unit tests
bash scripts/integration-test.sh                #  56 end-to-end checks
python3 scripts/feature-test.py                 # 196 failure-mode checks
bash scripts/framework-test.sh                  # against real FastAPI and
                                                #   Flask applications
<venv>/bin/python scripts/http2-test.py         # 162 against `h2`
<venv>/bin/python scripts/http3-test.py         # 114 against `aioquic`
python3 scripts/contrib_test.py                 #  58 Python-only
<venv>/bin/python scripts/webtransport-test.py  # including FastAPI over HTTP/3
                                                #   and WebTransport
```

The suites drive the executable.

---

## When it goes wrong

**`no Swift toolchain found on PATH`** — `pip` fell back to the sdist because
no wheel matched this interpreter and platform. Install Swift 6.1+ and make
sure `swift --version` works in the same shell `pip` runs in. `sudo pip` will
not see a toolchain installed for your user.

**`patchelf is required to make the server relocatable`** — Linux source
builds need `patchelf` so the Swift runtime can travel with the server.
`sudo apt install patchelf`.

**`pkg-config cannot find python3`** — the development files for that
interpreter are missing. `python3-dev` on Debian and Ubuntu, `python3-devel` on
Fedora. On macOS, the system Python cannot supply them at all. A uv-managed
interpreter has them, but `pkg-config` has to be pointed at its
`lib/pkgconfig` with `PKG_CONFIG_PATH`.

**`pkg-config resolves python3 to Python 3.11, but this build is running under
Python 3.12`** — the headers belong to another interpreter. Install the
development files for the version you are installing into, or run `pip` from
the interpreter you intend to serve with.

**`pkg-config found GIL headers ... but this build is running under
free-threaded Python`** — the same mistake across the free-threaded divide,
which a version number cannot catch. Point `PKG_CONFIG_PATH` at the
free-threaded interpreter's `lib/pkgconfig`.

**`the built extension does not import`** — the module was built but will not
load in a clean interpreter, most often because the Swift runtime was not
vendored. The error below it names the library the loader could not find.

**`warning: this binary embeds Python 3.12 but you are running it from 3.13`**
— only the standalone executable says this: the package moved between
interpreters after it was built. Reinstall it in the environment you are
running it from; until you do, the application is served by 3.12 and will not
see 3.13's packages.

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
state. The server lives in the package directory and goes with it.

---

Next: [CONFIG.md](CONFIG.md) — configuring FastAPI and Flask for every
protocol the server speaks. [README.md](README.md) — what it is and what it
supports. [ARCHITECTURE.md](ARCHITECTURE.md) — how it is built.
[TRANSPORT.md](TRANSPORT.md) — what each protocol does.

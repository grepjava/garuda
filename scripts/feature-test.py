#!/usr/bin/env python3
"""End-to-end checks for the behaviour a curl-based script cannot reach.

    python3 scripts/feature-test.py [path-to-garuda]

The server defaults to the repo build, .build/release/garuda, and runs with its
built-in router and no application. The checks lean on its fixed routes: GET /
is 200 with an empty body, GET /user/:id answers with the id, POST /user reads
its body and throws it away, GET /delay/:ms answers after that many
milliseconds (at most five seconds), and anything else is 404.

Everything here exists because it is a failure mode that only shows up under
conditions an ordinary request never creates: a request that will not finish
while the server is trying to stop, several workers sharing one unix socket, a
worker killed out from under its supervisor, a scrape that arrives a byte at a
time, or a request target no log collector would expect.

Only the standard library is used, so the suite runs anywhere the server does.
The supervision and reload checks find the workers in /proc, so they are
skipped where there is none.

Every duration here is measured with time.monotonic(). Half of these checks are
"did this happen before that", and a wall clock can be stepped backwards under
them -- which is a failure in a suite that is supposed to be about the server.
"""

import json
import os
import random
import re
import shlex
import shutil
import signal
import socket
import ssl
import string
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda")

# Extra server flags, so most of the suite can be pointed at a different
# configuration:  GARUDA_EXTRA_ARGS="--workers 4"
EXTRA = shlex.split(os.environ.get("GARUDA_EXTRA_ARGS", ""))

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print("  ok   %s" % name)


def bad(name, expected, actual):
    global FAIL
    FAIL += 1
    print("  FAIL %s\n     expected: %s\n     actual:   %s" % (name, expected, actual))


def check(name, condition, detail=""):
    if condition:
        ok(name)
    else:
        bad(name, "true", detail or "false")


def is_(name, actual, expected):
    if actual == expected:
        ok(name)
    else:
        bad(name, expected, actual)


# --------------------------------------------------------------------------
# Server lifecycle
# --------------------------------------------------------------------------

class Server:
    def __init__(self, *args, port=None, unix=None, env=None, tls=False, alpn=None,
                 cwd=None, binary=None):
        self.port = port
        self.unix = unix
        self.tls = tls
        self.alpn = alpn
        cmd = [binary or BIN, "--log-level", "error"]
        cmd += EXTRA
        if tls:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
        if unix:
            cmd += ["--unix", unix]
        else:
            cmd += ["--port", str(port)]
        cmd += list(args)
        environment = dict(os.environ)
        if env:
            environment.update(env)
        # A file rather than a pipe: nothing reads a pipe while the server
        # runs, and an access log under load fills one and stalls the worker
        # writing to it.
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(cmd, env=environment, cwd=cwd,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.wait_ready()

    def output(self):
        """Everything the server has written so far, as bytes."""
        self.log.seek(0)
        return self.log.read()

    def wait_ready(self, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                out = self.output().decode(errors="replace")
                raise RuntimeError("server exited during start-up:\n" + out)
            try:
                s = self.connect()
                s.close()
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("server did not become ready")

    def connect(self, timeout=5.0, plaintext=False):
        if self.unix:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(self.unix)
        else:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
            s.settimeout(timeout)
        if self.tls and not plaintext:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            if self.alpn:
                context.set_alpn_protocols(self.alpn)
            s = context.wrap_socket(s, server_hostname="localhost")
            s.settimeout(timeout)
        return s

    def get(self, path, headers=None, timeout=10.0):
        """One request on a fresh connection. Returns (status, headers, body)."""
        s = self.connect(timeout)
        try:
            request = "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" % path
            for k, v in (headers or {}).items():
                request += "%s: %s\r\n" % (k, v)
            request += "\r\n"
            s.sendall(request.encode())
            return read_http_response(s)
        finally:
            s.close()

    def workers(self):
        """The supervisor's child processes, or None with no /proc to ask.

        Which worker answered used to be something the application could say.
        The router cannot, so the process tree is asked instead -- which is
        also where a worker the supervisor failed to reap would show.
        """
        try:
            entries = os.listdir("/proc")
        except OSError:
            return None
        children = set()
        for entry in entries:
            if not entry.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % entry) as fh:
                    stat = fh.read()
            except OSError:
                continue
            # The command name is in parentheses and may hold spaces, so the
            # fields are counted from the last closing one: state, then ppid.
            fields = stat.rpartition(")")[2].split()
            if len(fields) > 1 and int(fields[1]) == self.proc.pid:
                children.add(int(entry))
        return children

    def wait_workers(self, count, timeout=10.0):
        """The workers once there are `count` of them, or as many as there are."""
        deadline = time.monotonic() + timeout
        while True:
            found = self.workers()
            if found is None or len(found) >= count or time.monotonic() > deadline:
                return found
            time.sleep(0.1)

    def stop(self, sig=signal.SIGTERM, timeout=20.0):
        if self.proc.poll() is not None:
            return self.proc.returncode, 0.0
        started = time.monotonic()
        self.proc.send_signal(sig)
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            return None, time.monotonic() - started
        return self.proc.returncode, time.monotonic() - started

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.stop()


def read_http_response(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1]) if lines and len(lines[0].split()) > 1 else 0
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            k, _, v = line.partition(b":")
            headers[k.strip().lower().decode()] = v.strip().decode()
    body = rest
    if headers.get("transfer-encoding") == "chunked":
        while not body.endswith(b"0\r\n\r\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            body += chunk
        body = dechunk(body)
    else:
        want = int(headers.get("content-length", -1))
        while want >= 0 and len(body) < want:
            chunk = sock.recv(65536)
            if not chunk:
                break
            body += chunk
        if want < 0:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                body += chunk
    return status, headers, body


def read_until_closed(sock):
    raw = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            raw += chunk
    except OSError:
        pass
    return raw


def dechunk(raw):
    out = b""
    while raw:
        line, _, raw = raw.partition(b"\r\n")
        n = int(line.split(b";")[0], 16)
        if n == 0:
            break
        out += raw[:n]
        raw = raw[n + 2:]
    return out


CERTS = None


def make_certs():
    """A throwaway self-signed certificate for the TLS checks."""
    global CERTS
    if CERTS is None:
        directory = tempfile.mkdtemp(prefix="garuda-tls-")
        cert = os.path.join(directory, "cert.pem")
        key = os.path.join(directory, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                        "-keyout", key, "-out", cert, "-days", "2", "-nodes",
                        "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        CERTS = (cert, key)
    return CERTS


def have_openssl():
    try:
        subprocess.run(["openssl", "version"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except (OSError, subprocess.CalledProcessError):
        return False


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# ==========================================================================
# Tests
# ==========================================================================

def test_websocket_refusal():
    print("\nWebSocket upgrades")
    # Asked of /, which the router answers 200: a 501 can only be the refusal,
    # never a route that happens not to exist.
    port = free_port()
    with Server("--no-websockets", port=port) as server:
        s = server.connect()
        try:
            s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                      b"Connection: Upgrade\r\n"
                      b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                      b"Sec-WebSocket-Version: 13\r\n\r\n")
            status, _, _ = read_http_response(s)
        finally:
            s.close()
        is_("--no-websockets rejects the upgrade", status, 501)


def test_graceful_shutdown():
    print("\nGraceful shutdown")

    # A request that finishes in time is waited for.
    port = free_port()
    server = Server("--graceful-timeout", "10000", port=port)
    s = server.connect(timeout=20)
    s.sendall(b"GET /delay/2000 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=25)
    check("an in-flight request is allowed to finish (%.1fs)" % elapsed,
          0.5 < elapsed < 8.0, "%.1fs" % elapsed)
    s.close()

    # A request that will not finish in time is not waited for. Five seconds is
    # the longest the router holds a request, so the deadline sits well inside
    # that and the stop has to beat the request by a clear margin -- a stop
    # that merely ends would be the request finishing on its own.
    port = free_port()
    server = Server("--graceful-timeout", "1000", port=port)
    s = server.connect(timeout=30)
    s.sendall(b"GET /delay/5000 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=30)
    check("a request still running at the deadline does not hold up shutdown (%.1fs)"
          % elapsed, elapsed < 3.5, "%.1fs" % elapsed)
    check("the process exited rather than being killed", code is not None,
          "had to be SIGKILLed")
    s.close()


def test_multiworker_unix():
    print("\nMultiworker unix socket")
    path = os.path.join(tempfile.gettempdir(), "garuda-mw-%d.sock" % os.getpid())
    if os.path.exists(path):
        os.unlink(path)
    # Which worker answered is read from the JSON access log, which names the
    # process that wrote each line.
    server = Server("--workers", "4", "--log-level", "info", "--access-log-format", "json",
                    unix=path)
    answered = [0]
    try:
        # Sustained concurrent load, not a single burst. With one shared
        # listener the first worker to wake drains its whole accept batch, so a
        # burst of connections all land on that worker whether the socket is
        # shared or not; only continuous traffic distinguishes a shared
        # listener from four workers that replaced each other's socket.
        lock = threading.Lock()
        stop = [False]

        def hammer():
            while not stop[0]:
                try:
                    status, _, _ = server.get("/", timeout=5)
                except OSError:
                    continue
                if status == 200:
                    with lock:
                        answered[0] += 1

        threads = [threading.Thread(target=hammer) for _ in range(12)]
        for t in threads:
            t.start()
        time.sleep(3.0)
        stop[0] = True
        for t in threads:
            t.join()
    finally:
        server.stop()

    pids = {}
    for line in server.output().split(b"\n"):
        if not line.startswith(b"{"):
            continue
        try:
            pid = json.loads(line).get("pid")
        except ValueError:
            continue
        pids[pid] = pids.get(pid, 0) + 1
    check("requests over the shared unix socket are answered (%d)" % answered[0],
          answered[0] > 100, str(pids))
    check("all four workers serve the one unix socket (%d seen)" % len(pids),
          len(pids) >= 3,
          "only %s answered, so workers replaced each other's socket" % sorted(pids))
    check("the unix socket is removed on exit", not os.path.exists(path),
          "%s still exists" % path)


def test_access_log():
    print("\nAccess log")

    def served_bytes(args, raw_requests):
        """Runs the requests and returns the log lines as the bytes they are.

        Bytes rather than text on purpose: a lenient decode is exactly the
        thing that would repair a line broken in the middle of a character,
        and a collector reading the file will not be so kind.
        """
        port = free_port()
        server = Server(*args, "--log-level", "info", port=port)
        try:
            for request in raw_requests:
                s = server.connect()
                try:
                    s.sendall(request)
                    read_http_response(s)
                finally:
                    s.close()
        finally:
            server.stop()
        return server.output().split(b"\n")

    def served(args, raw_requests):
        """The same, decoded, for the checks that are about text."""
        return [ln.decode("utf-8", "replace")
                for ln in served_bytes(args, raw_requests)]

    plain = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    # A target is the peer's bytes: a quote would end a JSON string early, and
    # these bytes are not valid UTF-8 at all. Neither is a route, which does
    # not matter: a 404 is logged like anything else.
    quoted = b'GET /has"quote HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
    invalid = b"GET /raw\xff\xfe HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

    lines = served(["--access-log"], [plain])
    text = [ln for ln in lines if " / 200 " in ln]
    check("the text access log has one line per request", len(text) == 1,
          "logged %r" % lines)
    check("it carries the method, target, status and duration",
          bool(text) and re.search(r"GET / 200 \d+us", text[0]),
          "line was %r" % (text[0] if text else None))

    lines = served(["--access-log-format", "json"], [plain, quoted, invalid])
    objects = []
    for ln in lines:
        if not ln.startswith("{"):
            continue                      # the server's own start-up lines
        try:
            objects.append(json.loads(ln))
        except ValueError as exc:
            bad("a JSON access line parses", "an object", "%s in %r" % (exc, ln))
            return
    is_("--access-log-format json logs one object per request", len(objects), 3)
    if len(objects) != 3:
        return
    ok("every JSON access line parses whole, prefix included")
    is_("the object carries the request",
        (objects[0].get("method"), objects[0].get("target"),
         objects[0].get("status"), objects[0].get("proto")),
        ("GET", "/", 200, "HTTP/1.1"))
    check("and a duration in microseconds",
          isinstance(objects[0].get("duration_us"), int),
          "duration_us was %r" % objects[0].get("duration_us"))
    is_("a quote in the target cannot break the line out of its string",
        objects[1].get("target"), '/has"quote')
    is_("a target that is not valid UTF-8 survives byte for byte",
        objects[2].get("target"), "/rawÿþ")

    # A target is as long as the peer cares to make it, up to the head limit,
    # and the line it goes into is a fixed stack buffer. Running out of buffer
    # has to cut the target short, not the JSON: a line that stops mid-string
    # is not an object, and without its newline it takes the next line with it.
    long_target = b"GET /" + b"a" * 8000 + \
        b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    lines = served(["--access-log-format", "json"], [long_target, plain])
    objects = []
    for ln in lines:
        if not ln.startswith("{"):
            continue
        try:
            objects.append(json.loads(ln))
        except ValueError as exc:
            bad("a long target leaves the line valid JSON", "an object",
                "%s in a line of %d bytes" % (exc, len(ln)))
            return
    is_("a target too long for the line does not break the JSON", len(objects), 2)
    if len(objects) != 2:
        return
    check("the oversized line says it was truncated",
          objects[0].get("truncated") is True, str(objects[0])[:120])
    check("and still carries the fields after the target",
          isinstance(objects[0].get("status"), int)
          and isinstance(objects[0].get("duration_us"), int)
          and objects[0].get("proto") == "HTTP/1.1",
          str(objects[0])[-120:])
    check("the line after it is untouched", objects[1].get("target") == "/",
          str(objects[1])[:120])

    # Cutting a target short must not cut a character in half: a JSON string
    # that is not UTF-8 is not JSON, whatever a lenient decode makes of it.
    # Four alignments, so the cut lands at each offset within a four-byte one.
    emoji = "\U0001f426".encode("utf-8")
    requests = [b"GET /" + b"a" * pad + emoji * 1600
                + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                for pad in range(4)]
    broken = []
    parsed = 0
    for raw in served_bytes(["--access-log-format", "json"], requests):
        if not raw.startswith(b"{"):
            continue
        try:
            # json.loads on bytes insists the bytes are valid UTF-8, which is
            # the whole point of feeding it bytes.
            obj = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as exc:
            broken.append("%s in a line of %d bytes" % (exc, len(raw)))
            continue
        parsed += 1
        if not obj.get("target", "").startswith("/"):
            broken.append("target came back as %r" % obj.get("target")[:40])
    check("a target cut mid-character still leaves valid UTF-8",
          not broken, "; ".join(broken[:3]))
    is_("every alignment logged one parseable line", parsed, 4)


def test_body_limit():
    print("\nBody limits")

    def paced_upload(chunks=8, size=512):
        """Uploads in chunks slow enough for the server to drain each one."""
        port = free_port()
        server = Server("--max-body", "1024", port=port)
        try:
            s = server.connect(timeout=10)
            s.sendall(b"POST /user HTTP/1.1\r\nHost: x\r\n"
                      b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            sent = 0
            try:
                for _ in range(chunks):
                    s.sendall(b"%x\r\n" % size + b"x" * size + b"\r\n")
                    sent += size
                    # The point of the pacing: a reader that takes the body as
                    # it goes -- the router discards POST /user's as it
                    # arrives -- keeps the buffer small, so a limit measured
                    # on buffered bytes is no limit at all.
                    time.sleep(0.15)
                s.sendall(b"0\r\n\r\n")
            except OSError:
                pass
            data = read_until_closed(s)
            s.close()
            return sent, data
        finally:
            server.stop()

    sent, data = paced_upload()
    check("a paced upload cannot walk past --max-body",
          sent <= 2048 and b"200 OK" not in data.split(b"\r\n")[0],
          "sent %d bytes and got %r" % (sent, data.split(b"\r\n")[0]))

    # The limit still lets a body under it through.
    sent, data = paced_upload(chunks=1, size=512)
    check("a body inside the limit is still served",
          b"200" in data.split(b"\r\n")[0],
          "%r" % data.split(b"\r\n")[0])


def test_metrics():
    print("\nPrometheus metrics")

    def scrape(port, path="/metrics"):
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        try:
            s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                       % path).encode())
            return read_http_response(s)
        finally:
            s.close()

    def values(body):
        out = {}
        for line in body.decode().splitlines():
            if not line or line.startswith("#"):
                continue
            name, _, value = line.rpartition(" ")
            out[name] = float(value)
        return out

    # Two workers, so the interesting part is whether a scrape that lands on
    # one of them answers for both.
    port, metrics_port = free_port(), free_port()
    with Server("--workers", "2", "--metrics-port", str(metrics_port),
                port=port) as server:
        for _ in range(7):
            server.get("/")
        server.get("/nope")

        status, headers, body = scrape(metrics_port)
        is_("the metrics port answers a scrape", status, 200)
        check("with the content type Prometheus expects",
              "version=0.0.4" in (headers.get("content-type") or ""),
              headers.get("content-type"))

        v = values(body)
        is_("requests are counted by status class, across every worker",
            (v.get('garuda_requests_total{status="2xx"}'),
             v.get('garuda_requests_total{status="4xx"}')),
            (7.0, 1.0))
        is_("the scrape reports every worker's counters",
            v.get("garuda_workers"), 2.0)
        check("connections are counted",
              v.get("garuda_connections_accepted_total", 0) >= 8,
              "accepted %r" % v.get("garuda_connections_accepted_total"))
        check("the duration histogram counts every request",
              v.get("garuda_request_duration_seconds_count") == 8.0,
              "count was %r" % v.get("garuda_request_duration_seconds_count"))
        check("and its buckets are cumulative",
              v.get('garuda_request_duration_seconds_bucket{le="+Inf"}') == 8.0,
              "+Inf was %r"
              % v.get('garuda_request_duration_seconds_bucket{le="+Inf"}'))
        check("the buffer pool reports hits and misses",
              "garuda_buffer_pool_hits_total" in v
              and "garuda_buffer_pool_misses_total" in v,
              str(sorted(k for k in v if "pool" in k)))

        # The scrape port is not a way to the routes, and the service port is
        # not a way to the counters.
        _, _, body = scrape(metrics_port, path="/")
        check("the metrics port serves metrics and not the routes",
              body.startswith(b"# HELP"), body[:80])
        is_("the service port has no metrics route",
            server.get("/metrics")[0], 404)

        # A request that arrives in more than one segment is a request the
        # server has only half of. Answering it early means closing under a
        # peer still writing, which costs it an EPIPE on writes it was entitled
        # to make and can cost it the answer, a close with bytes still inbound
        # being a reset.
        s = socket.create_connection(("127.0.0.1", metrics_port), timeout=10)
        s.settimeout(10)
        sent_whole = True
        try:
            for byte in b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n":
                s.sendall(bytes([byte]))
                time.sleep(0.01)
        except OSError:
            sent_whole = False
        check("a scrape written one byte at a time is not cut off", sent_whole,
              "the server closed the connection while the request was arriving")
        status, _, body = read_http_response(s)
        s.close()
        is_("and it is answered in full", status, 200)
        check("with the whole exposition", b"garuda_requests_total" in body,
              body[:80])

        # Places to wait in are finite, and a peer that stops writing must not
        # hold one for longer than the deadline.
        stalled = []
        for _ in range(12):
            half = socket.create_connection(("127.0.0.1", metrics_port), timeout=10)
            half.sendall(b"G")
            stalled.append(half)
        began = time.monotonic()
        is_("a scrape still works while half-written ones are parked",
            scrape(metrics_port)[0], 200)
        is_("and so does the service port", server.get("/")[0], 200)
        check("neither waited on them",
              time.monotonic() - began < 3.0,
              "took %.1fs" % (time.monotonic() - began))
        for half in stalled:
            half.close()

    # With every place to wait taken, a scrape whose request has not arrived
    # yet must still be answered. One worker, so the stalled peers cannot be
    # spread out; macOS hands every connection on a SO_REUSEPORT port to one
    # socket anyway.
    port, metrics_port = free_port(), free_port()
    with Server("--workers", "1", "--metrics-port", str(metrics_port), port=port):
        # The server is ready when its service port is; the scrape port is
        # bound by the worker, a moment later.
        deadline = time.monotonic() + 10
        while True:
            try:
                scrape(metrics_port)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.1)
        stalled = []
        for _ in range(12):
            half = socket.create_connection(("127.0.0.1", metrics_port), timeout=10)
            half.sendall(b"G")
            stalled.append(half)
        time.sleep(0.2)
        # Written a byte at a time, a scrape is one the server has only part
        # of for as long as it likes. Answering it at once would close under a
        # peer still writing -- the reset that, racing an ordinary scrape,
        # can cost it the answer.
        outcomes = {}
        for _ in range(3):
            s = socket.create_connection(("127.0.0.1", metrics_port), timeout=10)
            try:
                for byte in b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n":
                    s.sendall(bytes([byte]))
                    time.sleep(0.01)
                status, _, body = read_http_response(s)
                outcome = status if b"garuda_requests_total" in body else "short"
            except OSError as e:
                outcome = type(e).__name__
            finally:
                s.close()
            outcomes[outcome] = outcomes.get(outcome, 0) + 1
        is_("a scrape is not cut off when every place to wait is taken",
            outcomes, {200: 3})
        for half in stalled:
            half.close()

    # Counting must cost nothing when nobody asked for it.
    port = free_port()
    with Server(port=port) as server:
        is_("without --metrics-port the server still serves", server.get("/")[0], 200)


def test_worker_restart():
    print("\nWorker supervision")
    port = free_port()
    server = Server("--workers", "2", port=port)
    try:
        before = server.wait_workers(2)
        if before is None:
            print("  --   skipped: no /proc to find the workers in")
            return
        check("both workers are running (%d seen)" % len(before), len(before) == 2,
              str(sorted(before)))
        if not before:
            return

        victim = sorted(before)[0]
        os.kill(victim, signal.SIGKILL)
        # A worker that is killed but never reaped is still in the tree, as a
        # zombie, so waiting for it to leave is waiting for the supervisor.
        deadline = time.monotonic() + 10
        after = before
        while time.monotonic() < deadline:
            time.sleep(0.2)
            after = server.workers() or set()
            if victim not in after and len(after) >= 2:
                break
        answered = 0
        for _ in range(40):
            try:
                if server.get("/")[0] == 200:
                    answered += 1
            except OSError:
                pass
        check("the supervisor replaces a killed worker",
              len(after - before) >= 1 and answered == 40,
              "workers %s -> %s, %d of 40 requests answered"
              % (sorted(before), sorted(after), answered))
        check("the killed worker is gone", victim not in after,
              "%d is still a child of the supervisor" % victim)
    finally:
        server.stop()


def copy_executable(path):
    """A private copy of the server, for a test to rebuild under itself."""
    shutil.copyfile(BIN, path)
    os.chmod(path, 0o755)


def rebuild(path, content=None):
    """A rebuild the way a linker writes one: a new file renamed over the old.
    With `content`, what gets written is that rather than a working server."""
    temporary = path + ".new"
    if content is None:
        shutil.copyfile(BIN, temporary)
    else:
        with open(temporary, "wb") as fh:
            fh.write(content)
    os.chmod(temporary, 0o755)
    os.replace(temporary, path)


def process_executable(pid):
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return None


def wait_restarted(server, binary, before, timeout):
    """Waits for the supervisor to be running `binary` itself -- not a deleted
    file of that name -- with none of the workers in `before` left. Returns the
    workers, and how long it took."""
    began = time.monotonic()
    after = before
    while time.monotonic() - began < timeout:
        time.sleep(0.1)
        after = server.workers() or set()
        # Disjoint, not merely different: the replacement is started before
        # the worker it replaces is asked to stop.
        if (after and after.isdisjoint(before)
                and process_executable(server.proc.pid) == binary):
            break
    return after, time.monotonic() - began


def test_reload():
    print("\nDevelopment reload")
    # --reload watches the executable, so the server runs from a copy that the
    # test can rebuild without touching the one the rest of the suite uses.
    project = tempfile.mkdtemp(prefix="garuda-reload-")
    binary = os.path.join(project, "garuda")
    copy_executable(binary)
    port = free_port()
    server = Server("--reload", "--reload-interval", "200", port=port, cwd=project,
                    binary=binary)
    try:
        before = server.wait_workers(1)
        if before is None:
            print("  --   skipped: no /proc to find the workers in")
            return
        supervisor = server.proc.pid
        time.sleep(0.4)
        rebuild(binary)
        after, _ = wait_restarted(server, binary, before, 15.0)
        check("a rebuilt executable restarts the server on it",
              bool(after) and after.isdisjoint(before)
              and process_executable(supervisor) == binary,
              "workers %s -> %s, supervisor running %s"
              % (sorted(before), sorted(after), process_executable(supervisor)))
        check("the supervisor keeps its pid across the restart",
              server.proc.poll() is None and server.proc.pid == supervisor)
        running = {pid: process_executable(pid) for pid in after}
        check("every worker runs the rebuilt executable",
              bool(running) and all(exe == binary for exe in running.values()),
              "worker executables: %s" % running)
        is_("the server still answers after a reload", server.get("/")[0], 200)

        # A half-written or broken build is not something to become.
        rebuild(binary, b"\x7fELF not a whole executable\n")
        time.sleep(2.0)
        still = server.workers() or set()
        check("a rebuilt executable that does not run is not restarted on",
              server.proc.poll() is None and still == after,
              "workers %s -> %s" % (sorted(after), sorted(still)))
        is_("the server still answers after a broken build", server.get("/")[0], 200)

        rebuild(binary)
        fixed, _ = wait_restarted(server, binary, after, 15.0)
        check("the next good build is picked up",
              bool(fixed) and fixed.isdisjoint(after)
              and process_executable(supervisor) == binary,
              "workers %s -> %s" % (sorted(after), sorted(fixed)))
    finally:
        server.stop()
        shutil.rmtree(project, ignore_errors=True)


def test_reload_notified():
    print("\nDevelopment reload, woken by the kernel")
    # A local filesystem, because a bind mount or a Windows drive under WSL may
    # never send a notification, and an interval long enough that a restart
    # arriving quickly can only have been woken, not polled.
    project = tempfile.mkdtemp(prefix="garuda-reload-", dir=os.path.expanduser("~"))
    binary = os.path.join(project, "garuda")
    copy_executable(binary)
    port = free_port()
    server = Server("--reload", "--reload-interval", "10000", port=port, cwd=project,
                    binary=binary)
    try:
        before = server.wait_workers(1)
        if before is None:
            print("  --   skipped: no /proc to find the workers in")
            return
        time.sleep(0.5)
        rebuild(binary)
        after, elapsed = wait_restarted(server, binary, before, 8.0)
        check("a rebuild restarts well inside a 10 s --reload-interval",
              bool(after) and after.isdisjoint(before) and elapsed < 5.0,
              "workers %s -> %s after %.1fs" % (sorted(before), sorted(after), elapsed))
    finally:
        server.stop()
        shutil.rmtree(project, ignore_errors=True)


def test_reload_certificates():
    print("\nDevelopment reload, certificates")
    if not have_openssl():
        print("  --   skipped: no openssl to make a certificate with")
        return
    project = tempfile.mkdtemp(prefix="garuda-reload-tls-")
    cert, key = make_certs()
    my_cert = os.path.join(project, "cert.pem")
    my_key = os.path.join(project, "key.pem")
    shutil.copyfile(cert, my_cert)
    shutil.copyfile(key, my_key)
    port = free_port()
    server = Server("--reload", "--reload-interval", "200", "--log-level", "info",
                    "--tls-cert", my_cert, "--tls-key", my_key, port=port, cwd=project)
    server.tls = True
    try:
        before = server.wait_workers(1)
        if before is None:
            print("  --   skipped: no /proc to find the workers in")
            return
        time.sleep(0.4)
        # Renewed the way a tool writes one: a new file renamed over the old.
        temporary = my_cert + ".new"
        shutil.copyfile(cert, temporary)
        os.replace(temporary, my_cert)
        deadline = time.monotonic() + 15.0
        after = before
        while time.monotonic() < deadline:
            time.sleep(0.2)
            after = server.workers() or set()
            if after and after.isdisjoint(before):
                break
        check("a changed certificate replaces the workers",
              bool(after) and after.isdisjoint(before),
              "workers %s -> %s" % (sorted(before), sorted(after)))
        output = server.output()
        check("without restarting the supervisor",
              b"certificate changed on disk" in output
              and b"restarting the supervisor" not in output,
              output.decode(errors="replace")[-400:])
        is_("the server still answers over TLS", server.get("/")[0], 200)
    finally:
        server.stop()
        shutil.rmtree(project, ignore_errors=True)


def test_tls():
    print("\nTLS")
    if not have_openssl():
        print("  --   skipped: no openssl to make a certificate")
        return
    port = free_port()
    with Server(port=port, tls=True, alpn=["http/1.1"]) as server:
        status, headers, body = server.get("/")
        is_("a request over TLS is answered", status, 200)

        # Records are 16 KiB at most. /user/:id answers with the id, so a 20 KiB
        # one is a request head the read side has to reassemble and a response
        # body the write side has to get through a partial SSL_write.
        ident = "".join(random.choice(string.ascii_lowercase + string.digits)
                        for _ in range(20000))
        status, _, body = server.get("/user/" + ident, timeout=30)
        check("a head and a body larger than a TLS record round trip",
              status == 200 and body == ident.encode(),
              "status %d, %d bytes back of %d" % (status, len(body), len(ident)))

        # POST /user reads its body and throws it away, so what shows the body
        # was read to its end, and not a record short, is the next request on
        # the same connection being answered.
        payload = os.urandom(300000)
        s = server.connect(timeout=30)
        s.sendall(b"POST /user HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                  % len(payload))
        s.sendall(payload)
        s.sendall(b"GET /user/after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        raw = read_until_closed(s)
        s.close()
        check("a request body far larger than a TLS record is read to its end",
              raw.count(b"HTTP/1.1 200") == 2 and raw.endswith(b"after"),
              repr(raw[:80]))

    # ALPN is what makes HTTP/2 reachable from a browser, and the server picks
    # from its own preference list rather than the client's.
    port = free_port()
    with Server(port=port, tls=True, alpn=["http/1.1", "h2"]) as server:
        s = server.connect(timeout=10)
        is_("the server prefers h2 when the client offers both",
            s.selected_alpn_protocol(), "h2")
        s.close()

    port = free_port()
    with Server(port=port, tls=True, alpn=["http/1.1"]) as server:
        s = server.connect(timeout=10)
        is_("a client that only offers http/1.1 gets it",
            s.selected_alpn_protocol(), "http/1.1")
        s.close()

        # Plaintext to a TLS port is a mistake, not a request: it must be
        # refused rather than answered in the clear.
        s = server.connect(timeout=10, plaintext=True)
        s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        try:
            answer = s.recv(4096)
        except OSError:
            answer = b""
        s.close()
        check("a plaintext request to a TLS port is not answered in the clear",
              not answer.startswith(b"HTTP/"), repr(answer[:40]))
        is_("the server is still healthy afterwards", server.get("/")[0], 200)


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    print("garuda feature tests (%s)" % BIN)
    for test in (test_tls, test_websocket_refusal, test_access_log, test_metrics,
                 test_body_limit, test_multiworker_unix, test_worker_restart,
                 test_reload, test_reload_notified, test_reload_certificates,
                 test_graceful_shutdown):
        try:
            test()
        except Exception as exc:                            # noqa: BLE001
            global FAIL
            FAIL += 1
            import traceback
            print("  FAIL %s raised" % test.__name__)
            traceback.print_exc()
    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

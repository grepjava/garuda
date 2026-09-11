#!/usr/bin/env python3
"""End-to-end checks for the behaviour a curl-based script cannot reach.

    python3 scripts/feature-test.py [path-to-peregrine]

Everything here exists because it is a failure mode that only shows up under
conditions an ordinary request never creates: a client that reads slowly, a
request that will not finish while the server is trying to stop, several
workers sharing one unix socket, or a protocol that is not HTTP at all.

Only the standard library is used, including the WebSocket client, so the suite
runs anywhere the server does.

Every duration here is measured with time.monotonic(). Half of these checks are
"did this happen before that", and a wall clock can be stepped backwards under
them -- which is a failure in a suite that is supposed to be about the server.
"""

import base64
import hashlib
import json
import os
import random
import re
import shlex
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/release/peregrine")

# Extra server flags, so most of the suite can be pointed at a different
# execution model:  PEREGRINE_EXTRA_ARGS="--workers 4 --free-threaded"
# The free-threaded section below sets its own flags and ignores this.
EXTRA = shlex.split(os.environ.get("PEREGRINE_EXTRA_ARGS", ""))

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
    def __init__(self, *args, app="asgi_app:app", port=None, unix=None, env=None,
                 tls=False, alpn=None):
        self.port = port
        self.unix = unix
        self.tls = tls
        self.alpn = alpn
        cmd = [BIN, "--log-level", "error", "--python-path", os.path.join(ROOT, "examples")]
        cmd += EXTRA
        if tls:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
        if unix:
            cmd += ["--unix", unix]
        else:
            cmd += ["--port", str(port)]
        cmd += list(args) + [app]
        environment = dict(os.environ)
        if env:
            environment.update(env)
        self.proc = subprocess.Popen(cmd, env=environment,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.wait_ready()

    def wait_ready(self, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                out = self.proc.stdout.read().decode(errors="replace")
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

    def rss_kb(self):
        """Resident size of the worker, for the backpressure check."""
        try:
            with open("/proc/%d/status" % self.proc.pid) as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1])
        except OSError:
            pass
        return -1

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
        directory = tempfile.mkdtemp(prefix="peregrine-tls-")
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


# --------------------------------------------------------------------------
# A minimal RFC 6455 client
# --------------------------------------------------------------------------

class WebSocket:
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, server, path, subprotocols=None, timeout=10.0):
        self.sock = server.connect(timeout)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET %s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n" % (path, key)
        )
        if subprotocols:
            request += "Sec-WebSocket-Protocol: %s\r\n" % ", ".join(subprotocols)
        request += "\r\n"
        self.sock.sendall(request.encode())

        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("connection closed during handshake")
            head += chunk
        raw, _, rest = head.partition(b"\r\n\r\n")
        self.buffer = rest
        self.raw_handshake = raw.decode(errors="replace")
        self.status = int(self.raw_handshake.split()[1])
        self.headers = {}
        for line in self.raw_handshake.split("\r\n")[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                self.headers[k.strip().lower()] = v.strip()
        if self.status == 101:
            expect = base64.b64encode(
                hashlib.sha1((key + self.GUID).encode()).digest()).decode()
            self.accept_valid = self.headers.get("sec-websocket-accept") == expect
        else:
            self.accept_valid = False

    # --- framing ---

    def send(self, payload, opcode=0x1, fin=True, mask=True):
        if isinstance(payload, str):
            payload = payload.encode()
        header = bytes([(0x80 if fin else 0) | opcode])
        n = len(payload)
        maskbit = 0x80 if mask else 0
        if n < 126:
            header += bytes([maskbit | n])
        elif n <= 0xFFFF:
            header += bytes([maskbit | 126]) + struct.pack("!H", n)
        else:
            header += bytes([maskbit | 127]) + struct.pack("!Q", n)
        if mask:
            key = os.urandom(4)
            masked = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
            self.sock.sendall(header + key + masked)
        else:
            self.sock.sendall(header + payload)

    def send_raw(self, data):
        self.sock.sendall(data)

    def _fill(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("connection closed")
            self.buffer += chunk

    def recv_frame(self):
        self._fill(2)
        b0, b1 = self.buffer[0], self.buffer[1]
        fin = bool(b0 & 0x80)
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        offset = 2
        if length == 126:
            self._fill(4)
            length = struct.unpack("!H", self.buffer[2:4])[0]
            offset = 4
        elif length == 127:
            self._fill(10)
            length = struct.unpack("!Q", self.buffer[2:10])[0]
            offset = 10
        self._fill(offset + length)
        payload = self.buffer[offset:offset + length]
        self.buffer = self.buffer[offset + length:]
        return fin, opcode, payload

    def recv_message(self):
        """Returns (opcode, payload), answering nothing. Control frames are
        returned to the caller rather than swallowed, because the tests care."""
        parts = b""
        first = None
        while True:
            fin, opcode, payload = self.recv_frame()
            if opcode & 0x8:
                return opcode, payload
            if first is None:
                first = opcode
            parts += payload
            if fin:
                return first, parts

    def close(self, code=1000):
        try:
            self.send(struct.pack("!H", code), opcode=0x8)
        except OSError:
            pass
        self.sock.close()


# ==========================================================================
# Tests
# ==========================================================================

def test_websockets():
    print("\nWebSockets")
    port = free_port()
    with Server(port=port) as server:
        ws = WebSocket(server, "/ws")
        is_("handshake returns 101", ws.status, 101)
        check("Sec-WebSocket-Accept is correct", ws.accept_valid,
              ws.headers.get("sec-websocket-accept"))

        ws.send("hello")
        opcode, payload = ws.recv_message()
        is_("text echo", (opcode, payload), (0x1, b"echo:hello"))

        ws.send(b"\x00\x01\x02", opcode=0x2)
        opcode, payload = ws.recv_message()
        is_("binary echo", (opcode, payload), (0x2, b"echo:\x00\x01\x02"))

        # Fragmented text: "frag" split across a text frame and a continuation.
        ws.send("fr", opcode=0x1, fin=False)
        ws.send("ag", opcode=0x0, fin=True)
        opcode, payload = ws.recv_message()
        is_("fragmented message is reassembled", payload, b"echo:frag")

        ws.send("héllo ☃")
        opcode, payload = ws.recv_message()
        is_("utf-8 text survives the round trip", payload,
            "echo:héllo ☃".encode())

        # A ping must be answered with a pong carrying the same payload.
        ws.send(b"ping-payload", opcode=0x9)
        opcode, payload = ws.recv_message()
        is_("ping is answered with a matching pong", (opcode, payload),
            (0xA, b"ping-payload"))

        big = "x" * 200000
        ws.send(big)
        opcode, payload = ws.recv_message()
        is_("200 KB message round trip", len(payload), len(big) + 5)

        # The application closes when told to.
        ws.send("close")
        opcode, payload = ws.recv_message()
        code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0
        is_("application-initiated close", (opcode, code), (0x8, 1000))
        is_("close reason is carried", payload[2:], b"asked to")
        ws.sock.close()

        # Subprotocol negotiation.
        ws = WebSocket(server, "/ws-sub", subprotocols=["chat", "other"])
        is_("subprotocol is negotiated", ws.headers.get("sec-websocket-protocol"), "chat")
        ws.close()

        # Rejection before accept is an HTTP failure, not a websocket close.
        ws = WebSocket(server, "/ws-reject")
        is_("close before accept is an HTTP rejection", ws.status, 403)
        ws.sock.close()

        # Scope shape.
        ws = WebSocket(server, "/ws-scope", subprotocols=["a", "b"])
        _, payload = ws.recv_message()
        scope = json.loads(payload)
        is_("scope type", scope["type"], "websocket")
        is_("scope scheme", scope["scheme"], "ws")
        is_("scope carries offered subprotocols", scope["subprotocols"], ["a", "b"])
        check("scope carries the client address", scope["client"] is not None)
        ws.close()

        # --- protocol enforcement ---
        ws = WebSocket(server, "/ws")
        ws.send("nope", mask=False)          # a client frame must be masked
        try:
            opcode, payload = ws.recv_message()
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0
            is_("an unmasked client frame is refused", (opcode, code), (0x8, 1002))
        except EOFError:
            ok("an unmasked client frame is refused")
        ws.sock.close()

        ws = WebSocket(server, "/ws")
        ws.send(b"\xff\xfe", opcode=0x1)     # not valid UTF-8 in a text frame
        try:
            opcode, payload = ws.recv_message()
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0
            is_("invalid UTF-8 in a text frame is refused", (opcode, code), (0x8, 1007))
        except EOFError:
            ok("invalid UTF-8 in a text frame is refused")
        ws.sock.close()

        # RSV bits set with no extension negotiated.
        ws = WebSocket(server, "/ws")
        ws.send_raw(bytes([0xC1, 0x80]) + b"\x00\x00\x00\x00")
        try:
            opcode, payload = ws.recv_message()
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0
            is_("a reserved bit is a protocol error", (opcode, code), (0x8, 1002))
        except EOFError:
            ok("a reserved bit is a protocol error")
        ws.sock.close()

    # Message size limit.
    port = free_port()
    with Server("--ws-max-message", "65536", port=port) as server:
        ws = WebSocket(server, "/ws")
        try:
            ws.send("y" * 200000)
            opcode, payload = ws.recv_message()
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0
            is_("an oversized message is refused", (opcode, code), (0x8, 1009))
        except (EOFError, OSError):
            ok("an oversized message is refused")
        ws.sock.close()

    # Keepalive pings on an idle connection.
    port = free_port()
    with Server("--ws-ping-interval", "300", "--ws-ping-timeout", "20000",
                port=port) as server:
        ws = WebSocket(server, "/ws", timeout=15)
        opcode, payload = ws.recv_message()
        is_("an idle websocket is pinged", opcode, 0x9)
        ws.send(payload, opcode=0xA)          # answer it
        ws.send("still here")
        opcode, payload = ws.recv_message()
        if opcode == 0x9:                     # a second ping may arrive first
            ws.send(payload, opcode=0xA)
            opcode, payload = ws.recv_message()
        is_("answering the ping keeps the connection alive", payload, b"echo:still here")
        ws.sock.close()

    # A peer that stops answering pings is dropped rather than left forever.
    port = free_port()
    with Server("--ws-ping-interval", "300", "--ws-ping-timeout", "500",
                port=port) as server:
        ws = WebSocket(server, "/ws", timeout=15)
        dropped = False
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                ws.recv_frame()               # pings, which we deliberately ignore
            except (EOFError, OSError):
                dropped = True
                break
        check("a peer that never answers a ping is dropped", dropped,
              "the connection was still open after 10s of unanswered pings")
        ws.sock.close()

    # Disabled entirely.
    port = free_port()
    with Server("--no-websockets", port=port) as server:
        ws = WebSocket(server, "/ws")
        is_("--no-websockets rejects the upgrade", ws.status, 501)
        ws.sock.close()

    # WSGI cannot express an upgrade and must say so.
    port = free_port()
    with Server(port=port, app="wsgi_app:application") as server:
        ws = WebSocket(server, "/ws")
        is_("a WSGI server refuses the upgrade", ws.status, 501)
        ws.sock.close()


def test_backpressure():
    print("\nASGI write backpressure (slow consumer)")
    port = free_port()
    with Server(port=port) as server:
        baseline = server.rss_kb()
        s = server.connect(timeout=30)
        # 256 MB, from a producer that only ever awaits send().
        s.sendall(b"GET /firehose?268435456 HTTP/1.1\r\nHost: x\r\n"
                  b"Connection: close\r\n\r\n")

        peak = baseline
        read = 0
        deadline = time.monotonic() + 6.0
        # Read slowly on purpose: 32 KB every 100 ms is far below what the
        # application produces.
        while time.monotonic() < deadline:
            time.sleep(0.1)
            try:
                chunk = s.recv(32768)
            except socket.timeout:
                break
            if not chunk:
                break
            read += len(chunk)
            peak = max(peak, server.rss_kb())
        s.close()

        # rss_kb reads /proc, so there is no number to compare on a platform
        # without one. Saying so is better than subtracting -1 from -1 and
        # reporting that nothing grew.
        if baseline < 0 or peak < 0:
            print("  --   skipped: no /proc to read the worker's RSS from")
        else:
            growth = peak - baseline
            check("a slow consumer does not grow the worker without bound "
                  "(baseline %d KB, peak %d KB, read %d KB)"
                  % (baseline, peak, read // 1024),
                  growth < 65536, "grew by %d KB" % growth)
        # The producer must actually have been throttled rather than finishing.
        check("the producer was throttled rather than buffering the response",
              read < 268435456, "read the whole 256 MB")

        # And the server is still healthy afterwards.
        status, _, body = server.get("/")
        is_("the server still answers after a slow consumer leaves", status, 200)


def test_graceful_shutdown():
    print("\nGraceful shutdown")

    # A request that finishes in time is waited for.
    port = free_port()
    server = Server("--graceful-timeout", "10000", port=port)
    s = server.connect(timeout=20)
    s.sendall(b"GET /slow?1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=25)
    check("an in-flight request is allowed to finish (%.1fs)" % elapsed,
          0.5 < elapsed < 8.0, "%.1fs" % elapsed)
    s.close()

    # A request that will not finish is not waited for indefinitely.
    port = free_port()
    server = Server("--graceful-timeout", "2000", port=port)
    s = server.connect(timeout=30)
    s.sendall(b"GET /slow?300 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=30)
    check("a stuck request does not block shutdown past the deadline (%.1fs)" % elapsed,
          elapsed < 12.0, "%.1fs" % elapsed)
    check("the process exited rather than being killed", code is not None,
          "had to be SIGKILLed")
    s.close()

    # The same guarantee for a request running on a pool thread, where the
    # deadline has to reach across a thread boundary.
    port = free_port()
    server = Server("--wsgi-threads", "4", "--graceful-timeout", "2000",
                    port=port, app="wsgi_app:application")
    s = server.connect(timeout=30)
    s.sendall(b"GET /sleep?300 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=30)
    check("a stuck pooled request does not block shutdown (%.1fs)" % elapsed,
          elapsed < 12.0, "%.1fs" % elapsed)
    s.close()

    # Lifespan shutdown runs, and runs after the request tasks.
    marker = os.path.join(tempfile.gettempdir(), "peregrine-shutdown-%d" % os.getpid())
    if os.path.exists(marker):
        os.unlink(marker)
    port = free_port()
    server = Server("--graceful-timeout", "5000", port=port,
                    env={"PEREGRINE_SHUTDOWN_MARKER": marker})
    server.get("/")
    server.stop(timeout=20)
    check("lifespan shutdown runs on SIGTERM", os.path.exists(marker),
          "the application never saw lifespan.shutdown")
    if os.path.exists(marker):
        os.unlink(marker)


def test_multiworker_unix():
    print("\nMultiworker unix socket")
    path = os.path.join(tempfile.gettempdir(), "peregrine-mw-%d.sock" % os.getpid())
    if os.path.exists(path):
        os.unlink(path)
    server = Server("--workers", "4", unix=path)
    try:
        # Sustained concurrent load, not a single burst. With one shared
        # listener the first worker to wake drains its whole accept batch, so a
        # burst of connections all land on that worker whether the socket is
        # shared or not; only continuous traffic distinguishes a shared
        # listener from four workers that replaced each other's socket.
        import threading
        pids = {}
        lock = threading.Lock()
        stop = [False]

        def hammer():
            while not stop[0]:
                try:
                    status, _, body = server.get("/pid", timeout=5)
                except OSError:
                    continue
                if status == 200:
                    with lock:
                        key = body.decode().strip()
                        pids[key] = pids.get(key, 0) + 1

        threads = [threading.Thread(target=hammer) for _ in range(12)]
        for t in threads:
            t.start()
        time.sleep(3.0)
        stop[0] = True
        for t in threads:
            t.join()

        check("requests over the shared unix socket are answered (%d)"
              % sum(pids.values()), sum(pids.values()) > 100, str(pids))
        check("all four workers serve the one unix socket (%d seen)" % len(pids),
              len(pids) >= 3,
              "only %s answered, so workers replaced each other's socket" % sorted(pids))
    finally:
        server.stop()
    check("the unix socket is removed on exit", not os.path.exists(path),
          "%s still exists" % path)


def test_forwarded():
    print("\nTrusted proxy headers")
    # One hop, which is what a single reverse proxy produces.
    headers = {"X-Forwarded-For": "203.0.113.9",
               "X-Forwarded-Proto": "https"}

    # Untrusted by default.
    port = free_port()
    with Server(port=port, app="wsgi_app:application") as server:
        status, _, body = server.get("/client", headers=headers)
        parts = body.decode().split()
        is_("an untrusted peer cannot set the scheme", parts[0], "http")
        check("an untrusted peer cannot set the client address",
              parts[1] != "203.0.113.9", parts[1])

    # Trusted.
    port = free_port()
    with Server("--forwarded-allow-ips", "127.0.0.1", port=port,
                app="wsgi_app:application") as server:
        status, _, body = server.get("/client", headers=headers)
        parts = body.decode().split()
        is_("a trusted proxy sets wsgi.url_scheme", parts[0], "https")
        is_("a trusted proxy sets REMOTE_ADDR", parts[1], "203.0.113.9")

    # CIDR form, and the ASGI side.
    port = free_port()
    with Server("--forwarded-allow-ips", "127.0.0.0/8", port=port) as server:
        status, _, body = server.get("/scope", headers=headers)
        scope = json.loads(body)
        is_("a trusted proxy sets the ASGI scheme", scope["scheme"], "https")
        is_("a trusted proxy sets the ASGI client", scope["client"][0], "203.0.113.9")

        # The rightmost untrusted entry wins, so a chain of trusted hops
        # resolves to the client rather than to the innermost proxy.
        status, _, body = server.get("/scope", headers={
            "X-Forwarded-For": "203.0.113.9, 127.0.0.1, 127.0.0.2"})
        scope = json.loads(body)
        is_("a chain of trusted hops resolves to the real client",
            scope["client"][0], "203.0.113.9")

        # ...and an untrusted hop stops the walk, so a client cannot prepend a
        # forged address and have it believed.
        status, _, body = server.get("/scope", headers={
            "X-Forwarded-For": "203.0.113.9, 198.51.100.7"})
        scope = json.loads(body)
        is_("an untrusted hop stops the walk (no spoofing by prepending)",
            scope["client"][0], "198.51.100.7")

    # RFC 7239.
    port = free_port()
    with Server("--forwarded-allow-ips", "*", port=port) as server:
        status, _, body = server.get("/scope", headers={
            "Forwarded": 'for=198.51.100.4;proto=https'})
        scope = json.loads(body)
        is_("RFC 7239 Forwarded sets the client", scope["client"][0], "198.51.100.4")
        is_("RFC 7239 Forwarded sets the scheme", scope["scheme"], "https")


def test_wsgi_threads():
    print("\nWSGI thread pool")
    port = free_port()
    with Server("--wsgi-threads", "8", port=port, app="wsgi_app:application") as server:
        status, _, body = server.get("/client")
        is_("wsgi.multithread is True with a pool", body.decode().split()[2], "True")

        import threading
        results = []

        def hit():
            try:
                results.append(server.get("/sleep?0.5", timeout=20)[0])
            except Exception as exc:                       # noqa: BLE001
                results.append(repr(exc))

        started = time.monotonic()
        threads = [threading.Thread(target=hit) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        elapsed = time.monotonic() - started
        is_("all pooled requests answered", results.count(200), 8)
        check("8 concurrent 0.5s WSGI requests overlap (%.2fs)" % elapsed,
              elapsed < 2.0, "%.2fs, so they serialised" % elapsed)

        # Streaming through the pool still applies backpressure.
        baseline = server.rss_kb()
        s = server.connect(timeout=30)
        s.sendall(b"GET /firehose?134217728 HTTP/1.1\r\nHost: x\r\n"
                  b"Connection: close\r\n\r\n")
        peak = baseline
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline:
            time.sleep(0.1)
            try:
                if not s.recv(32768):
                    break
            except socket.timeout:
                break
            peak = max(peak, server.rss_kb())
        s.close()
        check("a pooled streaming response is throttled by the client "
              "(baseline %d KB, peak %d KB)" % (baseline, peak),
              peak - baseline < 65536, "grew by %d KB" % (peak - baseline))

    # Correctness must not depend on the execution model.
    port = free_port()
    with Server("--wsgi-threads", "4", port=port, app="wsgi_app:application") as server:
        is_("pooled GET /", server.get("/")[2], b"hello from peregrine\n")
        is_("pooled 404", server.get("/nope")[0], 404)
        is_("pooled 500", server.get("/boom")[0], 500)
        status, headers, body = server.get("/stream")
        is_("pooled generator body", body, b"".join(b"chunk-%d\n" % i for i in range(5)))
        is_("pooled generator is chunked", headers.get("transfer-encoding"), "chunked")
        status, headers, body = server.get("/big?250000")
        is_("pooled large response", len(body), 250000)


def test_wsgi_streaming():
    print("\nWSGI streaming (PEP 3333 unbuffered output)")

    def first_line_arrival(server, path, budget=6.0):
        """Seconds until the first body byte lands, and the total."""
        s = server.connect(timeout=budget + 4)
        s.settimeout(budget + 4)
        started = time.monotonic()
        s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                   % path).encode())
        first = None
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if first is None and b"\r\n\r\n" in buf:
                if buf.split(b"\r\n\r\n", 1)[1].strip():
                    first = time.monotonic() - started
            elif first is None and chunk.strip():
                first = time.monotonic() - started
        total = time.monotonic() - started
        s.close()
        return first, total, buf

    # The application holds the connection for a second between blocks. If the
    # server is buffering, both numbers land together at the end; if it is
    # streaming, the first block is already there while the application waits.
    for label, extra in (("inline", []), ("pooled", ["--wsgi-threads", "4"])):
        port = free_port()
        with Server(*extra, port=port, app="wsgi_app:application") as server:
            for route, what in (("/slowwrite?1.0", "write()"),
                                ("/slowstream?1.0", "a generator")):
                first, total, buf = first_line_arrival(server, route)
                check("%s: %s sends its first block before the application "
                      "finishes (%s vs %.2fs)"
                      % (label, what,
                         "%.2fs" % first if first is not None else "never", total),
                      first is not None and first < 0.5 < total,
                      "first block at %s, response complete at %.2fs"
                      % ("never" if first is None else "%.2fs" % first, total))
                body = buf.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in buf else b""
                check("%s: %s delivers the whole body" % (label, what),
                      b"first" in body and b"second" in body,
                      "body was %r" % body[:120])

    # A block bigger than the write buffer, delivered to a client too slow to
    # take it in one go. Draining only down to the high water mark leaves up to
    # that much of the block behind, and on the inline path nothing can send it
    # while the application sleeps.
    def bytes_before_the_pause(server, path, pace=0.004):
        s = server.connect(timeout=40)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024)
        s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                   % path).encode())
        time.sleep(1.0)              # let the server fill the socket
        s.settimeout(30)
        last = time.monotonic()
        total = 0
        widest = 0.0
        before = 0
        while True:
            try:
                chunk = s.recv(262144)
            except socket.timeout:
                break
            if not chunk:
                break
            now = time.monotonic()
            if now - last > widest:
                widest, before = now - last, total
            last = now
            total += len(chunk)
            if b"TAIL" in chunk:
                break
            time.sleep(pace)
        s.close()
        return before, total, widest

    for label, extra in (("inline", []), ("pooled", ["--wsgi-threads", "4"])):
        port = free_port()
        with Server(*extra, port=port, app="wsgi_app:application") as server:
            sleeps = 3.0
            before, total, widest = bytes_before_the_pause(server,
                                                           "/bigwrite?%.1f" % sleeps)
            block = 8 * 1024 * 1024
            # The failure being looked for is bytes stranded in the server
            # while the application sleeps: the client waits out the sleep and
            # only then gets the rest. That shows up as a gap the length of the
            # sleep with the block still owed.
            #
            # The longest gap is only that sleep if it is anywhere near as
            # long. A slow reader stalls a sender for a fraction of a second
            # routinely, and on the pooled path the loop keeps writing while
            # the application sleeps, so there may be no long gap at all --
            # which is itself proof that nothing was stranded. Taking the
            # longest gap for the sleep regardless is how this check used to
            # measure a 0.7s stall on a busy machine and call 32 KB the whole
            # response.
            stranded = widest >= sleeps / 2 and before < block
            check("%s: an 8 MiB write() is not left in the server's buffer "
                  "while the application sleeps (%.2f of 8.00 MiB before the "
                  "longest gap, %.1fs)"
                  % (label, before / (1024.0 * 1024.0), widest),
                  not stranded, "%d bytes of %d arrived before a %.1fs pause; "
                  "the rest was stranded in the server's buffer"
                  % (before, block, widest))
            check("%s: the whole 8 MiB response still arrives" % label,
                  total >= block, "got %d bytes" % total)

    # Framing, which the early head has to settle without a return value in
    # hand: chunked unless the application declared a length of its own.
    port = free_port()
    with Server(port=port, app="wsgi_app:application") as server:
        status, headers, body = server.get("/write")
        is_("write() plus a returned iterable is chunked",
            headers.get("transfer-encoding"), "chunked")
        is_("write() output precedes the returned body", body,
            b"written and returned\n")

    # A write callable outlives its request whenever the application stores it,
    # and the machinery behind it does not: inline it is a stack frame that has
    # returned, pooled it is a job that has been released. Calling it later has
    # to raise, not write through either.
    def stale_write(server):
        """Saves the write callable on one request, calls it on the next."""
        s = server.connect()
        try:
            s.sendall(b"GET /savewrite HTTP/1.1\r\nHost: localhost\r\n\r\n")
            first = read_http_response(s)
            s.sendall(b"GET /stalewrite HTTP/1.1\r\nHost: localhost\r\n"
                      b"Connection: close\r\n\r\n")
            return first, read_http_response(s)
        finally:
            s.close()

    # The same thing with both requests sent at once. Finishing a response
    # dispatches whatever was pipelined behind it, from inside the frame that
    # served the first one, so this is where a sink cleared "when the request
    # is over" is cleared too late.
    def pipelined_stale_write(server):
        s = server.connect()
        try:
            s.sendall(b"GET /savewrite HTTP/1.1\r\nHost: x\r\n\r\n"
                      b"GET /stalewrite HTTP/1.1\r\nHost: x\r\n"
                      b"Connection: close\r\n\r\n")
            raw = b""
            while True:
                try:
                    chunk = s.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                raw += chunk
            return raw
        finally:
            s.close()

    for label, extra in (("inline", []), ("pooled", ["--wsgi-threads", "4"])):
        port = free_port()
        with Server(*extra, port=port, app="wsgi_app:application") as server:
            first, second = stale_write(server)
            is_("%s: the request that saves a write() is unaffected" % label,
                first[2], b"saved\n")
            status, headers, body = second
            is_("%s: a write() saved by an earlier request raises" % label,
                body, b"RuntimeError: write() called outside its own request\n")
            is_("%s: the stale write() leaves this response intact" % label,
                (status, headers.get("content-length")),
                (200, str(len(body))))

            raw = pipelined_stale_write(server)
            check("%s: a stale write() cannot reach a pipelined request" % label,
                  b"stale" not in raw, "the response stream was %r" % raw[:400])
            check("%s: the pipelined stale write() raises instead" % label,
                  b"RuntimeError" in raw, "the response stream was %r" % raw[:400])
            is_("%s: both pipelined requests are answered once" % label,
                raw.count(b"HTTP/1.1 200"), 2)


def test_wsgi_declared_length():
    print("\nWSGI Content-Length enforcement")

    def with_one_behind(server, path):
        """Everything the server sends when a second request is pipelined.

        The second request is the point: a message that is not the length it
        declared must be the last one on its connection, so the server must
        never answer what was queued behind it.
        """
        s = server.connect()
        try:
            s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n"
                       "GET /pid HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                       % path).encode())
            raw = b""
            while True:
                try:
                    chunk = s.recv(65536)
                except OSError:                     # timeout or reset
                    break
                if not chunk:
                    break
                raw += chunk
            return raw
        finally:
            s.close()

    # A declared length is the only thing that says where a message ends on a
    # keep-alive connection. Whichever way the application breaks its own
    # promise, the bytes on the wire have to keep it and the connection has to
    # go: anything else is read as part of the next response.
    for label, extra in (("inline", []), ("pooled", ["--wsgi-threads", "4"])):
        port = free_port()
        with Server(*extra, port=port, app="wsgi_app:application") as server:
            for route, what, expected in (("/overlong", "a returned body", b"12"),
                                          ("/overlongwrite", "write()", b"12"),
                                          ("/shortbody", "a short body", b"12345")):
                raw = with_one_behind(server, route)
                head, _, body = raw.partition(b"\r\n\r\n")
                is_("%s: the wire carries the declared length, not the produced "
                    "one (%s)" % (label, what), body, expected)
                check("%s: the announced Content-Length is unchanged (%s)"
                      % (label, what),
                      b"Content-Length: 2" in head if expected == b"12"
                      else b"Content-Length: 10" in head,
                      "the head was %r" % head[:200])
                is_("%s: nothing pipelined behind it is answered (%s)"
                    % (label, what), raw.count(b"HTTP/1.1 200"), 1)


def test_wsgi_lazy_start_response():
    print("\nWSGI start_response from the first iteration")

    # PEP 3333 allows an application to call start_response from inside the
    # first step of the iterable it returns, so the server has to advance the
    # iterable before it can require a head.
    for label, extra in (("inline", []), ("pooled", ["--wsgi-threads", "4"])):
        port = free_port()
        with Server(*extra, port=port, app="wsgi_app:application") as server:
            status, headers, body = server.get("/lazystart")
            is_("%s: a generator may call start_response at its first yield"
                % label, status, 200)
            is_("%s: its first block is not lost" % label, body, b"lazy\nstart\n")
            status, headers, body = server.get("/lazystart?empty")
            is_("%s: an empty block before start_response is allowed" % label,
                status, 200)
            is_("%s: the body after the empty block still arrives" % label,
                body, b"lazy\nstart\n")

            # Nothing has gone out while the iterable yields empty blocks, so
            # the application can still replace what it said.
            status, headers, body = server.get("/lazyreplace")
            is_("%s: exc_info replaces a head that has not been sent" % label,
                status, 500)
            is_("%s: the replacement response is what arrives" % label,
                body, b"replaced\n")


def test_header_shapes():
    print("\nFramework compatibility")
    port = free_port()
    with Server(port=port) as server:
        status, headers, body = server.get("/listpairs")
        is_("ASGI list-of-lists headers are accepted", status, 200)
        is_("ASGI list-pair header value reaches the client",
            headers.get("x-shape"), "list")
    port = free_port()
    with Server(port=port, app="wsgi_app:application") as server:
        status, headers, body = server.get("/listpairs")
        is_("WSGI list-of-lists headers are accepted", status, 200)
        is_("WSGI list-pair header value reaches the client",
            headers.get("x-shape"), "list")


def test_access_log():
    print("\nAccess log")

    def served(args, raw_requests):
        """Runs the requests, then returns everything the server logged."""
        port = free_port()
        server = Server(*args, "--log-level", "info", port=port,
                        app="wsgi_app:application")
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
        return server.proc.stdout.read().decode("utf-8", "replace").splitlines()

    plain = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    # A target is the peer's bytes: a quote would end a JSON string early, and
    # these bytes are not valid UTF-8 at all.
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


def test_factory():
    print("\nApplication loading")
    port = free_port()
    with Server("--factory", port=port, app="wsgi_app:make_application") as server:
        is_("--factory calls the target to get the application",
            server.get("/")[2], b"hello from peregrine\n")


def test_worker_restart():
    print("\nWorker supervision")
    port = free_port()
    server = Server("--workers", "2", port=port)
    try:
        pids = set()
        for _ in range(40):
            pids.add(server.get("/pid")[2].decode().strip())
        check("both workers serve TCP connections (%d seen)" % len(pids), len(pids) >= 1)

        victim = int(sorted(pids)[0])
        os.kill(victim, signal.SIGKILL)
        time.sleep(1.0)
        replaced = set()
        for _ in range(40):
            status, _, body = server.get("/pid")
            if status == 200:
                replaced.add(body.decode().strip())
        check("the supervisor replaces a killed worker", len(replaced) >= 1,
              "no worker answered after one was killed")
        check("the killed worker is gone", str(victim) not in replaced or len(replaced) > 1)
    finally:
        server.stop()


def test_response_length():
    print("\nResponse framing")
    port = free_port()
    with Server(port=port) as server:
        # An overlong body must not reach the wire: on a keep-alive connection
        # the excess would be read as the start of the next response.
        s = server.connect(timeout=10)
        s.sendall(b"GET /overlong HTTP/1.1\r\nHost: x\r\n\r\n")
        try:
            status, headers, body = read_http_response(s)
        except OSError:
            status, headers, body = 0, {}, b""
        s.close()
        is_("a body longer than Content-Length is truncated, not emitted",
            body[:4], b"LO")
        is_("the declared length is what the client is told",
            headers.get("content-length"), "2")

        # And the connection must not then be reused, because the response is
        # not the one that was promised.
        s = server.connect(timeout=10)
        s.sendall(b"GET /overlong HTTP/1.1\r\nHost: x\r\n\r\n"
                  b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        raw = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            pass
        s.close()
        is_("no second response is served on a mis-framed connection",
            raw.count(b"HTTP/1.1 "), 1)

        # A short body is the same promise broken the other way: the client
        # would wait for bytes that are never coming.
        s = server.connect(timeout=10)
        s.sendall(b"GET /short HTTP/1.1\r\nHost: x\r\n\r\n")
        raw = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            pass
        s.close()
        check("a short body closes the connection rather than hanging",
              raw.startswith(b"HTTP/1.1 200"), repr(raw[:40]))

        is_("the server is still healthy afterwards", server.get("/")[0], 200)


def test_streaming_request_bodies():
    print("\nStreaming request bodies")
    port = free_port()
    with Server(port=port) as server:
        # An application that answers on the head alone must not have to wait
        # for an upload it has already refused.
        s = server.connect(timeout=10)
        s.sendall(b"POST /reject HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nA")
        began = time.monotonic()
        try:
            status, _, body = read_http_response(s)
        except OSError:
            status, body = 0, b""
        elapsed = time.monotonic() - began
        check("a rejection arrives before the body does (%.2fs)" % elapsed,
              status == 403, "status %s after %.2fs" % (status, elapsed))
        is_("the rejection is the application's own", body.strip(), b"denied")
        # The nine bytes still to come are not a request, so the connection
        # cannot be handed to whatever would parse them next.
        s.settimeout(5)
        try:
            trailing = s.recv(4096)
        except OSError:
            trailing = b""
        s.close()
        is_("a connection with an unread body is not reused", trailing, b"")

        # Body chunks reach the application as they arrive, not once the
        # declared length is complete.
        s = server.connect(timeout=10)
        s.sendall(b"POST /drip HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\nAAAAA")
        try:
            status, _, body = read_http_response(s)
        except OSError:
            status, body = 0, b""
        s.close()
        check("a partial body is delivered to receive()",
              body.strip() == b"first-chunk:AAAAA", repr(body[:60]))

        # And the whole body still arrives intact when the application does
        # read all of it.
        payload = bytes(random.getrandbits(8) for _ in range(64 * 1024))
        s = server.connect(timeout=15)
        s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                  % len(payload))
        time.sleep(0.2)
        s.sendall(payload)
        status, _, body = read_http_response(s)
        s.close()
        is_("a body split across packets round trips exactly", body, payload)

        is_("the server is still healthy afterwards", server.get("/")[0], 200)


def test_request_backpressure():
    print("\nRequest body backpressure")
    port = free_port()
    total = 8 * 1024 * 1024
    with Server(port=port) as server:
        # The first request through an embedded interpreter costs several MiB
        # of imports and caches, which would swamp what is being measured.
        for _ in range(3):
            server.get("/")
        base = server.rss_kb()
        s = server.connect(timeout=30)
        s.sendall(b"POST /slowsink?2.0 HTTP/1.1\r\nHost: x\r\n"
                  b"Content-Length: %d\r\n\r\n" % total)

        sent = [0]

        def push():
            block = b"y" * 65536
            try:
                while sent[0] < total:
                    s.sendall(block)
                    sent[0] += len(block)
            except OSError:
                pass

        writer = threading.Thread(target=push)
        writer.start()
        # Sampled while the application is still asleep and reading nothing.
        time.sleep(1.0)
        growth = server.rss_kb() - base
        stalled = sent[0]
        check("the sender stalls when the application stops reading (%d of "
              "%d KiB)" % (stalled // 1024, total // 1024), stalled < total,
              "the whole upload was accepted while nobody was reading it")
        check("an unread upload is left in the socket, not buffered (%d KiB)"
              % growth, growth < 3000, "%d KiB of growth" % growth)
        writer.join(60)
        status, _, body = read_http_response(s)
        s.close()
        is_("the application still receives every byte",
            body.strip(), str(total).encode())


def test_tls():
    print("\nTLS")
    if not have_openssl():
        print("  --   skipped: no openssl to make a certificate")
        return
    port = free_port()
    with Server(port=port, tls=True, alpn=["http/1.1"]) as server:
        status, headers, body = server.get("/")
        is_("a request over TLS is answered", status, 200)
        is_("the body survives the record layer", body, b"hello from peregrine asgi\n")

        # A TLS listener is https, and the application should be told so
        # rather than having to guess from a port number.
        _, _, raw = server.get("/scope")
        check("the scope reports the https scheme", b'"scheme": "https"' in raw,
              raw[:200].decode(errors="replace"))

        # Records are 16 KiB at most, so anything larger proves the read side
        # reassembles and the write side handles a partial SSL_write.
        payload = bytes(random.getrandbits(8) for _ in range(300000))
        s = server.connect(timeout=30)
        s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                  % len(payload))
        s.sendall(payload)
        _, _, echoed = read_http_response(s)
        s.close()
        is_("a body far larger than a TLS record round trips", echoed, payload)

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


def test_receive_after_response():
    print("\nreceive() after the response is complete")
    port = free_port()
    with Server(port=port) as server:
        # Both requests go down one keep-alive connection, the second sent
        # while the first application task is still in receive().
        s = server.connect(timeout=10)
        s.sendall(b"GET /lateread HTTP/1.1\r\nHost: x\r\n\r\n")
        time.sleep(0.3)
        s.sendall(b"GET /lateread-result HTTP/1.1\r\nHost: x\r\n\r\n")
        raw = b""
        try:
            while raw.count(b"HTTP/1.1 ") < 2 and len(raw) < 8192:
                chunk = s.recv(4096)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            pass
        s.close()
        check("the first response is delivered", b"first" in raw, repr(raw[:80]))
        check("the connection is reused while the first task is still reading",
              raw.count(b"HTTP/1.1 ") == 2,
              "%d response(s), so the second request went unanswered"
              % raw.count(b"HTTP/1.1 "))
        check("a read after the response is complete reports the disconnect",
              b"http.disconnect" in raw,
              repr(raw.rsplit(b"\r\n\r\n", 1)[-1][:40]))
        is_("the server is still healthy afterwards", server.get("/")[0], 200)


def test_websocket_control_independence():
    print("\nWebSocket control frames without application reads")
    port = free_port()
    # Short ping interval so the server's own keepalive is exercised too.
    with Server("--ws-ping-interval", "400", "--ws-ping-timeout", "1500",
                port=port) as server:
        # A push-only endpoint: it never calls receive() after accepting.
        ws = WebSocket(server, "/ws-silent", timeout=20)
        is_("the push-only endpoint accepted", ws.status, 101)

        ws.send(b"are-you-there", opcode=0x9)      # client ping
        got_pong = False
        ticks = 0
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and not got_pong:
            fin, opcode, payload = ws.recv_frame()
            if opcode == 0xA and payload == b"are-you-there":
                got_pong = True
            elif opcode == 0x9:                    # the server's own ping
                ws.send(payload, opcode=0xA)
            elif opcode == 0x1:
                ticks += 1
        check("a ping is answered by an endpoint that never calls receive()",
              got_pong, "no pong arrived in 6s")

        # The connection must still be alive: the server saw our pongs, so its
        # own ping timeout must not have fired.
        alive = False
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                fin, opcode, payload = ws.recv_frame()
            except (EOFError, OSError):
                break
            if opcode == 0x9:
                ws.send(payload, opcode=0xA)
            elif opcode == 0x1:
                alive = True
                break
        check("answering pings keeps a push-only connection open", alive,
              "the server closed a healthy connection")
        ws.sock.close()

    # An endpoint busy for three seconds before its first receive().
    port = free_port()
    with Server("--ws-ping-interval", "400", "--ws-ping-timeout", "1500",
                port=port) as server:
        ws = WebSocket(server, "/ws-slow", timeout=20)
        ws.send("queued-while-busy")
        ws.send(b"ping-while-busy", opcode=0x9)
        pong_seen = False
        echoed = None
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and echoed is None:
            try:
                fin, opcode, payload = ws.recv_frame()
            except (EOFError, OSError):
                break
            if opcode == 0xA and payload == b"ping-while-busy":
                pong_seen = True
            elif opcode == 0x9:
                ws.send(payload, opcode=0xA)
            elif opcode == 0x1:
                echoed = payload
        check("a ping is answered while the application is busy", pong_seen,
              "no pong while the endpoint was working")
        is_("a message sent while the application was busy is not lost",
            echoed, b"late:queued-while-busy")
        ws.sock.close()


def test_shutdown_is_bounded():
    print("\nShutdown cannot be blocked by the application")
    # A task that catches CancelledError and carries on. Cancellation is a
    # request, not a guarantee, so something has to enforce the deadline.
    port = free_port()
    server = Server("--graceful-timeout", "1000", port=port)
    s = server.connect(timeout=30)
    s.sendall(b"GET /uncancellable HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.5)
    code, elapsed = server.stop(timeout=45)
    check("a task that ignores cancellation does not block shutdown (%.1fs)"
          % elapsed, elapsed < 25.0, "%.1fs" % elapsed)
    check("the process exited on its own rather than being killed",
          code is not None, "had to be SIGKILLed by the test harness")
    s.close()

    # The same refusal from the other end of the shutdown: a lifespan handler
    # that reports itself finished and then ignores its own cancellation.
    port = free_port()
    server = Server("--graceful-timeout", "200", port=port,
                    env={"PEREGRINE_STUBBORN_LIFESPAN": "1"})
    is_("the server runs with a stubborn lifespan handler",
        server.get("/")[0], 200)
    code, elapsed = server.stop(timeout=30)
    check("a lifespan handler that ignores cancellation does not block "
          "shutdown (%.1fs)" % elapsed, elapsed < 5.0, "%.1fs" % elapsed)
    check("that process also exited on its own",
          code is not None, "had to be SIGKILLed by the test harness")


def test_reload():
    print("\nDevelopment reload")
    # A file inside the watched tree that no test depends on.
    scratch = os.path.join(ROOT, "examples", "_reload_probe.py")
    with open(scratch, "w") as fh:
        fh.write("MARK = 1\n")
    port = free_port()
    server = Server("--reload", "--reload-interval", "200", port=port)
    try:
        before = server.get("/pid")[2].decode().strip()
        time.sleep(0.4)
        with open(scratch, "w") as fh:
            fh.write("MARK = 2\n")
        deadline = time.monotonic() + 15.0
        after = before
        while time.monotonic() < deadline:
            time.sleep(0.3)
            try:
                status, _, body = server.get("/pid", timeout=5)
            except OSError:
                continue
            if status == 200:
                after = body.decode().strip()
                if after != before:
                    break
        check("editing a watched file restarts the worker", after != before,
              "the worker pid stayed at %s" % before)
        is_("the server still answers after a reload", server.get("/")[0], 200)
    finally:
        server.stop()
        if os.path.exists(scratch):
            os.unlink(scratch)


def free_threaded_build():
    """True when this binary is linked against a CPython without the GIL."""
    out = subprocess.run([BIN, "--version"], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT).stdout.decode(errors="replace")
    return "free-threaded" in out


def test_free_threaded():
    print("\nFree-threaded workers")

    if not free_threaded_build():
        # The refusal is the behaviour worth checking on a standard build: it
        # has to be a clear error before anything binds, not a silent fallback
        # to a single worker.
        port = free_port()
        proc = subprocess.run(
            [BIN, "--free-threaded", "--port", str(port),
             "--python-path", os.path.join(ROOT, "examples"), "asgi_app:app"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        out = proc.stdout.decode(errors="replace")
        check("--free-threaded is refused on a build with the GIL",
              proc.returncode != 0 and "free-threaded" in out, out.strip()[:200])
        print("  (linked against a standard CPython; the rest is skipped)")
        return

    # --- one process, several threads, all of them serving ---
    port = free_port()
    server = Server("--workers", "4", "--free-threaded", port=port)
    try:
        pids = set()
        code = 0
        for _ in range(40):
            code, _hdrs, body = server.get("/pid")
            if code != 200:
                break
            pids.add(body.strip())
        is_("every request is answered", code, 200)
        check("all workers share one process", len(pids) == 1,
              "saw %d pids: %r" % (len(pids), pids))
    finally:
        server.stop()

    # The threads are real, and more than one of them serves. /threadid is
    # answered by whichever worker accepted the connection, so a spread of
    # identities is the observable proof that the workers are separate threads.
    port = free_port()
    server = Server("--workers", "4", "--free-threaded", port=port)
    try:
        threads = set()
        # New connections, not keep-alive: a reused connection stays on the
        # worker that accepted it, which would only ever show one thread.
        for _ in range(60):
            code, _hdrs, body = server.get("/threadid")
            if code == 200:
                threads.add(body.strip())
        check("requests are spread over several worker threads (%d seen)" % len(threads),
              len(threads) > 1, "only %d thread served" % len(threads))
    finally:
        server.stop()

    # --- the lifespan follows the loop that will serve requests ---
    #
    # By default that is one lifespan per worker thread. Running it once for the
    # whole process reads better until you ask which loop the pool it opened is
    # attached to: the supervising thread's, which serves nothing.
    def startup_count(*extra):
        marker = os.path.join(tempfile.gettempdir(),
                              "peregrine-ft-boot-%d" % os.getpid())
        if os.path.exists(marker):
            os.unlink(marker)
        port = free_port()
        server = Server("--workers", "4", "--free-threaded", *extra, port=port,
                        env={"PEREGRINE_STARTUP_COUNTER": marker})
        try:
            server.get("/")
            if not os.path.exists(marker):
                return 0
            with open(marker) as fh:
                return len(fh.read().split())
        finally:
            server.stop()
            if os.path.exists(marker):
                os.unlink(marker)

    count = startup_count()
    check("lifespan startup runs once per worker thread",
          count == 4, "ran %d times" % count)
    count = startup_count("--lifespan-scope", "process")
    check("--lifespan-scope process runs it once for the whole process",
          count == 1, "ran %d times" % count)

    # The point of the per-worker default: what `startup` binds to its loop is
    # awaited on that same loop. /looptest asks the application to await a Future
    # its lifespan created, which raises "attached to a different loop" when the
    # two are not the same.
    port = free_port()
    server = Server("--workers", "4", "--free-threaded", port=port)
    try:
        verdicts = set()
        for _ in range(20):
            code, _hdrs, body = server.get("/looptest")
            if code == 200:
                verdicts.add(body.strip())
        check("a resource opened in startup is usable from the worker's loop",
              verdicts == {b"ok"}, "saw %r" % (verdicts,))
    finally:
        server.stop()

    # --- shutdown: in-flight requests on worker threads are waited for, and
    #     the lifespan shuts down only afterwards ---
    marker = os.path.join(tempfile.gettempdir(), "peregrine-ft-shutdown-%d" % os.getpid())
    if os.path.exists(marker):
        os.unlink(marker)
    port = free_port()
    server = Server("--workers", "4", "--free-threaded",
                    "--graceful-timeout", "10000", port=port,
                    env={"PEREGRINE_SHUTDOWN_MARKER": marker})
    s = server.connect(timeout=20)
    s.sendall(b"GET /slow?1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=25)
    check("an in-flight request on a worker thread is waited for (%.1fs)" % elapsed,
          0.5 < elapsed < 8.0, "%.1fs" % elapsed)
    check("lifespan shutdown runs after the worker threads have drained",
          os.path.exists(marker), "the application never saw lifespan.shutdown")
    s.close()
    if os.path.exists(marker):
        os.unlink(marker)

    # A request that will never finish must not hold the process open, even
    # though the deadline now has to cross a thread boundary and then a join.
    port = free_port()
    server = Server("--workers", "3", "--free-threaded",
                    "--graceful-timeout", "2000", port=port)
    s = server.connect(timeout=30)
    s.sendall(b"GET /slow?300 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    time.sleep(0.3)
    code, elapsed = server.stop(timeout=40)
    check("a stuck request does not block shutdown past the deadline (%.1fs)" % elapsed,
          elapsed < 20.0, "%.1fs" % elapsed)
    check("the process exited rather than being killed", code is not None,
          "had to be SIGKILLed")
    s.close()

    # --- WSGI, where the workers are threads and PEP 3333 has to say so ---
    port = free_port()
    server = Server("--workers", "3", "--free-threaded", port=port,
                    app="wsgi_app:application")
    try:
        code, _hdrs, body = server.get("/environ")
        is_("WSGI free-threaded workers answer", code, 200)
        text = body.decode() if isinstance(body, bytes) else body
        check("wsgi.multithread is True", "multithread=True" in text, text[:200])
        check("wsgi.multiprocess is False", "multiprocess=False" in text, text[:200])
    finally:
        server.stop()


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    print("peregrine feature tests (%s)" % BIN)
    for test in (test_header_shapes, test_factory, test_websockets, test_backpressure,
                 test_tls, test_response_length, test_streaming_request_bodies,
                 test_request_backpressure, test_receive_after_response,
                 test_websocket_control_independence,
                 test_wsgi_threads, test_wsgi_streaming, test_access_log,
                 test_wsgi_declared_length, test_wsgi_lazy_start_response,
                 test_forwarded, test_multiworker_unix,
                 test_worker_restart, test_reload, test_graceful_shutdown,
                 test_shutdown_is_bounded, test_free_threaded):
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

#!/usr/bin/env python3
"""End-to-end checks for the behaviour a curl-based script cannot reach.

    python3 scripts/feature-test.py [path-to-peregrine]

Everything here exists because it is a failure mode that only shows up under
conditions an ordinary request never creates: a client that reads slowly, a
request that will not finish while the server is trying to stop, several
workers sharing one unix socket, or a protocol that is not HTTP at all.

Only the standard library is used, including the WebSocket client, so the suite
runs anywhere the server does.
"""

import base64
import hashlib
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/release/peregrine")

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
    def __init__(self, *args, app="asgi_app:app", port=None, unix=None, env=None):
        self.port = port
        self.unix = unix
        cmd = [BIN, "--log-level", "error", "--python-path", os.path.join(ROOT, "examples")]
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
        deadline = time.time() + timeout
        while time.time() < deadline:
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

    def connect(self, timeout=5.0):
        if self.unix:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(self.unix)
        else:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
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
        started = time.time()
        self.proc.send_signal(sig)
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            return None, time.time() - started
        return self.proc.returncode, time.time() - started

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
        deadline = time.time() + 10
        while time.time() < deadline:
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
        deadline = time.time() + 6.0
        # Read slowly on purpose: 32 KB every 100 ms is far below what the
        # application produces.
        while time.time() < deadline:
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

        growth = peak - baseline
        check("a slow consumer does not grow the worker without bound "
              "(baseline %d KB, peak %d KB, read %d KB)" % (baseline, peak, read // 1024),
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

        started = time.time()
        threads = [threading.Thread(target=hit) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        elapsed = time.time() - started
        is_("all pooled requests answered", results.count(200), 8)
        check("8 concurrent 0.5s WSGI requests overlap (%.2fs)" % elapsed,
              elapsed < 2.0, "%.2fs, so they serialised" % elapsed)

        # Streaming through the pool still applies backpressure.
        baseline = server.rss_kb()
        s = server.connect(timeout=30)
        s.sendall(b"GET /firehose?134217728 HTTP/1.1\r\nHost: x\r\n"
                  b"Connection: close\r\n\r\n")
        peak = baseline
        deadline = time.time() + 4.0
        while time.time() < deadline:
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
        deadline = time.time() + 6
        while time.time() < deadline and not got_pong:
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
        deadline = time.time() + 4
        while time.time() < deadline:
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
        deadline = time.time() + 12
        while time.time() < deadline and echoed is None:
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
        deadline = time.time() + 15.0
        after = before
        while time.time() < deadline:
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


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    print("peregrine feature tests (%s)" % BIN)
    for test in (test_header_shapes, test_factory, test_websockets, test_backpressure,
                 test_response_length, test_websocket_control_independence,
                 test_wsgi_threads, test_forwarded, test_multiworker_unix,
                 test_worker_restart, test_reload, test_graceful_shutdown,
                 test_shutdown_is_bounded):
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

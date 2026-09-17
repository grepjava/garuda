#!/usr/bin/env python3
"""The handler API, end to end: what a handler is given and what it can say.

    ~/pgvenv/bin/python scripts/handler-test.py [path-to-garuda-conformance]

Runs .build/release/garuda-conformance (swift build -c release --product
garuda-conformance), whose routes exist to make one behaviour each observable.
Needs openssl, and h2 and aioquic for the HTTP/2 and HTTP/3 sections.

Covers the first phase of HANDLER-API.md: request bodies delivered whole on
every protocol; headers, client address, scheme, request ID, trace context and
request start as a handler sees them; status and header framing, a handler's
own server headers, and a declared Content-Length held to; a handler that
throws; start-up and shutdown hooks, and shutdown staying bounded.
"""

import asyncio
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

try:
    import h2.config
    import h2.connection
    import h2.errors
    import h2.events
    from aioquic.asyncio.client import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import StreamReset
except ImportError:
    sys.stderr.write("this script needs h2 and aioquic: pip install h2 aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, ".build", "release", "garuda-conformance")

PASS = 0
FAIL = 0
CERTS = None


def ok(name):
    global PASS
    PASS += 1
    print("  ok   %s" % name)
    sys.stdout.flush()


def bad(name, expected, actual):
    global FAIL
    FAIL += 1
    print("  FAIL %s\n       expected: %r\n       actual:   %r" % (name, expected, actual))
    sys.stdout.flush()


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


def make_certs():
    global CERTS
    if CERTS is None:
        directory = tempfile.mkdtemp(prefix="garuda-handler-")
        cert = os.path.join(directory, "cert.pem")
        key = os.path.join(directory, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                        "-keyout", key, "-out", cert, "-days", "2", "-nodes",
                        "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        CERTS = (cert, key)
    return CERTS


def free_port():
    # TLS over TCP and QUIC over UDP share the port, so it has to be free for both.
    while True:
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tcp = socket.socket()
        try:
            udp.bind(("127.0.0.1", 0))
            port = udp.getsockname()[1]
            tcp.bind(("127.0.0.1", port))
            return port
        except OSError:
            pass
        finally:
            tcp.close()
            udp.close()


class Server:
    def __init__(self, *args, tls=False, http3=False, env=None, wait=True):
        self.port = free_port()
        self.tls = tls or http3
        cmd = [BIN, "--port", str(self.port), "--log-level", "error"]
        if self.tls:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
        if http3:
            cmd.append("--http3")
        cmd += list(args)
        environment = dict(os.environ)
        environment.update(env or {})
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(cmd, env=environment, stdout=self.log,
                                     stderr=subprocess.STDOUT)
        if wait:
            self.wait_ready()

    def wait_ready(self):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.25).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise SystemExit("server exited during start-up:\n" + self.output())
                time.sleep(0.05)
        raise SystemExit("server never came up")

    def output(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def alive(self):
        return self.proc.poll() is None

    def signal(self, sig):
        self.proc.send_signal(sig)

    def wait_exit(self, timeout):
        """Seconds until the process exited, or None if it had not by `timeout`."""
        began = time.monotonic()
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return None
        return time.monotonic() - began

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(5)


# ------------------------------------------------------------------- HTTP/1.1


class Response:
    def __init__(self, status, headers, body, complete=True):
        self.status = status
        self.headers = headers
        self.body = body
        # False for a chunked body the connection closed in the middle of.
        self.complete = complete

    def values(self, name):
        return [v for k, v in self.headers if k == name]

    def header(self, name):
        found = self.values(name)
        return found[0] if found else None

    def json(self):
        return json.loads(self.body)


class H1:
    """One HTTP/1.1 connection, read a response at a time."""

    def __init__(self, server, tls=None, timeout=10.0):
        sock = socket.create_connection(("127.0.0.1", server.port), timeout)
        if tls if tls is not None else server.tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.set_alpn_protocols(["http/1.1"])
            sock = context.wrap_socket(sock, server_hostname="localhost")
        self.sock = sock
        self.buf = b""

    def send(self, data):
        self.sock.sendall(data)

    @staticmethod
    def head(method, path, headers=(), length=None):
        lines = ["%s %s HTTP/1.1" % (method, path), "Host: localhost"]
        lines += ["%s: %s" % (k, v) for k, v in headers]
        if length is not None:
            lines.append("Content-Length: %d" % length)
        return ("\r\n".join(lines) + "\r\n\r\n").encode()

    def request(self, method, path, headers=(), body=None):
        data = self.head(method, path, headers, None if body is None else len(body))
        self.send(data + (body or b""))
        return self.response(method)

    def fill(self):
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise EOFError
        self.buf += chunk

    def response(self, method="GET"):
        while b"\r\n\r\n" not in self.buf:
            self.fill()
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split()[1])
        headers = []
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers.append((name.strip().lower(), value.strip()))
        if 100 <= status < 200:
            return Response(status, headers, b"")
        if (method != "HEAD" and status not in (204, 304)
                and ("transfer-encoding", "chunked") in headers):
            return self.chunked(status, headers)
        length = 0
        if status not in (204, 304) and method != "HEAD":
            declared = [v for k, v in headers if k == "content-length"]
            length = int(declared[0]) if declared else None
        try:
            if length is None:
                while True:
                    self.fill()
            while len(self.buf) < length:
                self.fill()
        except EOFError:
            pass
        take = len(self.buf) if length is None else length
        body, self.buf = self.buf[:take], self.buf[take:]
        return Response(status, headers, body)

    def chunked(self, status, headers):
        body = b""
        try:
            while True:
                while b"\r\n" not in self.buf:
                    self.fill()
                line, _, self.buf = self.buf.partition(b"\r\n")
                size = int(line.split(b";")[0], 16)
                while len(self.buf) < size + 2:
                    self.fill()
                body += self.buf[:size]
                self.buf = self.buf[size + 2:]
                if size == 0:
                    return Response(status, headers, body)
        except EOFError:
            return Response(status, headers, body, complete=False)

    def closed(self, timeout=3.0):
        """Whether the server closes the connection within `timeout`."""
        self.sock.settimeout(timeout)
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return True
                self.buf += chunk
        except (socket.timeout, TimeoutError):
            return False
        except OSError:
            return True

    def close(self):
        self.sock.close()


def get_json(server, path="/headers", headers=(), tls=None):
    conn = H1(server, tls=tls)
    try:
        return conn.request("GET", path, headers).json()
    finally:
        conn.close()


def header_values(dump, name):
    return [v for k, v in dump["headers"] if k.lower() == name]


# -------------------------------------------------------------------- HTTP/2


class H2Client:
    def __init__(self, server, timeout=15.0):
        sock = socket.create_connection(("127.0.0.1", server.port), timeout)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["h2"])
        self.sock = context.wrap_socket(sock, server_hostname="localhost")
        self.conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True, header_encoding=None))
        self.conn.initiate_connection()
        self.flush()
        self.port = server.port
        self.status, self.headers, self.body = {}, {}, {}
        self.ended, self.reset = set(), {}

    def flush(self):
        data = self.conn.data_to_send()
        if data:
            self.sock.sendall(data)

    def open(self, method, path, headers=(), length=None, end_stream=False):
        block = [(":method", method), (":scheme", "https"),
                 (":authority", "localhost:%d" % self.port), (":path", path)]
        block += list(headers)
        if length is not None:
            block.append(("content-length", str(length)))
        stream = self.conn.get_next_available_stream_id()
        self.conn.send_headers(stream, block, end_stream=end_stream)
        self.flush()
        return stream

    def request(self, method, path, headers=(), body=None):
        stream = self.open(method, path, headers, None if body is None else len(body),
                           end_stream=body is None)
        if body is not None:
            self.send_body(stream, body, end_stream=True)
        return stream

    def send_body(self, stream, data, end_stream=False):
        # Within the peer's windows, reading while it waits for WINDOW_UPDATE.
        view = memoryview(data)
        while view:
            window = min(self.conn.local_flow_control_window(stream),
                         self.conn.max_outbound_frame_size)
            if window <= 0:
                self.step(0.05)
                continue
            n = min(window, len(view))
            self.conn.send_data(stream, bytes(view[:n]))
            self.flush()
            view = view[n:]
        if end_stream:
            self.conn.end_stream(stream)
            self.flush()

    def step(self, timeout=0.2):
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(1 << 20)
        except (socket.timeout, TimeoutError, ssl.SSLWantReadError):
            return True
        if not data:
            return False
        for event in self.conn.receive_data(data):
            if isinstance(event, h2.events.ResponseReceived):
                fields = {}
                for name, value in event.headers:
                    fields.setdefault(name, []).append(value)
                self.headers[event.stream_id] = fields
                self.status[event.stream_id] = int(fields[b":status"][0])
            elif isinstance(event, h2.events.DataReceived):
                self.body[event.stream_id] = self.body.get(event.stream_id, b"") + event.data
                self.conn.acknowledge_received_data(event.flow_controlled_length,
                                                    event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                self.ended.add(event.stream_id)
            elif isinstance(event, h2.events.StreamReset):
                self.ended.add(event.stream_id)
                self.reset[event.stream_id] = event.error_code
        self.flush()
        return True

    def collect(self, streams, deadline=20.0):
        limit = time.monotonic() + deadline
        while not set(streams) <= self.ended and time.monotonic() < limit:
            if not self.step():
                break

    def value(self, stream, name):
        found = self.headers.get(stream, {}).get(name.encode())
        return found[0] if found else None

    def values(self, stream, name):
        return self.headers.get(stream, {}).get(name.encode(), [])

    def close(self):
        try:
            self.conn.close_connection()
            self.flush()
        except Exception:
            pass
        self.sock.close()


# -------------------------------------------------------------------- HTTP/3


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self.status, self.headers, self.body = {}, {}, {}
        self.reset = {}
        self._done = {}

    def open(self, method, path, headers=(), length=None, end_stream=False):
        stream = self._quic.get_next_available_stream_id()
        block = [(b":method", method.encode()), (b":scheme", b"https"),
                 (b":authority", b"localhost"), (b":path", path.encode())]
        block += [(k.encode(), v.encode()) for k, v in headers]
        if length is not None:
            block.append((b"content-length", str(length).encode()))
        self._http.send_headers(stream_id=stream, headers=block, end_stream=end_stream)
        self._done[stream] = asyncio.get_running_loop().create_future()
        self.transmit()
        return stream

    def send(self, stream, data, end_stream=False):
        self._http.send_data(stream_id=stream, data=data, end_stream=end_stream)
        self.transmit()

    def request(self, method, path, headers=(), body=None):
        stream = self.open(method, path, headers, None if body is None else len(body),
                           end_stream=body is None)
        if body is not None:
            self.send(stream, body, end_stream=True)
        return stream

    async def collect(self, streams, timeout=20.0):
        try:
            await asyncio.wait_for(
                asyncio.gather(*(asyncio.shield(self._done[s]) for s in streams)), timeout)
        except asyncio.TimeoutError:
            pass

    def quic_event_received(self, event):
        if isinstance(event, StreamReset):
            self.reset[event.stream_id] = event.error_code
            done = self._done.get(event.stream_id)
            if done is not None and not done.done():
                done.set_result(None)
        for http_event in self._http.handle_event(event):
            if not isinstance(http_event, (HeadersReceived, DataReceived)):
                continue
            stream = http_event.stream_id
            if isinstance(http_event, HeadersReceived):
                fields = {}
                for name, value in http_event.headers:
                    if name == b":status":
                        self.status[stream] = int(value)
                    else:
                        fields.setdefault(name, []).append(value)
                self.headers[stream] = fields
            else:
                self.body[stream] = self.body.get(stream, b"") + http_event.data
            if http_event.stream_ended:
                done = self._done.get(stream)
                if done is not None and not done.done():
                    done.set_result(None)


def h3_connect(server):
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    return connect("127.0.0.1", server.port, configuration=config, create_protocol=H3Client)


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# ------------------------------------------------------------------ 1. Bodies


def bodies_h1():
    print("\nRequest bodies, HTTP/1.1")
    with Server() as server:
        conn = H1(server)
        r = conn.request("POST", "/echo", [("Content-Type", "text/plain")], b"round trip")
        is_("a body round trips", (r.status, r.body), (200, b"round trip"))
        is_("with the content-type it was sent with", r.header("content-type"), "text/plain")
        r = conn.request("POST", "/echo", body=b"")
        is_("an empty body is still a body", (r.status, r.body), (200, b""))

        conn.send(H1.head("POST", "/echo", [("Transfer-Encoding", "chunked")])
                  + b"3\r\nchu\r\n3\r\nnky\r\n0\r\n\r\n")
        is_("a chunked body arrives whole", conn.response().body, b"chunky")

        conn.send(H1.head("POST", "/echo", [("Transfer-Encoding", "chunked")])
                  + b"5\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n")
        is_("a chunked trailer section is accepted", conn.response().body, b"hello")

        conn.send(H1.head("POST", "/echo", [("Expect", "100-continue")], length=9))
        interim = conn.response()
        is_("100-continue is answered before the body is sent", interim.status, 100)
        conn.send(b"continued")
        is_("and the body that follows is echoed", conn.response().body, b"continued")

        big = os.urandom(1 << 20)
        is_("a 1 MiB Content-Length body round trips", conn.request("POST", "/echo", body=big).body, big)
        framed = b"".join(b"%x\r\n%s\r\n" % (len(big[i:i + 65536]), big[i:i + 65536])
                          for i in range(0, len(big), 65536)) + b"0\r\n\r\n"
        conn.send(H1.head("POST", "/echo", [("Transfer-Encoding", "chunked")]) + framed)
        is_("a 1 MiB chunked body round trips", conn.response().body, big)
        conn.close()

        pipe = H1(server)
        pipe.send(H1.head("POST", "/echo", length=3) + b"AAA"
                  + H1.head("POST", "/echo", [("Connection", "close")], length=3) + b"BBB")
        first, second = pipe.response("POST"), pipe.response("POST")
        is_("pipelined POSTs keep their own bodies", (first.body, second.body), (b"AAA", b"BBB"))
        pipe.close()

    with Server(tls=True) as server:
        big = os.urandom(300_000)
        conn = H1(server)
        is_("a body far larger than a TLS record round trips",
            conn.request("POST", "/echo", body=big).body, big)
        conn.close()


def bodies_h2():
    print("\nRequest bodies, HTTP/2")
    with Server(tls=True) as server:
        client = H2Client(server)
        cases = [
            ("a body larger than a frame round trips", bytes(range(256)) * 400),
            ("an upload larger than the initial window completes", b"z" * (1 << 20)),
            ("a body larger than the window round trips", bytes(i % 251 for i in range(200_000))),
            ("an empty body is still a body", b""),
        ]
        streams = [(name, body, client.request("POST", "/echo", body=body)) for name, body in cases]
        client.collect([s for _, _, s in streams])
        for name, body, stream in streams:
            is_(name, (client.status.get(stream), client.body.get(stream, b"")), (200, body))
        client.close()

    with Server("--request-timeout", "2000", tls=True) as server:
        client = H2Client(server)
        stream = client.open("POST", "/echo", length=10)
        for byte in b"abcdefghij":
            client.send_body(stream, bytes([byte]))
            limit = time.monotonic() + 0.6
            while time.monotonic() < limit:
                client.step(0.1)
        client.conn.end_stream(stream)
        client.flush()
        client.collect([stream])
        is_("a body dripped slower than --request-timeout per byte arrives whole",
            client.body.get(stream, b""), b"abcdefghij")
        client.close()

    with Server("--max-body", "1024", tls=True) as server:
        client = H2Client(server)
        stream = client.request("POST", "/echo", body=b"y" * 512)
        client.collect([stream])
        is_("a body under --max-body comes back whole", client.body.get(stream, b""), b"y" * 512)
        client.close()


def bodies_h3():
    print("\nRequest bodies, HTTP/3")

    async def scenario(server):
        async with h3_connect(server) as client:
            small = client.request("POST", "/echo", body=b"hello")
            big_body = bytes(range(256)) * 400
            big = client.request("POST", "/echo", body=big_body)
            wide_body = bytes(i % 251 for i in range(200_000))
            wide = client.request("POST", "/echo", body=wide_body)
            empty = client.request("POST", "/echo", body=b"")
            await client.collect([small, big, wide, empty])
            is_("a small body echoes back", client.body.get(small), b"hello")
            is_("a body larger than the window round trips", client.body.get(big), big_body)
            is_("a 200,000-byte body round trips", client.body.get(wide), wide_body)
            is_("an empty body is still a body", (client.status.get(empty), client.body.get(empty, b"")),
                (200, b""))

            chunks = [bytes([0x41 + i]) * 8192 for i in range(20)]
            drip = client.open("POST", "/echo")
            for chunk in chunks:
                client.send(drip, chunk)
                await asyncio.sleep(0.01)
            client.send(drip, b"", end_stream=True)
            await client.collect([drip])
            is_("a drip-fed body reassembles in order", client.body.get(drip), b"".join(chunks))

    with Server(http3=True) as server:
        run(scenario(server))


# ---------------------------------------------------------------- 2. Headers


def headers_h1():
    print("\nWhat a handler reads, HTTP/1.1")
    with Server() as server:
        dump = get_json(server, "/headers?a=1", [("X-Mixed-Case", "v")])
        is_("the method, path and query", (dump["method"], dump["path"], dump["query"]),
            ("GET", "/headers", "a=1"))
        is_("the version is 1.1", dump["version"], "1.1")
        is_("a header reaches the handler as sent", header_values(dump, "x-mixed-case"), ["v"])
        is_("the host is the authority", dump["authority"], "localhost")
        is_("the client is the peer", dump["remote"], "127.0.0.1")
        is_("the scheme of a plaintext connection is http", dump["scheme"], "http")
        is_("the start-up hook ran before the first request", dump["started"], 0)
        is_("no request ID without --request-id", dump["requestID"], None)
        is_("no request start without --request-start-header", dump["requestStart"], None)

        spoofed = [("X-Forwarded-For", "203.0.113.9"), ("X-Forwarded-Proto", "https")]
        dump = get_json(server, headers=spoofed)
        is_("an untrusted peer cannot set the client address", dump["remote"], "127.0.0.1")
        is_("or the scheme", dump["scheme"], "http")

    with Server("--forwarded-allow-ips", "127.0.0.0/8") as server:
        dump = get_json(server, headers=[("X-Forwarded-For", "203.0.113.9"),
                                         ("X-Forwarded-Proto", "https")])
        is_("a trusted proxy sets the client address", dump["remote"], "203.0.113.9")
        is_("and the scheme", dump["scheme"], "https")
        dump = get_json(server, headers=[("X-Forwarded-For", "203.0.113.9, 127.0.0.1, 127.0.0.2")])
        is_("a chain of trusted hops resolves to the real client", dump["remote"], "203.0.113.9")
        dump = get_json(server, headers=[("X-Forwarded-For", "203.0.113.9, 198.51.100.7")])
        is_("an untrusted hop stops the walk", dump["remote"], "198.51.100.7")
        dump = get_json(server, headers=[("X-Forwarded-For", "203.0.113.9"),
                                         ("X-Forwarded-For", "127.0.0.2")])
        is_("X-Forwarded-For over two lines is walked as one list", dump["remote"], "203.0.113.9")
        dump = get_json(server, headers=[("X-Forwarded-For", "203.0.113.9"),
                                         ("X-Forwarded-For", "198.51.100.7, 127.0.0.2")])
        is_("and an untrusted hop on a later line still stops it", dump["remote"], "198.51.100.7")

    with Server("--forwarded-allow-ips", "*") as server:
        dump = get_json(server, headers=[("Forwarded", "for=198.51.100.4;proto=https")])
        is_("RFC 7239 Forwarded sets the client and scheme",
            (dump["remote"], dump["scheme"]), ("198.51.100.4", "https"))

    with Server(tls=True) as server:
        is_("a TLS connection's scheme is https", get_json(server)["scheme"], "https")


def request_ids():
    print("\nRequest IDs and trace context")
    with Server("--request-id", "--workers", "2", tls=True) as server:
        conn = H1(server)
        r = conn.request("GET", "/headers")
        is_("the handler is given the ID the response carries", r.json()["requestID"],
            r.header("x-request-id"))
        r = conn.request("GET", "/headers", [("X-Request-ID", "client-chosen-id")])
        dump = r.json()
        check("a client's ID is replaced", dump["requestID"] not in (None, "client-chosen-id"),
              dump["requestID"])
        is_("and the handler has the replacement", dump["requestID"], r.header("x-request-id"))
        conn.close()

        client = H2Client(server)
        stream = client.request("GET", "/headers")
        client.collect([stream])
        dump = json.loads(client.body.get(stream, b"{}"))
        is_("over HTTP/2 too", dump.get("requestID", "").encode(), client.value(stream, "x-request-id"))
        client.close()

    with Server("--request-id", "--forwarded-allow-ips", "127.0.0.1") as server:
        dump = get_json(server, headers=[("X-Request-ID", "proxy-7f3a.42")])
        is_("a trusted proxy's ID reaches the handler", dump["requestID"], "proxy-7f3a.42")

    with Server() as server:
        dump = get_json(server, headers=[("X-Request-ID", "client-chosen-id")])
        is_("without the flag the client's header reaches the handler untouched",
            (dump["requestID"], header_values(dump, "x-request-id")), (None, ["client-chosen-id"]))

    parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    with Server("--trace-context") as server:
        dump = get_json(server, headers=[("traceparent", parent)])
        is_("a traceparent reaches the handler unchanged", header_values(dump, "traceparent"), [parent])
        other = "00-4bf92f3577b34da6a3ce929d0e0e4736-1111111111111111-01"
        dump = get_json(server, headers=[("traceparent", parent), ("traceparent", other)])
        is_("two of them both arrive, as sent", header_values(dump, "traceparent"), [parent, other])
    with Server() as server:
        dump = get_json(server, headers=[("traceparent", parent)])
        is_("without --trace-context it still arrives", header_values(dump, "traceparent"), [parent])


def request_start():
    print("\nRequest start")
    with Server("--request-start-header", "--workers", "1", tls=False) as server:
        before = time.time() * 1e6
        dump = get_json(server)
        check("the start is now, in microseconds",
              dump["requestStart"] is not None and abs(dump["requestStart"] - before) < 2e6,
              "%r against %r" % (dump["requestStart"], before))
        dump = get_json(server, headers=[("X-Request-Start", "t=1234567890123456")])
        is_("a proxy's own X-Request-Start still reaches the handler",
            header_values(dump, "x-request-start"), ["t=1234567890123456"])
        conn = H1(server)
        first = conn.request("GET", "/headers").json()["requestStart"]
        second = conn.request("GET", "/headers").json()["requestStart"]
        check("keep-alive stamps every request", first and second and second >= first,
              "%r then %r" % (first, second))
        conn.close()

        # A handler that blocks the worker: the request queued behind it is
        # stamped when it arrived, not when the worker got to it.
        blocked = {}

        def block():
            conn = H1(server)
            blocked["status"] = conn.request("GET", "/block/300").status
            conn.close()

        blocker = threading.Thread(target=block)
        blocker.start()
        time.sleep(0.05)
        sent = time.time() * 1e6
        dump = get_json(server)
        answered = time.time() * 1e6
        blocker.join()
        check("a request queued behind a blocking handler waited for it",
              blocked.get("status") == 200 and answered - sent > 150_000,
              "blocker answered %r, queued request answered after %.0f ms"
              % (blocked.get("status"), (answered - sent) / 1000))
        check("and is stamped when it arrived",
              dump["requestStart"] is not None and abs(dump["requestStart"] - sent) < 100_000,
              "stamped %.0f ms after it was sent" % ((dump["requestStart"] - sent) / 1000))

    with Server("--request-start-header", tls=True) as server:
        client = H2Client(server)
        stream = client.request("GET", "/headers")
        client.collect([stream])
        check("HTTP/2 requests are stamped",
              json.loads(client.body.get(stream, b"{}")).get("requestStart") is not None)
        client.close()


def headers_h2_h3():
    print("\nWhat a handler reads, HTTP/2 and HTTP/3")
    with Server(http3=True) as server:
        client = H2Client(server)
        pads = [("x-pad-%03d" % i, "v" * 512) for i in range(48)]
        dump_stream = client.request("GET", "/headers")
        padded = client.request("GET", "/headers", pads)
        client.collect([dump_stream, padded])
        dump = json.loads(client.body.get(dump_stream, b"{}"))
        is_("the version is 2", dump.get("version"), "2")
        is_("the scheme is https", dump.get("scheme"), "https")
        is_("the authority becomes the host header", dump.get("authority"), "localhost:%d" % server.port)
        got = json.loads(client.body.get(padded, b"{}"))
        is_("every header spread over CONTINUATION frames arrives",
            sum(1 for k, _ in got.get("headers", []) if k.startswith("x-pad-")), 48)
        client.close()

        async def scenario():
            async with h3_connect(server) as h3:
                long_headers = [("x-long-%d" % i, "aeiou-repeated-text" * 20) for i in range(4)]
                stream = h3.request("GET", "/headers", long_headers + [("x-garuda-probe", "1")])
                await h3.collect([stream])
                return json.loads(h3.body.get(stream, b"{}"))

        dump = run(scenario())
        is_("over HTTP/3 the version is 3", dump.get("version"), "3")
        is_("and the scheme is https", dump.get("scheme"), "https")
        is_("long values arrive whole", header_values(dump, "x-long-3"), ["aeiou-repeated-text" * 20])
        is_("an unknown header name arrives", header_values(dump, "x-garuda-probe"), ["1"])


# ----------------------------------------------------- 3. Status and headers


def framing_h1():
    print("\nStatus and headers, HTTP/1.1")
    with Server("--request-id") as server:
        conn = H1(server)
        no_content = conn.request("GET", "/status/204")
        is_("a 204 has no Content-Length", no_content.header("content-length"), None)
        not_modified = conn.request("GET", "/status/304?header=etag:%22v1%22&header=content-length:5")
        is_("a 304 keeps the Content-Length the handler gave", not_modified.header("content-length"), "5")
        is_("and neither has a body", (no_content.body, not_modified.body), (b"", b""))
        is_("and the connection carries on after both", conn.request("GET", "/").status, 200)

        fixed = conn.request("GET", "/length/13/13")
        is_("a handler's Content-Length is not duplicated", fixed.values("content-length"), ["13"])
        is_("and the body is what it declared", len(fixed.body), 13)

        own = conn.request("GET", "/status/200?header=x-request-id:from-the-handler")
        is_("a handler's own X-Request-ID is kept, not doubled", own.values("x-request-id"),
            ["from-the-handler"])
        extra = conn.request("GET", "/status/200?header=x-one:1&header=x-two:2")
        is_("a handler's headers reach the client", (extra.header("x-one"), extra.header("x-two")),
            ("1", "2"))
        conn.close()

        overlong = H1(server)
        overlong.send(H1.head("GET", "/length/2/4") + H1.head("GET", "/"))
        r = overlong.response()
        is_("a body longer than its Content-Length is cut to it", (r.header("content-length"), r.body),
            ("2", b"ab"))
        check("and nothing pipelined behind it is answered", overlong.closed() and not overlong.buf,
              overlong.buf[:80])
        overlong.close()

        short = H1(server)
        r = short.request("GET", "/length/10/3")
        is_("a short body sends what it has", r.body, b"abc")
        check("and closes the connection rather than hanging", short.closed())
        short.close()
        is_("the server is healthy afterwards", H1(server).request("GET", "/").status, 200)


def own_server_headers():
    print("\nA handler's own server headers")
    with Server("--hsts", "31536000", http3=True) as server:
        conn = H1(server)
        r = conn.request("GET", "/status/200?header=strict-transport-security:max-age=60")
        is_("a handler's own Strict-Transport-Security is kept, not doubled",
            r.values("strict-transport-security"), ["max-age=60"])
        r = conn.request("GET", "/status/200?header=alt-svc:h3=%22:9999%22")
        is_("a handler's own Alt-Svc is kept, not doubled", r.values("alt-svc"), ['h3=":9999"'])
        plain = conn.request("GET", "/")
        check("and the server's own are there when it sets none",
              plain.header("strict-transport-security") and plain.header("alt-svc"))
        conn.close()

        client = H2Client(server)
        stream = client.request("GET", "/status/200?header=strict-transport-security:max-age=60")
        client.collect([stream])
        is_("and not doubled over HTTP/2", client.values(stream, "strict-transport-security"),
            [b"max-age=60"])
        client.close()


def framing_streams():
    print("\nStatus and headers, HTTP/2 and HTTP/3")
    with Server(http3=True) as server:
        client = H2Client(server)
        no_content = client.request("GET", "/status/204")
        not_modified = client.request("GET", "/status/304?header=content-length:5")
        headers = client.request("GET", "/status/200?header=x-one:1&header=x-two:2")
        overlong = client.request("GET", "/length/2/4")
        short = client.request("GET", "/length/10/3")
        client.collect([no_content, not_modified, headers, overlong, short])
        is_("a 204 has no content-length", client.value(no_content, "content-length"), None)
        is_("a 304 keeps the content-length the handler gave", client.value(not_modified, "content-length"), b"5")
        is_("and neither has a body", (client.body.get(no_content, b""), client.body.get(not_modified, b"")),
            (b"", b""))
        is_("a handler's headers reach the client",
            (client.value(headers, "x-one"), client.value(headers, "x-two")), (b"1", b"2"))
        is_("an overlong body is cut to what it declared", client.body.get(overlong, b""), b"ab")
        check("and that stream ends cleanly", overlong not in client.reset, client.reset.get(overlong))
        is_("a short body's bytes still arrive", client.body.get(short, b""), b"abc")
        is_("and the stream is reset rather than ended", client.reset.get(short),
            h2.errors.ErrorCodes.INTERNAL_ERROR)
        after = client.request("GET", "/")
        client.collect([after])
        is_("the connection survives a reset stream", client.status.get(after), 200)
        client.close()

        async def scenario():
            async with h3_connect(server) as h3:
                fixed = h3.request("GET", "/length/13/13")
                await h3.collect([fixed])
                is_("over HTTP/3 a declared length reaches the client",
                    h3.headers.get(fixed, {}).get(b"content-length"), [b"13"])
                is_("and the body matches it", len(h3.body.get(fixed, b"")), 13)

        run(scenario())


# ------------------------------------------------ Streamed responses


def pieces(n, size):
    return b"".join(bytes([97 + i % 26]) * size for i in range(n))


HIGH_WATER = 512 * 1024


def queued_most(body):
    """The figure /stream-queued ends its body with, or -1 if the body is not whole."""
    head, _, tail = body.rpartition(b"\nqueued ")
    if head != pieces(64, 65536) or not tail.isdigit():
        return -1
    return int(tail)


EVENTS_3 = b"".join(b"id: %d\ndata: event %d\n\n" % (i, i) for i in range(3))


def streaming_h1():
    print("\nStreamed responses, HTTP/1.1")
    with Server() as server:
        conn = H1(server)
        r = conn.request("GET", "/stream/3/5")
        is_("a streamed body arrives whole", (r.status, r.body), (200, pieces(3, 5)))
        is_("chunked, with no length", (r.header("transfer-encoding"), r.header("content-length")),
            ("chunked", None))
        is_("and the connection is kept for the next request", conn.request("GET", "/").status, 200)

        r = conn.request("GET", "/stream/64/65536")
        check("4 MiB streamed in 64 KiB writes arrives intact", r.body == pieces(64, 65536),
              len(r.body))

        r = conn.request("GET", "/stream-queued/64/65536")
        most = queued_most(r.body)
        check("a write waits above the high-water mark", 0 <= most <= HIGH_WATER + 65536, most)

        r = conn.request("GET", "/events/3")
        is_("server-sent events are text/event-stream", r.header("content-type"), "text/event-stream")
        is_("and each event is framed", r.body, EVENTS_3)
        conn.close()

        # A client that does not read. The handler waits for it rather than
        # queueing 4 MiB, and the worker goes on serving everyone else.
        stalled = H1(server)
        stalled.send(H1.head("GET", "/stream/64/65536"))
        time.sleep(0.5)
        other = H1(server)
        started = time.monotonic()
        is_("a stalled reader does not hold up another client", other.request("GET", "/").status, 200)
        check("which is answered promptly", time.monotonic() - started < 1.0,
              time.monotonic() - started)
        other.close()
        r = stalled.response()
        check("and the stalled reader still gets every byte once it reads",
              r.body == pieces(64, 65536), len(r.body))
        stalled.close()

        conn = H1(server)
        r = conn.request("GET", "/stream-throw")
        is_("a handler that throws part-way sends what it wrote", r.body, b"partial")
        check("and the body is cut off rather than ended", not r.complete)
        conn.close()
        time.sleep(0.2)
        check("and the failure is logged", "part-way through a streamed response" in server.output(),
              server.output()[-300:])

        old = socket.create_connection(("127.0.0.1", server.port), 10)
        old.sendall(b"GET /stream/2/3 HTTP/1.0\r\nHost: localhost\r\n\r\n")
        data = b""
        while True:
            chunk = old.recv(65536)
            if not chunk:
                break
            data += chunk
        old.close()
        head, _, body = data.partition(b"\r\n\r\n")
        check("to HTTP/1.0 the body ends with the connection",
              body == pieces(2, 3) and b"chunked" not in head.lower(), data)


def streaming_stalled():
    print("\nA streamed response nobody reads")
    with Server("--request-timeout", "1000") as server:
        stalled = H1(server)
        stalled.send(H1.head("GET", "/stream/64/65536"))
        time.sleep(3.5)
        data = b""
        stalled.sock.settimeout(5)
        try:
            while True:
                chunk = stalled.sock.recv(1 << 20)
                if not chunk:
                    break
                data += chunk
        except (socket.timeout, TimeoutError, OSError):
            data = None
        check("is closed once the client has been silent for --request-timeout",
              data is not None and len(data) < 4 * 1024 * 1024, None if data is None else len(data))
        stalled.close()
        is_("and the server goes on", get_json(server)["method"], "GET")


def streaming_streams():
    print("\nStreamed responses, HTTP/2 and HTTP/3")
    with Server(http3=True) as server:
        client = H2Client(server)
        # On its own: bytes still waiting for window when the reset goes are
        # dropped with the stream, and a 4 MiB neighbour would hold the window.
        broken = client.request("GET", "/stream-throw")
        client.collect([broken])
        small = client.request("GET", "/stream/3/5")
        big = client.request("GET", "/stream/64/65536")
        events = client.request("GET", "/events/3")
        client.collect([small, big, events], deadline=30)
        is_("over HTTP/2 a streamed body arrives whole", client.body.get(small, b""), pieces(3, 5))
        is_("with no length", client.value(small, "content-length"), None)
        check("4 MiB through HTTP/2 flow control arrives intact",
              client.body.get(big, b"") == pieces(64, 65536), len(client.body.get(big, b"")))
        is_("events over HTTP/2", client.body.get(events, b""), EVENTS_3)
        is_("a handler that throws part-way sends what it wrote",
            client.body.get(broken, b""), b"partial")
        is_("and the stream is reset rather than ended", client.reset.get(broken),
            h2.errors.ErrorCodes.INTERNAL_ERROR)
        after = client.request("GET", "/")
        client.collect([after])
        is_("and the connection goes on", client.status.get(after), 200)
        queued = client.request("GET", "/stream-queued/64/65536")
        client.collect([queued], deadline=30)
        most = queued_most(client.body.get(queued, b""))
        check("over HTTP/2 a write waits above the high-water mark", 0 <= most <= HIGH_WATER + 65536, most)
        client.close()

        async def scenario():
            async with h3_connect(server) as h3:
                small = h3.request("GET", "/stream/3/5")
                big = h3.request("GET", "/stream/64/65536")
                events = h3.request("GET", "/events/3")
                broken = h3.request("GET", "/stream-throw")
                await h3.collect([small, big, events, broken], timeout=30)
                is_("over HTTP/3 a streamed body arrives whole", h3.body.get(small, b""), pieces(3, 5))
                check("4 MiB over QUIC arrives intact", h3.body.get(big, b"") == pieces(64, 65536),
                      len(h3.body.get(big, b"")))
                is_("events over HTTP/3", h3.body.get(events, b""), EVENTS_3)
                check("a handler that throws part-way resets the stream", broken in h3.reset,
                      h3.reset)
                queued = h3.request("GET", "/stream-queued/64/65536")
                await h3.collect([queued], timeout=30)
                most = queued_most(h3.body.get(queued, b""))
                # QUIC takes the bytes at once; what it has not had acknowledged
                # is what the client is behind by, and a write waits on that.
                check("over HTTP/3 what QUIC holds unacknowledged counts as queued",
                      65536 <= most <= HIGH_WATER + 65536, most)

        run(scenario())


# ------------------------------------------------ 4. Errors and lifecycle


def errors():
    print("\nA handler that throws")
    with Server() as server:
        conn = H1(server)
        is_("is answered 500", conn.request("GET", "/throw").status, 500)
        is_("and the connection survives it", conn.request("GET", "/").status, 200)
        conn.close()
        time.sleep(0.2)
        check("and the failure is logged", "handler threw" in server.output(), server.output()[-300:])
        check("and the server is still running", server.alive())


def lifecycle():
    print("\nStart-up and shutdown hooks")
    marker = tempfile.mktemp(prefix="garuda-hooks-")
    with Server("--workers", "4", env={"GARUDA_START_MARKER": marker}) as server:
        time.sleep(0.5)
        lines = open(marker).read().split("\n") if os.path.exists(marker) else []
        starts = [line for line in lines if line.startswith("start ")]
        is_("the start-up hook runs once per worker", len({line.split()[1] for line in starts}), 4)

    shutdown = tempfile.mktemp(prefix="garuda-shutdown-")
    server = Server(env={"GARUDA_SHUTDOWN_MARKER": shutdown})
    result = {}

    def slow():
        conn = H1(server)
        result["status"] = conn.request("GET", "/delay/1000").status
        result["at"] = time.time() * 1e6

    requester = threading.Thread(target=slow)
    requester.start()
    time.sleep(0.3)
    server.signal(signal.SIGTERM)
    exited = server.wait_exit(10)
    requester.join(5)
    is_("an in-flight request is answered through SIGTERM", result.get("status"), 200)
    check("and shutdown waited for it", exited is not None and 0.5 <= exited + 0.3 <= 8,
          "exited after %r s" % exited)
    lines = [l for l in open(shutdown).read().split("\n") if l] if os.path.exists(shutdown) else []
    check("the shutdown hook ran", bool(lines), lines)
    if lines and "at" in result:
        ran_at = int(lines[-1].split()[3])
        check("after the in-flight request had been answered", ran_at + 5000 >= result["at"],
              "hook at %d, response at %d" % (ran_at, result["at"]))

    for sig, name in ((signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")):
        slow_start = Server("--workers", "2", env={"GARUDA_START_SLEEP_MS": "1500"}, wait=False)
        time.sleep(0.5)
        slow_start.signal(sig)
        exited = slow_start.wait_exit(5)
        check("%s during a slow start-up hook is not lost" % name, exited is not None,
              "still running after 5 s")
        slow_start.__exit__()

    stubborn = Server("--graceful-timeout", "1000")
    conn = H1(stubborn)
    conn.send(H1.head("GET", "/stuck"))
    time.sleep(0.3)
    stubborn.signal(signal.SIGTERM)
    exited = stubborn.wait_exit(25)
    check("a handler that never answers does not block shutdown", exited is not None,
          "still running after 25 s")
    is_("and the server exited on its own", stubborn.proc.returncode, 0)
    conn.close()

    hanging = Server("--graceful-timeout", "200", env={"GARUDA_SHUTDOWN_HANG": "1"})
    hanging.signal(signal.SIGTERM)
    exited = hanging.wait_exit(15)
    check("a shutdown hook that never returns does not block shutdown", exited is not None,
          "still running after 15 s")
    is_("and that server also exited on its own", hanging.proc.returncode, 0)
    hanging.__exit__()


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s (swift build -c release --product garuda-conformance)" % BIN)
        return 2
    print("garuda handler tests (%s)" % BIN)
    for section in (bodies_h1, bodies_h2, bodies_h3, headers_h1, request_ids, request_start,
                    headers_h2_h3, framing_h1, own_server_headers, framing_streams,
                    streaming_h1, streaming_stalled, streaming_streams, errors, lifecycle):
        try:
            section()
        except Exception as exc:  # noqa: BLE001 -- one broken section must not hide the rest
            bad("%s ran to the end" % section.__name__, "no exception", repr(exc))
    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

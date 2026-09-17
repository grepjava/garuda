#!/usr/bin/env python3
"""WebSockets over HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220), end to end.

    python3 scripts/websocket-streams-test.py [path-to-garuda-conformance]

Every check runs twice: over an HTTP/2 connection driven by the `h2` package,
and over an HTTP/3 connection driven by `aioquic`. Neither shares code with the
server. The WebSocket frames on top are built here, as in websocket-test.py,
so that the broken ones a library would never send can be sent too.

Uses the routes in Sources/GarudaConformance under /ws and /broadcast.
Needs:  pip install h2 aioquic
"""

import asyncio
import os
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib

try:
    import h2.config
    import h2.connection
    import h2.events
    import h2.settings
    from aioquic.asyncio.client import connect as quic_connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3_ALPN, H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import ConnectionTerminated, StreamReset
except ImportError:
    sys.stderr.write("this script needs the h2 and aioquic packages: pip install h2 aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda-conformance")

ENABLE_CONNECT_PROTOCOL = 0x8
SETTINGS_INITIAL_WINDOW_SIZE = 0x4
H2_PROTOCOL_ERROR = 0x1
H2_CANCEL = 0x8
H3_REQUEST_CANCELLED = 0x010C
H3_MESSAGE_ERROR = 0x010E

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
        directory = tempfile.mkdtemp(prefix="garuda-wss-")
        cert = os.path.join(directory, "cert.pem")
        key = os.path.join(directory, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
                        "-days", "2", "-nodes", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        CERTS = (cert, key)
    return CERTS


def free_port():
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
    """One worker, so /ws/last-close sees every handler. TLS for HTTP/1.1 and HTTP/2 (ALPN) and HTTP/3,
    all on the same port."""

    def __init__(self, *args):
        self.port = free_port()
        cert, key = make_certs()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error", "--http3",
               "--tls-cert", cert, "--tls-key", key] + list(args)
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.25).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    self.log.seek(0)
                    raise SystemExit("server exited during start-up:\n" + self.log.read().decode(errors="replace"))
                time.sleep(0.05)
        raise SystemExit("server never came up")

    def get(self, path):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen("https://127.0.0.1:%d%s" % (self.port, path), context=context,
                                    timeout=10) as response:
            return response.read().decode()

    def post(self, path, body):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        request = urllib.request.Request("https://127.0.0.1:%d%s" % (self.port, path), data=body, method="POST")
        with urllib.request.urlopen(request, context=context, timeout=10) as response:
            return response.read().decode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


# -- One stream, whichever protocol carries it ---------------------------------

class Stream:
    def __init__(self, owner, stream_id):
        self.owner = owner
        self.id = stream_id
        self.headers = None
        self.buf = bytearray()
        self.ended = False
        self.reset = None
        self.changed = asyncio.Event()

    def poke(self):
        self.changed.set()

    async def wait(self, condition, timeout):
        deadline = time.monotonic() + timeout
        while not condition():
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            self.changed.clear()
            try:
                await asyncio.wait_for(self.changed.wait(), left)
            except asyncio.TimeoutError:
                return condition()
        return True

    async def response(self, timeout=10):
        await self.wait(lambda: self.headers is not None or self.reset is not None or self.owner.closed, timeout)
        return self.headers

    @property
    def status(self):
        return int(self.headers.get(":status", "0")) if self.headers else None

    async def read(self, n, timeout=10):
        ready = await self.wait(lambda: len(self.buf) >= n or self.ended or self.reset is not None
                                or self.owner.closed, timeout)
        if len(self.buf) < n:
            raise EOFError("ended" if ready else "timed out")
        out = bytes(self.buf[:n])
        del self.buf[:n]
        self.owner.consumed(self, n)
        return out

    async def finished(self, timeout=10):
        """'end', ('reset', code), or 'open'."""
        await self.wait(lambda: self.ended or self.reset is not None or self.owner.closed, timeout)
        if self.reset is not None:
            return ("reset", self.reset)
        if self.ended:
            return "end"
        return "closed" if self.owner.closed else "open"

    async def send(self, data, end=False):
        await self.owner.send(self, data, end)


class H2Client:
    name = "HTTP/2"

    def __init__(self):
        self.streams = {}
        self.settings = {}
        self.closed = False
        self.auto_ack = True
        self.window_changed = asyncio.Event()

    @classmethod
    async def open(cls, server, tls=True):
        self = cls()
        context = None
        if tls:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.set_alpn_protocols(["h2"])
        self.reader, self.writer = await asyncio.open_connection(
            "127.0.0.1", server.port, ssl=context, server_hostname="localhost" if tls else None)
        config = h2.config.H2Configuration(client_side=True, header_encoding="utf-8",
                                           validate_outbound_headers=False, normalize_outbound_headers=False,
                                           validate_inbound_headers=False)
        self.conn = h2.connection.H2Connection(config)
        self.conn.initiate_connection()
        self.flush()
        self.settings_seen = asyncio.Event()
        self.task = asyncio.ensure_future(self.pump())
        await asyncio.wait_for(self.settings_seen.wait(), 10)
        return self

    def flush(self):
        data = self.conn.data_to_send()
        if data and not self.closed:
            self.writer.write(data)

    async def pump(self):
        try:
            while True:
                data = await self.reader.read(65536)
                if not data:
                    break
                for event in self.conn.receive_data(data):
                    self.handle(event)
                self.flush()
        except Exception:  # noqa: BLE001 -- a broken connection is an ending, which the checks see
            pass
        self.closed = True
        for stream in self.streams.values():
            stream.poke()
        self.window_changed.set()

    def handle(self, event):
        stream = self.streams.get(getattr(event, "stream_id", None))
        if isinstance(event, h2.events.RemoteSettingsChanged):
            for code, change in event.changed_settings.items():
                self.settings[int(code)] = change.new_value
            self.settings_seen.set()
        elif isinstance(event, h2.events.ResponseReceived) and stream:
            stream.headers = dict(event.headers)
        elif isinstance(event, h2.events.DataReceived) and stream:
            stream.buf += event.data
            stream.flow = getattr(stream, "flow", 0) + event.flow_controlled_length
            stream.pending_ack = getattr(stream, "pending_ack", 0) + event.flow_controlled_length
            if self.auto_ack:
                self.ack(stream)
        elif isinstance(event, h2.events.StreamEnded) and stream:
            stream.ended = True
        elif isinstance(event, h2.events.StreamReset) and stream:
            stream.reset = event.error_code
        elif isinstance(event, h2.events.WindowUpdated):
            self.window_changed.set()
        elif isinstance(event, h2.events.ConnectionTerminated):
            self.closed = True
        if stream:
            stream.poke()

    def ack(self, stream):
        n = getattr(stream, "pending_ack", 0)
        if n and stream.id in self.conn.streams:
            try:
                self.conn.acknowledge_received_data(n, stream.id)
            except Exception:  # noqa: BLE001 -- a stream already closed has nothing to acknowledge
                pass
        stream.pending_ack = 0
        self.flush()

    def consumed(self, stream, n):
        pass

    def open_stream(self, path, protocol="websocket", method="CONNECT", extra=(), end=False,
                    authority="localhost", scheme="https"):
        stream_id = self.conn.get_next_available_stream_id()
        headers = [(":method", method)]
        if protocol is not None:
            headers.append((":protocol", protocol))
        headers += [(":scheme", scheme), (":path", path)]
        if authority is not None:
            headers.append((":authority", authority))
        if method == "CONNECT" and protocol == "websocket":
            headers.append(("sec-websocket-version", "13"))
        headers += list(extra)
        stream = Stream(self, stream_id)
        self.streams[stream_id] = stream
        self.conn.send_headers(stream_id, headers, end_stream=end)
        self.flush()
        return stream

    async def send(self, stream, data, end):
        view = memoryview(data)
        while view:
            window = min(self.conn.local_flow_control_window(stream.id), self.conn.max_outbound_frame_size)
            if window <= 0:
                self.window_changed.clear()
                await asyncio.wait_for(self.window_changed.wait(), 10)
                continue
            chunk = view[:window]
            view = view[window:]
            self.conn.send_data(stream.id, bytes(chunk), end_stream=end and not view)
            self.flush()
            await self.writer.drain()
        if end and not data:
            self.conn.end_stream(stream.id)
            self.flush()

    def end(self, stream):
        self.conn.end_stream(stream.id)
        self.flush()

    def cancel(self, stream):
        self.conn.reset_stream(stream.id, H2_CANCEL)
        self.flush()

    async def close(self):
        if not self.closed:
            try:
                self.conn.close_connection()
                self.flush()
            except Exception:  # noqa: BLE001
                pass
            self.writer.close()
        self.task.cancel()


class H3Protocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.client = None

    def quic_event_received(self, event):
        client = self.client
        if client is None:
            return
        if isinstance(event, StreamReset):
            stream = client.streams.get(event.stream_id)
            if stream:
                stream.reset = event.error_code
                stream.poke()
        if isinstance(event, ConnectionTerminated):
            client.closed = True
            for stream in client.streams.values():
                stream.poke()
        for http_event in self.http.handle_event(event):
            stream = client.streams.get(getattr(http_event, "stream_id", None))
            if not stream:
                continue
            if isinstance(http_event, HeadersReceived):
                if stream.headers is None:
                    stream.headers = {k.decode(): v.decode() for k, v in http_event.headers}
            elif isinstance(http_event, DataReceived):
                stream.buf += http_event.data
            if getattr(http_event, "stream_ended", False):
                stream.ended = True
            stream.poke()


class H3Client:
    name = "HTTP/3"

    def __init__(self):
        self.streams = {}
        self.closed = False

    @classmethod
    async def open(cls, server):
        self = cls()
        configuration = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN,
                                          verify_mode=ssl.CERT_NONE, server_name="localhost")
        self.context = quic_connect("127.0.0.1", server.port, configuration=configuration,
                                    create_protocol=H3Protocol)
        self.protocol = await self.context.__aenter__()
        self.protocol.client = self
        return self

    def consumed(self, stream, n):
        pass

    def open_stream(self, path, protocol="websocket", method="CONNECT", extra=(), end=False,
                    authority="localhost", scheme="https"):
        quic = self.protocol._quic
        stream_id = quic.get_next_available_stream_id()
        headers = [(b":method", method.encode())]
        if protocol is not None:
            headers.append((b":protocol", protocol.encode()))
        headers += [(b":scheme", scheme.encode()), (b":path", path.encode())]
        if authority is not None:
            headers.append((b":authority", authority.encode()))
        if method == "CONNECT" and protocol == "websocket":
            headers.append((b"sec-websocket-version", b"13"))
        headers += [(k.encode(), v.encode()) for k, v in extra]
        stream = Stream(self, stream_id)
        self.streams[stream_id] = stream
        self.protocol.http.send_headers(stream_id, headers, end_stream=end)
        self.protocol.transmit()
        return stream

    async def send(self, stream, data, end):
        self.protocol.http.send_data(stream.id, data, end_stream=end)
        self.protocol.transmit()
        await asyncio.sleep(0)

    def end(self, stream):
        self.protocol.http.send_data(stream.id, b"", end_stream=True)
        self.protocol.transmit()

    def cancel(self, stream):
        self.protocol._quic.reset_stream(stream.id, H3_REQUEST_CANCELLED)
        self.protocol.transmit()

    async def close(self):
        try:
            await self.context.__aexit__(None, None, None)
        except Exception:  # noqa: BLE001
            pass


# -- WebSocket frames on a stream ------------------------------------------------

class WS:
    def __init__(self, stream):
        self.stream = stream
        self.inflater = zlib.decompressobj(-15)

    async def send_frame(self, opcode, payload, fin=True, rsv1=False, mask=True):
        if isinstance(payload, str):
            payload = payload.encode()
        b0 = (0x80 if fin else 0) | (0x40 if rsv1 else 0) | opcode
        n = len(payload)
        bit = 0x80 if mask else 0
        if n < 126:
            head = struct.pack("!BB", b0, bit | n)
        elif n < 65536:
            head = struct.pack("!BBH", b0, bit | 126, n)
        else:
            head = struct.pack("!BBQ", b0, bit | 127, n)
        if mask:
            key = os.urandom(4)
            payload = bytes(b ^ key[i & 3] for i, b in enumerate(payload))
            head += key
        await self.stream.send(head + payload)

    async def text(self, s):
        await self.send_frame(0x1, s)

    async def recv_frame(self, timeout=10):
        b0, b1 = await self.stream.read(2, timeout)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", await self.stream.read(2, timeout))[0]
        elif n == 127:
            n = struct.unpack("!Q", await self.stream.read(8, timeout))[0]
        payload = await self.stream.read(n, timeout)
        return b0 & 0x0F, bool(b0 & 0x40), bool(b0 & 0x80), bool(b1 & 0x80), payload

    async def recv_message(self, timeout=10):
        while True:
            opcode, rsv1, _, _, payload = await self.recv_frame(timeout)
            if opcode == 0x9:
                await self.send_frame(0xA, payload)
                continue
            if rsv1:
                payload = self.inflater.decompress(payload + b"\x00\x00\xff\xff")
            return opcode, payload

    async def close_frame(self, timeout=10):
        try:
            while True:
                opcode, _, _, _, payload = await self.recv_frame(timeout)
                if opcode == 0x8:
                    if len(payload) >= 2:
                        return struct.unpack("!H", payload[:2])[0], payload[2:].decode(errors="replace")
                    return None, ""
        except EOFError:
            return None

    async def close(self, code=1000):
        await self.send_frame(0x8, struct.pack("!H", code))


async def websocket(client, path, extra=()):
    stream = client.open_stream(path, extra=extra)
    await stream.response()
    return stream, WS(stream)


async def last_close(server, expect_prefix, timeout=5):
    deadline = time.monotonic() + timeout
    got = ""
    while time.monotonic() < deadline:
        got = await asyncio.get_event_loop().run_in_executor(None, server.get, "/ws/last-close")
        if got.startswith(expect_prefix):
            return got
        await asyncio.sleep(0.05)
    return got


# -- The checks, once per protocol ---------------------------------------------

async def handshake(server, client):
    p = client.name
    stream, ws = await websocket(client, "/ws/echo")
    is_("%s: an extended CONNECT is answered 200" % p, stream.status, 200)
    check("%s: with no Sec-WebSocket-Accept" % p, "sec-websocket-accept" not in (stream.headers or {}),
          stream.headers)
    await ws.text("hello")
    is_("%s: a text message is echoed" % p, await ws.recv_message(), (0x1, b"hello"))
    await ws.send_frame(0x2, b"\x00\xff")
    is_("%s: and a binary one" % p, await ws.recv_message(), (0x2, b"\x00\xff"))

    stream, ws = await websocket(client, "/ws/sub", [("sec-websocket-protocol", "chat.v1, chat.v2")])
    is_("%s: a subprotocol is agreed" % p, (stream.headers or {}).get("sec-websocket-protocol"), "chat.v2")
    is_("%s: and the handler sees it" % p, await ws.recv_message(), (0x1, b"chat.v2 of chat.v1,chat.v2"))

    stream = client.open_stream("/ws/room/kitchen")
    await stream.response()
    is_("%s: middleware runs, and its headers go out with the 200" % p,
        (stream.status, (stream.headers or {}).get("set-cookie")), (200, "seen=1"))
    is_("%s: with the path parameter" % p, await WS(stream).recv_message(), (0x1, b"welcome to kitchen"))

    stream = client.open_stream("/ws/reject")
    await stream.response()
    is_("%s: middleware can refuse one" % p, stream.status, 403)

    stream = client.open_stream("/ws/nowhere")
    await stream.response()
    is_("%s: a path with no route is 404" % p, stream.status, 404)

    stream = client.open_stream("/ws/echo", extra=[("sec-websocket-version", "8")])
    await stream.response()
    is_("%s: another version is 426" % p, (stream.status, (stream.headers or {}).get("sec-websocket-version")),
        (426, "13"))

    stream = client.open_stream("/ws/echo", protocol=None, method="GET", end=True)
    await stream.response()
    is_("%s: a plain GET to a WebSocket route is 400" % p, stream.status, 400)

    stream = client.open_stream("/ws/echo", protocol="something-else")
    await stream.response()
    is_("%s: a protocol not served here is 501" % p, stream.status, 501)

    if isinstance(client, H2Client):
        is_("HTTP/2: SETTINGS_ENABLE_CONNECT_PROTOCOL is sent", client.settings.get(ENABLE_CONNECT_PROTOCOL), 1)
        stream = client.open_stream("/ws/echo", authority=None)
        is_("HTTP/2: an extended CONNECT without :authority is reset", await stream.finished(),
            ("reset", H2_PROTOCOL_ERROR))
        stream = client.open_stream("/ws/echo", end=True)
        is_("HTTP/2: one that ends its stream at once is reset", await stream.finished(),
            ("reset", H2_PROTOCOL_ERROR))
        stream = client.open_stream("/ws/echo", protocol="websocket", method="GET")
        is_("HTTP/2: :protocol on anything but CONNECT is reset", await stream.finished(),
            ("reset", H2_PROTOCOL_ERROR))


async def messages(server, client):
    p = client.name
    stream, ws = await websocket(client, "/ws/echo")
    await ws.send_frame(0x1, "frag", fin=False)
    await ws.send_frame(0x0, "men", fin=False)
    await ws.send_frame(0x9, b"between")
    await ws.send_frame(0x0, "ted", fin=True)
    got = []
    for _ in range(2):
        opcode, _, _, _, payload = await ws.recv_frame()
        got.append((opcode, payload))
    check("%s: fragments are joined, and a ping between them answered" % p,
          sorted(got) == sorted([(0xA, b"between"), (0x1, b"fragmented")]), got)

    big = os.urandom(3 * 1024 * 1024)
    await ws.send_frame(0x2, big)
    opcode, payload = await ws.recv_message(timeout=30)
    check("%s: a 3 MiB message, larger than any window, arrives whole both ways" % p,
          opcode == 0x2 and payload == big, (opcode, len(payload)))

    for i in range(300):
        await ws.text("n%d" % i)
    order = []
    for _ in range(300):
        order.append((await ws.recv_message())[1])
    check("%s: 300 messages keep their order" % p, order == [("n%d" % i).encode() for i in range(300)])

    await ws.send_frame(0x1, b"\xce\xba\xe1\xbd\xb9\xcf", fin=True)
    got = await ws.close_frame()
    is_("%s: text that is not UTF-8 is closed with 1007" % p, got[0] if got else None, 1007)

    stream, ws = await websocket(client, "/ws/echo")
    await ws.send_frame(0x1, "no mask", mask=False)
    got = await ws.close_frame()
    is_("%s: an unmasked frame is closed with 1002" % p, got[0] if got else None, 1002)


async def closing(server, client):
    p = client.name
    stream, ws = await websocket(client, "/ws/echo")
    await ws.text("x")
    await ws.recv_message()
    await ws.close(1000)
    got = await ws.close_frame()
    is_("%s: a close is answered with the same code" % p, got[0] if got else None, 1000)
    client.end(stream)
    is_("%s: and the stream ends cleanly" % p, await stream.finished(), "end")
    is_("%s: the handler saw 1000" % p, await last_close(server, "1000"), "1000 ")

    stream, ws = await websocket(client, "/ws/close/4001")
    got = await ws.close_frame()
    is_("%s: a handler's close carries its code and reason" % p, got, (4001, "bye"))
    await ws.close(4001)
    is_("%s: and ends the stream once answered" % p, await stream.finished(), "end")

    stream, ws = await websocket(client, "/ws/return")
    got = await ws.close_frame()
    is_("%s: a handler that returns closes with 1000" % p, got[0] if got else None, 1000)

    stream, ws = await websocket(client, "/ws/throw")
    await ws.text("go")
    got = await ws.close_frame()
    is_("%s: one that throws closes with 1011" % p, got[0] if got else None, 1011)

    stream, ws = await websocket(client, "/ws/echo")
    await ws.text("x")
    await ws.recv_message()
    client.cancel(stream)
    is_("%s: a stream reset by the client is 1006 to the handler" % p, await last_close(server, "1006"), "1006 ")

    stream, ws = await websocket(client, "/ws/echo")
    await ws.text("x")
    await ws.recv_message()
    client.end(stream)
    is_("%s: so is a stream ended without a close" % p, await last_close(server, "1006"), "1006 ")
    check("%s: which the server ends too" % p, await stream.finished() in ("end", ("reset", H2_CANCEL),
                                                                          ("reset", H3_REQUEST_CANCELLED)))


async def multiplexing(server, client):
    p = client.name
    a_stream, a = await websocket(client, "/ws/echo")
    b_stream, b = await websocket(client, "/ws/echo")
    plain = client.open_stream("/ws/last-close", protocol=None, method="GET", end=True)
    await a.text("to a")
    await b.text("to b")
    await plain.response()
    is_("%s: two WebSockets and a request share one connection" % p,
        (await a.recv_message(), await b.recv_message(), plain.status), ((1, b"to a"), (1, b"to b"), 200))
    await a.close()
    await a.close_frame()
    await b.text("still here")
    is_("%s: closing one leaves the other open" % p, await b.recv_message(), (1, b"still here"))


async def backpressure(server, client):
    p = client.name
    if isinstance(client, H2Client):
        # The server sends until the stream's window is spent, and waits.
        client.auto_ack = False
        stream, ws = await websocket(client, "/ws/flood/64/65536")
        await stream.wait(lambda: False, 1.0)
        held = len(stream.buf)
        check("HTTP/2: a client that does not credit the stream holds the server back",
              held <= 70000 and held > 0, held)
        client.auto_ack = True
        client.ack(stream)
        count = 0
        while True:
            opcode, payload = await ws.recv_message(timeout=20)
            client.ack(stream)
            if opcode == 0x1:
                break
            count += 1
        is_("HTTP/2: and every message arrives once it does", (count, payload), (64, b"sent 64"))

        # A handler not reading: its queue fills, the stream is not credited,
        # and the client's window runs out. Frames are only sent whole, so a
        # window that stays shut leaves nothing half sent; a server crediting
        # regardless would take frames for as long as the loop runs.
        stream, ws = await websocket(client, "/ws/silent/4000")
        sent = 0
        chunk = os.urandom(32 * 1024)
        frame = 32 * 1024 + 14
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            if client.conn.local_flow_control_window(stream.id) >= frame:
                await ws.send_frame(0x2, chunk)
                sent += 1
                continue
            client.window_changed.clear()
            try:
                await asyncio.wait_for(client.window_changed.wait(), max(0.01, deadline - time.monotonic()))
            except asyncio.TimeoutError:
                break
        window = client.settings.get(SETTINGS_INITIAL_WINDOW_SIZE, 65535)
        check("HTTP/2: a handler that is not reading closes the client's window",
              sent * frame <= 2 * window + 8 * frame, (sent, window))
        remaining = 0
        for _ in range(8):
            try:
                await asyncio.wait_for(ws.send_frame(0x2, chunk), 5)
                remaining += 1
            except asyncio.TimeoutError:
                break
        await ws.close()
        got = await last_close(server, "1000 read %d" % (sent + remaining), timeout=15)
        is_("HTTP/2: and it reads everything once it starts" % (), got, "1000 read %d" % (sent + remaining))
    else:
        stream, ws = await websocket(client, "/ws/flood/64/65536")
        count = 0
        while True:
            opcode, payload = await ws.recv_message(timeout=20)
            if opcode == 0x1:
                break
            count += 1
        is_("HTTP/3: a flood of messages all arrive", (count, payload), (64, b"sent 64"))
        stream, ws = await websocket(client, "/ws/silent/800")
        chunk = os.urandom(32 * 1024)
        for _ in range(200):
            await ws.send_frame(0x2, chunk)
        await ws.close()
        got = await last_close(server, "1000 read 200", timeout=20)
        is_("HTTP/3: a handler that is not reading reads everything once it starts", got, "1000 read 200")


async def broadcast(server, client):
    p = client.name
    stream, ws = await websocket(client, "/broadcast/streams-%s/ws" % p[-1])
    opcode, first = await ws.recv_message()
    check("%s: a broadcast subscriber over a stream is up" % p, first.startswith(b"pid "), first)
    await asyncio.get_event_loop().run_in_executor(None, server.post, "/broadcast/streams-%s" % p[-1], b"hi")
    opcode, got = await ws.recv_message()
    check("%s: and hears what is published" % p, got.endswith(b" - hi"), got)


async def run_section(section, server, protocol):
    client = await (H2Client.open(server) if protocol == 2 else H3Client.open(server))
    try:
        await asyncio.wait_for(section(server, client), 120)
    finally:
        await client.close()


def section(name, func, *args):
    print("\n" + name)
    with Server(*args) as server:
        for protocol in (2, 3):
            try:
                asyncio.run(run_section(func, server, protocol))
            except Exception as exc:  # noqa: BLE001 -- one broken section must not hide the rest
                bad("%s over HTTP/%d ran to the end" % (func.__name__, protocol), "no exception", repr(exc))


def keepalive():
    print("\nPings")
    with Server("--ws-ping-interval", "300", "--ws-ping-timeout", "1000") as server:
        for protocol in (2, 3):
            async def run():
                client = await (H2Client.open(server) if protocol == 2 else H3Client.open(server))
                p = client.name
                try:
                    stream, ws = await websocket(client, "/ws/silent/60000")
                    opcode = None
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        opcode, _, _, _, _ = await ws.recv_frame(timeout=3)
                        if opcode == 0x9:
                            break
                    is_("%s: the server pings a quiet WebSocket" % p, opcode, 0x9)
                    # Not answering: the stream is abandoned with a reset.
                    got = await stream.finished(timeout=5)
                    check("%s: and resets it when no pong comes" % p,
                          got in (("reset", H2_CANCEL), ("reset", H3_REQUEST_CANCELLED)), got)
                    other, ws2 = await websocket(client, "/ws/echo")
                    await ws2.text("alive")
                    is_("%s: while the connection carries on" % p, await ws2.recv_message(), (1, b"alive"))
                finally:
                    await client.close()
            try:
                asyncio.run(run())
            except Exception as exc:  # noqa: BLE001
                bad("keepalive over HTTP/%d ran to the end" % protocol, "no exception", repr(exc))


def compression():
    print("\nCompression")
    with Server("--ws-compress") as server:
        for protocol in (2, 3):
            async def run():
                client = await (H2Client.open(server) if protocol == 2 else H3Client.open(server))
                p = client.name
                try:
                    stream, ws = await websocket(client, "/ws/echo",
                                                 [("sec-websocket-extensions", "permessage-deflate")])
                    header = (stream.headers or {}).get("sec-websocket-extensions", "")
                    check("%s: permessage-deflate is agreed" % p, header.startswith("permessage-deflate"), header)
                    compressor = zlib.compressobj(wbits=-15)
                    body = compressor.compress(b"z" * 10000) + compressor.flush(zlib.Z_SYNC_FLUSH)
                    await ws.send_frame(0x1, body[:-4], rsv1=True)
                    opcode, rsv1, _, _, payload = await ws.recv_frame()
                    text = ws.inflater.decompress(payload + b"\x00\x00\xff\xff") if rsv1 else payload
                    check("%s: and a compressed message round-trips compressed" % p,
                          rsv1 and text == b"z" * 10000, (rsv1, len(payload)))
                finally:
                    await client.close()
            try:
                asyncio.run(run())
            except Exception as exc:  # noqa: BLE001
                bad("compression over HTTP/%d ran to the end" % protocol, "no exception", repr(exc))


def protocols_flag():
    print("\n--websocket-protocols")
    with Server("--websocket-protocols", "http1") as server:
        async def run():
            client = await H2Client.open(server)
            try:
                is_("without http2, SETTINGS_ENABLE_CONNECT_PROTOCOL is not sent",
                    client.settings.get(ENABLE_CONNECT_PROTOCOL), None)
                stream = client.open_stream("/ws/echo")
                is_("and :protocol is refused as RFC 8441 says", await stream.finished(),
                    ("reset", H2_PROTOCOL_ERROR))
            finally:
                await client.close()
            client = await H3Client.open(server)
            try:
                stream = client.open_stream("/ws/echo")
                await stream.response()
                is_("without http3, one over HTTP/3 is 501", stream.status, 501)
            finally:
                await client.close()
        asyncio.run(run())
    with Server("--websocket-protocols", "http2,http3") as server:
        sock = socket.create_connection(("127.0.0.1", server.port), 10)
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["http/1.1"])
        sock = context.wrap_socket(sock, server_hostname="localhost")
        sock.sendall(b"GET /ws/echo HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
        head = sock.recv(4096).split(b"\r\n")[0]
        sock.close()
        is_("without http1, an upgrade is 501", head.split()[1] if len(head.split()) > 1 else head, b"501")

        async def run():
            client = await H2Client.open(server)
            try:
                stream, ws = await websocket(client, "/ws/echo")
                await ws.text("h2")
                is_("while HTTP/2 still carries them", await ws.recv_message(), (1, b"h2"))
            finally:
                await client.close()
        asyncio.run(run())
    try:
        subprocess.run([BIN, "--websocket-protocols", "http4", "--port", "1"], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        exited = 0
    except subprocess.CalledProcessError as error:
        exited = error.returncode
    is_("an unknown protocol in the list stops the server starting", exited, 2)


def tls():
    print("\nHTTP/2 over TLS")
    with Server() as server:
        async def run():
            client = await H2Client.open(server, tls=True)
            try:
                stream = client.open_stream("/ws/echo", scheme="https")
                await stream.response()
                ws = WS(stream)
                await ws.text("secret")
                is_("a WebSocket over h2 with TLS works", (stream.status, await ws.recv_message()), (200, (1, b"secret")))
            finally:
                await client.close()
        asyncio.run(run())


def draining():
    print("\nShutting down")
    with Server("--graceful-timeout", "5") as server:
        async def run():
            h2c = await H2Client.open(server)
            h3c = await H3Client.open(server)
            s2, w2 = await websocket(h2c, "/ws/echo")
            s3, w3 = await websocket(h3c, "/ws/echo")
            server.proc.send_signal(signal.SIGTERM)
            got2 = await w2.close_frame()
            got3 = await w3.close_frame()
            is_("HTTP/2: an open WebSocket is closed with 1001", got2[0] if got2 else None, 1001)
            is_("HTTP/3: and the same", got3[0] if got3 else None, 1001)
            await w2.close(1001)
            await w3.close(1001)
            await h2c.close()
            await h3c.close()
        asyncio.run(run())
        try:
            server.proc.wait(10)
            exited = True
        except subprocess.TimeoutExpired:
            exited = False
        check("and the worker exits once they are answered", exited)


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s (swift build -c release --product garuda-conformance)" % BIN)
        return 2
    print("garuda websocket over HTTP/2 and HTTP/3 tests (%s)" % BIN)
    section("Handshake", handshake)
    section("Messages", messages)
    section("Closing", closing)
    section("Several on one connection", multiplexing)
    section("Backpressure", backpressure, "--ws-max-queue", "4")
    section("Broadcast", broadcast)
    for extra in (keepalive, compression, protocols_flag, tls, draining):
        try:
            extra()
        except Exception as exc:  # noqa: BLE001
            bad("%s ran to the end" % extra.__name__, "no exception", repr(exc))
    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

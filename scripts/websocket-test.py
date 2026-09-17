#!/usr/bin/env python3
"""WebSocket handlers, end to end.

    python3 scripts/websocket-test.py [path-to-garuda-conformance]

Most of this drives the server with a client built here from a socket, because
the cases worth testing are the ones a well-behaved library never produces: an
unmasked frame, a close code nobody may send, text that stops being UTF-8
half-way through a fragment. The last section checks the `websockets` library
against the server, when it is installed.

Uses the routes in Sources/GarudaConformance under /ws.
"""

import asyncio
import base64
import hashlib
import os
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda-conformance")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

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
        directory = tempfile.mkdtemp(prefix="garuda-ws-")
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
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Server:
    def __init__(self, *args, tls=False):
        self.port = free_port()
        self.tls = tls
        cmd = [BIN, "--port", str(self.port), "--log-level", "error"]
        if tls:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
        cmd += list(args)
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
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

    def connect(self, timeout=10.0):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout)
        if self.tls:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            sock = context.wrap_socket(sock, server_hostname="localhost")
        return sock

    def get(self, path):
        sock = self.connect()
        sock.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % path).encode())
        raw = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            raw += chunk
        sock.close()
        head, _, body = raw.partition(b"\r\n\r\n")
        return int(head.split()[1]), body.decode(errors="replace")

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


class Client:
    """A WebSocket client with the frame layer in plain sight."""

    def __init__(self, server, path, headers=None, timeout=10.0, sock=None):
        self.sock = sock or server.connect(timeout)
        self.sock.settimeout(timeout)
        self.key = base64.b64encode(os.urandom(16)).decode()
        fields = {"Host": "localhost", "Upgrade": "websocket", "Connection": "Upgrade",
                  "Sec-WebSocket-Key": self.key, "Sec-WebSocket-Version": "13"}
        for name, value in (headers or {}).items():
            if value is None:
                fields.pop(name, None)
            else:
                fields[name] = value
        request = "GET %s HTTP/1.1\r\n" % path
        request += "".join("%s: %s\r\n" % item for item in fields.items()) + "\r\n"
        self.sock.sendall(request.encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            raw += chunk
        head, _, self.buffer = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1]) if lines and len(lines[0].split()) > 1 else 0
        self.headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            self.headers[name.strip().lower()] = value.strip()
        expect = base64.b64encode(hashlib.sha1((self.key + GUID).encode()).digest()).decode()
        self.accept_valid = self.headers.get("sec-websocket-accept") == expect
        self.inflater = zlib.decompressobj(-15)

    def body(self):
        """What follows a refusal's head, up to its Content-Length."""
        n = int(self.headers.get("content-length", "0"))
        return self.recv_exact(n).decode(errors="replace")

    def send_frame(self, opcode, payload, fin=True, rsv1=False, rsv2=False, mask=True, length=None):
        if isinstance(payload, str):
            payload = payload.encode()
        b0 = (0x80 if fin else 0) | (0x40 if rsv1 else 0) | (0x20 if rsv2 else 0) | opcode
        n = len(payload) if length is None else length
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
        self.sock.sendall(head + payload)

    def text(self, s):
        self.send_frame(0x1, s)

    def recv_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def recv_frame(self):
        b0, b1 = self.recv_exact(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", self.recv_exact(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self.recv_exact(8))[0]
        return b0 & 0x0F, bool(b0 & 0x40), bool(b0 & 0x80), bool(b1 & 0x80), self.recv_exact(n)

    def recv_message(self):
        """(opcode, payload) of the next data message, answering pings."""
        while True:
            opcode, rsv1, fin, _, payload = self.recv_frame()
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if rsv1:
                payload = self.inflater.decompress(payload + b"\x00\x00\xff\xff")
            return opcode, payload

    def close_frame(self):
        """Reads until the server's close and returns (code, reason), or None
        when the connection ended without one."""
        try:
            while True:
                opcode, _, _, _, payload = self.recv_frame()
                if opcode == 0x8:
                    if len(payload) >= 2:
                        return struct.unpack("!H", payload[:2])[0], payload[2:].decode(errors="replace")
                    return None, ""
        except (ConnectionError, socket.timeout, OSError):
            return None

    def ended(self, timeout=5.0):
        """Whether the server closed the TCP connection within `timeout`."""
        self.sock.settimeout(timeout)
        try:
            while True:
                if not self.sock.recv(65536):
                    return True
        except socket.timeout:
            return False
        except OSError:
            return True

    def close(self, code=1000, reason=b""):
        try:
            self.send_frame(0x8, struct.pack("!H", code) + reason)
        except OSError:
            pass

    def drop(self):
        try:
            self.sock.close()
        except OSError:
            pass


def last_close(server, expect=None, timeout=3.0):
    """The conformance app's record of how the last WebSocket ended, waiting
    for the handler to have written it."""
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        _, value = server.get("/ws/last-close")
        if expect is None or value == expect:
            return value
        time.sleep(0.05)
    return value


# ==========================================================================


def handshake():
    print("\nHandshake")
    with Server() as server:
        c = Client(server, "/ws/echo")
        is_("an upgrade is answered 101", c.status, 101)
        check("Sec-WebSocket-Accept is right", c.accept_valid, c.headers.get("sec-websocket-accept"))
        is_("Upgrade: websocket", c.headers.get("upgrade", "").lower(), "websocket")
        is_("Connection: Upgrade", c.headers.get("connection", "").lower(), "upgrade")
        check("no Content-Length on a 101", "content-length" not in c.headers, c.headers)
        c.text("hello")
        is_("and it talks", c.recv_message(), (0x1, b"hello"))
        c.drop()

        c = Client(server, "/ws/sub", headers={"Sec-WebSocket-Protocol": "chat.v1, chat.v2"})
        is_("the route's preferred subprotocol is agreed", c.headers.get("sec-websocket-protocol"), "chat.v2")
        is_("and the handler sees it and the offer", c.recv_message(), (0x1, b"chat.v2 of chat.v1,chat.v2"))
        c.drop()

        c = Client(server, "/ws/sub", headers={"Sec-WebSocket-Protocol": "other"})
        is_("an offer the route does not speak is still accepted", c.status, 101)
        check("without a subprotocol", "sec-websocket-protocol" not in c.headers, c.headers)
        is_("and the handler sees none", c.recv_message(), (0x1, b"none of other"))
        c.drop()

        c = Client(server, "/ws/room/lobby")
        is_("extractors run before the upgrade", c.recv_message(), (0x1, b"welcome to lobby"))
        is_("and middleware's headers go out with the 101", c.headers.get("set-cookie"), "seen=1")
        c.drop()

        c = Client(server, "/ws/reject")
        is_("middleware that refuses answers with its status", c.status, 403)
        c.drop()

        c = Client(server, "/ws/echo", headers={"Upgrade": None, "Connection": "close"})
        is_("a plain GET to a WebSocket route is 426", c.status, 426)
        is_("naming the protocol to upgrade to", c.headers.get("upgrade"), "websocket")
        c.drop()

        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Version": "8"})
        is_("another version is 426", c.status, 426)
        is_("naming version 13", c.headers.get("sec-websocket-version"), "13")
        c.drop()

        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Key": None})
        is_("an upgrade without a key is 400", c.status, 400)
        c.drop()

        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Key": "c2hvcnQ="})
        is_("a key that is not 16 bytes is 400", c.status, 400)
        c.drop()

        c = Client(server, "/ws/echo", headers={"Connection": "keep-alive"})
        is_("an Upgrade header without Connection: Upgrade is 426", c.status, 426)
        c.drop()

        c = Client(server, "/ws/nowhere")
        is_("an upgrade to no route is 404", c.status, 404)
        c.drop()

        # Frames sent straight after the handshake, before the 101 is read.
        sock = server.connect()
        key = base64.b64encode(os.urandom(16)).decode()
        frame = bytes([0x81, 0x80 | 5]) + b"\0\0\0\0" + b"early"
        sock.sendall(("GET /ws/echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode() + frame)
        raw = b""
        sock.settimeout(5)
        try:
            while b"early" not in raw:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                raw += chunk
        except socket.timeout:
            pass
        check("a frame sent with the handshake is read after it", raw.endswith(b"\x81\x05early"), raw[-20:])
        sock.close()

    with Server("--no-websockets") as server:
        c = Client(server, "/ws/echo")
        is_("--no-websockets refuses the upgrade with 501", c.status, 501)
        c.drop()


def messages():
    print("\nMessages")
    with Server() as server:
        c = Client(server, "/ws/echo")
        c.send_frame(0x2, bytes(range(256)))
        is_("binary is echoed as binary", c.recv_message(), (0x2, bytes(range(256))))
        c.send_frame(0x1, b"")
        is_("an empty text message", c.recv_message(), (0x1, b""))
        c.send_frame(0x1, b"one ", fin=False)
        c.send_frame(0x0, b"two ", fin=False)
        c.send_frame(0x0, b"three")
        is_("fragments are joined into one message", c.recv_message(), (0x1, b"one two three"))
        c.send_frame(0x1, b"before ", fin=False)
        c.send_frame(0x9, b"between")
        c.send_frame(0x0, b"after")
        opcode, _, _, _, payload = c.recv_frame()
        is_("a ping between fragments is answered at once", (opcode, payload), (0xA, b"between"))
        is_("and the message is still whole", c.recv_message(), (0x1, b"before after"))
        snowman = "café ☃".encode()
        c.send_frame(0x1, snowman[:4], fin=False)
        c.send_frame(0x0, snowman[4:])
        is_("a character split across fragments", c.recv_message(), (0x1, snowman))
        big = os.urandom(3 * 1024 * 1024)
        c.send_frame(0x2, big)
        opcode, payload = c.recv_message()
        check("a 3 MiB message round-trips", opcode == 0x2 and payload == big, len(payload))
        for i in range(200):
            c.text("m%d" % i)
        received = [c.recv_message()[1] for _ in range(200)]
        is_("200 messages in a burst arrive in order", received, [("m%d" % i).encode() for i in range(200)])
        c.drop()

        c = Client(server, "/ws/ticks/5")
        ticks = [c.recv_message()[1] for _ in range(5)]
        is_("a handler sleeps between sends", ticks, [b"tick %d" % i for i in range(1, 6)])
        is_("and closes with 1000", c.close_frame(), (1000, ""))
        c.drop()


def violations():
    print("\nViolations")
    with Server("--ws-max-message", "65536") as server:
        cases = [
            ("an unmasked frame is 1002", lambda c: c.send_frame(0x1, b"hi", mask=False), 1002),
            ("text that is not UTF-8 is 1007", lambda c: c.send_frame(0x1, b"\xff\xfe"), 1007),
            ("text that ends mid-character is 1007", lambda c: c.send_frame(0x1, b"caf\xc3"), 1007),
            ("a continuation with no message is 1002", lambda c: c.send_frame(0x0, b"x"), 1002),
            ("a new message during a fragmented one is 1002",
             lambda c: (c.send_frame(0x1, b"a", fin=False), c.send_frame(0x1, b"b")), 1002),
            ("RSV2 is 1002", lambda c: c.send_frame(0x1, b"x", rsv2=True), 1002),
            ("RSV1 without an extension is 1002", lambda c: c.send_frame(0x1, b"x", rsv1=True), 1002),
            ("an unknown opcode is 1002", lambda c: c.send_frame(0x3, b"x"), 1002),
            ("a control frame over 125 bytes is 1002", lambda c: c.send_frame(0x9, b"p" * 126), 1002),
            ("a fragmented ping is 1002", lambda c: c.send_frame(0x9, b"p", fin=False), 1002),
            ("a message over --ws-max-message is 1009", lambda c: c.send_frame(0x2, b"x" * 70000), 1009),
            ("fragments adding up past the limit are 1009",
             lambda c: [c.send_frame(0x2 if i == 0 else 0x0, b"x" * 30000, fin=False) for i in range(3)], 1009),
            ("a close with one byte is 1002", lambda c: c.send_frame(0x8, b"\x03"), 1002),
            ("a close with code 999 is 1002", lambda c: c.send_frame(0x8, struct.pack("!H", 999)), 1002),
            ("a close with 1005, reserved, is 1002", lambda c: c.send_frame(0x8, struct.pack("!H", 1005)), 1002),
            ("a close whose reason is not UTF-8 is 1007",
             lambda c: c.send_frame(0x8, struct.pack("!H", 1000) + b"\xff"), 1007),
        ]
        for name, act, code in cases:
            c = Client(server, "/ws/echo")
            act(c)
            got = c.close_frame()
            is_(name, got[0] if got else None, code)
            check("  and the connection ends", c.ended(), "still open")
            c.drop()

        # The text is checked as it arrives, so the first bad fragment fails it.
        c = Client(server, "/ws/echo")
        c.send_frame(0x1, b"\xff", fin=False)
        got = c.close_frame()
        is_("a bad fragment fails before the message ends", got[0] if got else None, 1007)
        c.drop()

        is_("a server that turned away all that still answers", server.get("/ws/last-close")[0], 200)


def closing():
    print("\nClosing")
    with Server() as server:
        c = Client(server, "/ws/echo")
        c.close(1000)
        is_("a close is answered with the same code", c.close_frame(), (1000, ""))
        check("and the server ends the connection", c.ended(), "still open")
        is_("the handler's receive ended with the code", last_close(server, "1000 "), "1000 ")

        c = Client(server, "/ws/echo")
        c.close(4000, b"done")
        is_("an application code is echoed", c.close_frame(), (4000, ""))
        is_("and its reason reaches the handler", last_close(server, "4000 done"), "4000 done")
        c.drop()

        c = Client(server, "/ws/echo")
        c.send_frame(0x8, b"")
        is_("a close without a code is answered 1000", c.close_frame(), (1000, ""))
        is_("and reported as 1005", last_close(server, "1005 "), "1005 ")
        c.drop()

        c = Client(server, "/ws/echo")
        c.text("x")
        c.recv_message()
        c.drop()
        is_("a connection dropped without a close is reported as 1006", last_close(server, "1006 "), "1006 ")

        c = Client(server, "/ws/close/4001")
        is_("a handler's close carries its code and reason", c.close_frame(), (4001, "bye"))
        c.text("late")
        c.close(4001)
        check("the server ends the connection once the client answers", c.ended(), "still open")
        c.drop()

        c = Client(server, "/ws/return")
        is_("a handler that returns closes with 1000", c.close_frame(), (1000, ""))
        c.drop()

        c = Client(server, "/ws/throw")
        c.text("go")
        is_("a handler that throws closes with 1011", c.close_frame(), (1011, ""))
        c.drop()

        c = Client(server, "/ws/close/4002")
        is_("a close the client never answers", c.close_frame(), (4002, "bye"))
        check("still open for a moment, waiting for the answer", not c.ended(0.5), "closed at once")
        c.drop()

    with Server("--ws-ping-timeout", "500") as server:
        c = Client(server, "/ws/close/4003")
        c.close_frame()
        check("is given up on after --ws-ping-timeout", c.ended(5), "still open after 5 s")
        c.drop()


def keepalive():
    print("\nPings, and a handler that is not reading")
    with Server("--ws-ping-interval", "300", "--ws-ping-timeout", "1500") as server:
        c = Client(server, "/ws/silent/4000", timeout=20)
        c.send_frame(0x9, b"are-you-there")
        pong = False
        server_ping = False
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not (pong and server_ping):
            opcode, _, _, _, payload = c.recv_frame()
            if opcode == 0xA and payload == b"are-you-there":
                pong = True
            elif opcode == 0x9:
                server_ping = True
                c.send_frame(0xA, payload)
        check("a ping is answered while the handler is not reading", pong)
        check("the server sends keepalive pings", server_ping)
        for i in range(10):
            c.text("while-asleep-%d" % i)
        # Answer pings until the handler wakes, then close.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            c.sock.settimeout(0.2)
            try:
                opcode, _, _, _, payload = c.recv_frame()
                if opcode == 0x9:
                    c.send_frame(0xA, payload)
            except (socket.timeout, ConnectionError):
                pass
        c.sock.settimeout(10)
        check("answering pings keeps the connection open", not c.ended(0.1), "closed")
        c.close(1000)
        is_("messages sent while the handler slept are all read", last_close(server, "1000 read 10", 6), "1000 read 10")
        c.drop()

        c = Client(server, "/ws/silent/60000", timeout=20)
        # Never answer the server's pings.
        check("a peer that stops answering pings is closed", c.ended(6), "still open")
        c.drop()

    with Server("--ws-max-queue", "4", "--ws-ping-interval", "0") as server:
        c = Client(server, "/ws/silent/1500", timeout=20)
        for i in range(60):
            c.text("q%d" % i)
        c.close(1000)
        is_("past --ws-max-queue the socket waits, and nothing is lost",
            last_close(server, "1000 read 60", 8), "1000 read 60")
        c.drop()


def backpressure():
    print("\nSending to a slow reader")
    with Server() as server:
        c = Client(server, "/ws/flood/400/65536", timeout=30)
        time.sleep(1.0)
        count = 0
        total = 0
        while True:
            opcode, payload = c.recv_message()
            if opcode == 0x1:
                break
            count += 1
            total += len(payload)
        is_("every message of a 26 MiB flood arrives", (count, total), (400, 400 * 65536))
        is_("then the handler's count", payload, b"sent 400")
        c.close(1000)
        c.drop()


def compression():
    print("\nCompression")
    text = ("the quick brown fox jumps over the lazy dog " * 40).encode()
    with Server("--ws-compress") as server:
        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits"})
        is_("permessage-deflate is agreed", c.headers.get("sec-websocket-extensions"),
            "permessage-deflate; client_max_window_bits=12")
        compressor = zlib.compressobj(wbits=-15)
        data = compressor.compress(text) + compressor.flush(zlib.Z_SYNC_FLUSH)
        c.send_frame(0x1, data[:-4], rsv1=True)
        opcode, rsv1, _, _, payload = c.recv_frame()
        check("the echo comes back compressed", rsv1)
        is_("and inflates to the message", c.inflater.decompress(payload + b"\x00\x00\xff\xff"), text)
        c.drop()

        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Extensions": "permessage-deflate"})
        bomb = zlib.compressobj(wbits=-15)
        data = bomb.compress(b"\0" * 20_000_000) + bomb.flush(zlib.Z_SYNC_FLUSH)
        c.send_frame(0x2, data[:-4], rsv1=True)
        got = c.close_frame()
        is_("a message that inflates past the limit is 1009", got[0] if got else None, 1009)
        c.drop()

    with Server() as server:
        c = Client(server, "/ws/echo", headers={"Sec-WebSocket-Extensions": "permessage-deflate"})
        check("without --ws-compress nothing is agreed", "sec-websocket-extensions" not in c.headers, c.headers)
        c.drop()


def tls():
    print("\nOver TLS")
    with Server(tls=True) as server:
        c = Client(server, "/ws/echo")
        is_("wss: the upgrade", c.status, 101)
        c.text("secure")
        is_("and a message", c.recv_message(), (0x1, b"secure"))
        c.close(1000)
        is_("and the close", c.close_frame(), (1000, ""))
        c.drop()


def draining():
    print("\nShutting down")
    with Server("--graceful-timeout", "5") as server:
        c = Client(server, "/ws/echo")
        c.text("x")
        c.recv_message()
        server.proc.send_signal(signal.SIGTERM)
        got = c.close_frame()
        is_("an open WebSocket is closed with 1001", got[0] if got else None, 1001)
        c.close(1001)
        try:
            server.proc.wait(10)
            exited = True
        except subprocess.TimeoutExpired:
            exited = False
        check("and the worker exits once it is answered", exited)
        c.drop()


def library():
    print("\nThe websockets library")
    try:
        from websockets.asyncio.client import connect
    except ImportError:
        print("  skipped: websockets is not installed")
        return

    async def talk(port, compression):
        async with connect("ws://127.0.0.1:%d/ws/sub" % port, compression=compression,
                           subprotocols=["chat.v1"], max_size=None) as ws:
            greeting = await ws.recv()
            header = ws.response.headers.get("Sec-WebSocket-Extensions")
            await ws.send("x" * 5000)
            echoed = await ws.recv()
            await ws.send(b"\x00\x01")
            binary = await ws.recv()
            return greeting, header, echoed, binary, ws.subprotocol

    with Server("--ws-compress") as server:
        greeting, header, echoed, binary, sub = asyncio.run(talk(server.port, "deflate"))
        is_("it agrees a subprotocol", (greeting, sub), ("chat.v1 of chat.v1", "chat.v1"))
        check("and permessage-deflate", header is not None and header.startswith("permessage-deflate"), header)
        is_("and messages round-trip", (echoed, binary), ("x" * 5000, b"\x00\x01"))


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s (swift build -c release --product garuda-conformance)" % BIN)
        return 2
    print("garuda websocket tests (%s)" % BIN)
    for section in (handshake, messages, violations, closing, keepalive, backpressure,
                    compression, tls, draining, library):
        try:
            section()
        except Exception as exc:  # noqa: BLE001 -- one broken section must not hide the rest
            bad("%s ran to the end" % section.__name__, "no exception", repr(exc))
    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

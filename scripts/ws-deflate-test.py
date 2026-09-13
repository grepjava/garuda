#!/usr/bin/env python3
"""--ws-compress: permessage-deflate (RFC 7692), end to end.

    python3 scripts/ws-deflate-test.py [path-to-peregrine]

Most of this drives the server with a client built here from a socket and zlib,
because the cases worth testing are the ones a well-behaved library never
produces: RSV1 on a control frame, a compressed message that inflates past the
limit, a stream that is not deflate at all. The last section checks the
`websockets` library against it, when that is installed.
"""

import asyncio
import base64
import os
import shlex
import socket
import struct
import subprocess
import sys
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/debug/peregrine")
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


def is_(name, actual, expected):
    if actual == expected:
        ok(name)
    else:
        bad(name, expected, actual)


def check(name, condition, detail=""):
    if condition:
        ok(name)
    else:
        bad(name, "true", detail)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Server:
    def __init__(self, *args):
        self.port = free_port()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error",
               "--python-path", os.path.join(ROOT, "examples")] + EXTRA + list(args) + ["asgi_app:app"]
        self.process = subprocess.Popen(cmd)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.25).close()
                return
            except OSError:
                if self.process.poll() is not None:
                    raise SystemExit("server exited during start-up")
                time.sleep(0.05)
        raise SystemExit("server did not start")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


class Client:
    """A WebSocket client with the frame layer in plain sight."""

    def __init__(self, port, offer=None, path="/ws"):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        head = ("GET %s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                "Sec-WebSocket-Version: 13\r\n" % (path, key))
        if offer is not None:
            head += "Sec-WebSocket-Extensions: %s\r\n" % offer
        self.sock.sendall((head + "\r\n").encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            raw += chunk
        head, _, self.buffer = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = lines[0]
        self.extensions = None
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "sec-websocket-extensions":
                self.extensions = value.strip()
        self.inflater = zlib.decompressobj(-15)

    def send_frame(self, opcode, payload, fin=True, rsv1=False):
        b0 = (0x80 if fin else 0) | (0x40 if rsv1 else 0) | opcode
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", b0, 0x80 | n)
        elif n < 65536:
            head = struct.pack("!BBH", b0, 0x80 | 126, n)
        else:
            head = struct.pack("!BBQ", b0, 0x80 | 127, n)
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def recv_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
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
        return b0 & 0x0F, bool(b0 & 0x40), bool(b0 & 0x80), self.recv_exact(n)

    def recv_message(self):
        """(opcode, compressed-on-the-wire, wire size, payload)."""
        opcode, rsv1, fin, payload = self.recv_frame()
        wire = len(payload)
        if rsv1:
            data = self.inflater.decompress(payload + b"\x00\x00\xff\xff")
        else:
            data = payload
        return opcode, rsv1, wire, data

    def close_code(self):
        """Reads until the server's close frame and returns its code."""
        try:
            while True:
                opcode, _, _, payload = self.recv_frame()
                if opcode == 0x8:
                    return struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
        except (ConnectionError, socket.timeout, OSError):
            return None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def deflate(data, compressor=None):
    c = compressor or zlib.compressobj(wbits=-15)
    out = c.compress(data) + c.flush(zlib.Z_SYNC_FLUSH)
    assert out.endswith(b"\x00\x00\xff\xff")
    return out[:-4]


TEXT = ("the quick brown fox jumps over the lazy dog " * 40).encode()


def negotiation():
    print("\nNegotiation")
    with Server("--ws-compress") as server:
        c = Client(server.port, "permessage-deflate; client_max_window_bits")
        is_("the upgrade succeeds", c.status, "HTTP/1.1 101 Switching Protocols")
        is_("permessage-deflate is accepted, with a smaller client window",
            c.extensions, "permessage-deflate; client_max_window_bits=12")
        c.close()

        c = Client(server.port, "permessage-deflate")
        is_("a bare offer is accepted as it is", c.extensions, "permessage-deflate")
        c.close()

        c = Client(server.port, "permessage-deflate; server_no_context_takeover; "
                                "client_no_context_takeover")
        is_("both no_context_takeover parameters are agreed to",
            c.extensions, "permessage-deflate; server_no_context_takeover; "
                          "client_no_context_takeover")
        c.close()

        c = Client(server.port, "permessage-deflate; server_max_window_bits=8")
        is_("a server window of 8 bits, which zlib cannot make, is declined",
            c.extensions, None)
        c.close()

        c = Client(server.port, "permessage-deflate; server_max_window_bits=10")
        is_("a smaller server window is agreed to",
            c.extensions, "permessage-deflate; server_max_window_bits=10")
        c.close()

        c = Client(server.port, "permessage-deflate; unknown_thing, permessage-deflate")
        is_("an offer with an unknown parameter is passed over for the next one",
            c.extensions, "permessage-deflate")
        c.close()

        c = Client(server.port, "x-webkit-deflate-frame, permessage-deflate")
        is_("an unknown extension is ignored", c.extensions, "permessage-deflate")
        c.close()

        c = Client(server.port, "permessage-deflate; server_no_context_takeover; "
                                "server_no_context_takeover")
        is_("a parameter given twice spoils the offer", c.extensions, None)
        c.close()

    with Server() as server:
        c = Client(server.port, "permessage-deflate")
        is_("without --ws-compress nothing is negotiated", c.extensions, None)
        c.send_frame(0x1, b"plain")
        is_("and plain messages still work", c.recv_message()[3], b"echo:plain")
        c.close()


def messages():
    print("\nMessages")
    with Server("--ws-compress") as server:
        c = Client(server.port, "permessage-deflate")
        client = zlib.compressobj(wbits=-15)
        c.send_frame(0x1, deflate(TEXT, client), rsv1=True)
        opcode, rsv1, first_wire, data = c.recv_message()
        is_("a compressed text message is inflated and echoed", data, b"echo:" + TEXT)
        check("the echo comes back compressed", rsv1)
        check("and much smaller than it is", first_wire < len(TEXT) // 4, first_wire)

        c.send_frame(0x1, deflate(TEXT, client), rsv1=True)
        _, rsv1, second_wire, data = c.recv_message()
        is_("a second message on the client's context inflates", data, b"echo:" + TEXT)
        check("the server's context carries over, so the repeat is smaller still",
              second_wire < first_wire, "%d then %d" % (first_wire, second_wire))

        c.send_frame(0x2, deflate(bytes(range(256)) * 8, client), rsv1=True)
        _, _, _, data = c.recv_message()
        is_("binary messages too", data, b"echo:" + bytes(range(256)) * 8)

        c.send_frame(0x1, b"hi")
        _, rsv1, _, data = c.recv_message()
        is_("an uncompressed message is still accepted", data, b"echo:hi")
        check("and a reply that small is not compressed", not rsv1)

        compressed = deflate(TEXT, client)
        half = len(compressed) // 2
        c.send_frame(0x1, compressed[:half], fin=False, rsv1=True)
        c.send_frame(0x0, compressed[half:], fin=True)
        _, _, _, data = c.recv_message()
        is_("a compressed message in two frames is put back together", data, b"echo:" + TEXT)
        c.close()

        c = Client(server.port, "permessage-deflate; server_no_context_takeover; "
                                "client_no_context_takeover")
        sizes = []
        for _ in range(2):
            c.send_frame(0x1, deflate(TEXT), rsv1=True)
            _, _, wire, data = c.recv_message()
            c.inflater = zlib.decompressobj(-15)
            sizes.append(wire)
        is_("with no context takeover each message inflates on its own", data, b"echo:" + TEXT)
        is_("and the server's repeat is no smaller", sizes[0], sizes[1])
        c.close()


def violations():
    print("\nViolations")
    with Server("--ws-compress", "--ws-max-message", "65536") as server:
        c = Client(server.port, "permessage-deflate")
        c.send_frame(0x9, b"", rsv1=True)
        is_("RSV1 on a control frame is a protocol error", c.close_code(), 1002)
        c.close()

        c = Client(server.port, "permessage-deflate")
        c.send_frame(0x1, b"part", fin=False)
        c.send_frame(0x0, b"rest", rsv1=True)
        is_("RSV1 on a continuation frame is a protocol error", c.close_code(), 1002)
        c.close()

        c = Client(server.port, "permessage-deflate")
        c.send_frame(0x1, deflate(b"\0" * 10_000_000), rsv1=True)
        is_("a message that inflates past --ws-max-message is refused", c.close_code(), 1009)
        c.close()

        c = Client(server.port, "permessage-deflate")
        c.send_frame(0x1, deflate(b"\xff\xfe not utf-8"), rsv1=True)
        is_("text that is not UTF-8 once inflated is refused", c.close_code(), 1007)
        c.close()

        c = Client(server.port, "permessage-deflate")
        c.send_frame(0x1, b"\xff\xff\xff\xff this is not deflate", rsv1=True)
        is_("a payload that is not deflate is refused", c.close_code(), 1007)
        c.close()

    with Server("--ws-compress") as server:
        c = Client(server.port, None)
        c.send_frame(0x1, deflate(b"hello"), rsv1=True)
        is_("RSV1 without the extension negotiated is a protocol error", c.close_code(), 1002)
        c.close()


def library():
    print("\nThe websockets library")
    try:
        from websockets.asyncio.client import connect
    except ImportError:
        print("  skipped: websockets is not installed")
        return

    async def talk(port, compression):
        async with connect("ws://127.0.0.1:%d/ws" % port, compression=compression,
                           max_size=None) as ws:
            header = ws.response.headers.get("Sec-WebSocket-Extensions")
            await ws.send(TEXT.decode())
            first = await ws.recv()
            await ws.send(TEXT.decode())
            second = await ws.recv()
            return header, first, second

    with Server("--ws-compress") as server:
        header, first, second = asyncio.run(talk(server.port, "deflate"))
        check("the library negotiates permessage-deflate",
              header is not None and header.startswith("permessage-deflate"), header)
        is_("and its messages round-trip", (first, second),
            ("echo:" + TEXT.decode(), "echo:" + TEXT.decode()))
        header, first, _ = asyncio.run(talk(server.port, None))
        is_("a client that offers nothing gets nothing", header, None)
        is_("and still talks", first, "echo:" + TEXT.decode())


def main():
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    print("peregrine permessage-deflate tests (%s)" % BIN)
    for test in (negotiation, messages, violations, library):
        try:
            test()
        except Exception:
            global FAIL
            FAIL += 1
            import traceback
            print("  FAIL %s raised" % test.__name__)
            traceback.print_exc()
    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


sys.exit(main())

#!/usr/bin/env python3
"""Broadcast across workers, server-sent events and their keep-alive, end to end.

    python3 scripts/broadcast-test.py [path-to-garuda-conformance]

A server with several workers, and clients on as many connections as it takes
to land on more than one of them: a message published through any worker has
to reach event streams, long polls and WebSockets held by every other, in the
order it was published, and a client that reconnects with Last-Event-ID has
to be sent what it missed by whichever worker it reaches.

Uses the routes in Sources/GarudaConformance/BroadcastRoutes.swift.
"""

import base64
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda-conformance")

PASS = 0
FAIL = 0


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


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Server:
    def __init__(self, *args, tls=None):
        self.port = free_port()
        cmd = [BIN, "--port", str(self.port), "--log-level", "warn"] + list(args)
        if tls:
            cmd += ["--tls-cert", tls[0], "--tls-key", tls[1]]
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.25).close()
                # Every worker, not just the first, before clients spread out.
                time.sleep(0.3)
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise SystemExit("server exited during start-up:\n" + self.output())
                time.sleep(0.05)
        raise SystemExit("server never came up")

    def output(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def request(self, method, path, body=b"", headers=None):
        sock = socket.create_connection(("127.0.0.1", self.port), 10)
        fields = {"Host": "localhost", "Connection": "close", "Content-Length": str(len(body))}
        fields.update(headers or {})
        head = "%s %s HTTP/1.1\r\n" % (method, path)
        head += "".join("%s: %s\r\n" % item for item in fields.items()) + "\r\n"
        sock.sendall(head.encode() + body)
        raw = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            raw += chunk
        sock.close()
        head, _, rest = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split()[1])
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        return status, headers, rest.decode(errors="replace")

    def publish(self, topic, data, event=None, blocking=False):
        headers = {"X-Event": event} if event else {}
        path = "/broadcast/%s%s" % (topic, "/blocking" if blocking else "")
        body = data if isinstance(data, bytes) else data.encode()
        return self.request("POST", path, body, headers)

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


class Stream:
    """An event stream over HTTP/1.1, parsed as it arrives."""

    def __init__(self, server, topic, last_event_id=None, keepalive=None):
        self.sock = socket.create_connection(("127.0.0.1", server.port), 10)
        path = "/broadcast/%s/events" % topic
        if keepalive is not None:
            path += "?keepalive=%d" % keepalive
        request = "GET %s HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n" % path
        if last_event_id is not None:
            request += "Last-Event-ID: %s\r\n" % last_event_id
        self.sock.sendall((request + "\r\n").encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("stream closed before its head")
            raw += chunk
        head, _, self.wire = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            self.headers[name.strip().lower()] = value.strip()
        self.pid = self.headers.get("x-worker-pid")
        self.text = b""
        self.comments = 0
        # Events that arrived with the head.
        self._dechunk()

    def _dechunk(self):
        while True:
            end = self.wire.find(b"\r\n")
            if end < 0:
                return
            size = int(self.wire[:end].split(b";")[0], 16)
            if len(self.wire) < end + 2 + size + 2:
                return
            self.text += self.wire[end + 2:end + 2 + size]
            self.wire = self.wire[end + 2 + size + 2:]

    def events(self, count, timeout=10.0):
        """The next `count` events, each a dict of its fields."""
        out = []
        deadline = time.monotonic() + timeout
        while len(out) < count:
            while b"\n\n" in self.text and len(out) < count:
                block, _, self.text = self.text.partition(b"\n\n")
                event = {}
                comment = True
                for line in block.decode().split("\n"):
                    if line.startswith(":"):
                        continue
                    comment = False
                    name, _, value = line.partition(":")
                    value = value[1:] if value.startswith(" ") else value
                    if name == "data" and "data" in event:
                        event["data"] += "\n" + value
                    else:
                        event[name] = value
                if comment:
                    self.comments += 1
                else:
                    out.append(event)
            if len(out) >= count:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            self.wire += chunk
            self._dechunk()
        return out

    def raw_until(self, needle, timeout):
        deadline = time.monotonic() + timeout
        while needle not in self.text and time.monotonic() < deadline:
            self.sock.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            self.wire += chunk
            self._dechunk()
        return needle in self.text

    def close(self):
        self.sock.close()


class WebSocketClient:
    def __init__(self, server, path):
        self.sock = socket.create_connection(("127.0.0.1", server.port), 10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n" % (path, key)).encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            raw += self.sock.recv(4096)
        head, _, self.buffer = raw.partition(b"\r\n\r\n")
        self.status = int(head.split()[1])

    def recv_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def receive(self, timeout=10.0):
        self.sock.settimeout(timeout)
        b0, b1 = self.recv_exact(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", self.recv_exact(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self.recv_exact(8))[0]
        payload = self.recv_exact(n)
        if b0 & 0x0F == 1:
            return payload.decode()
        return None

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        head = struct.pack("!BB", 0x81, 0x80 | len(payload)) + mask
        self.sock.sendall(head + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def close(self):
        try:
            mask = os.urandom(4)
            payload = struct.pack("!H", 1000)
            self.sock.sendall(struct.pack("!BB", 0x88, 0x82) + mask
                              + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        except OSError:
            pass
        self.sock.close()


def open_streams(server, topic, count):
    streams = [Stream(server, topic) for _ in range(count)]
    # Subscribed once the head has gone, which it has.
    return streams


def across_workers():
    print("across workers")
    with Server("--workers", "4") as server:
        streams = open_streams(server, "room", 16)
        pids = {s.pid for s in streams}
        check("event streams landed on more than one worker", len(pids) > 1, pids)
        check("every stream is text/event-stream",
              all(s.headers.get("content-type") == "text/event-stream" for s in streams))

        sent = []
        publishers = set()
        for i in range(30):
            status, headers, body = server.publish("room", "message %d" % i,
                                                   event="said" if i % 3 == 0 else None,
                                                   blocking=(i % 5 == 4))
            sent.append((body, "message %d" % i, "said" if i % 3 == 0 else None))
            publishers.add(headers.get("x-worker-pid"))
        check("messages were published through more than one worker", len(publishers) > 1, publishers)
        ids = [int(s[0]) for s in sent]
        is_("numbers rise by one per message", ids, list(range(ids[0], ids[0] + 30)))

        everyone = True
        detail = ""
        for stream in streams:
            events = stream.events(30)
            got = [(e.get("id"), e.get("data"), e.get("event")) for e in events]
            if got != sent:
                everyone = False
                detail = "stream on %s: %r" % (stream.pid, got[:5])
        check("every stream, on every worker, got all 30 in order", everyone, detail)

        resumed = Stream(server, "room", last_event_id=sent[9][0])
        events = resumed.events(20)
        is_("Last-Event-ID is sent what came after it",
            [(e.get("id"), e.get("data")) for e in events], [(s[0], s[1]) for s in sent[10:]])
        server.publish("room", "live after replay")
        events = resumed.events(1)
        is_("and then what is published live", [e.get("data") for e in events], ["live after replay"])
        resumed.close()

        # Several reconnects, so that some land on a worker other than the one
        # the missed messages were first delivered through.
        replayed_on = set()
        wrong = []
        for _ in range(8):
            again = Stream(server, "room", last_event_id=sent[27][0])
            replayed_on.add(again.pid)
            got = [e.get("data") for e in again.events(2)]
            if got != ["message 28", "message 29"]:
                wrong.append((again.pid, got))
            again.close()
        check("a reconnect is sent what it missed on whichever worker it reaches",
              not wrong and len(replayed_on) > 1, (replayed_on, wrong))

        old = Stream(server, "room", last_event_id="1")
        first = old.events(1)
        is_("an ID older than the ring is a gap, sent as a missed event",
            [(e.get("event"), e.get("data")) for e in first], [("missed", "missed")])
        old.close()

        status, _, body = server.request("GET", "/broadcast/room/poll?timeout=100")
        is_("a long poll with nothing published times out empty", status, 204)
        status, _, body = server.request("GET", "/broadcast/room/poll?after=%s" % sent[28][0])
        is_("a long poll after a number is answered from the ring", body, "%s - message 29" % sent[29][0])

        for stream in streams:
            stream.close()
        time.sleep(0.2)
        for i in range(5):
            server.publish("room", "to nobody %d" % i)
        fresh = Stream(server, "room")
        server.publish("room", "still working")
        is_("streams that went away leave the topic working",
            [e.get("data") for e in fresh.events(1)], ["still working"])
        fresh.close()
        check("the server is still running", server.proc.poll() is None)
        log = server.output()
        check("and logged nothing untoward", "error" not in log.lower() and "fatal" not in log.lower(), log[-2000:])


def websockets():
    print("websockets")
    with Server("--workers", "4") as server:
        clients = [WebSocketClient(server, "/broadcast/chat/ws") for _ in range(12)]
        check("every upgrade was accepted", all(c.status == 101 for c in clients))
        pids = {c.receive() for c in clients}
        check("WebSockets landed on more than one worker", len(pids) > 1, pids)
        stream = Stream(server, "chat")

        clients[0].send("hello from a socket")
        lines = [c.receive() for c in clients]
        ids = {line.split(" ", 1)[0] for line in lines}
        rest = {line.split(" ", 1)[1] for line in lines}
        check("every WebSocket heard it, with one number", len(ids) == 1, lines)
        is_("as the ws event", rest, {"ws hello from a socket"})
        events = stream.events(1)
        is_("and so did the event stream",
            [(e.get("event"), e.get("data")) for e in events], [("ws", "hello from a socket")])

        server.publish("chat", "from a request", event="said")
        lines = {c.receive().split(" ", 1)[1] for c in clients}
        is_("a request's message reaches every WebSocket", lines, {"said from a request"})

        for c in clients[:6]:
            c.close()
        time.sleep(0.2)
        server.publish("chat", "after some left", event="said")
        lines = {c.receive().split(" ", 1)[1] for c in clients[6:]}
        is_("the rest still hear after some close", lines, {"said after some left"})
        for c in clients[6:]:
            c.close()
        stream.close()
        check("the server is still running", server.proc.poll() is None)


def keep_alive():
    print("keep-alive")
    with Server("--workers", "2") as server:
        stream = Stream(server, "quiet", keepalive=1)
        check("a quiet stream is sent a comment", stream.raw_until(b":\n\n", 3.0), stream.text)
        stream.close()

        stream = Stream(server, "quiet", keepalive=0)
        stream.raw_until(b":\n\n", 2.5)
        is_("keepalive=0 sends none", stream.text, b"")
        server.publish("quiet", "x")
        is_("and still delivers", [e.get("data") for e in stream.events(1)], ["x"])
        stream.close()

    with Server("--workers", "1", "--sse-keep-alive", "1") as server:
        stream = Stream(server, "quiet")
        check("--sse-keep-alive sets the default", stream.raw_until(b":\n\n", 3.0), stream.text)
        stream.close()


def http2():
    if shutil.which("curl") is None or shutil.which("openssl") is None:
        print("http/2: skipped, no curl or openssl")
        return
    features = subprocess.run(["curl", "--version"], capture_output=True, text=True).stdout
    if "HTTP2" not in features:
        print("http/2: skipped, curl has no HTTP/2")
        return
    print("http/2")
    directory = tempfile.mkdtemp(prefix="garuda-broadcast-")
    cert = os.path.join(directory, "cert.pem")
    key = os.path.join(directory, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
                    "-days", "2", "-nodes", "-subj", "/CN=localhost"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with Server("--workers", "2", tls=(cert, key)) as server:
        curl = subprocess.Popen(["curl", "-sk", "--http2", "-N", "--max-time", "3",
                                 "https://127.0.0.1:%d/broadcast/h2/events?keepalive=1" % server.port],
                                stdout=subprocess.PIPE)
        time.sleep(0.5)
        sock = socket.create_connection(("127.0.0.1", server.port), 10)
        sock.close()
        out = subprocess.run(["curl", "-sk", "--http2", "-X", "POST", "--data-binary", "over h2",
                              "https://127.0.0.1:%d/broadcast/h2" % server.port],
                             capture_output=True, text=True).stdout
        output, _ = curl.communicate(timeout=10)
        text = output.decode()
        check("over HTTP/2 the stream is forwarded", "data: over h2\n\n" in text, text)
        check("and sent a keep-alive comment", ":\n\n" in text, text)
        check("the published number is its id", ("id: %s\n" % out) in text, (out, text))


def limits():
    print("limits")
    with Server("--broadcast-size", "0") as server:
        status, _, _ = server.publish("off", "x")
        is_("with --broadcast-size 0 publishing is 503", status, 503)
        stream_status, _, _ = server.request("GET", "/broadcast/off/poll?timeout=10")
        is_("and so is subscribing", stream_status, 503)

    with Server("--broadcast-size", "1", "--max-body", "4194304") as server:
        status, _, body = server.publish("big", b"x" * 300_000)
        is_("a message larger than a quarter of the ring is 413", status, 413)

    with Server("--workers", "2", "--broadcast-size", "64", "--broadcast-queue", "4",
                "--max-body", "4194304") as server:
        # Not read while 12 MiB is published: the socket and the write buffer
        # fill, the handler waits to write, and its queue of four overflows.
        slow = Stream(server, "flood")
        payload = b"y" * 200_000
        for i in range(60):
            server.publish("flood", payload)
        delivered = 0
        missed = False
        while True:
            events = slow.events(1, timeout=5)
            if not events:
                break
            if events[0].get("event") == "missed":
                missed = True
                break
            delivered += 1
        check("a stream that stopped reading is told it missed some", missed and delivered < 60, delivered)
        # What was queued once there was room again comes first.
        server.publish("flood", "after catching up")
        arrived = False
        for _ in range(64):
            events = slow.events(1)
            if not events:
                break
            if events[0].get("data") == "after catching up":
                arrived = True
                break
        check("and gets what is published once it has caught up", arrived)
        slow.close()
        check("the server is still running", server.proc.poll() is None)


def main():
    if not os.path.exists(BIN):
        raise SystemExit("no binary at %s; swift build -c release first" % BIN)
    across_workers()
    websockets()
    keep_alive()
    http2()
    limits()
    print("\n%d passed, %d failed" % (PASS, FAIL))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

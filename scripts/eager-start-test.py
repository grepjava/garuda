#!/usr/bin/env python3
"""A request whose application never waits finishes inside the call that starts it.

    python3 scripts/eager-start-test.py [server]

The server is the first argument, else $PEREGRINE, else
~/pgbuild/release/peregrine; pass scripts/peregrine-ext for the extension
module. PEREGRINE_EXTRA_ARGS adds flags, PORT moves it off 8262. The HTTP/2
cases need the h2 package and are skipped without it.

From Python 3.12 an ASGI request's task is started eagerly, so an application
that never truly suspends runs to its end, and is reported finished, before
dispatch returns. That moves the end of a request inside dispatch: a response
already written, a failed request or a closed connection can all happen there.
Each case uses scripts/eager_start_apps.py and checks the bytes on the wire:
keep-alive and pipelined requests, pipelined responses large enough to be
written before the application returns, applications that wait, fail, or read
a body, HTTP/2 streams, and a task factory, which turns eager start off.
"""

import os
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "PEREGRINE", os.path.expanduser("~/pgbuild/release/peregrine"))
PORT = int(os.environ.get("PORT", "8262"))
EXTRA = shlex.split(os.environ.get("PEREGRINE_EXTRA_ARGS", ""))
WORK = tempfile.mkdtemp(prefix="eager-start-")
BIG = 200_000
MID = 64 * 1024

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name}{': ' + detail if detail else ''}")


class Conn:
    """One keep-alive connection, read a response at a time."""

    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        self.buf = b""

    @staticmethod
    def encode(method, target, body=b""):
        head = f"{method} {target} HTTP/1.1\r\nHost: localhost\r\n"
        if body:
            head += f"Content-Length: {len(body)}\r\n"
        return head.encode() + b"\r\n" + body

    def request(self, method, target, body=b""):
        self.sock.sendall(self.encode(method, target, body))

    def _fill(self):
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise EOFError(f"connection closed with {len(self.buf)} bytes unread")
        self.buf += chunk

    def head(self, timeout=5.0):
        self.sock.settimeout(timeout)
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(b":")
            headers[name.strip().lower()] = value.strip()
        return int(lines[0].split()[1]), headers

    def response(self, timeout=5.0):
        status, headers = self.head(timeout)
        length = int(headers.get(b"content-length", b"0"))
        while len(self.buf) < length:
            self._fill()
        body, self.buf = self.buf[:length], self.buf[length:]
        return status, body

    def closed(self, wait=2.0):
        """True once the server closes, keeping whatever it sent first."""
        self.sock.settimeout(wait)
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return True
                self.buf += chunk
        except (socket.timeout, TimeoutError):
            return False
        except ConnectionResetError:
            return True

    def close(self):
        self.sock.close()


def server_output():
    try:
        with open(os.path.join(WORK, "server.log")) as f:
            return f.read()
    except FileNotFoundError:
        return ""


def wait_for_log(text, since, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and text not in server_output()[since:]:
        time.sleep(0.05)
    return server_output()[since:]


def attempt(name, fn):
    try:
        fn()
    except Exception as exc:
        check(name, False, f"{type(exc).__name__}: {exc}")


def case_how():
    print("How a request is started")
    c = Conn()
    c.request("GET", "/how")
    _, body = c.response()
    # Eager start needs Python 3.12 or later in the server.
    check("an application that never waits starts eagerly, with a current task",
          body == b"eager task=True", repr(body))
    c.request("GET", "/set-factory")
    c.response()
    c.request("GET", "/how")
    _, body = c.response()
    check("with a task factory installed it is scheduled, through the factory",
          body == b"scheduled task=True", repr(body))
    c.request("GET", "/clear-factory")
    c.response()
    c.request("GET", "/how")
    _, body = c.response()
    check("and eager again once the factory is removed",
          body == b"eager task=True", repr(body))
    c.close()


def case_keep_alive():
    print("Keep-alive requests that finish inside dispatch")
    c = Conn()
    good = 0
    for i in range(300):
        c.request("GET", f"/n/{i}")
        if c.response() == (200, str(i).encode()):
            good += 1
    check("300 requests in turn on one connection are each answered with their own",
          good == 300, f"{good}/300")
    c.close()


def case_pipelined():
    print("Pipelined requests")
    c = Conn()
    n = 1500
    c.sock.sendall(b"".join(Conn.encode("GET", f"/n/{i}") for i in range(n)))
    got = [c.response() for _ in range(n)]
    wrong = [i for i, r in enumerate(got) if r != (200, str(i).encode())]
    check(f"{n} pipelined requests are answered in order", not wrong, f"first wrong {wrong[:3]}")
    c.request("GET", "/n/after")
    check("the connection still serves the next request", c.response() == (200, b"after"))
    c.close()

    c = Conn()
    n = 60
    c.sock.sendall(b"".join(Conn.encode("GET", f"/big/{i}") for i in range(n)))
    wrong = []
    for i in range(n):
        status, body = c.response(timeout=10)
        tag = str(i).encode()
        if status != 200 or len(body) != BIG or not body.startswith(tag + b"."):
            wrong.append(i)
    check(f"{n} pipelined 200 KiB responses, written before each application returned,"
          " arrive whole and in order", not wrong, f"first wrong {wrong[:3]}")
    c.close()

    c = Conn()
    paths = [f"/sleep/{i}" if i % 3 == 0 else f"/n/{i}" for i in range(300)]
    c.sock.sendall(b"".join(Conn.encode("GET", p) for p in paths))
    got = [c.response() for _ in paths]
    wrong = [i for i, r in enumerate(got) if r != (200, str(i).encode())]
    check("pipelined requests that wait, mixed with ones that do not, stay in order",
          not wrong, f"first wrong {wrong[:3]}")
    c.close()


def case_deep_pipeline():
    # Each response is 64 KiB, larger than the write buffer holds back, so it
    # is written while its application runs, and the connection is recycled
    # for the next request only when the application returns. A design that
    # dispatched that next request from inside the one before would nest as
    # deep as the pipeline is long, and 20,000 levels do not survive: the
    # interpreter's recursion limit or the stack gives out long before.
    print("A pipeline far longer than nesting could survive")
    n = 20_000
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=30)
    payload = b"".join(Conn.encode("GET", f"/mid/{i}") for i in range(n))
    sender = threading.Thread(target=sock.sendall, args=(payload,), daemon=True)
    sender.start()
    buf = bytearray()
    pos = 0
    answered = 0
    wrong = []
    try:
        while answered < n:
            end = buf.find(b"\r\n\r\n", pos)
            if end >= 0:
                head = bytes(buf[pos:end]).split(b"\r\n")
                length = 0
                for line in head[1:]:
                    name, _, value = line.partition(b":")
                    if name.strip().lower() == b"content-length":
                        length = int(value)
                if len(buf) >= end + 4 + length:
                    status = int(head[0].split()[1])
                    tag = f"{answered}.".encode()
                    if status != 200 or length != MID or buf[end + 4:end + 4 + len(tag)] != tag:
                        wrong.append(answered)
                        if len(wrong) > 3:
                            break
                    pos = end + 4 + length
                    answered += 1
                    if pos > (1 << 22):
                        del buf[:pos]
                        pos = 0
                    continue
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    finally:
        sock.close()
        sender.join(timeout=5)
    check(f"{n} pipelined 64 KiB responses arrive whole and in order",
          answered == n and not wrong, f"answered {answered}, first wrong {wrong[:3]}")


def case_waits():
    print("An application that waits")
    c = Conn()
    for i in range(50):
        c.request("GET", f"/sleep/{i}")
        if c.response() != (200, str(i).encode()):
            check("requests that wait once are answered", False, f"request {i}")
            break
    else:
        check("50 requests that wait once are answered on one connection", True)
    c.close()


def case_body():
    print("A request with a body")
    c = Conn()
    body = b"x" * 4000
    c.request("POST", "/echo", body)
    check("a body already here is read without waiting",
          c.response() == (200, body))
    head = f"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n\r\n"
    c.sock.sendall(head.encode() + body[:1000])
    time.sleep(0.3)
    c.sock.sendall(body[1000:])
    check("a body that arrives after the application started is waited for",
          c.response() == (200, body))
    c.request("GET", "/n/next")
    check("the connection serves the next request", c.response() == (200, b"next"))
    c.close()


def case_failures():
    print("An application that fails")
    since = len(server_output())
    c = Conn()
    c.request("GET", "/raise")
    status, _ = c.response()
    check("failing before answering gives a 500", status == 500, str(status))
    c.close()
    text = wait_for_log("deliberate failure before the response", since)
    check("the failure is logged with its traceback",
          "application task failed" in text
          and "ValueError: deliberate failure before the response" in text, repr(text[-300:]))

    since = len(server_output())
    c = Conn()
    c.request("GET", "/raise-mid")
    # The head is still in the write buffer when the failure is reported, and
    # a response that cannot be completed is not sent at all.
    closed = c.closed()
    check("failing after the response started closes the connection, with no response",
          closed and b"\r\n\r\n" not in c.buf, repr(c.buf[:80]))
    c.close()
    text = wait_for_log("deliberate failure mid-response", since)
    check("that failure is logged too", "ValueError: deliberate failure mid-response" in text,
          repr(text[-300:]))

    c = Conn()
    c.request("GET", "/n/fine")
    check("a new connection is served afterwards", c.response() == (200, b"fine"))
    c.close()


def case_http2():
    print("HTTP/2 streams")
    try:
        import h2.config
        import h2.connection
        import h2.events
    except ImportError:
        print("  skip (no h2 package)")
        return
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
    conn.initiate_connection()
    paths = [f"/n/{i}" for i in range(40)] + [f"/sleep/{i}" for i in range(40, 60)]
    paths += ["/big/60", "/raise"]
    streams = {}
    for p in paths:
        sid = conn.get_next_available_stream_id()
        conn.send_headers(sid, [(":method", "GET"), (":path", p), (":scheme", "http"),
                                (":authority", "localhost")], end_stream=True)
        streams[sid] = [p, None, b"", False]
    sock.sendall(conn.data_to_send())
    deadline = time.monotonic() + 10
    while not all(s[3] for s in streams.values()) and time.monotonic() < deadline:
        data = sock.recv(1 << 20)
        if not data:
            break
        for ev in conn.receive_data(data):
            if isinstance(ev, h2.events.ResponseReceived):
                streams[ev.stream_id][1] = dict(ev.headers).get(b":status")
            elif isinstance(ev, h2.events.DataReceived):
                streams[ev.stream_id][2] += ev.data
                conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, (h2.events.StreamEnded, h2.events.StreamReset)):
                streams[ev.stream_id][3] = True
        sock.sendall(conn.data_to_send())
    sock.close()
    wrong = []
    for path, status, body, ended in streams.values():
        if path == "/raise":
            ok = ended and status == b"500"
        elif path.startswith("/big/"):
            ok = ended and status == b"200" and len(body) == BIG and body.startswith(b"60.")
        else:
            ok = ended and status == b"200" and body == path.rsplit("/", 1)[1].encode()
        if not ok:
            wrong.append((path, status, len(body), ended))
    check(f"{len(paths)} concurrent streams, eager, waiting, large and failing, each end correctly",
          not wrong, repr(wrong[:3]))


def main():
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close()
        print(f"port {PORT} is already in use; stop whatever is on it and run this again")
        return 1
    except OSError:
        pass

    server_log = open(os.path.join(WORK, "server.log"), "w")
    server = subprocess.Popen(
        [BIN, "--port", str(PORT), "--workers", "1", "--log-level", "info", *EXTRA,
         "--python-path", HERE, "eager_start_apps:app"],
        stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        for _ in range(100):
            try:
                c = Conn()
                c.request("GET", "/")
                c.response()
                c.close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            print("the server did not start:")
            print(server_output()[-2000:])
            return 1

        for name, fn in (("how", case_how), ("keep-alive", case_keep_alive),
                         ("pipelined", case_pipelined),
                         ("deep pipeline", case_deep_pipeline), ("waits", case_waits),
                         ("body", case_body), ("failures", case_failures),
                         ("http2", case_http2)):
            attempt(name, fn)
        check("the server is still running", server.poll() is None)
    finally:
        try:
            os.killpg(server.pid, signal.SIGTERM)
            server.wait(timeout=10)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(server.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        server_log.close()

    print(f"\neager start: {passed} passed, {failed} failed")
    if failed:
        print(f"server log: {os.path.join(WORK, 'server.log')}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

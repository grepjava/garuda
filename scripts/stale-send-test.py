#!/usr/bin/env python3
"""A `send` or `receive` that outlives its request must not reach the next one.

    python3 scripts/stale-send-test.py [server]

The server is the first argument, else $GARUDA, else
~/pgbuild/release/garuda; pass scripts/garuda-ext for the extension
module. GARUDA_EXTRA_ARGS adds flags, PORT moves it off 8261.

An ASGI application can keep its channels past the end of a request: a task it
started still holding `send`, a background job that calls `receive` late.
Every other ASGI server ignores those calls once the request is over. The
channels here used to name the connection, not the request, so on a
keep-alive connection a late `send` could write into the response of the
request after it, and a late `receive` take that request's body.

Each case uses scripts/stale_send_apps.py: /leak starts a task that calls its
channels after a delay, and the case puts the next request, an idle
connection or a closed one in that window. The bytes on the wire are checked,
and so is what the late calls were told, which is what uvicorn tells them:
while the connection is open a late `send` raises RuntimeError, the response
it belonged to being complete, whether or not another request has started;
once the connection has closed it returns quietly; and a late `receive` says
http.disconnect.
"""

import os
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "GARUDA", os.path.expanduser("~/pgbuild/release/garuda"))
PORT = int(os.environ.get("PORT", "8261"))
EXTRA = shlex.split(os.environ.get("GARUDA_EXTRA_ARGS", ""))
WORK = tempfile.mkdtemp(prefix="stale-send-")
LOG = os.path.join(WORK, "calls.log")

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
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=3)
        self.buf = b""

    def request(self, method, target, body=b"", close=False):
        head = f"{method} {target} HTTP/1.1\r\nHost: localhost\r\n"
        if body:
            head += f"Content-Length: {len(body)}\r\n"
        if close:
            head += "Connection: close\r\n"
        self.sock.sendall(head.encode() + b"\r\n" + body)

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError(f"connection closed with {self.buf!r} unread")
        self.buf += chunk

    def response(self, timeout=3.0):
        self.sock.settimeout(timeout)
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split()[1])
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(b":")
            headers[name.strip().lower()] = value.strip()
        length = int(headers.get(b"content-length", b"0"))
        while len(self.buf) < length:
            self._fill()
        body, self.buf = self.buf[:length], self.buf[length:]
        return status, body

    def stray(self, wait):
        """Bytes that arrive with no request outstanding, over `wait` seconds."""
        self.sock.settimeout(wait)
        deadline = time.monotonic() + wait
        try:
            while time.monotonic() < deadline:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return self.buf + b"<closed>"
                self.buf += chunk
        except (socket.timeout, TimeoutError):
            pass
        return self.buf

    def close(self):
        self.sock.close()


def calls():
    try:
        with open(LOG) as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        return []


def reset_log():
    open(LOG, "w").close()


def wait_for_calls(n, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and len(calls()) < n:
        time.sleep(0.05)
    return calls()


def attempt(name, fn):
    try:
        fn()
    except Exception as exc:
        check(name, False, f"{type(exc).__name__}: {exc}")


def case_next_request():
    print("A late send and receive while the next request on the connection waits")
    reset_log()
    c = Conn()
    c.request("GET", "/leak?delay=0.2")
    check("the leaking request is answered", c.response() == (200, b"leaked"))
    # The late calls land 0.2 s in, while /echo is still asleep with its body
    # buffered and its response not started.
    c.request("POST", "/echo?delay=0.6", body=b"the-real-body")
    got = c.response()
    check("the next response is its own", got == (200, b"the-real-body"), repr(got))
    extra = c.stray(0.3)
    check("nothing follows it on the connection", extra == b"", repr(extra[:200]))
    c.close()
    seen = wait_for_calls(2)
    check("the late send raised RuntimeError", "send raised RuntimeError" in seen, repr(seen))
    check("the late receive was told http.disconnect",
          "receive http.disconnect 0" in seen, repr(seen))


def case_idle():
    print("A late send on an idle keep-alive connection")
    reset_log()
    c = Conn()
    c.request("GET", "/leak?delay=0.2")
    check("the leaking request is answered", c.response() == (200, b"leaked"))
    extra = c.stray(0.8)
    check("no bytes arrive while the connection is idle", extra == b"", repr(extra[:200]))
    c.request("GET", "/")
    got = c.response()
    check("the connection still serves the next request", got == (200, b"ok"), repr(got))
    c.close()
    seen = wait_for_calls(2)
    check("the late send raised RuntimeError", "send raised RuntimeError" in seen, repr(seen))
    check("the late receive was told http.disconnect",
          "receive http.disconnect 0" in seen, repr(seen))


def case_closed():
    print("A late send after the connection closed, with a new connection in its place")
    reset_log()
    a = Conn()
    a.request("GET", "/leak?delay=0.3", close=True)
    check("the leaking request is answered", a.response() == (200, b"leaked"))
    a.close()
    b = Conn()
    b.request("POST", "/echo?delay=0.6", body=b"second-connection")
    got = b.response()
    check("the new connection's response is its own",
          got == (200, b"second-connection"), repr(got))
    b.close()
    seen = wait_for_calls(2)
    check("the late send returned quietly", "send returned" in seen, repr(seen))
    check("the late receive was told http.disconnect",
          "receive http.disconnect 0" in seen, repr(seen))


def case_probe():
    print("What await send() hands back")
    reset_log()
    c = Conn()
    c.request("GET", "/probe")
    check("the probe is answered", c.response() == (200, b"ok"))
    c.close()
    seen = wait_for_calls(1)
    check("send's awaitable gives None, and next() on it raises StopIteration(None)",
          "probe start=None next=StopIteration(None)" in seen, repr(seen))


def server_output():
    try:
        with open(os.path.join(WORK, "server.log")) as f:
            return f.read()
    except FileNotFoundError:
        return ""


def case_task_outcome():
    # The same end of a request's task, from the other side: what the server
    # makes of how it finished.
    print("How a finished application task is reported")
    reset_log()
    before = len(server_output())
    c = Conn()
    c.request("GET", "/raise")
    status, _ = c.response()
    check("an application that raises gets a 500", status == 500, str(status))
    c.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and "deliberate failure" not in server_output()[before:]:
        time.sleep(0.05)
    text = server_output()[before:]
    check("its failure is logged", "application task failed" in text, repr(text[-400:]))
    check("with its traceback",
          "ValueError: deliberate failure in the application" in text, repr(text[-400:]))


def main():
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close()
        print(f"port {PORT} is already in use; stop whatever is on it and run this again")
        return 1
    except OSError:
        pass

    env = dict(os.environ, STALE_LOG=LOG)
    server_log = open(os.path.join(WORK, "server.log"), "w")
    server = subprocess.Popen(
        [BIN, "--port", str(PORT), "--workers", "1", "--log-level", "info", *EXTRA,
         "--python-path", HERE, "stale_send_apps:app"],
        stdout=server_log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
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
            print(open(os.path.join(WORK, "server.log")).read()[-2000:])
            return 1

        for name, fn in (("next request", case_next_request), ("idle", case_idle),
                         ("closed", case_closed), ("probe", case_probe),
                         ("task outcome", case_task_outcome)):
            attempt(name, fn)
        alive = server.poll() is None
        check("the server is still running", alive)
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

    print(f"\nstale send: {passed} passed, {failed} failed")
    if failed:
        print(f"server log: {os.path.join(WORK, 'server.log')}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

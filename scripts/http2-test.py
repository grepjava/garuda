#!/usr/bin/env python3
"""HTTP/2 checks against an independent implementation.

    <venv>/bin/python scripts/http2-test.py [path-to-peregrine]

The server's own framing and HPACK are tested by unit tests and by h2spec;
what this adds is interop with a stack written by someone else (the `h2`
library) and the behaviour a conformance suite has no opinion about --
multiplexing that actually overlaps, flow control on a real body, an
application that answers before the upload finishes, and cancellation.

Needs `h2` in the interpreter running it:  pip install h2
"""

import os
import socket
import ssl
import shlex
import subprocess
import sys
import tempfile
import time

try:
    import h2.config
    import h2.connection
    import h2.errors
    import h2.events
    import h2.exceptions
except ImportError:
    sys.stderr.write("this script needs the h2 package: pip install h2\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/release/peregrine")

# Extra server flags, so the same suite can be pointed at a different
# execution model:  PEREGRINE_EXTRA_ARGS="--workers 4 --free-threaded"
EXTRA = shlex.split(os.environ.get("PEREGRINE_EXTRA_ARGS", ""))

# Set for the second pass, which runs everything again over TLS so that ALPN,
# record boundaries and partial writes are exercised by the same checks.
USE_TLS = False
CERTS = None


def make_certs():
    """A throwaway self-signed certificate, or None if openssl is missing."""
    global CERTS
    if CERTS is not None:
        return CERTS
    directory = tempfile.mkdtemp(prefix="peregrine-h2-tls-")
    cert = os.path.join(directory, "cert.pem")
    key = os.path.join(directory, "key.pem")
    try:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                        "-keyout", key, "-out", cert, "-days", "2", "-nodes",
                        "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        CERTS = (None, None)
        return CERTS
    CERTS = (cert, key)
    return CERTS

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
    print("  FAIL %s\n     expected: %s\n     actual:   %s" % (name, expected, actual))
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
    def __init__(self, *args, app="asgi_app:app"):
        self.port = free_port()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error",
               "--python-path", os.path.join(ROOT, "examples")] + EXTRA + list(args)
        if USE_TLS:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
        cmd += [app]
        self.proc = subprocess.Popen(cmd)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.25).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise SystemExit("server exited during start-up")
                time.sleep(0.05)
        raise SystemExit("server never came up")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(5)


class Client:
    """A thin wrapper over the h2 state machine and one socket."""

    def __init__(self, server, timeout=15.0, window=None):
        self.sock = socket.create_connection(("127.0.0.1", server.port), timeout)
        self.sock.settimeout(timeout)
        if USE_TLS:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.set_alpn_protocols(["h2"])
            self.sock = context.wrap_socket(self.sock, server_hostname="localhost")
            if self.sock.selected_alpn_protocol() != "h2":
                raise SystemExit("ALPN did not settle on h2")
        self.conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True))
        self.conn.initiate_connection()
        if window is not None:
            self.conn.update_settings(
                {h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: window})
        self.flush()
        self.port = server.port
        # Per-stream state accumulated across every pump, so a response that
        # arrives while another stream is being waited on is not lost.
        self.status = {}
        self.headers = {}
        self.body = {}
        self.ended = set()
        self.reset = {}
        self.events = []

    def flush(self):
        data = self.conn.data_to_send()
        if data:
            self.sock.sendall(data)

    def request(self, method="GET", path="/", extra=None, body=None, end=True):
        headers = [(":method", method), (":scheme", "http"),
                   (":authority", "127.0.0.1:%d" % self.port), (":path", path)]
        if body is not None:
            headers.append(("content-length", str(len(body))))
        headers.extend(extra or [])
        stream = self.conn.get_next_available_stream_id()
        self.conn.send_headers(stream, headers, end_stream=(body is None and end))
        self.flush()
        if body is not None:
            self.send_body(stream, body, end=end)
        return stream

    def send_body(self, stream, body, end=True):
        """Sends a body of any size, waiting for window when it runs out."""
        sent = 0
        deadline = time.monotonic() + 30
        while sent < len(body):
            window = min(self.conn.local_flow_control_window(stream),
                         self.conn.max_outbound_frame_size)
            if window <= 0:
                if time.monotonic() > deadline:
                    raise RuntimeError("no window for the request body")
                self.step()
                continue
            chunk = body[sent:sent + window]
            sent += len(chunk)
            self.conn.send_data(stream, chunk, end_stream=(end and sent == len(body)))
            self.flush()
        if end and not body:
            self.conn.end_stream(stream)
            self.flush()

    def step(self, timeout=1.0):
        """Reads whatever is available and folds it into the per-stream state."""
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not data:
            return False
        for event in self.conn.receive_data(data):
            self.events.append(event)
            if isinstance(event, h2.events.ResponseReceived):
                fields = dict(event.headers)
                self.headers[event.stream_id] = fields
                self.status[event.stream_id] = int(fields[b":status"])
            elif isinstance(event, h2.events.DataReceived):
                self.body[event.stream_id] = (self.body.get(event.stream_id, b"")
                                              + event.data)
                self.conn.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                self.ended.add(event.stream_id)
            elif isinstance(event, h2.events.StreamReset):
                self.ended.add(event.stream_id)
                self.reset[event.stream_id] = event.error_code
        self.flush()
        return True

    def collect(self, streams, deadline=25.0):
        """Runs until every stream in `streams` has ended, or time runs out."""
        wanted = set(streams)
        limit = time.monotonic() + deadline
        while not wanted <= self.ended and time.monotonic() < limit:
            if not self.step():
                break
        return self.status, self.headers, self.body, self.events

    def close(self):
        try:
            self.conn.close_connection()
            self.flush()
        except Exception:
            pass
        self.sock.close()


def test_basics():
    print("\nRequests and responses")
    with Server() as server:
        c = Client(server)
        s1 = c.request(path="/")
        status, headers, body, _ = c.collect([s1])
        is_("a GET is answered", status.get(s1), 200)
        is_("the body arrives intact", body.get(s1), b"hello from peregrine asgi\n")
        is_("headers are lowercase on the wire",
            headers[s1].get(b"content-type"), b"text/plain")
        check("no connection-specific headers are sent",
              not any(k in headers[s1] for k in (b"connection", b"transfer-encoding",
                                                 b"keep-alive")),
              str(sorted(headers[s1])))

        s2 = c.request(path="/scope")
        status, _, body, _ = c.collect([s2])
        scope = body[s2].decode()
        check("the scope reports HTTP/2", '"http_version": "2"' in scope, scope[:200])
        check("the path survives HPACK", '"path": "/scope"' in scope, scope[:200])
        check("the authority becomes the host header",
              '"host": "127.0.0.1:%d"' % server.port in scope, scope[:300])

        s3 = c.request(method="HEAD", path="/")
        status, headers, body, _ = c.collect([s3])
        is_("HEAD is answered", status.get(s3), 200)
        is_("HEAD is answered without a body", body.get(s3, b""), b"")
        c.close()


def test_multiplexing():
    print("\nMultiplexing")
    with Server() as server:
        c = Client(server)
        # Each of these sleeps 250ms in the application. Run sequentially they
        # would take two and a half seconds.
        began = time.monotonic()
        streams = [c.request(path="/sleep") for _ in range(10)]
        status, _, body, _ = c.collect(streams)
        elapsed = time.monotonic() - began
        is_("every stream is answered", len(status), 10)
        check("all ten succeeded", all(v == 200 for v in status.values()), str(status))
        check("they ran concurrently (%.2fs for 10 x 250ms)" % elapsed, elapsed < 1.5,
              "%.2fs, which is close to sequential" % elapsed)
        c.close()


def test_request_bodies():
    print("\nRequest bodies")
    with Server() as server:
        c = Client(server)
        payload = bytes(range(256)) * 400          # 100 KiB, larger than one frame
        s = c.request(method="POST", path="/echo", body=payload)
        status, _, body, _ = c.collect([s])
        is_("a body larger than a frame round trips", body.get(s), payload)

        # An application that answers on the head alone must not have to wait
        # for the upload, exactly as in HTTP/1.
        stream = c.request(method="POST", path="/reject", body=b"x" * 100, end=False)
        status, _, body, _ = c.collect([stream], deadline=10.0)
        is_("an early rejection does not wait for the body", status.get(stream), 403)
        c.close()


def test_flow_control():
    print("\nFlow control")
    with Server() as server:
        # A deliberately small window, so the response cannot be sent in one go
        # and the server has to wait for WINDOW_UPDATE frames.
        c = Client(server, window=16384)
        s = c.request(path="/big?400000")
        status, _, body, _ = c.collect([s], deadline=30.0)
        is_("a response far larger than the window arrives whole",
            len(body.get(s, b"")), 400000)

        # And the other direction: the server's own window has to be refreshed
        # as the application reads, or an upload stalls at the initial window.
        payload = b"z" * (1024 * 1024)
        s2 = c.request(method="POST", path="/echo", body=payload)
        status, _, body, _ = c.collect([s2], deadline=30.0)
        is_("an upload larger than the initial window completes",
            len(body.get(s2, b"")), len(payload))
        c.close()


def test_cancellation():
    print("\nCancellation")
    with Server() as server:
        c = Client(server)
        s = c.request(path="/slow?10")
        time.sleep(0.3)
        c.conn.reset_stream(s, error_code=8)        # CANCEL
        c.flush()
        time.sleep(0.5)
        # The connection stays usable, and the cancelled request never answers.
        s2 = c.request(path="/")
        status, _, body, _ = c.collect([s2], deadline=10.0)
        is_("the connection survives a reset stream", status.get(s2), 200)
        is_("the cancelled stream is not answered", status.get(s), None)
        is_("the cancelled request produced no body", body.get(s), None)

        # RST_STREAM is the one disconnect that is not ambiguous: unlike a FIN
        # on a socket, which may only mean the peer has finished talking, it
        # says this request is over. /abandonable never calls receive(), so the
        # http.disconnect message ASGI would deliver has nobody waiting for it
        # and cancellation is the only thing that can still reach the task.
        abandoned = c.request(path="/abandonable")
        time.sleep(0.3)
        c.conn.reset_stream(abandoned, error_code=8)
        c.flush()
        time.sleep(0.5)
        s3 = c.request(path="/cancelled")
        status, _, body, _ = c.collect([s3], deadline=10.0)
        is_("a reset stream cancels the task nobody is left to talk to",
            body.get(s3, b"").strip(), b"yes")
        c.close()


def test_rapid_reset():
    """CVE-2023-44487.

    A reset frees the stream slot immediately, so the concurrency limit alone
    never sees a peer that opens a stream and cancels it in the same breath --
    while the server still decodes a header block, builds a request and starts
    an application task for every one. What bounds it here is the ratio of
    cancelled streams to answered ones, so the first half of this checks that
    an ordinary client, which cancels among requests it completes, is left
    alone.
    """
    print("\nRapid reset")
    with Server() as server:
        c = Client(server)
        for _ in range(40):
            done = c.request(path="/")
            c.collect([done], deadline=10.0)
            cancelled = c.request(path="/")
            c.conn.reset_stream(cancelled, error_code=8)
            c.flush()
        s = c.request(path="/")
        status, _, _, _ = c.collect([s], deadline=10.0)
        is_("cancelling alongside completed requests is not penalised",
            status.get(s), 200)
        c.close()

        # Now the same thing with nothing ever completed.
        c = Client(server)
        terminated = None
        try:
            for _ in range(12):
                # One write carrying many HEADERS/RST_STREAM pairs, which is
                # the shape of the attack: every stream is cancelled before
                # the server has had a chance to answer any of them, so none
                # of the cancellations is the harmless post-response race.
                burst(c, 64)
                # Drained as we go, or the server is talking into a socket
                # buffer nobody reads and the GOAWAY never gets looked at.
                c.step(timeout=0.05)
                terminated = goaway_code(c)
                if terminated is not None:
                    break
        except (OSError, h2.exceptions.H2Error):
            pass
        deadline = time.monotonic() + 5
        while terminated is None and time.monotonic() < deadline:
            try:
                if not c.step(timeout=0.5):
                    break
            except (OSError, h2.exceptions.H2Error):
                break
            terminated = goaway_code(c)
        is_("a flood of cancellations is told to enhance its calm",
            None if terminated is None else int(terminated), 11)
        c.close()

        # The server itself is still there for everyone else.
        c = Client(server)
        s = c.request(path="/")
        status, _, _, _ = c.collect([s], deadline=10.0)
        is_("other connections are unaffected", status.get(s), 200)
        c.close()


def test_slow_stream():
    """A stream that is making progress must not hit the request timeout.

    A stream slot has no descriptor, so nothing refreshes it the way a poller
    event refreshes an HTTP/1 connection. Without the stream itself recording
    the bytes that move on it, the timeout stops being a check for a stalled
    request and becomes an absolute cap on a slow one.

    WSGI, because PEP 3333 hands the application a whole body and so leaves the
    stream reading until END_STREAM -- which is the state the sweep looks at.
    """
    print("\nSlow but steady streams")
    with Server("--request-timeout", "2000", app="wsgi_app:application") as server:
        c = Client(server)
        body = b"abcdefghij"
        stream = c.request(method="POST", path="/echo",
                           extra=[("content-length", str(len(body)))], end=False)
        # Six seconds of dribbling against a two-second timeout: any absolute
        # cap fires long before the last byte.
        killed = None
        began = time.monotonic()
        for i in range(len(body)):
            time.sleep(0.6)
            try:
                c.conn.send_data(stream, body[i:i + 1], end_stream=(i == len(body) - 1))
                c.flush()
            except (OSError, h2.exceptions.H2Error) as exc:
                killed = "%.1fs in: %s" % (time.monotonic() - began,
                                           type(exc).__name__)
                break
            c.step(timeout=0.01)
        if killed is not None:
            bad("a steadily uploaded body outlives the request timeout",
                "the upload to finish", "the server dropped the stream " + killed)
            c.close()
            return
        status, _, echoed, _ = c.collect([stream], deadline=10.0)
        is_("a steadily uploaded body outlives the request timeout",
            status.get(stream), 200)
        is_("and arrives whole", echoed.get(stream), body)
        is_("the stream is not reset out from under it", c.reset.get(stream), None)
        c.close()


def burst(client, count):
    """Opens and cancels `count` streams in a single write."""
    for _ in range(count):
        stream = client.conn.get_next_available_stream_id()
        client.conn.send_headers(stream, [
            (":method", "GET"), (":scheme", "http"),
            (":authority", "127.0.0.1:%d" % client.port), (":path", "/"),
        ], end_stream=True)
        client.conn.reset_stream(stream, error_code=8)
    client.flush()


def goaway_code(client):
    """The error code from a GOAWAY, if one has arrived."""
    for event in client.events:
        if isinstance(event, h2.events.ConnectionTerminated):
            return event.error_code
    return None


def test_large_headers():
    print("\nHeader blocks larger than a frame")
    with Server() as server:
        c = Client(server)
        # 24 KiB of request headers, which must arrive as CONTINUATION frames.
        extra = [("x-pad-%03d" % i, "v" * 512) for i in range(48)]
        s = c.request(path="/scope", extra=extra)
        status, _, body, _ = c.collect([s])
        is_("a request split across CONTINUATION frames is understood",
            status.get(s), 200)
        check("every padded header arrives", body.get(s, b"").count(b"x-pad-") == 48,
              str(body.get(s, b"").count(b"x-pad-")))
        c.close()


def test_response_framing():
    print("\nResponse framing")
    with Server() as server:
        c = Client(server)
        s = c.request(path="/overlong")
        status, headers, body, _ = c.collect([s], deadline=10.0)
        is_("an overlong body is truncated to what was declared",
            body.get(s, b""), b"LO")
        is_("the declared length is what the client is told",
            headers[s].get(b"content-length"), b"2")

        s2 = c.request(path="/short")
        c.collect([s2], deadline=10.0)
        check("a short body resets the stream rather than ending it",
              c.reset.get(s2) is not None,
              "the stream ended cleanly, which would pass off a truncated "
              "body as the whole message")
        c.close()


def test_wsgi():
    """A WSGI application over HTTP/2.

    PEP 3333 has no idea what a stream is, and it does not need one: the two
    differ in how a message is framed, and framing is the server's job in both.
    What has to be checked is that a head produced by code that only knows how
    to write HTTP/1.1 comes out as a proper header block, and that nothing
    belonging to HTTP/1 framing survives the trip.
    """
    print("\nWSGI")
    for threads in (1, 4):
        label = "pooled" if threads > 1 else "inline"
        with Server("--wsgi-threads", str(threads),
                    app="wsgi_app:application") as server:
            c = Client(server)
            s = c.request(path="/")
            status, headers, body, _ = c.collect([s])
            is_("a WSGI GET is answered (%s)" % label, status.get(s), 200)
            is_("the body arrives intact (%s)" % label, body.get(s),
                b"hello from peregrine\n")
            is_("a length is declared (%s)" % label,
                headers[s].get(b"content-length"), b"21")
            check("no HTTP/1 framing survives (%s)" % label,
                  not any(k in headers[s] for k in (b"connection",
                                                    b"transfer-encoding",
                                                    b"keep-alive")),
                  str(sorted(headers[s])))
            is_("the server names itself (%s)" % label,
                headers[s].get(b"server"), b"peregrine")

            s = c.request(path="/env")
            _, _, body, _ = c.collect([s])
            check("SERVER_PROTOCOL says HTTP/2 (%s)" % label,
                  b"SERVER_PROTOCOL='HTTP/2'" in body.get(s, b""),
                  body.get(s, b"")[:200])

            s = c.request(path="/headers")
            _, headers, _, _ = c.collect([s])
            is_("application headers reach the client (%s)" % label,
                (headers[s].get(b"x-one"), headers[s].get(b"x-two")), (b"1", b"2"))

            # No Content-Length: a generator whose length nobody knows. On
            # HTTP/1 that is chunked; here the stream ending is the framing.
            s = c.request(path="/stream")
            _, headers, body, _ = c.collect([s])
            is_("a generator response arrives whole (%s)" % label, body.get(s),
                b"".join(b"chunk-%d\n" % i for i in range(5)))
            check("with no transfer-encoding (%s)" % label,
                  b"transfer-encoding" not in headers[s], str(sorted(headers[s])))

            # Large enough to be split across frames and, when pooled, to be
            # handed over in pieces while the head is still being staged.
            s = c.request(path="/big?300000")
            status, _, body, _ = c.collect([s], deadline=30.0)
            is_("a large WSGI response is intact (%s)" % label,
                (status.get(s), len(body.get(s, b""))), (200, 300000))

            s = c.request(method="HEAD", path="/")
            status, headers, body, _ = c.collect([s])
            is_("HEAD carries no body (%s)" % label,
                (status.get(s), body.get(s, b"")), (200, b""))
            is_("but still declares a length (%s)" % label,
                headers[s].get(b"content-length"), b"21")

            s = c.request(path="/write")
            _, _, body, _ = c.collect([s])
            is_("the legacy write() callable works (%s)" % label, body.get(s),
                b"written and returned\n")

            s = c.request(path="/nope")
            status, _, _, _ = c.collect([s])
            is_("an unknown path is 404 (%s)" % label, status.get(s), 404)

            # wsgi.input is a single read of the whole body, so the request
            # cannot be dispatched on its head the way an ASGI one is: the
            # application would be called with nothing to read.
            s = c.request(method="POST", path="/echo", body=b"a body")
            status, _, body, _ = c.collect([s])
            is_("a request body reaches the application (%s)" % label,
                (status.get(s), body.get(s)), (200, b"a body"))

            big = bytes(i % 251 for i in range(200000))
            s = c.request(method="POST", path="/echo", body=big)
            status, _, body, _ = c.collect([s], deadline=30.0)
            is_("a body larger than the window round trips (%s)" % label,
                (status.get(s), body.get(s) == big), (200, True))

            s = c.request(method="POST", path="/echo")
            status, _, body, _ = c.collect([s])
            is_("an empty body is still a body (%s)" % label,
                (status.get(s), body.get(s, b"")), (200, b""))

            # A message that is not the length it declared must not be ended as
            # if it were whole. On a stream the ending is a flag on a frame, so
            # the only honest ending left is a reset -- there is no connection
            # close to mean anything here, and the connection itself is fine.
            s = c.request(path="/shortbody")
            status, headers, body, _ = c.collect([s])
            is_("a short WSGI response declares the length it promised (%s)"
                % label, headers.get(s, {}).get(b"content-length"), b"10")
            is_("what it did produce still arrives (%s)" % label,
                body.get(s, b""), b"12345")
            is_("and the stream is reset rather than ended cleanly (%s)" % label,
                c.reset.get(s), h2.errors.ErrorCodes.INTERNAL_ERROR)

            s = c.request(path="/")
            status, _, body, _ = c.collect([s])
            is_("the connection survives a reset stream (%s)" % label,
                (status.get(s), body.get(s)), (200, b"hello from peregrine\n"))

            s = c.request(path="/overlong")
            status, headers, body, _ = c.collect([s])
            is_("an over-long WSGI response is cut to its declared length (%s)"
                % label, body.get(s, b""), b"12")
            check("and that stream ends cleanly, having kept its promise (%s)"
                  % label, s not in c.reset, "reset with %r" % c.reset.get(s))
            c.close()


def run_all():
    global FAIL
    for test in (test_basics, test_multiplexing, test_request_bodies,
                 test_flow_control, test_cancellation, test_rapid_reset,
                 test_slow_stream,
                 test_large_headers,
                 test_response_framing, test_wsgi):
        try:
            test()
        except Exception:
            FAIL += 1
            import traceback
            print("  FAIL %s raised" % test.__name__)
            traceback.print_exc()


def main():
    global USE_TLS
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    print("peregrine HTTP/2 tests (%s, h2 %s)" % (BIN, h2.__version__))
    print("\n== cleartext (prior knowledge) ==")
    run_all()

    cert, _ = make_certs()
    if cert is None:
        print("\n== TLS: skipped, no openssl to make a certificate ==")
    else:
        # Everything again over TLS, where ALPN chooses the protocol and the
        # record layer decides where the frame boundaries fall.
        print("\n== TLS (ALPN) ==")
        USE_TLS = True
        run_all()
        USE_TLS = False

    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

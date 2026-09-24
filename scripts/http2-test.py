#!/usr/bin/env python3
"""HTTP/2 checks against an independent implementation.

    <venv>/bin/python scripts/http2-test.py [path-to-garuda]

The server's own framing and HPACK are tested by unit tests and by h2spec;
what this adds is interop with a stack written by someone else (the `h2`
library) and the behaviour a conformance suite has no opinion about --
multiplexing that actually overlaps, flow control on a real body in both
directions, a body held to its declared length, body and request timeouts on
a stream, header blocks split across frames, and the rapid-reset defence.

Everything is served by the built-in router (GET /, GET /user/:id, POST /user
and GET /delay/:ms) or by the server's own --static-dir, so no application is
needed. Each check runs twice: cleartext with prior knowledge, then over TLS
with ALPN. Routes, delays and cancelling a waiting delay are covered over TLS
by scripts/router-streams-test.py and are not repeated here.

Needs `h2` in the interpreter running it, and openssl for the TLS pass:
pip install h2
"""

import os
import shutil
import socket
import ssl
import shlex
import struct
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
    import h2.settings
except ImportError:
    sys.stderr.write("this script needs the h2 package: pip install h2\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda")

# Extra server flags, so the same suite can be pointed at a different
# execution model:  GARUDA_EXTRA_ARGS="--workers 4"
EXTRA = shlex.split(os.environ.get("GARUDA_EXTRA_ARGS", ""))

# Set for the second pass, which runs everything again over TLS so that ALPN,
# record boundaries and partial writes are exercised by the same checks.
USE_TLS = False
CERTS = None


def make_certs():
    """A throwaway self-signed certificate, or None if openssl is missing."""
    global CERTS
    if CERTS is not None:
        return CERTS
    directory = tempfile.mkdtemp(prefix="garuda-h2-tls-")
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
    def __init__(self, *args):
        self.port = free_port()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error"] + EXTRA + list(args)
        if USE_TLS:
            cert, key = make_certs()
            cmd += ["--tls-cert", cert, "--tls-key", key]
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
        is_("an empty body is declared as one", headers[s1].get(b"content-length"), b"0")
        check("no connection-specific headers are sent",
              not any(k in headers[s1] for k in (b"connection", b"transfer-encoding",
                                                 b"keep-alive")),
              str(sorted(headers[s1])))

        # The id comes back as the body, so what arrives is what HPACK decoded.
        s2 = c.request(path="/user/survives-hpack")
        status, _, body, _ = c.collect([s2])
        is_("the path survives HPACK", (status.get(s2), body.get(s2)),
            (200, b"survives-hpack"))

        # RFC 9113 8.3.1: a Host beside :authority must be the same, and a
        # client or proxy may well send both. It was once rebuilt as two Host
        # lines, which the parser refuses, so every such request was reset.
        authority = "127.0.0.1:%d" % c.port
        s3 = c.request(path="/", extra=[("host", authority)])
        s4 = c.request(path="/", extra=[("host", authority.upper())])
        status, _, _, _ = c.collect([s3, s4])
        is_("a Host the same as :authority is served", status.get(s3), 200)
        is_("and compared without regard to case", status.get(s4), 200)
        c.close()

        # One that differs is malformed. h2 refuses to send it, so it is told
        # not to look.
        c = Client(server)
        c.conn.config.validate_outbound_headers = False
        s5 = c.request(path="/", extra=[("host", "elsewhere.example")])
        c.collect([s5])
        check("a Host that differs from :authority is reset", s5 in c.reset,
              "status %s" % c.status.get(s5))
        # An empty :authority is not the same as a Host that names something.
        s6 = c.conn.get_next_available_stream_id()
        c.conn.send_headers(s6, [(":method", "GET"), (":scheme", "http"),
                                 (":authority", ""), (":path", "/"),
                                 ("host", authority)], end_stream=True)
        c.flush()
        c.collect([s6])
        check("an empty :authority beside a Host is reset", s6 in c.reset,
              "status %s" % c.status.get(s6))
        c.close()


def test_multiplexing():
    print("\nMultiplexing")
    with Server() as server:
        c = Client(server)
        # Each of these waits 250ms in the router. Run sequentially they would
        # take two and a half seconds.
        began = time.monotonic()
        streams = [c.request(path="/delay/250") for _ in range(10)]
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
        s = c.request(method="POST", path="/user", body=payload)
        status, _, body, _ = c.collect([s])
        is_("a body larger than a frame is taken whole", status.get(s), 200)

        # A trailer section ends a body as surely as END_STREAM on DATA does,
        # and is held to the same declared length (RFC 9113 section 8.1.1).
        # Before, trailers ended it unchecked, and a body three bytes into a
        # declared ten reached the application as if it were whole.
        s = c.request(method="POST", path="/user",
                      extra=[("content-length", "3")], end=False)
        c.send_body(s, b"abc", end=False)
        c.conn.send_headers(s, [("x-checksum", "1")], end_stream=True)
        c.flush()
        status, _, body, _ = c.collect([s])
        is_("a body of its declared length ends with trailers", status.get(s), 200)

        s = c.request(method="POST", path="/user",
                      extra=[("content-length", "10")], end=False)
        c.send_body(s, b"abc", end=False)
        c.conn.send_headers(s, [("x-checksum", "1")], end_stream=True)
        c.flush()
        c.collect([s])
        is_("a body short of its declared length is refused at the trailers",
            c.reset.get(s), h2.errors.ErrorCodes.PROTOCOL_ERROR)
        check("and never reaches the router as a whole body",
              c.status.get(s) is None, "answered %r" % c.status.get(s))

        s = c.request(path="/user/after-reset")
        status, _, body, _ = c.collect([s])
        is_("the connection survives that reset",
            (status.get(s), body.get(s)), (200, b"after-reset"))
        c.close()


def test_flow_control():
    print("\nFlow control")
    # The router has no large responses, so the large one comes from
    # --static-dir, which refills a stream from the file as the window opens.
    root = tempfile.mkdtemp(prefix="garuda-h2-static-")
    large = os.urandom(400000)
    with open(os.path.join(root, "big.bin"), "wb") as fh:
        fh.write(large)
    try:
        with Server("--static-dir", "/static=" + root) as server:
            flow_control_checks(server, large)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def flow_control_checks(server, large):
    # A deliberately small window, so the response cannot be sent in one go
    # and the server has to wait for WINDOW_UPDATE frames.
    c = Client(server, window=16384)
    s = c.request(path="/static/big.bin")
    status, _, body, _ = c.collect([s], deadline=30.0)
    is_("a response far larger than the window arrives whole",
        (status.get(s), body.get(s, b"") == large), (200, True))

    # And the other direction: the server's own window has to be refreshed
    # as the router reads, or an upload stalls at the initial window.
    payload = b"z" * (1024 * 1024)
    try:
        s2 = c.request(method="POST", path="/user", body=payload)
    except RuntimeError as exc:
        # Recorded rather than raised, so the SETTINGS checks below still run.
        bad("an upload larger than the initial window completes",
            "the upload to finish", "%s: the server never refreshed it" % exc)
    else:
        status, _, body, _ = c.collect([s2], deadline=30.0)
        is_("an upload larger than the initial window completes", status.get(s2), 200)
    c.close()

    # One SETTINGS frame may change INITIAL_WINDOW_SIZE more than once, and
    # each value applies in turn to the streams already open, not just the
    # last. The h2 library never sends that, so these frames are made here.
    # Every case starts from a window of 0: the router writes its answer while
    # decoding the HEADERS frame, so a response with any window at all would
    # be gone before the SETTINGS after it were read.
    def frame(kind, flags, stream, payload=b""):
        return len(payload).to_bytes(3, "big") + bytes([kind, flags]) \
            + struct.pack("!I", stream) + payload

    def settings(*windows):
        return frame(4, 0, 0, b"".join(struct.pack("!HI", 4, w) for w in windows))

    def data_received(initial, updates):
        """DATA bytes a 100-byte response gets, or all it gets before stalling."""
        sock = socket.create_connection(("127.0.0.1", server.port), 5)
        if USE_TLS:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.set_alpn_protocols(["h2"])
            sock = context.wrap_socket(sock, server_hostname="localhost")
        # /user/:id answers with the id, so a 100-byte id is a 100-byte body.
        path = b"/user/" + b"w" * 100
        # GET, :scheme http, then :path and :authority as literals.
        block = b"\x82\x86\x04" + bytes([len(path)]) + path + b"\x01\x09localhost"
        sock.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + settings(initial)
                     + frame(1, 0x5, 1, block) + settings(*updates))
        received = 0
        pending = b""
        sock.settimeout(1.0)
        try:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    return received
                pending += chunk
                while len(pending) >= 9:
                    n = int.from_bytes(pending[:3], "big")
                    if len(pending) < 9 + n:
                        break
                    kind, flags = pending[3], pending[4]
                    pending = pending[9 + n:]
                    if kind == 4 and not flags & 1:
                        sock.sendall(frame(4, 1, 0))
                    elif kind == 0:
                        received += n
                        if flags & 1:
                            return received
        except socket.timeout:
            return received
        finally:
            sock.close()

    is_("INITIAL_WINDOW_SIZE given twice counts both (0, then 100 and 100)",
        data_received(0, [100, 100]), 100)
    is_("the second of two is what the window ends at (0, then 100 and 50)",
        data_received(0, [100, 50]), 50)


def test_rapid_reset():
    """CVE-2023-44487.

    A reset frees the stream slot immediately, so the concurrency limit alone
    never sees a peer that opens a stream and cancels it in the same breath --
    while the server still decodes a header block, builds a request and starts
    work for every one. What bounds it here is the ratio of cancelled streams
    to answered ones, so the first half of this checks that an ordinary
    client, which cancels among requests it completes, is left alone.

    The cancelled requests are /delay/5000, not /: the router answers / inside
    the dispatch that decoded it, so by the time a reset for it is read the
    response is already finished and the reset is the harmless race, charged
    nothing. A delay is still waiting when its reset arrives.
    """
    print("\nRapid reset")
    with Server() as server:
        c = Client(server)
        for _ in range(40):
            done = c.request(path="/")
            c.collect([done], deadline=10.0)
            cancelled = c.request(path="/delay/5000")
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


def test_body_limit():
    """--max-body is a limit on the upload, not on what happens to be buffered.

    The router reads the body as it arrives and discards it, so the buffer
    empties as fast as it fills. A limit measured there would let a peer send
    any amount at all provided it sent it slowly enough.
    """
    print("\nBody limits")
    with Server("--max-body", "1024") as server:
        c = Client(server)
        stream = c.request(method="POST", path="/user", end=False)
        sent = 0
        killed = None
        for _ in range(8):
            try:
                c.conn.send_data(stream, b"x" * 512, end_stream=False)
                c.flush()
            except (OSError, h2.exceptions.H2Error) as exc:
                killed = type(exc).__name__
                break
            sent += 512
            # Slow enough for the router to have taken each block.
            time.sleep(0.15)
            c.step(timeout=0.01)
            if c.reset.get(stream) is not None:
                killed = "reset %s" % c.reset[stream]
                break
        check("a paced upload cannot walk past --max-body",
              killed is not None and sent <= 2048,
              "sent %d bytes with no complaint" % sent)
        c.step(timeout=0.5)
        is_("it is answered 413, as on HTTP/1.1 and HTTP/3", c.status.get(stream), 413)
        is_("and reset with NO_ERROR, so the client stops sending",
            c.reset.get(stream), h2.errors.ErrorCodes.NO_ERROR)
        c.close()

        # A declared length past the limit is refused before the body.
        c = Client(server)
        declared = c.request(method="POST", path="/user",
                             extra=[("content-length", "4096")], end=False)
        c.collect([declared], deadline=5.0)
        is_("a declared Content-Length past --max-body is answered 413 at once",
            c.status.get(declared), 413)
        c.close()

        # Under the limit, everything still works.
        c = Client(server)
        ok_stream = c.request(method="POST", path="/user", body=b"y" * 512)
        status, _, body, _ = c.collect([ok_stream], deadline=10.0)
        is_("a body inside the limit is served", status.get(ok_stream), 200)
        c.close()


def test_slow_stream():
    """A stream that is making progress must not hit the request timeout.

    A stream slot has no descriptor, so nothing refreshes it the way a poller
    event refreshes an HTTP/1 connection. Without the stream itself recording
    the bytes that move on it, the timeout stops being a check for a stalled
    request and becomes an absolute cap on a slow one.

    POST /user answers only once the whole body has been read, so the stream
    stays reading until END_STREAM -- which is the state the sweep looks at.
    """
    print("\nSlow but steady streams")
    with Server("--request-timeout", "2000") as server:
        c = Client(server)
        body = b"abcdefghij"
        stream = c.request(method="POST", path="/user",
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
        status, _, _, _ = c.collect([stream], deadline=10.0)
        is_("a steadily uploaded body outlives the request timeout",
            status.get(stream), 200)
        is_("the stream is not reset out from under it", c.reset.get(stream), None)
        c.close()


def burst(client, count):
    """Opens and cancels `count` streams in a single write."""
    for _ in range(count):
        stream = client.conn.get_next_available_stream_id()
        client.conn.send_headers(stream, [
            (":method", "GET"), (":scheme", "http"),
            (":authority", "127.0.0.1:%d" % client.port), (":path", "/delay/5000"),
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
        s = c.request(path="/user/continued", extra=extra)
        status, _, body, _ = c.collect([s])
        is_("a request split across CONTINUATION frames is understood",
            (status.get(s), body.get(s)), (200, b"continued"))
        c.close()


def run_all():
    global FAIL
    for test in (test_basics, test_multiplexing, test_request_bodies,
                 test_flow_control, test_rapid_reset,
                 test_slow_stream, test_body_limit,
                 test_large_headers):
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
    print("garuda HTTP/2 tests (%s, h2 %s)" % (BIN, h2.__version__))
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

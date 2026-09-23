#!/usr/bin/env python3
"""HTTP/3 checks against an independent implementation.

    <venv>/bin/python scripts/http3-test.py [path-to-garuda]

Garuda's QUIC, TLS 1.3 and QPACK are its own; the packet protection is
checked against RFC 9001's vectors by the unit tests. What this adds is a peer
that shares none of that code: aioquic drives the handshake, the transport and
the HTTP/3 layer, so anything the two implementations disagree about shows up
as a request that does not work rather than as a test that agrees with itself.

Everything is served by the built-in router (GET /, GET /user/:id, POST /user
and GET /delay/:ms) or by the server's own features: --hsts, --request-id,
--health-check-path, --static-dir with --compress-static, and the Alt-Svc
advertisement on TCP. Routes, delays and cancelling a waiting delay are
covered by scripts/router-streams-test.py and are not repeated here.

Needs `aioquic` in the interpreter running it, and openssl for a certificate:
pip install aioquic (and `h2` too, for the HTTP/2 Alt-Svc check)
"""

import asyncio
import gzip
import os
import re
import socket
import ssl
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

try:
    from aioquic.asyncio.client import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import ConnectionTerminated
    from cryptography.x509.oid import NameOID
except ImportError:
    sys.stderr.write("this script needs the aioquic package: pip install aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda")

# Extra server flags, so the same suite can be pointed at a different
# execution model:  GARUDA_EXTRA_ARGS="--workers 4"
EXTRA = shlex.split(os.environ.get("GARUDA_EXTRA_ARGS", ""))

PASS = 0
FAIL = 0
CERTS = None
NAMED_CERTS = None


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
    if CERTS is not None:
        return CERTS
    directory = tempfile.mkdtemp(prefix="garuda-h3-")
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


def make_named_certs():
    """One certificate per name, for the SNI checks.

    The same three scripts/sni-test.sh makes for TCP -- two exact names and a
    wildcard -- so the two transports are asked the same question. They go
    after the default pair on the command line, which leaves CN=localhost as
    the default and these three as the ones SNI chooses.
    """
    global NAMED_CERTS
    if NAMED_CERTS is not None:
        return NAMED_CERTS
    directory = tempfile.mkdtemp(prefix="garuda-h3-sni-")
    made = []
    for name, san in [("alpha", "DNS:alpha.example"),
                      ("beta", "DNS:beta.example"),
                      ("star", "DNS:*.wild.example")]:
        cert = os.path.join(directory, name + ".pem")
        key = os.path.join(directory, name + ".key")
        try:
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                            "-keyout", key, "-out", cert, "-days", "2", "-nodes",
                            "-subj", "/CN=" + name,
                            "-addext", "subjectAltName=" + san],
                           check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            NAMED_CERTS = []
            return NAMED_CERTS
        made.append((cert, key))
    NAMED_CERTS = made
    return NAMED_CERTS


def free_port():
    # The server listens on the port for TCP as well as QUIC, so a port free
    # only for UDP can still fail its start-up with "Address already in use".
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
    def __init__(self, *args):
        self.port = free_port()
        cert, key = make_certs()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error",
               "--http3", "--tls-cert", cert, "--tls-key", key] + EXTRA + list(args)
        self.process = subprocess.Popen(cmd)
        # The TCP listener comes up with the UDP one, and is the easier of the
        # two to wait on.
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

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.stop()


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._events = {}
        self._waiters = {}
        # The last CONNECTION_CLOSE, for the tests that expect one.
        self.terminated = None

    def start(self, method, path, authority="localhost", body=None, headers=(),
              end_stream=True):
        """Sends a request and returns its stream id, without waiting."""
        stream_id = self._quic.get_next_available_stream_id()
        block = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
        ]
        block.extend(headers)
        self._http.send_headers(stream_id=stream_id, headers=block,
                                end_stream=(body is None and end_stream))
        if body is not None:
            self._http.send_data(stream_id=stream_id, data=body, end_stream=end_stream)
        self._events[stream_id] = []
        self._waiters[stream_id] = asyncio.get_event_loop().create_future()
        self.transmit()
        return stream_id

    def send_body(self, stream_id, data, end_stream=False):
        self._http.send_data(stream_id=stream_id, data=data, end_stream=end_stream)
        self.transmit()

    async def collect(self, stream_id, timeout=15.0):
        events = await asyncio.wait_for(asyncio.shield(self._waiters[stream_id]), timeout)
        return summarise(events)

    async def request(self, method, path, **kwargs):
        return await self.collect(self.start(method, path, **kwargs))

    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            self.terminated = event
        for http_event in self._http.handle_event(event):
            if isinstance(http_event, (HeadersReceived, DataReceived)):
                sid = http_event.stream_id
                if sid in self._events:
                    self._events[sid].append(http_event)
                    if http_event.stream_ended and sid in self._waiters:
                        self._waiters.pop(sid).set_result(self._events.pop(sid))


def summarise(events):
    status = None
    headers = []
    body = b""
    for event in events:
        if isinstance(event, HeadersReceived):
            for name, value in event.headers:
                if name == b":status":
                    status = int(value)
                else:
                    headers.append((name, value))
        elif isinstance(event, DataReceived):
            body += event.data
    return status, dict(headers), body


def configuration():
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    return config


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, timeout=180))


# --------------------------------------------------------------------------


async def basics():
    print("\nBasics")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, headers, body = await client.request("GET", "/")
            is_("a GET is answered", status, 200)
            check("a date is present", b"date" in headers, headers)

            # RFC 9114 4.3.1: a Host beside :authority must be the same, and a
            # client or proxy may send both. Rebuilt as two Host lines, every
            # such request was once refused.
            status, _, _ = await client.request("GET", "/", headers=[(b"host", b"localhost")])
            is_("a Host the same as :authority is served", status, 200)
            status, _, _ = await client.request("GET", "/", headers=[(b"host", b"LocalHost")])
            is_("and compared without regard to case", status, 200)
            # A reset stream never ends, so a refusal is the wait running out.
            sid = client.start("GET", "/", headers=[(b"host", b"elsewhere.example")])
            try:
                status, _, _ = await client.collect(sid, timeout=3)
            except asyncio.TimeoutError:
                status = "refused"
            is_("a Host that differs from :authority is refused", status, "refused")


async def hsts():
    print("\nStrict-Transport-Security")
    with Server("--hsts", "600") as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, headers, _ = await client.request("GET", "/")
            is_("--hsts reaches an HTTP/3 response", headers.get(b"strict-transport-security"),
                b"max-age=600")
    with Server("--request-id") as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            _, headers, _ = await client.request("GET", "/")
            rid = headers.get(b"x-request-id") or b""
            check("--request-id reaches an HTTP/3 response",
                  re.fullmatch(rb"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
                               rid) is not None, rid)


async def health_check():
    print("\nHealth check path")
    with Server("--health-check-path", "/healthz") as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, _, body = await client.request("GET", "/healthz")
            is_("the probe is answered", status, 200)
            is_("it carries no body", body, b"")
            # The probe answers and ends its stream inside the dispatch that
            # received it. The request after it is the one that shows whether
            # the connection survived that.
            status, _, body = await client.request("GET", "/user/after-probe")
            is_("the connection still serves afterwards", (status, body),
                (200, b"after-probe"))
            status, _, _ = await client.request("GET", "/healthz")
            is_("a second probe is answered", status, 200)


async def static_files():
    print("\nStatic files")
    root = tempfile.mkdtemp()
    small = b"body { color: red }\n"
    # Larger than one QUIC stream window, so the response has to be refilled
    # from the file as the peer opens the window rather than queued in one go.
    large = os.urandom(3_000_000)
    with open(os.path.join(root, "site.css"), "wb") as fh:
        fh.write(small)
    with open(os.path.join(root, "big.bin"), "wb") as fh:
        fh.write(large)

    with Server("--static-dir", "/static=" + root) as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # HEAD is not checked here, and the reason is the client rather
            # than the server. A HEAD response declares the length a GET would
            # have had and sends no body, which RFC 9110 section 8.6 allows
            # explicitly -- but aioquic's H3Connection is generic over requests
            # and never learns the method, so a non-zero content-length with an
            # empty body reads to it as a stream that ended early, and it never
            # reports the response at all. Covered over HTTP/1.1 and HTTP/2 in
            # scripts/static-test.sh instead.
            status, headers, body = await client.request("GET", "/static/site.css")
            is_("a file is served over HTTP/3", status, 200)
            is_("its bytes are intact", body, small)
            is_("its media type is right", headers.get(b"content-type"),
                b"text/css; charset=utf-8")
            check("an ETag is sent", b"etag" in headers, headers)

            etag = headers.get(b"etag")
            status, _, body = await client.request(
                "GET", "/static/site.css", headers=((b"if-none-match", etag),))
            is_("a matching ETag is 304", status, 304)
            is_("the 304 carries no body", body, b"")

            status, _, body = await client.collect(
                client.start("GET", "/static/big.bin"), timeout=60.0)
            is_("a 3MB file arrives whole", len(body), len(large))
            is_("a 3MB file is byte-identical", body, large)

            # Ranges, which HTTP/3 encodes its own headers for.
            status, headers, body = await client.request(
                "GET", "/static/site.css", headers=((b"range", b"bytes=7-11"),))
            is_("a range is 206 over HTTP/3", status, 206)
            is_("and carries those bytes", body, small[7:12])
            is_("with the Content-Range that says so", headers.get(b"content-range"),
                b"bytes 7-11/%d" % len(small))
            is_("and a Content-Length of the range", headers.get(b"content-length"), b"5")
            check("ranges are advertised", headers.get(b"accept-ranges") == b"bytes", headers)

            status, headers, _ = await client.request(
                "GET", "/static/site.css", headers=((b"range", b"bytes=99999-"),))
            is_("a range past the end is 416", status, 416)
            is_("and says how big the file is", headers.get(b"content-range"),
                b"bytes */%d" % len(small))

            status, _, body = await client.collect(
                client.start("GET", "/static/big.bin",
                             headers=((b"range", b"bytes=1000000-1999999"),)),
                timeout=60.0)
            is_("a range of a 3MB file is byte-identical", body, large[1000000:2000000])

            status, _, body = await client.request(
                "GET", "/static/site.css",
                headers=((b"if-range", b'"nope"'), (b"range", b"bytes=0-3")))
            is_("a stale If-Range sends the whole file", status, 200)
            is_("every byte of it", body, small)

            status, _, _ = await client.request("GET", "/static/../etc/passwd")
            is_("dot-dot does not escape", status, 404)
            status, _, _ = await client.request("GET", "/static/missing.css")
            is_("a missing file reaches the router", status, 404)
            status, _, body = await client.request("GET", "/user/still-routed")
            is_("the router still answers", (status, body), (200, b"still-routed"))

    shutil.rmtree(root, ignore_errors=True)


def udp_receive_drops():
    """Datagrams the kernel dropped because a receive buffer was full, across
    the whole host, or None where there is no /proc/net/snmp to ask."""
    try:
        with open("/proc/net/snmp") as fh:
            rows = [line.split() for line in fh if line.startswith("Udp:")]
        return int(rows[1][rows[0].index("RcvbufErrors")])
    except (OSError, ValueError, IndexError):
        return None


async def congestion():
    print("\nCongestion control")
    # aioquic in Python is far slower than the server, which is exactly what
    # makes this a test: a sender that ignores its congestion window fills the
    # client's socket buffer and the kernel throws the overflow away. Before
    # the window was enforced a 20MB download here lost a quarter of a million
    # datagrams; with it, a few dozen.
    root = tempfile.mkdtemp()
    large = os.urandom(20_000_000)
    with open(os.path.join(root, "big.bin"), "wb") as fh:
        fh.write(large)

    with Server("--static-dir", "/static=" + root) as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            before = udp_receive_drops()
            status, _, body = await client.collect(
                client.start("GET", "/static/big.bin"), timeout=120.0)
            after = udp_receive_drops()
            is_("a 20MB file arrives whole", (status, len(body)), (200, len(large)))
            is_("and byte-identical", body == large, True)
            if before is None or after is None:
                print("  skip the sender does not overrun a slow receiver: no /proc/net/snmp")
            else:
                check("the sender does not overrun a slow receiver", after - before < 5000,
                      "%d datagrams dropped for want of buffer" % (after - before))

    shutil.rmtree(root, ignore_errors=True)


async def compression():
    print("\nCompression")
    # Text that compresses well and is past --compress-min-size, so gzip is
    # plainly worth serving.
    text = b"".join(b"line %04d of a stylesheet that repeats itself\n" % i
                    for i in range(400))
    root = tempfile.mkdtemp()
    with open(os.path.join(root, "site.css"), "wb") as fh:
        fh.write(text)
    with open(os.path.join(root, "site.css.gz"), "wb") as fh:
        fh.write(gzip.compress(text))

    with Server("--compress-static", "--static-dir", "/static=" + root) as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            gz = ((b"accept-encoding", b"gzip"),)
            status, headers, body = await client.request("GET", "/static/site.css", headers=gz)
            is_("a pre-compressed file is served", headers.get(b"content-encoding"), b"gzip")
            is_("and decodes", gzip.decompress(body), text)
            check("with its own etag", headers.get(b"etag", b"").endswith(b'-gzip"'), headers)

    shutil.rmtree(root, ignore_errors=True)


async def request_bodies():
    print("\nRequest bodies")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # Four times the 256 KiB stream window, so the upload only
            # completes if the server raises MAX_STREAM_DATA as the router
            # reads.
            payload = bytes(range(256)) * 4096
            status, _, _ = await client.collect(
                client.start("POST", "/user", body=payload), timeout=60.0)
            is_("an upload larger than the stream window completes", status, 200)

            status, _, _ = await client.request("POST", "/user", body=b"")
            is_("an empty body is still a body", status, 200)

            status, _, body = await client.request("GET", "/user/afterwards")
            is_("the connection still works afterwards", (status, body),
                (200, b"afterwards"))


async def multiplexing():
    print("\nMultiplexing")
    root = tempfile.mkdtemp()
    large = os.urandom(1024 * 1024)
    with open(os.path.join(root, "big.bin"), "wb") as fh:
        fh.write(large)

    with Server("--static-dir", "/static=" + root) as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            started = time.monotonic()
            results = await asyncio.gather(*[
                client.request("GET", "/delay/250") for _ in range(10)])
            elapsed = time.monotonic() - started
            is_("ten concurrent requests all answer",
                [r[0] for r in results], [200] * 10)
            # /delay/250 waits 250ms. Serialised that would be 2.5 seconds.
            check("they overlapped rather than queued", elapsed < 1.5,
                  "%.3fs" % elapsed)

            # Interleaved: a large response and a small one on the same
            # connection, where the small one must not wait for the large.
            # The router has no large responses, so that one is a file.
            big = client.start("GET", "/static/big.bin")
            small = client.start("GET", "/")
            status, _, body = await client.collect(small)
            is_("a small response is not stuck behind a large one", status, 200)
            status, _, big_body = await client.collect(big, timeout=60.0)
            is_("the large response is intact", (status, big_body == large),
                (200, True))

    shutil.rmtree(root, ignore_errors=True)


async def rapid_reset():
    """Cancelling without finishing has to cost the peer something.

    The HTTP/2 shape of this is CVE-2023-44487: open a stream, cancel it, and
    the concurrency credit comes straight back, so a peer can keep the server
    decoding headers and starting work while never holding more than one
    stream open. QUIC has the same property -- closing a stream queues
    MAX_STREAMS -- so it needs the same accounting.
    """
    print("\nRapid reset")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, _, _ = await client.request("GET", "/")
            is_("the connection works before the flood", status, 200)

            # /delay/5000 never answers within the test, so nothing earns its
            # cancellation back and the allowance only falls. The pairs go out
            # together, the way an attacker would send them: a response that
            # had already finished would be a race, not a reset, and is
            # charged nothing.
            sent = 0
            for _ in range(12):
                if client.terminated is not None:
                    break
                for _ in range(32):
                    try:
                        stream_id = client.start("GET", "/delay/5000")
                    except ValueError:
                        break       # out of stream credit; let the server catch up
                    client._quic.reset_stream(stream_id, 0x010c)
                    sent += 1
                client.transmit()
                await asyncio.sleep(0.15)

            check("the peer is cut off for cancelling what it never finished",
                  client.terminated is not None, "%d resets sent, still open" % sent)
            if client.terminated is not None:
                is_("and told why", client.terminated.error_code, 0x0107)  # H3_EXCESSIVE_LOAD


async def spoofed_address():
    """A forged packet must not redirect a connection.

    A connection ID travels in clear, so anyone who can see one can put it in
    a UDP header of their own. If the server believed the source address of
    such a packet, one forged datagram would send everything the connection
    had yet to write -- the client's own replies included -- wherever the
    sender liked.
    """
    print("\nAddress spoofing")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, _, _ = await client.request("GET", "/")
            is_("the connection works before the forgery", status, 200)

            # The identifier the client puts in the packets it sends, which is
            # the one the server routes on.
            cid = client._quic._peer_cid.cid
            attacker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            attacker.settimeout(2.0)
            attacker.bind(("127.0.0.1", 0))
            # A short header with the fixed bit set, the connection's own id,
            # and a payload that will not authenticate as anything.
            forged = bytes([0x40]) + cid + os.urandom(64)
            attacker.sendto(forged, ("127.0.0.1", server.port))
            await asyncio.sleep(0.3)

            # The real client must still be answered. Before the fix the
            # server had already switched to the attacker's address, and this
            # request timed out.
            try:
                status, _, body = await asyncio.wait_for(
                    client.request("GET", "/user/real-client"), 10)
            except asyncio.TimeoutError:
                status, body = None, b""
            is_("a forged packet does not redirect the connection", status, 200)
            is_("and the answer still reaches the client that asked",
                body, b"real-client")

            leaked = b""
            try:
                leaked = attacker.recv(65536)
            except OSError:
                pass
            check("nothing was sent to the forged address", not leaked,
                  "%d bytes went to the attacker" % len(leaked))
            attacker.close()


async def large_headers():
    print("\nHeader compression")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # Values long enough to need multi-byte QPACK lengths, and text
            # that Huffman coding will actually shorten.
            headers = [(b"x-long-%d" % i, (b"aeiou-repeated-text " * 20).strip())
                       for i in range(4)]
            status, _, body = await client.request("GET", "/user/long", headers=headers)
            is_("many long headers survive QPACK", (status, body), (200, b"long"))

            # A value that is worse under Huffman than as bytes, so the
            # encoder has to choose the plain form.
            raw = bytes(range(128, 200))
            status, _, _ = await client.request(
                "GET", "/", headers=[(b"x-binary", raw.hex().encode())])
            is_("a value Huffman cannot shrink is still sent", status, 200)


async def long_lived():
    """A connection that outlives its stream concurrency limit.

    A QUIC stream is credit as well as state: a peer may have only
    initial_max_streams_bidi of them open, and it is given more only when the
    server retires the ones that have finished. A server that never retires a
    completed stream works perfectly for exactly that many requests and then
    stops, with the next one waiting on credit that cannot arrive.
    """
    print("\nA long-lived connection")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            statuses = set()
            bodies = set()
            for _ in range(200):
                status, _, body = await client.request("GET", "/user/42")
                statuses.add(status)
                bodies.add(body)
            is_("200 requests on one connection are all answered",
                statuses, {200})
            is_("and every one of them is the whole response", bodies, {b"42"})


async def key_update():
    """A key update started by the client.

    Either endpoint may rotate the packet protection keys at any time by
    flipping the key phase bit (RFC 9001 section 6). The packet that announces
    it arrives under keys the server has derived but not adopted, so the server
    has to tell which keys apply from the header rather than by trying one set
    and then another: decryption happens in place, and an attempt that fails
    has already written over the packet a second attempt would need.
    """
    print("\nKey update")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, _, before = await client.request("GET", "/user/keyed")
            is_("a request before the update", (status, before), (200, b"keyed"))

            client._quic.request_key_update()
            client.transmit()

            status, _, after = await client.request("GET", "/user/keyed")
            is_("the connection survives the update", status, 200)
            is_("and answers the same thing", after, before)

            # The phase stays flipped, so this one is ordinary traffic under
            # the new keys rather than the announcement itself.
            status, _, later = await client.request("GET", "/user/keyed")
            is_("and goes on working under the new keys", status, 200)
            is_("with nothing lost in the change", later, before)

            # And again, in the other direction of the phase bit.
            client._quic.request_key_update()
            client.transmit()
            status, _, _ = await client.request("GET", "/")
            is_("a second update works as well as the first", status, 200)


def http1_headers(port, path, quic_port=None):
    """One HTTP/1.1 request over TLS, returning its headers."""
    import http.client
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    conn = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=15)
    try:
        conn.request("GET", path)
        response = conn.getresponse()
        response.read()
        return response.getheader("alt-svc"), len(response.headers.get_all("alt-svc") or [])
    finally:
        conn.close()


def http2_alt_svc(port, path):
    """The same over HTTP/2, where the header is encoded rather than written."""
    try:
        import h2.config
        import h2.connection
        import h2.events
    except ImportError:
        return False
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2"])
    sock = context.wrap_socket(socket.create_connection(("127.0.0.1", port), 15),
                               server_hostname="localhost")
    sock.settimeout(15)
    try:
        conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True))
        conn.initiate_connection()
        stream = conn.get_next_available_stream_id()
        conn.send_headers(stream, [(":method", "GET"), (":scheme", "https"),
                                   (":authority", "localhost"), (":path", path)],
                          end_stream=True)
        sock.sendall(conn.data_to_send())
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            data = sock.recv(65536)
            if not data:
                break
            for event in conn.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived):
                    return dict(event.headers).get(b"alt-svc")
            out = conn.data_to_send()
            if out:
                sock.sendall(out)
        return None
    finally:
        sock.close()


async def served_for(port, asked):
    """The common name of the certificate served to a client asking for
    `asked`, which is how the client says which one it wanted."""
    config = configuration()
    config.server_name = asked
    async with connect("127.0.0.1", port, configuration=config,
                       create_protocol=Client) as client:
        # After a request, so the handshake is certainly finished.
        await client.request("GET", "/")
        certificate = client._quic.tls._peer_certificate
        names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        return names[0].value if names else ""


async def sni():
    print("\nSNI")
    # HTTP/3 served the default certificate whatever the client asked for
    # until the QUIC handshake learned to choose: there is no OpenSSL
    # handshake here to do it. These are scripts/sni-test.sh's cases, over
    # QUIC, with CN=localhost as the default rather than alpha.
    named = make_named_certs()
    if not named:
        print("  skipped: no openssl to make certificates")
        return
    flags = []
    for cert, key in named:
        flags += ["--tls-cert", cert, "--tls-key", key]
    with Server(*flags) as server:
        is_("an exact name gets its own certificate",
            await served_for(server.port, "alpha.example"), "alpha")
        is_("a second exact name gets its own",
            await served_for(server.port, "beta.example"), "beta")
        is_("a wildcard covers one label",
            await served_for(server.port, "a.wild.example"), "star")
        is_("a wildcard does not cross a dot",
            await served_for(server.port, "a.b.wild.example"), "localhost")
        is_("a wildcard does not match the bare domain",
            await served_for(server.port, "wild.example"), "localhost")
        is_("a name no certificate claims gets the default",
            await served_for(server.port, "nothing.example"), "localhost")
        is_("matching is case-insensitive",
            await served_for(server.port, "BETA.Example"), "beta")
        # The certificate is chosen while the handshake is being built, so a
        # connection that chose one has to go on working like any other.
        config = configuration()
        config.server_name = "beta.example"
        async with connect("127.0.0.1", server.port, configuration=config,
                           create_protocol=Client) as client:
            status, _, body = await client.request("GET", "/user/sni")
            is_("a request on a chosen certificate is answered", status, 200)
            is_("and answers with its own body", body, b"sni")


async def alt_svc():
    print("\nAlt-Svc")
    # A client cannot find HTTP/3 by trying: it has to be told, on the TCP
    # connection it already has.
    with Server() as server:
        value, count = http1_headers(server.port, "/")
        is_("HTTP/1.1 advertises h3", value, 'h3=":%d"; ma=86400' % server.port)
        is_("exactly once", count, 1)

        value = http2_alt_svc(server.port, "/")
        if value is False:
            print("  ..   skipped the HTTP/2 check (no h2 library)")
        else:
            is_("HTTP/2 advertises it too", value,
                b'h3=":%d"; ma=86400' % server.port)

    # A separate UDP port is what the value has to name, not the TCP one.
    port = free_port()
    with Server("--quic-port", str(port)) as server:
        value, _ = http1_headers(server.port, "/")
        is_("a separate QUIC port is the one advertised", value,
            'h3=":%d"; ma=86400' % port)


async def main():
    if not os.path.exists(BIN):
        print("no such binary: %s" % BIN)
        return 2
    cert, _ = make_certs()
    if cert is None:
        print("skipped: no openssl to make a certificate")
        return 0
    print("garuda HTTP/3 tests (%s)" % BIN)

    for test in (basics, hsts, health_check, static_files, congestion, compression,
                 request_bodies, multiplexing, rapid_reset, spoofed_address,
                 large_headers, long_lived, key_update, alt_svc, sni):
        try:
            await test()
        except Exception:
            global FAIL
            FAIL += 1
            import traceback
            print("  FAIL %s raised" % test.__name__)
            traceback.print_exc()

    print("\npassed: %d   failed: %d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


sys.exit(run(main()))

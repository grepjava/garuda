#!/usr/bin/env python3
"""HTTP/3 checks against an independent implementation.

    <venv>/bin/python scripts/http3-test.py [path-to-peregrine]

Peregrine's QUIC, TLS 1.3 and QPACK are its own; the packet protection is
checked against RFC 9001's vectors by the unit tests. What this adds is a peer
that shares none of that code: aioquic drives the handshake, the transport and
the HTTP/3 layer, so anything the two implementations disagree about shows up
as a request that does not work rather than as a test that agrees with itself.

Needs `aioquic` in the interpreter running it:  pip install aioquic
"""

import asyncio
import os
import socket
import ssl
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
except ImportError:
    sys.stderr.write("this script needs the aioquic package: pip install aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/release/peregrine")

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
    if CERTS is not None:
        return CERTS
    directory = tempfile.mkdtemp(prefix="peregrine-h3-")
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


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Server:
    def __init__(self, *args, app="asgi_app:app"):
        self.port = free_port()
        cert, key = make_certs()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error",
               "--http3", "--tls-cert", cert, "--tls-key", key,
               "--python-path", os.path.join(ROOT, "examples")] + list(args) + [app]
        self.process = subprocess.Popen(cmd)
        # The TCP listener comes up with the UDP one, and is the easier of the
        # two to wait on.
        deadline = time.time() + 15
        while time.time() < deadline:
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
    return asyncio.run(asyncio.wait_for(coro, timeout=60))


# --------------------------------------------------------------------------


async def basics():
    print("\nBasics")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, headers, body = await client.request("GET", "/")
            is_("a GET is answered", status, 200)
            is_("the body arrives whole", body, b"hello from peregrine asgi\n")
            is_("the server names itself", headers.get(b"server"), b"peregrine")
            check("a date is present", b"date" in headers, headers)

            status, headers, body = await client.request("HEAD", "/")
            is_("HEAD is answered", status, 200)
            is_("HEAD carries no body", body, b"")

            status, _, _ = await client.request("GET", "/nope")
            is_("an unknown path is 404", status, 404)

            status, _, body = await client.request("GET", "/scope")
            check("the scope reports HTTP/3", b'"http_version": "3"' in body, body[:200])
            check("the scope reports https", b'"scheme": "https"' in body, body[:200])


async def request_bodies():
    print("\nRequest bodies")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, _, body = await client.request("POST", "/echo", body=b"hello")
            is_("a small body echoes back", (status, body), (200, b"hello"))

            status, _, body = await client.request("POST", "/echo", body=b"")
            is_("an empty body is still a body", (status, body), (200, b""))

            payload = bytes(range(256)) * 400        # 100 KiB, past one packet
            status, _, body = await client.request("POST", "/echo", body=payload)
            is_("a body larger than the window round trips",
                (status, len(body), body == payload), (200, len(payload), True))

            # The application answers without reading, which leaves the rest of
            # the upload with nowhere to go.
            status, _, _ = await client.request("POST", "/reject", body=b"x" * 40000)
            is_("an early answer is not disturbed by the rest of the upload", status, 403)

            status, _, body = await client.request("GET", "/")
            is_("the connection still works afterwards", (status, body),
                (200, b"hello from peregrine asgi\n"))


async def multiplexing():
    print("\nMultiplexing")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            started = time.time()
            results = await asyncio.gather(*[
                client.request("GET", "/sleep") for _ in range(10)])
            elapsed = time.time() - started
            is_("ten concurrent requests all answer",
                [r[0] for r in results], [200] * 10)
            # /sleep waits 250ms. Serialised that would be 2.5 seconds.
            check("they overlapped rather than queued", elapsed < 1.5,
                  "%.3fs" % elapsed)

            # Interleaved: a large response and a small one on the same
            # connection, where the small one must not wait for the large.
            big = client.start("GET", "/big?1048576")
            small = client.start("GET", "/")
            status, _, body = await client.collect(small)
            is_("a small response is not stuck behind a large one", status, 200)
            status, _, big_body = await client.collect(big)
            is_("the large response is intact", (status, len(big_body)),
                (200, 1024 * 1024))


async def cancellation():
    print("\nCancellation")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            stream_id = client.start("GET", "/slow?5")
            await asyncio.sleep(0.05)
            client._quic.reset_stream(stream_id, 0x010c)     # H3_REQUEST_CANCELLED
            client.transmit()
            await asyncio.sleep(0.4)

            status, _, body = await client.request("GET", "/")
            is_("a cancelled request does not disturb the connection",
                (status, body), (200, b"hello from peregrine asgi\n"))


async def large_headers():
    print("\nHeader compression")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # Values long enough to need multi-byte QPACK lengths, and text
            # that Huffman coding will actually shorten.
            headers = [(b"x-long-%d" % i, (b"aeiou-repeated-text " * 20).strip())
                       for i in range(4)]
            status, _, body = await client.request("GET", "/scope", headers=headers)
            is_("many long headers survive QPACK", status, 200)
            check("a long value round trips", b"aeiou-repeated-text" in body, body[:80])

            # A header whose name is not in the static table at all.
            status, _, body = await client.request(
                "GET", "/scope", headers=[(b"x-peregrine-probe", b"1")])
            check("an unknown header name round trips",
                  b"x-peregrine-probe" in body, body[:200])

            # A value that is worse under Huffman than as bytes, so the
            # encoder has to choose the plain form.
            raw = bytes(range(128, 200))
            status, _, _ = await client.request(
                "GET", "/", headers=[(b"x-binary", raw.hex().encode())])
            is_("a value Huffman cannot shrink is still sent", status, 200)


async def response_framing():
    print("\nResponse framing")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            status, headers, body = await client.request("GET", "/big?1048576")
            is_("a large response arrives whole", (status, len(body)),
                (200, 1024 * 1024))

            # A response that declares its own length has to say so, and say
            # it right: the stream ending is the other way a body can end, and
            # the two must not disagree.
            status, headers, body = await client.request("GET", "/fixed")
            is_("a declared length reaches the client",
                headers.get(b"content-length"), str(len(body)).encode())
            is_("and the body matches it", body, b"fixed length" + bytes([10]))

            # A HEAD whose GET would have declared a length is deliberately
            # not checked here: aioquic's HTTP/3 client does not record which
            # method it sent, so it measures the (correctly absent) body
            # against the content-length and calls it an error. The equivalent
            # over HTTP/2 is covered by scripts/http2-test.py, where the h2
            # library does keep track.

            status, headers, body = await client.request("GET", "/stream")
            is_("a streamed response arrives", status, 200)
            check("a streamed response has no content-length",
                  b"content-length" not in headers, headers)
            check("its body is complete", len(body) > 0, len(body))

            # A body with no declared length is delimited by the stream
            # ending, which is legal and is what HTTP/2 does too.
            status, headers, body = await client.request("GET", "/nope")
            is_("an undeclared length is delimited by the stream ending",
                (status, b"content-length" in headers, len(body) > 0),
                (404, False, True))


async def flow_control():
    print("\nFlow control")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # A body sent in pieces, with the application reading as it goes.
            stream_id = client.start("POST", "/echo", body=b"", end_stream=False)
            total = b""
            for i in range(20):
                chunk = bytes([65 + (i % 26)]) * 8192
                total += chunk
                client.send_body(stream_id, chunk)
                await asyncio.sleep(0)
            client.send_body(stream_id, b"", end_stream=True)
            status, _, body = await client.collect(stream_id)
            is_("a drip-fed body reassembles in order",
                (status, len(body), body == total), (200, len(total), True))


async def wsgi():
    """A WSGI application over HTTP/3.

    Same reasoning as the HTTP/2 suite: PEP 3333 knows nothing about streams
    and does not have to. The head it produces is staged and encoded with
    QPACK here, so what is checked is that it arrives as a header block and
    that nothing belonging to HTTP/1 framing came with it.
    """
    print("\nWSGI")
    for threads in (1, 4):
        label = "pooled" if threads > 1 else "inline"
        with Server("--wsgi-threads", str(threads),
                    app="wsgi_app:application") as server:
            async with connect("127.0.0.1", server.port, configuration=configuration(),
                               create_protocol=Client) as client:
                status, headers, body = await client.request("GET", "/")
                is_("a WSGI GET is answered (%s)" % label, status, 200)
                is_("the body arrives intact (%s)" % label, body,
                    b"hello from peregrine\n")
                is_("a length is declared (%s)" % label,
                    headers.get(b"content-length"), b"21")
                check("no HTTP/1 framing survives (%s)" % label,
                      not any(k in headers for k in (b"connection",
                                                     b"transfer-encoding",
                                                     b"keep-alive")),
                      str(sorted(headers)))

                _, _, body = await client.request("GET", "/env")
                check("SERVER_PROTOCOL says HTTP/3 (%s)" % label,
                      b"SERVER_PROTOCOL='HTTP/3'" in body, body[:200])
                check("the scheme is https (%s)" % label,
                      b"wsgi.url_scheme='https'" in body, body[:400])

                _, headers, body = await client.request("GET", "/stream")
                is_("a generator response arrives whole (%s)" % label, body,
                    b"".join(b"chunk-%d\n" % i for i in range(5)))
                check("with no transfer-encoding (%s)" % label,
                      b"transfer-encoding" not in headers, str(sorted(headers)))

                status, _, body = await client.request("GET", "/big?300000")
                is_("a large WSGI response is intact (%s)" % label,
                    (status, len(body)), (200, 300000))

                # HEAD is not checked here for the same reason as above: this
                # application declares a length, and aioquic measures the
                # correctly absent body against it. scripts/http2-test.py
                # covers HEAD for WSGI, where the h2 library knows what it
                # asked for.

                _, _, body = await client.request("GET", "/write")
                is_("the legacy write() callable works (%s)" % label, body,
                    b"written and returned\n")

                status, _, _ = await client.request("GET", "/nope")
                is_("an unknown path is 404 (%s)" % label, status, 404)

                # wsgi.input is a single read of the whole body, so the
                # request cannot be dispatched on its head the way an ASGI
                # one is: the application would find nothing to read.
                status, _, body = await client.request("POST", "/echo",
                                                       body=b"a body")
                is_("a request body reaches the application (%s)" % label,
                    (status, body), (200, b"a body"))

                big = bytes(i % 251 for i in range(200000))
                status, _, body = await client.request("POST", "/echo", body=big)
                is_("a body larger than the window round trips (%s)" % label,
                    (status, body == big), (200, True))

                status, _, body = await client.request("POST", "/echo", body=b"")
                is_("an empty body is still a body (%s)" % label,
                    (status, body), (200, b""))


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
        return None
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
        deadline = time.time() + 15
        while time.time() < deadline:
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


async def alt_svc():
    print("\nAlt-Svc")
    # A client cannot find HTTP/3 by trying: it has to be told, on the TCP
    # connection it already has.
    with Server() as server:
        value, count = http1_headers(server.port, "/")
        is_("HTTP/1.1 advertises h3", value, 'h3=":%d"; ma=86400' % server.port)
        is_("exactly once", count, 1)

        value = http2_alt_svc(server.port, "/")
        if value is None:
            print("  ..   skipped the HTTP/2 check (no h2 library)")
        else:
            is_("HTTP/2 advertises it too", value,
                b'h3=":%d"; ma=86400' % server.port)

        value, count = http1_headers(server.port, "/altsvc")
        is_("an application's own alt-svc is left alone", value, 'h3=":9999"')
        is_("and is not doubled", count, 1)

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
    print("peregrine HTTP/3 tests (%s)" % BIN)

    for test in (basics, request_bodies, multiplexing, cancellation,
                 large_headers, response_framing, flow_control, wsgi, alt_svc):
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

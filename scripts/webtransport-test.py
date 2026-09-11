#!/usr/bin/env python3
"""WebTransport checks against an independent implementation.

    <venv>/bin/python scripts/webtransport-test.py [path-to-peregrine]

Peregrine's QUIC, HTTP/3 and WebTransport are all its own code, so a test that
drives them with that same code would mostly be checking that it agrees with
itself. aioquic shares none of it: it opens the session, prefixes the streams,
frames the datagrams and reads the capsules by its own reading of the drafts.
Anything the two disagree about shows up here as a session that does not work.

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
    from aioquic.buffer import encode_uint_var
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import (DataReceived, DatagramReceived,
                                   HeadersReceived,
                                   WebTransportStreamDataReceived)
    from aioquic.quic.configuration import QuicConfiguration
except ImportError:
    sys.stderr.write("this script needs the aioquic package: pip install aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pgbuild/release/peregrine")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CLOSE_WEBTRANSPORT_SESSION = 0x2843

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
    directory = tempfile.mkdtemp(prefix="peregrine-wt-")
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
    def __init__(self, *args, app="asgi_app:app", env=None):
        self.port = free_port()
        cert, key = make_certs()
        cmd = [BIN, "--port", str(self.port), "--log-level", "error",
               "--http3", "--tls-cert", cert, "--tls-key", key,
               "--python-path", os.path.join(ROOT, "examples"),
               # Ahead of the virtualenv deliberately: an installed release of
               # peregrine would otherwise shadow the checkout being tested.
               "--python-path", os.path.join(ROOT, "python")]
        # The framework examples import fastapi and django, which live in
        # whatever interpreter is running this script. Naming that virtualenv
        # explicitly means the script works when run as `<venv>/bin/python
        # ...` and not only when the environment has been activated -- the
        # server is a separate process and inherits nothing else from it.
        if sys.prefix != getattr(sys, "base_prefix", sys.prefix):
            cmd += ["--venv", sys.prefix]
        cmd += list(args) + [app]
        self.process = subprocess.Popen(cmd, env=env)
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
    """A WebTransport client that records everything it is told."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic, enable_webtransport=True)
        self.headers = {}                # connect stream id -> header dict
        self.connected = {}              # connect stream id -> Future
        self.stream_data = {}            # stream id -> bytes so far
        self.stream_ended = set()
        self.body = {}                   # request stream id -> response body
        self.body_ended = set()
        self.datagrams = []
        self.settings = None
        self._events = asyncio.Event()

    # -- session set-up ----------------------------------------------------

    def connect_session(self, path, authority="localhost", protocol="webtransport"):
        stream_id = self._quic.get_next_available_stream_id()
        self._http.send_headers(stream_id=stream_id, headers=[
            (b":method", b"CONNECT"),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
            (b":protocol", protocol.encode()),
        ], end_stream=False)
        self.connected[stream_id] = asyncio.get_event_loop().create_future()
        self.transmit()
        return stream_id

    async def await_session(self, stream_id, timeout=15.0):
        return await asyncio.wait_for(asyncio.shield(self.connected[stream_id]), timeout)

    # -- session traffic ---------------------------------------------------

    def open_stream(self, session_id, unidirectional=False, data=b"", end=True):
        stream_id = self._http.create_webtransport_stream(
            session_id, is_unidirectional=unidirectional)
        if not unidirectional:
            # aioquic writes the WEBTRANSPORT_STREAM prefix but does not record
            # it against its own stream, so it would try to read the answer as
            # HTTP/3 frames. The prefix is sent once by whoever opens the
            # stream and the reply carries none, which is what the draft says
            # and what the server does; this only teaches the client what it
            # already put on the wire.
            with self._http._get_or_create_stream(stream_id) as state:
                state.frame_type = 0x41
                state.session_id = session_id
        if data or end:
            self._quic.send_stream_data(stream_id, data, end_stream=end)
        self.transmit()
        return stream_id

    def send_stream(self, stream_id, data, end=False):
        self._quic.send_stream_data(stream_id, data, end_stream=end)
        self.transmit()

    def send_datagram(self, session_id, data):
        self._http.send_datagram(session_id, data)
        self.transmit()

    def close_session(self, session_id, code=0, reason=b""):
        payload = code.to_bytes(4, "big") + reason
        capsule = (encode_uint_var(CLOSE_WEBTRANSPORT_SESSION)
                   + encode_uint_var(len(payload)) + payload)
        self._quic.send_stream_data(session_id, capsule, end_stream=True)
        self.transmit()

    # -- ordinary requests -------------------------------------------------

    async def get(self, path, authority="localhost", timeout=10.0):
        """A plain HTTP/3 GET, for checking what the framework itself serves."""
        stream_id = self._quic.get_next_available_stream_id()
        self._http.send_headers(stream_id=stream_id, headers=[
            (b":method", b"GET"), (b":scheme", b"https"),
            (b":authority", authority.encode()), (b":path", path.encode()),
        ], end_stream=True)
        self.transmit()
        await self.wait_for(lambda: stream_id in self.body_ended, timeout)
        return (self.headers.get(stream_id, {}).get(b":status"),
                self.body.get(stream_id, b""))

    # -- waiting -----------------------------------------------------------

    async def wait_for(self, predicate, timeout=10.0):
        deadline = asyncio.get_event_loop().time() + timeout
        while not predicate():
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                return False
            self._events.clear()
            try:
                await asyncio.wait_for(self._events.wait(), remaining)
            except asyncio.TimeoutError:
                return predicate()
        return True

    async def wait_stream(self, stream_id, timeout=10.0):
        got = await self.wait_for(lambda: stream_id in self.stream_ended, timeout)
        return self.stream_data.get(stream_id, b"") if got else None

    async def wait_datagrams(self, count, timeout=10.0):
        await self.wait_for(lambda: len(self.datagrams) >= count, timeout)
        return list(self.datagrams)

    async def wait_new_stream(self, known, timeout=10.0):
        """Waits for a stream the server opened that we have not seen before."""
        def arrived():
            return any(s not in known for s in self.stream_ended)
        if not await self.wait_for(arrived, timeout):
            return None, None
        new = [s for s in self.stream_ended if s not in known][0]
        return new, self.stream_data.get(new, b"")

    def quic_event_received(self, event):
        for http_event in self._http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                sid = http_event.stream_id
                self.headers[sid] = dict(http_event.headers)
                if sid in self.connected and not self.connected[sid].done():
                    self.connected[sid].set_result(self.headers[sid])
            elif isinstance(http_event, DataReceived):
                sid = http_event.stream_id
                self.body[sid] = self.body.get(sid, b"") + http_event.data
                if http_event.stream_ended:
                    self.body_ended.add(sid)
            elif isinstance(http_event, WebTransportStreamDataReceived):
                sid = http_event.stream_id
                self.stream_data[sid] = self.stream_data.get(sid, b"") + http_event.data
                if http_event.stream_ended:
                    self.stream_ended.add(sid)
            elif isinstance(http_event, DatagramReceived):
                self.datagrams.append(http_event.data)
        self._events.set()


def configuration():
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    # WebTransport datagrams need the QUIC extension underneath them.
    config.max_datagram_frame_size = 65536
    return config


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, timeout=90))


# --------------------------------------------------------------------------


async def settings_and_handshake():
    print("\nSettings and session set-up")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt")
            headers = await client.await_session(session)
            is_("an extended CONNECT is accepted", headers.get(b":status"), b"200")

            settings = client._http.received_settings or {}
            # SETTINGS_ENABLE_CONNECT_PROTOCOL, H3_DATAGRAM,
            # WEBTRANSPORT_MAX_SESSIONS.
            is_("extended CONNECT is advertised", settings.get(0x08), 1)
            is_("HTTP/3 datagrams are advertised", settings.get(0x33), 1)
            check("WebTransport sessions are advertised",
                  settings.get(0xC671706A, 0) >= 1, settings)

            rejected = client.connect_session("/wt-reject")
            headers = await client.await_session(rejected)
            is_("an application may refuse a session", headers.get(b":status"), b"403")

            unknown = client.connect_session("/wt", protocol="flying-carpet")
            headers = await client.await_session(unknown)
            is_("an unknown :protocol is refused", headers.get(b":status"), b"501")


async def streams():
    print("\nStreams")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt")
            await client.await_session(session)

            bidi = client.open_stream(session, data=b"hello", end=True)
            body = await client.wait_stream(bidi)
            is_("a bidirectional stream is echoed on itself", body, b"echo:hello")

            known = set(client.stream_ended)
            client.open_stream(session, unidirectional=True, data=b"uni", end=True)
            new, body = await client.wait_new_stream(known)
            is_("a unidirectional stream is answered on a new one", body, b"echo:uni")
            check("the answer is unidirectional", new is not None and new % 4 == 3, new)

            # Split across several writes, so reassembly and the partial
            # more_data messages are both exercised.
            split = client.open_stream(session, data=b"", end=False)
            for piece in (b"a" * 100, b"b" * 100, b"c" * 100):
                client.send_stream(split, piece)
                await asyncio.sleep(0.02)
            client.send_stream(split, b"", end=True)
            body = await client.wait_stream(split)
            is_("a stream split across writes reassembles", body,
                b"echo:" + b"a" * 100 + b"b" * 100 + b"c" * 100)

            # Several at once, answered independently.
            ids = [client.open_stream(session, data=b"n%d" % i, end=True)
                   for i in range(8)]
            bodies = []
            for sid in ids:
                bodies.append(await client.wait_stream(sid))
            is_("streams are answered independently", bodies,
                [b"echo:n%d" % i for i in range(8)])

            # Large enough to need more than one packet and more than one
            # window extension.
            big = client.open_stream(session, data=b"", end=False)
            client.send_stream(big, b"z" * 400000, end=True)
            body = await client.wait_stream(big, timeout=30)
            is_("a large stream survives flow control",
                (len(body) if body else 0), len(b"echo:") + 400000)

            hold = client.connect_session("/wt-hold")
            await client.await_session(hold)
            client.open_stream(hold, data=b"x" * (2 * 1024 * 1024), end=False)
            fast = client.open_stream(hold, data=b"hello", end=True)
            body = await client.wait_stream(fast, timeout=15)
            is_("an unread stream does not stall the others",
                body, b"echo:hello")


async def aborted_streams():
    """A peer that resets a stream rather than finishing it.

    The two are the same thing to an application -- there is nothing it can do
    about either -- so a reset ends the read. What matters is that it ends it
    at all: a reader left parked on a stream the peer has abandoned is a
    coroutine, a queue and a slot held for as long as the session lives.
    """
    print("\nAborted streams")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt-abort")
            await client.await_session(session)

            known = set(client.stream_ended)
            # Bytes, then a reset instead of a FIN. The application is inside
            # `read()` by the time the reset lands.
            aborted = client.open_stream(session, data=b"half", end=False)
            await asyncio.sleep(0.2)
            client._quic.reset_stream(aborted, 0x01)
            client.transmit()

            new, body = await client.wait_new_stream(known, timeout=10)
            check("a reset ends the read on that stream", new is not None,
                  "the application never got past its read, so the stream it "
                  "answers on was never opened")
            is_("and what arrived before the reset is kept", body, b"ended:half")


async def server_streams():
    print("\nServer-initiated streams")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt-push")
            await client.await_session(session)

            got = await client.wait_for(lambda: len(client.stream_ended) >= 2, 10)
            check("the server opened two streams", got, sorted(client.stream_ended))
            bodies = sorted(client.stream_data[s] for s in client.stream_ended)
            is_("both carry what the application wrote", bodies,
                [b"push-bidi", b"push-uni"])
            kinds = sorted(s % 4 for s in client.stream_ended)
            is_("one is unidirectional and one bidirectional", kinds, [1, 3])


async def datagrams():
    print("\nDatagrams")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt")
            await client.await_session(session)

            client.send_datagram(session, b"ping")
            got = await client.wait_datagrams(1)
            is_("a datagram is echoed", got[:1], [b"echo:ping"])

            for i in range(16):
                client.send_datagram(session, b"n%d" % i)
            got = await client.wait_datagrams(17, timeout=15)
            # Datagrams are unreliable; over loopback none should be lost, but
            # the check that matters is that they are not corrupted or
            # misrouted.
            echoed = set(got[1:])
            check("every datagram comes back intact",
                  echoed <= {b"echo:n%d" % i for i in range(16)} and len(echoed) >= 8,
                  sorted(echoed))

            large = b"q" * 1000
            client.send_datagram(session, large)
            await client.wait_for(lambda: b"echo:" + large in client.datagrams, 10)
            check("a full-size datagram round trips",
                  b"echo:" + large in client.datagrams,
                  [len(d) for d in client.datagrams])


async def closing():
    print("\nClosing")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            # The application closes the session itself.
            session = client.connect_session("/wt-close")
            headers = await client.await_session(session)
            is_("the session is accepted first", headers.get(b":status"), b"200")
            reader = client._quic._streams.get(session)
            got = await client.wait_for(
                lambda: reader is not None and reader.receiver.is_finished, 10)
            check("the application close ends the CONNECT stream", got)

            # The client closes; the connection must survive it.
            second = client.connect_session("/wt")
            await client.await_session(second)
            client.close_session(second, code=3, reason=b"done")
            await asyncio.sleep(0.3)

            third = client.connect_session("/wt")
            headers = await client.await_session(third)
            is_("a further session works on the same connection",
                headers.get(b":status"), b"200")
            bidi = client.open_stream(third, data=b"still here", end=True)
            body = await client.wait_stream(bidi)
            is_("and carries traffic", body, b"echo:still here")


async def alongside_requests():
    print("\nAlongside ordinary requests")
    with Server() as server:
        async with connect("127.0.0.1", server.port, configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt")
            await client.await_session(session)

            # An ordinary request on the same connection, while the session is
            # live. Request streams and session streams differ only in their
            # first varint, so this is the check that they are told apart.
            request = client._quic.get_next_available_stream_id()
            client._http.send_headers(stream_id=request, headers=[
                (b":method", b"GET"), (b":scheme", b"https"),
                (b":authority", b"localhost"), (b":path", b"/"),
            ], end_stream=True)
            client.transmit()
            got = await client.wait_for(lambda: request in client.headers, 10)
            check("a request is answered while a session is open", got)
            is_("with the right status", client.headers.get(request, {}).get(b":status"),
                b"200")

            bidi = client.open_stream(session, data=b"after", end=True)
            body = await client.wait_stream(bidi)
            is_("the session still works afterwards", body, b"echo:after")

            # Two sessions at once, each with its own streams.
            other = client.connect_session("/wt")
            await client.await_session(other)
            a = client.open_stream(session, data=b"one", end=True)
            b = client.open_stream(other, data=b"two", end=True)
            is_("the first session answers its own stream",
                await client.wait_stream(a), b"echo:one")
            is_("the second answers its own", await client.wait_stream(b), b"echo:two")


async def frameworks():
    """The FastAPI and Django integrations, against the real frameworks.

    Neither can route a WebTransport session itself -- both assert on the
    scope type before they look at the path -- so what is being checked is
    that the router in front of them answers sessions while the framework
    still serves everything else.
    """
    print("\nFrameworks")
    try:
        import fastapi                                            # noqa: F401
        import django                                             # noqa: F401
    except ImportError:
        print("  ..   skipped (needs fastapi and django)")
        return

    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(ROOT, "python") + os.pathsep + \
        env.get("PYTHONPATH", "")

    # Django routes are written with a trailing slash, as urlpatterns are;
    # the router keeps each framework's own spelling rather than imposing one.
    for label, app, room in (("fastapi", "fastapi_app:wt", "/wt/room/lobby"),
                             ("django", "django_app:asgi_application",
                              "/wt/room/lobby/")):
        with Server(app=app, env=env) as server:
            async with connect("127.0.0.1", server.port,
                               configuration=configuration(),
                               create_protocol=Client) as client:
                session = client.connect_session("/wt/echo")
                headers = await client.await_session(session)
                is_("%s: a session is accepted" % label,
                    headers.get(b":status"), b"200")

                bidi = client.open_stream(session, data=b"hi", end=True)
                is_("%s: a bidirectional stream is echoed" % label,
                    await client.wait_stream(bidi), b"echo:hi")

                known = set(client.stream_ended)
                client.open_stream(session, unidirectional=True, data=b"uni",
                                   end=True)
                _, body = await client.wait_new_stream(known)
                is_("%s: a unidirectional stream is answered" % label, body,
                    b"echo:uni")

                # A path parameter, in each framework's own spelling.
                known = set(client.stream_ended)
                opened = client.connect_session(room)
                await client.await_session(opened)
                _, body = await client.wait_new_stream(known)
                is_("%s: a path parameter reaches the handler" % label, body,
                    b"welcome to lobby")

                # And the framework still serves ordinary requests, on the
                # same connection the session is on.
                status, _ = await client.get("/")
                is_("%s: ordinary requests still work" % label, status, b"200")

                # The view needs no integration to be reached over HTTP/3; it
                # is the same view, and it says so itself.
                status, body = await client.get("/proto")
                check("%s: a view is served over HTTP/3, and reports it"
                      % label,
                      status == b"200" and b'"http_version"' in body
                      and b'"3"' in body, (status, body))
                check("%s: an HTTP/3 request advertises WebTransport"
                      % label,
                      b'"webtransport": true' in body
                      or b'"webtransport":true' in body,
                      body)

    # Two things only one of the two examples exercises.
    with Server(app="fastapi_app:wt", env=env) as server:
        async with connect("127.0.0.1", server.port,
                           configuration=configuration(),
                           create_protocol=Client) as client:
            session = client.connect_session("/wt/chat")
            await client.await_session(session)
            bidi = client.open_stream(session, data=b"one", end=True)
            is_("fastapi: a class endpoint handles streams",
                await client.wait_stream(bidi), b"chat:one")
            client.send_datagram(session, b"two")
            got = await client.wait_datagrams(1)
            is_("fastapi: and datagrams, concurrently", got[:1], [b"chat:two"])

            rejected = client.connect_session("/wt/reject")
            headers = await client.await_session(rejected)
            is_("fastapi: an endpoint may refuse a session",
                headers.get(b":status"), b"403")

            missing = client.connect_session("/wt/nowhere")
            headers = await client.await_session(missing)
            is_("fastapi: an unrouted path is 404", headers.get(b":status"),
                b"404")

            known = set(client.stream_ended)
            counted = client.connect_session("/wt/n/7")
            await client.await_session(counted)
            _, body = await client.wait_new_stream(known)
            is_("fastapi: a {count:int} converter converts", body, b"n=7")

            slashed = client.connect_session("/wt/echo/")
            headers = await client.await_session(slashed)
            is_("fastapi: a trailing slash still matches",
                headers.get(b":status"), b"200")

    with Server(app="django_app:asgi_application", env=env) as server:
        async with connect("127.0.0.1", server.port,
                           configuration=configuration(),
                           create_protocol=Client) as client:
            known = set(client.stream_ended)
            counted = client.connect_session("/wt/n/42/")
            await client.await_session(counted)
            _, body = await client.wait_new_stream(known)
            is_("django: an <int:> converter converts", body, b"n=42")

            noslash = client.connect_session("/wt/n/42")
            headers = await client.await_session(noslash)
            is_("django: a missing trailing slash still matches",
                headers.get(b":status"), b"200")


class Channel:
    """A `receive`/`send` pair standing in for the server.

    The session helper is a piece of message plumbing, and its races are
    races between the pump and the endpoint -- ordering, not networking. They
    reproduce far more reliably when the messages arrive exactly when the test
    says they do than they would through a real connection.
    """

    def __init__(self, scripted=()):
        self.inbox = asyncio.Queue()
        self.sent = []
        self.on_send = {}
        for message in scripted:
            self.inbox.put_nowait(message)

    async def receive(self):
        return await self.inbox.get()

    async def send(self, message):
        self.sent.append(message)
        reply = self.on_send.get(message["type"])
        if reply is not None:
            reply(message)


SCOPE = {"type": "webtransport", "path": "/probe", "headers": []}


async def session_helper():
    """peregrine.webtransport, driven directly."""
    print("\nThe session helper")
    sys.path.insert(0, os.path.join(ROOT, "python"))
    from peregrine.webtransport import WebTransportSession
    from peregrine.contrib.fastapi import WebTransportEndpoint

    # A stream this endpoint opened, answered before create_stream() is
    # scheduled again. The reply belongs to the stream create_stream()
    # returns, not to a second object with the same id.
    channel = Channel([{"type": "webtransport.connect"}])

    def answer(_):
        channel.inbox.put_nowait({"type": "webtransport.stream.opened",
                                  "stream": 1, "bidirectional": True})
        channel.inbox.put_nowait({"type": "webtransport.stream.receive",
                                  "stream": 1, "data": b"pong",
                                  "more_data": False})

    channel.on_send["webtransport.stream.open"] = answer
    session = WebTransportSession(SCOPE, channel.receive, channel.send)
    await session.accept()
    try:
        stream = await asyncio.wait_for(session.create_stream(), 5)
        body = await asyncio.wait_for(stream.read(), 5)
        is_("a fast reply reaches the stream create_stream returned",
            body, b"pong")
    except asyncio.TimeoutError:
        bad("a fast reply reaches the stream create_stream returned",
            b"pong", "the read blocked")
    check("and it is not announced as a stream the peer opened",
          session._incoming.empty(),
          "%d stream(s) queued" % session._incoming.qsize())
    await session._stop()

    # A stream handler that raises has to end the session, and has to do it
    # when it raises rather than when the next stream arrives.
    channel = Channel([{"type": "webtransport.connect"},
                       {"type": "webtransport.stream.receive", "stream": 0,
                        "data": b"x", "more_data": False}])
    session = WebTransportSession(SCOPE, channel.receive, channel.send)

    class Boom(WebTransportEndpoint):
        async def on_stream(self, stream):
            raise RuntimeError("the handler failed")

    try:
        await asyncio.wait_for(Boom(session).dispatch(), 5)
        bad("a failing stream handler ends the endpoint", "no exception",
            "RuntimeError")
    except RuntimeError as error:
        is_("a failing stream handler ends the endpoint", str(error),
            "the handler failed")
    except asyncio.TimeoutError:
        bad("a failing stream handler ends the endpoint",
            "the endpoint kept running", "RuntimeError")
    await session._stop()

    # What arrived before the peer went away is still worth reading.
    channel = Channel([{"type": "webtransport.connect"},
                       {"type": "webtransport.datagram.receive",
                        "data": b"last"},
                       {"type": "webtransport.disconnect", "code": 7,
                        "reason": "done"}])
    session = WebTransportSession(SCOPE, channel.receive, channel.send)
    await session.accept()
    for _ in range(20):                       # let the pump reach the end
        if session.closed:
            break
        await asyncio.sleep(0)
    check("a disconnect closes the session", session.closed)
    try:
        is_("a datagram queued before it is still readable",
            await asyncio.wait_for(session.receive_datagram(), 5), b"last")
        is_("and then the iterator ends rather than raising",
            await asyncio.wait_for(session.receive_datagram(), 5), None)
        is_("accept_stream ends the same way",
            await asyncio.wait_for(session.accept_stream(), 5), None)
    except Exception as error:
        bad("a datagram queued before a disconnect is still readable",
            b"last", "%s: %s" % (type(error).__name__, error))
    await session._stop()


def main():
    import contrib_test
    contrib_test.run_all(ok, is_, check, bad)
    run(session_helper())

    if not os.path.exists(BIN):
        sys.stderr.write("no peregrine binary at %s\n" % BIN)
        print("\n%d passed, %d failed (server tests skipped)" % (PASS, FAIL))
        return 2
    if make_certs() == (None, None):
        sys.stderr.write("openssl is needed to generate a test certificate\n")
        return 2

    run(settings_and_handshake())
    run(streams())
    run(aborted_streams())
    run(server_streams())
    run(datagrams())
    run(closing())
    run(alongside_requests())
    run(frameworks())

    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())

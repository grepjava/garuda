#!/usr/bin/env python3
"""Router routes over HTTP/2 and HTTP/3, against independent clients.

    <venv>/bin/python scripts/router-streams-test.py [path-to-garuda]

The router answers at the dispatch seam whatever the protocol. What this checks
is that a stream gets the answers a connection does -- a body where the route
has one, a delay that waits on its timer -- and that a stream abandoned while
it waits leaves nothing behind: no late response, no slot, no timer. The
clients are the `h2` library and aioquic, which share no code with the server.

Needs `h2` and `aioquic` in the interpreter running it:  pip install h2 aioquic
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
    import h2.config
    import h2.connection
    import h2.errors
    import h2.events
    from aioquic.asyncio.client import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
except ImportError:
    sys.stderr.write("this script needs h2 and aioquic: pip install h2 aioquic\n")
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "garuda")

# H3_REQUEST_CANCELLED, RFC 9114 section 8.1.
H3_REQUEST_CANCELLED = 0x10C

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
    directory = tempfile.mkdtemp(prefix="garuda-router-")
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
    # One port serves TLS over TCP and QUIC over UDP, so it has to be free for
    # both.
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
        cmd = [BIN, "--port", str(self.port), "--log-level", "error", "--http3",
               "--tls-cert", cert, "--tls-key", key] + list(args)
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

    def alive(self):
        return self.proc.poll() is None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(5)


def waited(client, stream):
    return client.ended.get(stream, float("inf")) - client.started[stream]


# -------------------------------------------------------------------- HTTP/2


class H2Client:
    """The h2 state machine over one TLS socket, recording when each stream ends."""

    def __init__(self, server, timeout=15.0):
        sock = socket.create_connection(("127.0.0.1", server.port), timeout)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["h2"])
        self.sock = context.wrap_socket(sock, server_hostname="localhost")
        if self.sock.selected_alpn_protocol() != "h2":
            raise SystemExit("ALPN did not settle on h2")
        self.conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True))
        self.conn.initiate_connection()
        self.flush()
        self.port = server.port
        self.status, self.headers, self.body = {}, {}, {}
        self.started, self.ended, self.reset = {}, {}, {}

    def flush(self):
        data = self.conn.data_to_send()
        if data:
            self.sock.sendall(data)

    def request(self, method, path, body=None):
        headers = [(":method", method), (":scheme", "https"),
                   (":authority", "localhost:%d" % self.port), (":path", path)]
        if body is not None:
            headers.append(("content-length", str(len(body))))
        stream = self.conn.get_next_available_stream_id()
        self.conn.send_headers(stream, headers, end_stream=body is None)
        if body is not None:
            self.conn.send_data(stream, body, end_stream=True)
        self.flush()
        self.started[stream] = time.monotonic()
        return stream

    def cancel(self, stream):
        self.conn.reset_stream(stream, error_code=h2.errors.ErrorCodes.CANCEL)
        self.flush()

    def step(self, timeout=0.2):
        """Reads what is available. False once the server has closed."""
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(65536)
        except (socket.timeout, TimeoutError, ssl.SSLWantReadError):
            return True
        if not data:
            return False
        now = time.monotonic()
        for event in self.conn.receive_data(data):
            if isinstance(event, h2.events.ResponseReceived):
                fields = dict(event.headers)
                self.headers[event.stream_id] = fields
                self.status[event.stream_id] = int(fields[b":status"])
            elif isinstance(event, h2.events.DataReceived):
                self.body[event.stream_id] = self.body.get(event.stream_id, b"") + event.data
                self.conn.acknowledge_received_data(event.flow_controlled_length,
                                                    event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                self.ended[event.stream_id] = now
            elif isinstance(event, h2.events.StreamReset):
                self.ended[event.stream_id] = now
                self.reset[event.stream_id] = event.error_code
        self.flush()
        return True

    def collect(self, streams, deadline=15.0):
        limit = time.monotonic() + deadline
        while not set(streams) <= set(self.ended) and time.monotonic() < limit:
            if not self.step():
                break

    def wait(self, seconds):
        """Keeps reading for a while, so anything the server sends is seen."""
        limit = time.monotonic() + seconds
        while time.monotonic() < limit:
            if not self.step(max(0.01, min(0.2, limit - time.monotonic()))):
                break

    def close(self):
        try:
            self.conn.close_connection()
            self.flush()
        except Exception:
            pass
        self.sock.close()

    def drop(self):
        """Hangs up without a GOAWAY, as a client that goes away does."""
        self.sock.close()


def h2_routes():
    print("\nHTTP/2: routes")
    with Server() as server:
        client = H2Client(server)
        root = client.request("GET", "/")
        user = client.request("GET", "/user/42")
        create = client.request("POST", "/user", body=b"name=garuda")
        missing = client.request("GET", "/nope")
        client.collect([root, user, create, missing])
        is_("GET / is 200", client.status.get(root), 200)
        is_("GET / has no body", client.body.get(root, b""), b"")
        is_("GET /user/42 is 200", client.status.get(user), 200)
        is_("GET /user/42 carries the id", client.body.get(user, b""), b"42")
        is_("and declares its length", client.headers.get(user, {}).get(b"content-length"), b"2")
        is_("the server names itself", client.headers.get(user, {}).get(b"server"), b"garuda")
        is_("POST /user is 200", client.status.get(create), 200)
        is_("an unknown path is 404", client.status.get(missing), 404)
        client.close()


def h2_delays():
    print("\nHTTP/2: delays")
    with Server() as server:
        client = H2Client(server)
        slow = client.request("GET", "/delay/600")
        fast = client.request("GET", "/delay/200")
        user = client.request("GET", "/user/7")
        client.collect([slow, fast, user])
        is_("every stream is answered 200",
            [client.status.get(s) for s in (slow, fast, user)], [200, 200, 200])
        check("/delay/200 waits at least 200 ms", waited(client, fast) >= 0.2, waited(client, fast))
        check("/delay/600 waits at least 600 ms", waited(client, slow) >= 0.6, waited(client, slow))
        check("a delay does not hold up the request beside it",
              client.ended.get(user, float("inf")) < client.ended.get(fast, float("inf")))
        check("the shorter delay finishes first",
              client.ended.get(fast, float("inf")) < client.ended.get(slow, float("inf")))

        streams = [client.request("GET", "/delay/100") for _ in range(50)]
        client.collect(streams)
        is_("fifty delays on one connection all answer 200",
            [client.status.get(s) for s in streams], [200] * 50)
        client.close()


def h2_cancellation():
    print("\nHTTP/2: cancellation")
    with Server() as server:
        client = H2Client(server)
        doomed = client.request("GET", "/delay/1000")
        client.wait(0.1)
        client.cancel(doomed)
        after = client.request("GET", "/user/9")
        client.collect([after])
        is_("the connection serves on after a cancelled delay", client.body.get(after), b"9")
        client.wait(1.3)
        check("the cancelled delay never answers", doomed not in client.status,
              client.status.get(doomed))
        again = client.request("GET", "/")
        client.collect([again])
        is_("nor does its timer disturb the connection", client.status.get(again), 200)
        client.close()


def h2_abandoned():
    print("\nHTTP/2: abandoned delays")
    # The connection and each stream take a slot, and each delay an op, from
    # pools of 64. Twelve rounds of forty would exhaust a leaking server many
    # times over. Half the rounds hang up just as their timers fire.
    with Server("--max-connections", "64") as server:
        for round_ in range(12):
            client = H2Client(server)
            delay = 3000 if round_ % 2 else 150
            for _ in range(40):
                client.request("GET", "/delay/%d" % delay)
            client.wait(0.15)
            client.drop()
            time.sleep(0.2)
        time.sleep(0.5)
        client = H2Client(server)
        streams = [client.request("GET", "/delay/100") for _ in range(40)]
        client.collect(streams)
        is_("a fresh connection's delays all answer 200",
            [client.status.get(s) for s in streams], [200] * 40)
        client.close()
        check("the server is still running", server.alive())


# -------------------------------------------------------------------- HTTP/3


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self.status, self.headers, self.body = {}, {}, {}
        self.started, self.ended = {}, {}
        self._done = {}

    def request(self, method, path, body=None):
        stream = self._quic.get_next_available_stream_id()
        block = [(b":method", method.encode()), (b":scheme", b"https"),
                 (b":authority", b"localhost"), (b":path", path.encode())]
        if body is not None:
            block.append((b"content-length", str(len(body)).encode()))
        self._http.send_headers(stream_id=stream, headers=block, end_stream=body is None)
        if body is not None:
            self._http.send_data(stream_id=stream, data=body, end_stream=True)
        self.started[stream] = time.monotonic()
        self._done[stream] = asyncio.get_running_loop().create_future()
        self.transmit()
        return stream

    def extended_connect(self, path, protocol):
        """Opens an extended CONNECT stream, left open as a session would be."""
        stream = self._quic.get_next_available_stream_id()
        block = [(b":method", b"CONNECT"), (b":protocol", protocol.encode()),
                 (b":scheme", b"https"), (b":authority", b"localhost"),
                 (b":path", path.encode())]
        self._http.send_headers(stream_id=stream, headers=block, end_stream=False)
        self.started[stream] = time.monotonic()
        self._done[stream] = asyncio.get_running_loop().create_future()
        self.transmit()
        return stream

    def cancel(self, stream):
        self._quic.reset_stream(stream, H3_REQUEST_CANCELLED)
        self.transmit()

    async def collect(self, streams, timeout=15.0):
        try:
            await asyncio.wait_for(
                asyncio.gather(*(asyncio.shield(self._done[s]) for s in streams)), timeout)
        except asyncio.TimeoutError:
            pass

    def quic_event_received(self, event):
        for http_event in self._http.handle_event(event):
            if not isinstance(http_event, (HeadersReceived, DataReceived)):
                continue
            stream = http_event.stream_id
            if isinstance(http_event, HeadersReceived):
                fields = {}
                for name, value in http_event.headers:
                    if name == b":status":
                        self.status[stream] = int(value)
                    else:
                        fields[name] = value
                self.headers[stream] = fields
            else:
                self.body[stream] = self.body.get(stream, b"") + http_event.data
            if http_event.stream_ended:
                self.ended[stream] = time.monotonic()
                done = self._done.get(stream)
                if done is not None and not done.done():
                    done.set_result(None)


def configuration():
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    return config


def h3_connect(server):
    return connect("127.0.0.1", server.port, configuration=configuration(),
                   create_protocol=H3Client)


async def h3_routes():
    print("\nHTTP/3: routes")
    with Server() as server:
        async with h3_connect(server) as client:
            root = client.request("GET", "/")
            user = client.request("GET", "/user/42")
            create = client.request("POST", "/user", body=b"name=garuda")
            missing = client.request("GET", "/nope")
            await client.collect([root, user, create, missing])
            is_("GET / is 200", client.status.get(root), 200)
            is_("GET / has no body", client.body.get(root, b""), b"")
            is_("GET /user/42 is 200", client.status.get(user), 200)
            is_("GET /user/42 carries the id", client.body.get(user, b""), b"42")
            is_("and declares its length",
                client.headers.get(user, {}).get(b"content-length"), b"2")
            is_("the server names itself", client.headers.get(user, {}).get(b"server"), b"garuda")
            is_("POST /user is 200", client.status.get(create), 200)
            is_("an unknown path is 404", client.status.get(missing), 404)


async def h3_delays():
    print("\nHTTP/3: delays")
    with Server() as server:
        async with h3_connect(server) as client:
            slow = client.request("GET", "/delay/600")
            fast = client.request("GET", "/delay/200")
            user = client.request("GET", "/user/7")
            await client.collect([slow, fast, user])
            is_("every stream is answered 200",
                [client.status.get(s) for s in (slow, fast, user)], [200, 200, 200])
            check("/delay/200 waits at least 200 ms", waited(client, fast) >= 0.2,
                  waited(client, fast))
            check("/delay/600 waits at least 600 ms", waited(client, slow) >= 0.6,
                  waited(client, slow))
            check("a delay does not hold up the request beside it",
                  client.ended.get(user, float("inf")) < client.ended.get(fast, float("inf")))
            check("the shorter delay finishes first",
                  client.ended.get(fast, float("inf")) < client.ended.get(slow, float("inf")))

            streams = [client.request("GET", "/delay/100") for _ in range(50)]
            await client.collect(streams)
            is_("fifty delays on one connection all answer 200",
                [client.status.get(s) for s in streams], [200] * 50)


async def h3_cancellation():
    print("\nHTTP/3: cancellation")
    with Server() as server:
        async with h3_connect(server) as client:
            doomed = client.request("GET", "/delay/1000")
            await asyncio.sleep(0.1)
            client.cancel(doomed)
            after = client.request("GET", "/user/9")
            await client.collect([after])
            is_("the connection serves on after a cancelled delay", client.body.get(after), b"9")
            await asyncio.sleep(1.3)
            check("the cancelled delay never answers", doomed not in client.status,
                  client.status.get(doomed))
            again = client.request("GET", "/")
            await client.collect([again])
            is_("nor does its timer disturb the connection", client.status.get(again), 200)


async def h3_extended_connect():
    print("\nHTTP/3: extended CONNECT")
    # Nothing serves a :protocol. A CONNECT stream stays open by design, so a
    # refusal that waited for the end of the request would never be sent.
    with Server() as server:
        async with h3_connect(server) as client:
            session = client.extended_connect("/wt", "webtransport")
            unknown = client.extended_connect("/x", "unknown-protocol")
            await client.collect([session, unknown], timeout=5.0)
            is_("a WebTransport CONNECT is refused with 501", client.status.get(session), 501)
            is_("so is an unknown :protocol", client.status.get(unknown), 501)
            after = client.request("GET", "/user/5")
            await client.collect([after])
            is_("and the connection serves on", client.body.get(after), b"5")


async def h3_abandoned():
    print("\nHTTP/3: abandoned delays")
    with Server("--max-connections", "64") as server:
        for round_ in range(12):
            delay = 3000 if round_ % 2 else 150
            async with h3_connect(server) as client:
                for _ in range(40):
                    client.request("GET", "/delay/%d" % delay)
                await asyncio.sleep(0.15)
            await asyncio.sleep(0.2)
        await asyncio.sleep(0.5)
        async with h3_connect(server) as client:
            streams = [client.request("GET", "/delay/100") for _ in range(40)]
            await client.collect(streams)
            is_("a fresh connection's delays all answer 200",
                [client.status.get(s) for s in streams], [200] * 40)
        check("the server is still running", server.alive())


def run(coro):
    asyncio.run(asyncio.wait_for(coro, timeout=120))


def main():
    if not os.path.exists(BIN):
        raise SystemExit("no server binary at %s" % BIN)
    h2_routes()
    h2_delays()
    h2_cancellation()
    h2_abandoned()
    run(h3_routes())
    run(h3_delays())
    run(h3_cancellation())
    run(h3_extended_connect())
    run(h3_abandoned())
    print("\n%d passed, %d failed" % (PASS, FAIL))
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

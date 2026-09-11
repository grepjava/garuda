<p align="center">
  <img src="assets/peregrine-impact.png" alt="peregrine" width="360">
</p>

# Transports

Peregrine speaks HTTP/1.1, HTTP/2, HTTP/3, WebSocket and WebTransport. This
document is about what each of those is, what Peregrine implements of it, and
where the implementations disagree with the obvious approach and why.

The architecture underneath — the connection table, the process model, the
asyncio integration — is in [ARCHITECTURE.md](ARCHITECTURE.md).

| | HTTP/1.1 | HTTP/2 | HTTP/3 | WebSocket | WebTransport |
| --- | --- | --- | --- | --- | --- |
| ASGI | ✓ | ✓ | ✓ | ✓ | ✓ |
| WSGI | ✓ | ✓ | ✓ | 501 | 501 |

WebSockets and WebTransport are refused for WSGI rather than half-served: both
are streams that outlive their response, and PEP 3333 has no way to express
one. Everything else is the same server for both, which is the point of the
next section.

---

## One request path

HTTP/2 and HTTP/3 do not change what a request is. They change how it is
framed, how many can share a connection, and how the head is encoded. So
Peregrine keeps one request path and makes the transports agree with it rather
than the other way round.

**A connection is a slot in the connection table.** For HTTP/1.1 that slot owns
a socket. For HTTP/2 it owns a socket, the HPACK tables and the connection
window. For HTTP/3 it owns no descriptor at all — the socket belongs to the
QUIC listener — and the slot exists so a QUIC connection can be a connection
like any other.

**A request is also a slot.** Every HTTP/2 and HTTP/3 stream takes one from the
same table, with `fd` set to `-1` and a pointer back to its connection. A
stream slot has a head, a body buffer, a write buffer, a task and a
Content-Length budget, so ASGI dispatch, request-body streaming, write
backpressure and disconnect delivery work on a stream exactly as they work on a
connection. Three things know the difference: writing (bytes become frames on
the parent instead of going to a socket), read interest (a stream has no
descriptor of its own), and teardown.

**The head is rebuilt as HTTP/1.1 text and re-parsed.** An HTTP/2 or HTTP/3
request arrives as pseudo-headers and a compressed field section; it is
rendered back into `GET /path HTTP/1.1\r\nhost: ...` and handed to the ordinary
parser. That costs a copy and a parse per request. In exchange the scope
builder, the environ builder, the trusted-proxy logic and the access log keep
working on the representation they were written for, rather than growing a
second one — and a bug fixed in one is fixed in all three.

The response side is the mirror image, and it is where WSGI needed work: see
[WSGI on a multiplexed stream](#wsgi-on-a-multiplexed-stream).

---

## HTTP/1.1

Keep-alive, pipelining, chunked transfer in both directions, `Expect:
100-continue`, `HEAD`, and the statuses that forbid a body.

The parser produces `(offset, length)` pairs into the read buffer and never
allocates a `String`. Character-class membership (`tchar`, field-value bytes)
is two 64-bit shifts rather than a table lookup, so the inner loops touch no
memory beyond the request itself.

### Framing is enforced, not trusted

A declared `Content-Length` is a promise to the client and to every
intermediary between here and it. Both ways of breaking it are handled:

- an application that sends **more** than it promised has the excess dropped
  rather than written, because those bytes would be read as the start of the
  next response on a keep-alive connection;
- one that sends **less** has the connection closed rather than leaving the
  client waiting on bytes that are not coming.

Either way the application is told it has a bug, and the connection is not
reused. This holds for ASGI and for WSGI in both of its execution modes, and on
a WSGI response it covers the returned iterable and the legacy `write()`
callable alike — between them they produce one message, so they are accounted
against one budget. `write()` is told directly, by an exception at the call that
went too far; everywhere else it is a log line, because there is nothing left
running to tell. On a multiplexed stream, where there is no connection to close,
a short message ends as a reset rather than as a clean end of stream.

### Strictness that prevents smuggling

The parser is deliberately unforgiving wherever leniency would let two
implementations disagree about where a message ends:

- whitespace between a header name and its colon is rejected;
- `Content-Length` together with `Transfer-Encoding` is rejected;
- two disagreeing `Content-Length` values are rejected;
- `Transfer-Encoding` is parsed as the comma-separated coding list it is, and
  only a bare `chunked` frames a body. `xchunked` is not `chunked`, and neither
  is `chunked;x=1`; a list whose last coding is not `chunked` cannot be framed
  at all and is a 400 (RFC 9112 6.3), while `gzip, chunked` — framable, but
  under a coding this server cannot remove — is a 501 (RFC 9112 6.1). A second
  `Transfer-Encoding` field continues the same list, so it means the first
  field's coding was not the final one: also a 400;
- `obs-fold` continuation lines are rejected rather than unfolded;
- HTTP/1.1 without `Host` is a 400, and so is a second `Host`, whether or not
  the two agree (RFC 9112 3.2);
- the chunked trailer section is bounded by `--max-header-size`, the same limit
  the header section at the front of the message gets. Trailers decode to no
  body, so `--max-body` never grows while they arrive, and without a ceiling of
  their own a peer could stream them for as long as it liked and hold a
  connection, a slot and a read buffer for free. Past the limit the request is
  a 431.

On the response side, an application header containing CR or LF is refused
outright — the classic response-splitting hole. On the request side, header
names containing underscores are dropped (they would otherwise collide with the
dash-to-underscore environ mapping and let a client forge `X-Real-IP`), and a
`Proxy:` header is dropped entirely (httpoxy).

---

## TLS

```bash
peregrine --tls-cert fullchain.pem --tls-key privkey.pem myapp:app
```

OpenSSL is handed the descriptor directly, so a TLS connection is the same
connection as any other — same slab slot, same poller interest, same buffers,
same state machine — and the read and write wrappers report `EAGAIN` the way a
socket does, which is what keeps that true.

Two things about TLS cannot be wrapped away, and both are handled explicitly:
the handshake happens before any request exists and can want readability *or*
writability at each step, and a record is decrypted whole, so OpenSSL can be
holding bytes the socket no longer has — which a level-triggered poller will
never mention again.

**ALPN** is what makes HTTP/2 reachable from a browser, and it is where the
protocol is settled: `h2` if the client offers it, `http/1.1` otherwise, in the
server's order of preference rather than the client's. `--no-http2` and
`--http2-only` narrow the advertised list to match. A TLS listener also reports
`https` to the application, so URLs it builds are right without being told.

TLS 1.2 is the floor, renegotiation is off, and `--tls-ciphers` takes an
OpenSSL cipher list for anyone who needs to narrow the 1.2 suites. Certificates
are checked once at start-up rather than discovered to be unreadable inside
each worker.

---

## HTTP/2

Cleartext HTTP/2 is served to any client that opens with the connection
preface — `curl --http2-prior-knowledge`, a gRPC client, or a proxy configured
to talk h2c upstream. The same port still answers HTTP/1.1, because the preface
is recognised in full before anything is assumed. `--http2-only` drops the
HTTP/1 fallback for ports that only ever carry h2c, and `--no-http2` turns the
whole thing off.

The upgrade dance from RFC 7540 is deliberately absent: RFC 9113 removed it, no
browser ever used it, and prior knowledge covers every cleartext client that
exists.

### HPACK

A full implementation — static and dynamic tables, Huffman in both directions,
the eviction rules — checked against every example in RFC 7541 appendix C. The
Huffman table is generated from the RFC, and a unit test re-derives all 257
codes from their lengths alone, so a transcription error could not survive the
build.

Decoding hands out borrowed pointers rather than objects, and the dynamic table
is a FIFO of descriptors over an append-only arena, so a compressed header
block costs a memcpy per field and no allocations.

The encoder never uses incremental indexing. Mirroring the peer's table would
save a few bytes on responses whose headers barely repeat, and Huffman coding
of literals gets most of it for none of the bookkeeping.

### Flow control

Real in both directions. A response is held in the stream buffer until the
peer's window allows it, which is what makes `await send()` apply backpressure
on a multiplexed connection; the window is only given back as the application
actually reads the request body, so an upload nobody is consuming stops rather
than filling memory.

### Cancellation has a budget

`RST_STREAM` frees a stream slot at once, so a limit on concurrent streams is
by construction no defence against a peer that opens a stream and cancels it in
the same breath: the count never rises, while the server still decodes a header
block, builds a request and starts an application task for every one. That is
CVE-2023-44487, the rapid reset.

Cancelling is legitimate — a browser does it whenever a user navigates away —
so what is bounded here is not the count but the ratio. A connection starts
with an allowance of twice the concurrent-stream limit it advertises (256),
every cancelled stream that was never answered spends one, and every stream the
server does answer earns one back. A client that cancels among requests it also
completes never comes near it; one that only ever cancels spends the allowance
and is sent `GOAWAY(ENHANCE_YOUR_CALM)`. A reset that arrives after the
response was already finished is a race rather than an attack, and costs
nothing.

HTTP/3 keeps the same account for the same reason. QUIC has no `RST_STREAM`
frame, but closing a stream queues `MAX_STREAMS`, and a credit handed back is a
credit handed back whatever it is called; a peer that resets every stream it
opens holds one at a time and keeps a worker decoding headers indefinitely. The
cancellation is dearer to send than HTTP/2's — a packet of its own rather than
eight bytes trailing the request — but dearer is not bounded, so `RESET_STREAM`
and `STOP_SENDING` on a request stream spend from the same allowance, and a
peer that exhausts it is closed with `H3_EXCESSIVE_LOAD`.

### A stream measures its own progress

`--request-timeout` asks whether a request has stalled, and on HTTP/1 the
answer comes from the poller: every readable or writable event on the socket is
progress, so a slow-but-moving transfer is never mistaken for a stuck one.

A stream has no socket, so it has no events to be refreshed by, and it records
the bytes that move on it instead — DATA in, DATA out. Without that the timeout
would stop asking whether the request is stalled and start capping how long it
may take, which for an upload over a thin link is a different question with a
much worse answer. A window the peer never opens is still a stall, and still
times out: nothing is written in that case, so nothing is recorded.

Conformance is checked with [h2spec](https://github.com/summerwind/h2spec):
**146/146 over TLS**, for ASGI and WSGI alike.

---

## HTTP/3 and QUIC

```bash
peregrine --http3 --tls-cert fullchain.pem --tls-key privkey.pem myapp:app
```

The QUIC stack is Peregrine's own: packets, loss recovery, congestion control,
streams, flow control, key update, and a TLS 1.3 handshake. OpenSSL supplies
primitives and nothing else — hash, HKDF, AEAD, key agreement, signature —
because QUIC replaces the TLS record layer outright and `SSL_*` has no way to
be used without it.

Written from scratch, so it is checked against things that share none of it:
the packet protection reproduces RFC 9001 appendix A byte for byte, the
handshake and the HTTP/3 layer are driven by `aioquic` in
`scripts/http3-test.py`, and the QPACK static table is generated by reading
each entry back out of an independent implementation rather than transcribed.

What is implemented, and what each part is for:

| | |
| --- | --- |
| RFC 9000 | packets, frames, streams, flow control, connection IDs, the 3× anti-amplification limit |
| RFC 9001 | packet protection, header protection, key update |
| RFC 9002 | loss detection by packet ordering and by time, NewReno congestion control, PTO |
| RFC 9114 | HTTP/3 frames, control and QPACK streams, extended CONNECT |
| RFC 9204 | QPACK, static table and Huffman |
| RFC 9221 | unreliable datagrams |
| RFC 9297 | HTTP datagrams and the capsule protocol |

### QPACK advertises a dynamic table capacity of zero

That is a promise rather than a shortcut. It says no header block on this
connection can ever wait for another stream — which is the head-of-line
blocking HTTP/3 exists to remove. Encoding uses the static table and Huffman
literals, which is where nearly all of the saving was anyway.

### One socket per worker

One UDP socket serves every client, bound with `SO_REUSEPORT` so the kernel
hashes datagrams to workers by four-tuple. A connection is identified by its
connection ID rather than by the four-tuple, so a client that changes address
keeps its connection; a client that migrates to an address hashing to a
*different worker* reaches one that has never heard of it, and recovers by
making a new connection.

### Alt-Svc

A client cannot discover HTTP/3 by trying. There is no upgrade, no well-known
port, and nothing in a TCP response that implies a UDP one, so it has to be
told on a connection it already has. With `--http3`, every response served over
TCP — HTTP/1.1 and HTTP/2, WSGI and ASGI alike — carries

```
alt-svc: h3=":443"; ma=86400
```

naming the UDP port, which is `--quic-port` when it differs from the TCP one.
The header is advisory (RFC 7838): a client that ignores it stays where it is.
An application that sets its own `alt-svc` keeps it, and the server adds nothing
beside it. A response already travelling over HTTP/3 does not carry it, because
there is nothing left to discover.

---

## WebSocket

The full connect / accept / receive / send / close cycle, subprotocol
negotiation, extra handshake headers, fragmented messages, text and binary,
keepalive ping/pong with a dead-peer timeout, and a message size limit.

**Frames are decoded as they arrive** rather than when the application next
calls `receive()`. That matters more than it sounds: a push-only endpoint, or
one merely busy between receives, would otherwise leave pings unanswered and
never see the pong for the server's own keepalive ping — so the server would
eventually close a connection that was working perfectly.

Data messages therefore queue, bounded by `--ws-max-queue` and
`--ws-max-queue-bytes`, and the read side switches off at the bound so a slow
application becomes TCP backpressure rather than memory.

The framing is strict where leniency would let a peer desynchronise the stream:
an unmasked client frame, a set reserved bit, an unknown opcode, a fragmented
or oversized control frame, an invalid close code and non-UTF-8 text are each a
protocol failure with the close code RFC 6455 prescribes.

WebSocket over HTTP/2 and HTTP/3 (RFC 8441 / RFC 9220) is not implemented.
HTTP/3 advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL` because that is how
WebTransport arrives; `webtransport` is the only `:protocol` served. HTTP/2
does not advertise it — nothing here would answer an extended CONNECT on that
connection.

---

## WebTransport

WebTransport over HTTP/3 (draft-ietf-webtrans-http3) is an extended `CONNECT`
with `:protocol: webtransport` that never finishes, carrying streams and
unreliable datagrams that name their session by the identifier of the CONNECT
stream they belong to.

So a session is a router, not a connection:

- a peer **unidirectional** stream whose first varint is `0x54`, followed by a
  session identifier, belongs to that session;
- a peer **bidirectional** stream whose first varint is `0x41`
  (`WEBTRANSPORT_STREAM`), likewise — and because a request stream begins with
  a frame type instead, the two are told apart by that first varint alone;
- a **datagram** begins with the session's *quarter* stream identifier, which
  is how RFC 9297 fits a 62-bit stream id into as few bytes as possible.

The close capsule (`CLOSE_WEBTRANSPORT_SESSION`) works in both directions.

Session streams get no slot in the connection table. A slot carries a request
head, a parser and a body buffer, and a WebTransport stream wants none of that:
it is a byte pipe, read straight out of the QUIC receive buffer so that bulk
data is copied once into a Python `bytes` and not before.

### The ASGI extension

ASGI has no WebTransport specification, so this one is Peregrine's. It is
announced the way the specification says a server extension should be, in
`scope["extensions"]["webtransport"]`, and `scope["type"]` is `"webtransport"`.

`receive()` produces:

| message | fields |
| --- | --- |
| `webtransport.connect` | — |
| `webtransport.stream.opened` | `stream`, `bidirectional` |
| `webtransport.stream.receive` | `stream`, `data`, `more_data` |
| `webtransport.datagram.receive` | `data` |
| `webtransport.disconnect` | `code`, `reason` |

`send()` accepts:

| message | fields |
| --- | --- |
| `webtransport.accept` | `headers` (optional) |
| `webtransport.close` | `code`, `reason` |
| `webtransport.stream.open` | `bidirectional` |
| `webtransport.stream.send` | `stream`, `data`, `end_stream` |
| `webtransport.stream.pause` | `stream` |
| `webtransport.stream.resume` | `stream` |
| `webtransport.datagram.send` | `data` |

```python
async def app(scope, receive, send):
    assert scope["type"] == "webtransport"
    assert (await receive())["type"] == "webtransport.connect"
    await send({"type": "webtransport.accept"})
    while True:
        message = await receive()
        if message["type"] == "webtransport.disconnect":
            return
        if message["type"] == "webtransport.stream.receive" \
                and not message["more_data"]:
            await send({"type": "webtransport.stream.send",
                        "stream": message["stream"],
                        "data": b"got it", "end_stream": True})
```

Three details worth knowing:

- **`more_data` is false on the last message for a stream** whether the peer
  finished it or reset it. Either way nothing more is coming, which is the only
  thing an application can act on.
- **A stream the application opens is answered with
  `webtransport.stream.opened`** rather than by a return value, because ASGI's
  `send()` returns nothing. They arrive in the order they were asked for.
- **Backpressure is the transport's, per stream.** `webtransport.stream.pause`
  stops delivering one stream: its bytes stay in the QUIC receive buffer and
  its window does not reopen. `resume` starts it again. The session's
  `receive()` FIFO is not paused, so every other stream and every datagram
  still move. `await send()` waits when the session has more queued than
  acknowledged.

Before accept, `webtransport.close` refuses the session with an HTTP status: a
code in 400–599 is used as one, anything else becomes 403.

### Frameworks

That extension is a message protocol, and writing against it directly is fine.
What no framework can do unaided is *route* to it: a session is not a request,
so it arrives with `scope["type"] == "webtransport"`, and every ASGI framework
asserts on that field before it looks at the path. Starlette's router allows
`http`, `websocket` and `lifespan`; Django's handler allows `http` alone.

So `peregrine.contrib` puts a router in front, which answers sessions itself
and hands everything else to the framework unchanged.

```python
from fastapi import FastAPI
from peregrine.contrib.fastapi import WebTransportRouter

api = FastAPI()
app = WebTransportRouter(api)            # serve this one

@app.route("/chat/{room}")
async def chat(session):
    await session.accept()
    room = session.path_params["room"]
    async for stream in session.incoming_streams():
        await stream.send(b"welcome to " + room.encode(), end=True)
```

```python
# Django asgi.py
from django.core.asgi import get_asgi_application
from peregrine.contrib.django import WebTransportRouter

application = WebTransportRouter(get_asgi_application())

@application.route("chat/<str:room>/")
async def chat(session):
    await session.accept()
    ...
```

Paths keep each framework's own spelling — `{room}` and `{count:int}` for
Starlette, Django's `<str:room>` and `<int:count>` converters for Django. A
missing or extra trailing slash is tried the other way: a session cannot be
HTTP-redirected.

`peregrine.webtransport.WebTransportSession` is what those hand the endpoint,
and it is framework-agnostic: it demultiplexes the one ASGI `receive()` channel
into streams, datagrams and the answers to stream-open requests, so an endpoint
reads a stream as an async iterator rather than running its own state machine.
A full stream queue pauses that stream at the server rather than stopping the
pump. Datagrams drop the oldest when their queue is full, matching the server.
The queues are bounds, not buffers.

FastAPI also gets `WebTransportEndpoint`, the class-based form that mirrors
Starlette's `WebSocketEndpoint`, with `on_connect` / `on_stream` / `on_datagram`
/ `on_disconnect`; streams and datagrams are dispatched concurrently.

**HTTP/3 needs no integration at all.** A request is the same request whatever
carried it, and `request.is_secure()`, `request.scheme` and `REMOTE_ADDR` are
right over QUIC without either framework being told. `http_version(request)`
and `is_http3(request)` are provided for applications that want to know, and
`AltSvcMiddleware` for the case where HTTP/3 lives somewhere this process
cannot see — a terminating proxy, or a different port.

Channels composes with the router rather than competing with it, and for the
same reason it exists: Django serves `http`, Channels serves `websocket`, this
serves `webtransport`, each layer owning exactly the scope types the one
beneath it refuses. [CONFIG.md](CONFIG.md) has that composition in full, and
what to configure in each framework for every protocol here.

---

## WSGI on a multiplexed stream

PEP 3333 knows nothing about streams and does not have to. HTTP/1.1, HTTP/2 and
HTTP/3 differ in how a message is framed, and framing is the server's job in
all three. But two things do not carry across untouched.

**The head has to be compressed, and the compressor belongs to the
connection.** HPACK and QPACK are tables that both ends keep in step, so only
the thread that owns the connection may touch one — while a WSGI application
may be running on a `--wsgi-threads` pool thread, which owns nothing. So the
response head is staged in a neutral form by whichever thread produced it, and
encoded on the loop thread at the moment the first bytes are about to go out.
One walk over the application's headers produces either HTTP/1.1 text or that
staged block, so the two cannot drift apart. The body needs nothing: it is
already bytes, and the stream flush turns bytes into DATA frames whatever
produced them.

**The request cannot be dispatched on its head.** An ASGI application is
started as soon as the head is parsed — that is what lets it reject an upload
at byte one. WSGI is called once, with `wsgi.input` already holding the whole
body, so a multiplexed request waits for the stream to end exactly as it waits
for the body on HTTP/1.

Two things a WSGI application can observe about the transport are told the
truth: `SERVER_PROTOCOL` is `HTTP/2` or `HTTP/3`, and `wsgi.url_scheme` follows
the `:scheme` pseudo-header. A trusted proxy can still override the scheme, as
on HTTP/1.

One limitation is worth stating plainly: an inline WSGI application (the
default, `--wsgi-threads 1`) that streams an unbounded response over HTTP/2 or
HTTP/3 buffers whatever the peer has not taken, because there is no socket to
block on and blocking the loop would stall the acknowledgements that let it
drain. `--wsgi-threads N` does not have that problem — the pool holds the bytes
with the job and the loop takes them as the connection drains, which is real
backpressure.

---

## Testing

Every transport is checked against an implementation that shares none of its
code, because a test written against the same understanding as the code proves
only that the understanding is consistent.

```bash
<venv>/bin/python scripts/http2-test.py         # 162 checks against `h2`
<venv>/bin/python scripts/http3-test.py         #  82 checks against `aioquic`
python3 scripts/contrib_test.py                 #  58 Python-only
<venv>/bin/python scripts/webtransport-test.py  # 117 including FastAPI/Django

h2spec -h 127.0.0.1 -p 8443 -t -k               # 146/146
```

The HTTP/2 suite runs twice, cleartext and over TLS, because the record layer
decides where frame boundaries fall. Both multiplexed suites run their WSGI
sections twice more, inline and pooled.

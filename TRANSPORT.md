<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Transports

Garuda speaks HTTP/1.1, HTTP/2 and HTTP/3. This document covers what each of
them is, what the engine implements, and where the implementation departs from
the obvious approach and why. The process model, the connection table and the
async substrate are described in [ARCHITECTURE.md](ARCHITECTURE.md). Flags are
documented in [CONFIG.md](CONFIG.md).

| | status |
| --- | --- |
| HTTP/1.1 | served, cleartext and TLS |
| HTTP/2 | served: `h2` over TLS via ALPN, `h2c` with prior knowledge |
| HTTP/3 | served with `--http3`, over Garuda's own QUIC |
| WebSocket | framing code only; no application API |
| WebTransport | advertised on HTTP/3; a session CONNECT is answered 501 |

---

## One request path

HTTP/2 and HTTP/3 do not change what a request is. They change how it is
framed, how many share a connection, and how the head is encoded. So there is
one request path, and each transport adapts to it.

**A connection is a slot in the connection table.** For HTTP/1.1 the slot owns
a socket. For HTTP/2 it owns the socket, the HPACK state and the connection
window. For HTTP/3 it owns no descriptor at all (the UDP socket belongs to the
QUIC listener), and the slot exists so a QUIC connection can be handled like
any other.

**A request stream is also a slot.** Each HTTP/2 and HTTP/3 stream takes one
from the same table, with `fd = -1` and `parentSlot` pointing at its
connection. A stream slot has a head, a body buffer, a write buffer, a
Content-Length check and continuation fields, so dispatch, the handler API,
the timer substrate and cancellation work on a stream exactly as on a
connection.
Only three things know the difference: writing (bytes become frames on the
parent), read interest (a stream has no descriptor), and teardown.

**The head is rebuilt as HTTP/1.1 text and re-parsed.** An HTTP/2 or HTTP/3
request arrives as pseudo-headers plus a compressed field section. It is
validated, rendered into the stream's `headStore` as `GET /path
HTTP/1.1\r\nhost: …`, and handed to the ordinary parser. That costs one copy
and one parse per request. In exchange, the health check, rate limiter, static
files, forwarded-header trust, request ID, access log and a handler's
`Request` all work on the one representation they were written for. A handler
sees `:authority` as `Host`, and `:scheme` as `request.scheme`.

**The response side is one call with three encodings.** Every handler answer
goes through `respond` (`Respond.swift`). On HTTP/1.1 that writes header text
straight into the write buffer. On a stream it becomes `respondH2` or
`respondH3`, which encode `:status`, `content-length`, `date`, `server`, the
server headers and the handler's headers with HPACK or QPACK, then queue the
body on the stream. The server headers are Alt-Svc, HSTS and X-Request-ID,
written by `writeServerHeaders`, `encodeServerHeaders` and
`encodeServerHeadersH3`; a handler that sets one of them has its own sent
instead. A handler's `Content-Length` is held to on every protocol: a longer
body is cut to it, and a shorter one closes the HTTP/1.1 connection after it or
resets the stream. A status with no body, such as a health check or an error,
ends the stream on its HEADERS frame.

On HTTP/2 and HTTP/3 a request is dispatched when its stream ends (END_STREAM,
a trailer section, or the QUIC stream's FIN), because a handler is given the
whole body. The one exception is an HTTP/3 extended CONNECT,
which never ends. It is dispatched on its head and refused.

---

## HTTP/1.1

Keep-alive, pipelining, chunked request bodies, `Expect: 100-continue`, `HEAD`,
and HTTP/1.0. Handler and static-file responses carry a `Content-Length`,
except a 204 or 1xx, which never has one, and a 304, which has one only when
the handler gave it.

The parser (`HTTPParser.swift`) makes a single pass with no backtracking and
no allocation, producing `(offset, length)` slices into the read buffer.
Character-class membership is two 64-bit shifts rather than a table lookup.

### Strictness that prevents smuggling

The parser is unforgiving wherever leniency would let two implementations
disagree about where a message ends:

- whitespace between a header name and its colon is rejected;
- `Content-Length` together with `Transfer-Encoding` is rejected, and so are
  two `Content-Length` values that disagree;
- `Transfer-Encoding` is parsed as a comma-separated list of codings, and only
  a bare `chunked` frames a body. `xchunked` is not `chunked`, and neither is
  `chunked;x=1`. A list whose last coding is not `chunked` cannot be framed and
  is a 400 (RFC 9112 6.3). `gzip, chunked` can be framed but uses a coding
  this server cannot remove, so it is a 501 (RFC 9112 6.1). A second
  `Transfer-Encoding` field continues the list, so it too is a 400;
- `obs-fold` continuation lines are rejected rather than unfolded;
- HTTP/1.1 without `Host` is a 400, and so is a second `Host` (RFC 9112 3.2);
- the chunked trailer section is bounded by `--max-header-size`, like the head.
  Trailers add nothing to the body, so without their own limit a peer could
  stream them indefinitely.

`--max-body` counts decoded bytes cumulatively, not what happens to be
buffered. A request that answers early leaves its body unread: a small
remainder already on the socket is read and discarded so the connection can be
reused, and otherwise the connection closes after the response.

---

## TLS

OpenSSL handles TCP TLS (`Sources/CGaruda/garuda_tls.c`, `TLS.swift`). It is
given the descriptor directly, so a TLS connection is the same slot, the same
poller interest and the same state machine as any other. The read and write
wrappers report `EAGAIN` the way a socket does.

Two things cannot be wrapped away, and both are handled explicitly:

- the handshake runs before any request exists and can want readability *or*
  writability at each step (`driveHandshake`);
- a record is decrypted whole, so OpenSSL can hold bytes the socket no longer
  has, and a level-triggered poller will never report them. Every read path
  keeps reading while `pg_tls_pending` is non-zero (`drainBufferedTLS`).

**ALPN** is how a browser reaches HTTP/2. The server picks `h2` if offered and
`http/1.1` otherwise, in its own order of preference. `--no-http2` and
`--http2-only` narrow the list to match. A connection that negotiated `h2`
must open with the HTTP/2 preface.

TLS 1.2 is the floor and renegotiation is off. `--tls-ciphers` narrows the 1.2
suites. Extra certificates are chosen by SNI. With `--acme-domain`, a
`tls-alpn-01` handshake is completed and the connection closed, as RFC 8737
specifies.

**`--ktls`** asks OpenSSL for kernel TLS. When the kernel took the send side
for a connection, a `--static-dir` file goes out with `SSL_sendfile` instead of
being read and encrypted in the process. Otherwise TLS falls back to reading
the file into the write buffer.

---

## HTTP/2

Cleartext HTTP/2 is served to any client that opens with the connection
preface, such as `curl --http2-prior-knowledge` or a proxy talking h2c
upstream. The same port still answers HTTP/1.1, because the preface is
recognised in full before anything is assumed. A connection that begins
`PRI ` and then diverges, or whose first byte cannot start an HTTP/1 method,
is sent `GOAWAY(PROTOCOL_ERROR)` (RFC 9113 3.4). `--http2-only` drops the
HTTP/1 fallback, and `--no-http2` turns HTTP/2 off.

The RFC 7540 `Upgrade: h2c` dance is absent: RFC 9113 removed it and prior
knowledge covers every cleartext client.

The server's first SETTINGS advertises `MAX_CONCURRENT_STREAMS`,
`INITIAL_WINDOW_SIZE`, `MAX_FRAME_SIZE` and `MAX_HEADER_LIST_SIZE`, plus
`ENABLE_PUSH = 0`. It does not advertise `ENABLE_CONNECT_PROTOCOL`, because
nothing would answer an extended CONNECT. Priority is parsed only far enough to
reject a stream that depends on itself. `PUSH_PROMISE` from a client is a
connection error.

### HPACK

A full implementation (`HPACK.swift`): static and dynamic tables, Huffman in
both directions, and eviction. The Huffman and static tables are generated
from RFC 7541 by `scripts/gen-hpack-tables.py`. Unit tests check that the
committed codes are the canonical ones for their lengths, that the code is
complete, and that every example in appendix C decodes.

Decoding hands out borrowed pointers. The dynamic table is a FIFO of
descriptors over an append-only arena, and eviction moves a watermark rather
than bytes. The encoder never uses incremental indexing. Mirroring the peer's
table would save a few bytes on response headers that barely repeat, and
Huffman-coded literals get most of that saving without the bookkeeping.

A header block that is not wanted (a trailer, a refused stream) is still
decoded, because HPACK is stateful. A new stream past the advertised
concurrency limit, or after the peer's GOAWAY, is refused with
`RST_STREAM(REFUSED_STREAM)`.

### Flow control

**Sending.** A response body waits in the stream's write buffer. `flushStream`
moves it to the parent as DATA frames no larger than the peer's maximum frame
size, the stream window and the connection window allow. It stops while the
parent's write buffer is above the write high-water mark. `WINDOW_UPDATE`, a
changed `SETTINGS_INITIAL_WINDOW_SIZE` (applied to every open stream, one value
at a time) and socket writability all pump the waiting streams again. A
`--static-dir` file on a stream is read into the write buffer a block at a
time as the window opens.

**Receiving.** A DATA frame is charged against both windows before anything
else can reject it, because the peer has spent the window either way. Our
initial stream window is the larger of 65,535 and the body high-water mark,
and the connection window is raised to match at the start. The whole body is
buffered before a handler is called, so body bytes count as consumed on arrival
(`h2NoteConsumed`). Once half the initial window has accumulated,
`h2FlushWindowUpdates` sends `WINDOW_UPDATE` for the stream and the
connection, and it does so *before* the body is dispatched. Uploads larger
than the window therefore keep moving. DATA for a stream that is already gone
still returns its bytes to the connection window, so the peer is not stalled
by bytes nobody wanted.

**Body length.** A body that runs past its declared `Content-Length`, or ends
short of it, is `RST_STREAM(PROTOCOL_ERROR)` (RFC 9113 8.1.1). A body past
`--max-body` is `RST_STREAM(ENHANCE_YOUR_CALM)`. If the response finished
before the upload did, the stream waits in `closing`, still counting and still
granting window, when what is left is small. A large remainder gets
`RST_STREAM(NO_ERROR)` instead.

**Ending.** A response ends with END_STREAM on its last DATA frame, or on its
HEADERS for a bodyless response or `HEAD`. A file-fed response that comes up
short of its declared length is reset with `INTERNAL_ERROR` instead of ending
cleanly, so the client does not mistake a truncation for the whole body. A
handler body shorter than the `Content-Length` it declared is reset the same
way.

### Cancellation has a budget

`RST_STREAM` frees a stream at once, so a concurrency limit is no defence
against a peer that opens a stream and cancels it immediately. The count never
rises while the server decodes a header block and dispatches every request.
That is CVE-2023-44487, the rapid reset.

Cancelling is legitimate (a browser does it on navigation), so what is bounded
is the ratio, not the count. A connection starts with an allowance of
`max(100, 2 × the advertised concurrent-stream limit)`. Every stream cancelled
before its response ended spends one, and every stream answered earns one
back up to the cap. A peer that only cancels exhausts it and is sent
`GOAWAY(ENHANCE_YOUR_CALM)`. A reset that arrives after END_STREAM was sent is
a race, and costs nothing.

A reset stream goes through `closeStream` → `closeConnection` →
`cancelOps`, so a request parked on a timer (`Response.after`) is cancelled with
it and never answers late.

### A stream measures its own progress

`--request-timeout` asks whether a request has stalled. On HTTP/1.1 the poller
answers: every event on the socket is progress. A stream has no descriptor,
so it records the bytes that move on it instead, DATA in and DATA out.
Otherwise the timeout would cap how long an upload may take rather than detect
a stall. A window the peer never opens is still a stall and still times out,
because nothing moves.

Frame handling and HPACK are covered by unit tests and checked with
[h2spec](https://github.com/summerwind/h2spec); `scripts/http2-test.py` checks
interop against the `h2` library.

---

## HTTP/3 and QUIC

The QUIC stack is Garuda's own (`Sources/GarudaQUIC`): packets, loss recovery,
congestion control, streams, flow control, connection IDs, key update, and a
TLS 1.3 handshake. OpenSSL supplies primitives only (hash, HKDF, AEAD, key
agreement, signatures) through `garuda_crypto.c`. QUIC replaces the TLS record
layer, and `SSL_*` cannot be used without it.

The handshake (`TLS13.swift`) implements what QUIC needs and nothing more:
TLS 1.3 only, no session resumption or 0-RTT, no client certificates, and no
HelloRetryRequest (a client offering no group we support is refused). The
certificate is loaded again for QUIC, separately from the TCP `SSL_CTX`.

Because it was written from scratch, it is checked against implementations
that share none of its code. Packet protection is tested against vectors from
`scripts/quic-vectors.py`, which uses aioquic and RFC 9001 appendix A.3/A.5.
The QPACK static table is generated by reading every entry back out of
pylsqpack (`scripts/gen-qpack-table.py`). The handshake, transport and HTTP/3
layer are driven by aioquic in `scripts/http3-test.py`.

| | |
| --- | --- |
| RFC 9000 | packets, frames, streams, flow control, connection IDs, the 3× anti-amplification limit, version negotiation |
| RFC 9001 | packet and header protection, key update |
| RFC 9002 | loss detection by packet ordering and by time, PTO, NewReno |
| RFC 9114 | HTTP/3 frames, control and QPACK streams |
| RFC 9204 | QPACK, static table and Huffman |
| RFC 9221 | the datagram transport parameter and frames |

### Settings

The control stream's SETTINGS carries a QPACK dynamic table capacity of 0,
blocked streams 0, `MAX_FIELD_SECTION_SIZE`, and `ENABLE_CONNECT_PROTOCOL = 1`.
When the peer allows datagrams it also carries `H3_DATAGRAM = 1` and a
WebTransport session limit of 16. The server opens its QPACK encoder and
decoder streams, though it never sends instructions on them. An unknown
unidirectional stream type gets `STOP_SENDING`, and its bytes are dropped.
Losing the peer's control stream closes the connection
(`H3_CLOSED_CRITICAL_STREAM`).

### QPACK advertises a dynamic table capacity of zero

That is a promise rather than a shortcut: no header block on this connection
can ever wait on another stream, which is the head-of-line blocking HTTP/3
exists to remove. The encoder uses the static table and Huffman literals,
which is where nearly all of the saving is anyway. A peer that sends encoder
instructions anyway is closed with `QPACK_ENCODER_STREAM_ERROR`.

### Streams, flow control and cancellation

Transport parameters come from the configuration. The idle timeout is
`--keep-alive`. Per-stream data is the body high-water mark, and connection data
is eight times that. Concurrent bidirectional streams match the HTTP/2 limit.
`extendStreamWindow` reopens a stream's window as its bytes are read.

Retiring a stream queues `MAX_STREAMS`, and `closeH3Stream` flushes it
immediately. A peer at its stream limit may have no packet of its own to carry
the credit back on, and without that flush the connection would serve exactly
`initial_max_streams_bidi` requests and stall.

`RESET_STREAM` and `STOP_SENDING` on a request stream spend from the same kind
of allowance as HTTP/2's rapid-reset budget. A QUIC cancellation costs the peer
a packet rather than eight bytes, but that is dearer, not bounded. A peer that
exhausts the allowance is closed with `H3_EXCESSIVE_LOAD`. The aborted stream
is closed through `closeConnection`, which cancels any parked timer.

A body that disagrees with its declared length is reset with
`H3_MESSAGE_ERROR`. A body past `--max-body` is answered 413.

### One socket per worker

Each worker binds its own UDP socket with `SO_REUSEPORT`, so the kernel hashes
datagrams to workers by four-tuple. A connection is found by its destination
connection ID, not its address. A client that changes address keeps its
connection, but only once a packet from the new address has authenticated and
is newer than anything seen. A forged datagram carrying a visible connection ID
cannot redirect the connection's traffic. A client that migrates to an address
hashing to a *different worker* reaches one that has never heard of it, and
recovers by making a new connection.

A new connection needs a client Initial of at least 1,200 bytes, and the server
sends no more than three times what it has received until the address is
validated.

### Receiving and sending

`recvmmsg` takes up to 32 datagrams per syscall. The socket joins the worker's
poller as one descriptor. A readiness event services every connection it
touched, and `quicTick` runs loss, acknowledgement and idle timers at most
every 4 ms. The worker's poll timeout is shortened to the nearest QUIC
deadline.

A connection sends only while its congestion window has room. Past that only
acknowledgements go out, plus the probes a PTO allows. A lost packet is never
retransmitted: the *data* it carried is sent again in a new packet, which is
why every sent packet records what it held. A receiver slower than the server
is the normal case, and a sender that ignored the window would fill the
receiver's socket buffer and then retransmit what the kernel threw away.
`scripts/http3-test.py` downloads 20 MB and checks that the kernel dropped
next to nothing.

On Linux, runs of equal-sized datagrams to one peer go out as one `sendmsg`
with UDP GSO (`UDP_SEGMENT`), up to 32 per call. If the kernel or device
refuses segmentation, the worker falls back to one datagram per call for the
rest of its life. `GARUDA_UDP_GSO=0` forces that fallback. When the socket is
full the pending run is kept, and the worker waits for writability.

### Alt-Svc

A client cannot discover HTTP/3 by trying: there is no upgrade and no
well-known port. It has to be told over a connection it already has. With
`--http3`, every response the server builds on HTTP/1.1 and HTTP/2 carries

```
alt-svc: h3=":443"; ma=86400
```

naming the UDP port, which is `--quic-port` when it differs from the TCP port.
That covers handler responses, health checks, static files, errors and cached
responses. A handler that sets its own `Alt-Svc` has it sent instead. HTTP/3
responses do not carry it, because the client is already there.

---

## WebSocket

The engine pieces exist in GarudaHTTP: `WebSocketFrame.swift` (framing and
UTF-8 validation) and `WebSocketDeflate.swift` with `garuda_wsdeflate.c`
(permessage-deflate). Both are covered by unit tests. The `--ws-*` flags are
parsed.

There is no handshake path. With `--no-websockets`, an upgrade request is
refused with 501 before anything else can answer. Without it, an upgrade
request is an ordinary request to the routes. The server never enters the
`websocket` state. WebSocket over HTTP/2 or HTTP/3 (RFC 8441 / RFC 9220) is not
implemented.

## WebTransport

HTTP/3 advertises extended CONNECT and, when datagrams are allowed, a
WebTransport session limit. The frame loop recognises the WebTransport shapes:

- a peer unidirectional stream whose type is `0x54`, followed by a session ID;
- a peer bidirectional stream opening with `WEBTRANSPORT_STREAM` (`0x41`),
  which is told apart from a request by its first varint alone;
- HTTP datagrams.

The handlers for all three are stubs (`WebTransport.swift`) that drop what
they are given. A CONNECT with `:protocol` is dispatched on its head, because
the stream never ends, and `dispatch` answers it 501. No session is ever
created.

---

## Testing

Every transport is checked against an implementation that shares none of its
code. A test written from the same understanding as the code only proves that
understanding is consistent.

```bash
<venv>/bin/python scripts/http2-test.py          # 50 checks against `h2`, cleartext and TLS
<venv>/bin/python scripts/http3-test.py          # 53 checks against `aioquic`
<venv>/bin/python scripts/router-streams-test.py # 41: routes, delays and cancellation on h2 and h3
<venv>/bin/python scripts/handler-test.py        # 107: handler bodies, headers and framing on h1, h2 and h3
python3 scripts/feature-test.py                  # 62: shutdown, supervision, unix sockets, scrapes
```

The HTTP/2 suite runs each check twice, once cleartext with prior knowledge
and once over TLS with ALPN, because the record layer decides where frame
boundaries fall. `swift test` covers the parser, HPACK, QUIC packet protection
and streams, and WebSocket framing.

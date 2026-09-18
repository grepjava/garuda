<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Transports

What each protocol implementation does and enforces. The process model,
connection table and handler tasks are in [ARCHITECTURE.md](ARCHITECTURE.md).
Flags are in [CONFIG.md](CONFIG.md).

| | Status |
| --- | --- |
| HTTP/1.1, HTTP/1.0 | cleartext and TLS |
| HTTP/2 | `h2` over TLS via ALPN, `h2c` with prior knowledge |
| HTTP/3 | with `--http3`, over Garuda's own QUIC |
| WebTransport | over HTTP/3, through `app.webTransport` routes |
| WebSocket | HTTP/1.1, HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220), through `app.webSocket` routes |

---

## One request path

HTTP/2 and HTTP/3 change framing, multiplexing and header encoding, not what a
request is. All three share one path.

- **A connection is a slot** in the worker's connection table. An HTTP/2 slot
  owns the socket, HPACK state and connection window. An HTTP/3 slot owns no
  descriptor; the UDP socket belongs to the QUIC listener.
- **A request stream is also a slot**, with `fd = -1` and `parentSlot` set. It
  has a head, body buffer, write buffer, Content-Length budget and continuation
  fields, so dispatch, handlers, timers and cancellation work on it unchanged.
- **The head is rebuilt as HTTP/1.1 text** in the stream's `headStore` after
  validation, and parsed by the HTTP/1.1 parser: one copy and one parse per
  request. `:authority` becomes `Host`.
- **The response is one call with three encodings**: header text on HTTP/1.1,
  HPACK in `respondH2`, QPACK in `respondH3`. A declared `Content-Length` is
  enforced on all three: a longer body is cut to it, a shorter one closes the
  HTTP/1.1 connection or resets the stream.

On HTTP/2 and HTTP/3 a request is dispatched when its stream ends (END_STREAM,
a trailer section, or FIN), because handlers get the whole body. An HTTP/3
extended CONNECT is dispatched on its head, because its stream does not end.

---

## HTTP/1.1

RFC 9112. Keep-alive, pipelining, chunked request bodies,
`Expect: 100-continue`, `HEAD`, HTTP/1.0. The parser (`HTTPParser.swift`) is a
single pass with no backtracking or allocation, returning offsets into the read
buffer.

### Framing and smuggling defences

- Whitespace between a header name and its colon: 400.
- `Content-Length` with `Transfer-Encoding`, or two different `Content-Length`
  values: 400.
- `Transfer-Encoding` is parsed as a list, and only a bare `chunked` frames a
  body. A last coding other than `chunked` (`xchunked`, `chunked;x=1`, `gzip`)
  is 400 (RFC 9112 6.3). `gzip, chunked` is 501 (RFC 9112 6.1). A second
  `Transfer-Encoding` field is 400.
- `obs-fold` lines and control characters in field values (including bare CR)
  are rejected.
- HTTP/1.1 without `Host`, or with two: 400 (RFC 9112 3.2).
- Chunk sizes are at most 15 hex digits and chunk lines must end in CRLF.
  Extensions are skipped. The trailer section is limited to
  `--max-header-size`.
- A head over `--max-header-size` is 431. An oversized `Content-Length` is 413
  before any body is read. `--max-body` counts decoded bytes cumulatively.

### Keep-alive and pipelining

HTTP/1.1 defaults to keep-alive, HTTP/1.0 to close; `Connection` overrides
both. Keep-alive is off while draining.

A body is read into its own buffer and never past its declared end. Bytes
after it stay in the socket, with read interest off, until the response is
written; then any buffered pipelined request is parsed. If a handler answers
without the whole body having arrived, a small remainder already on the socket
is discarded and the connection reused. Otherwise, and for an unfinished
chunked body, the connection closes after the response. So does a response
whose body disagrees with its `Content-Length`.

Finished responses are written together at the end of each event batch, or
every 16 responses.

---

## TLS

OpenSSL handles TLS over TCP (`avian_tls.c`, `TLS.swift`), given the
descriptor directly. A TLS connection uses the same slot and state machine as
a cleartext one.

- The handshake (`driveHandshake`) may want readability or writability at each
  step.
- OpenSSL can hold decrypted bytes the socket no longer has, which a
  level-triggered poller will not report, so reads continue while
  `av_tls_pending` is non-zero.
- TLS 1.2 minimum, compression and renegotiation off, server cipher preference.
  `--tls-ciphers` sets the TLS 1.2 list.
- **ALPN**: server preference from `h2,http/1.1`, or `http/1.1` with
  `--no-http2`, or `h2` with `--http2-only`. A connection that negotiated `h2`
  must send the HTTP/2 preface.
- **SNI**: `--tls-cert`/`--tls-key` repeat. The first pair is the default; each
  other certificate serves the names in its subject alternative names (or
  common name). HTTP/3 always serves the default pair.
- **ACME**: under `--acme-domain`, a client offering `acme-tls/1` gets the
  `tls-alpn-01` challenge certificate and is closed (RFC 8737).
- **`--ktls`** sets `SSL_OP_ENABLE_KTLS`. When the kernel took the send side, a
  `--static-dir` file goes out with `SSL_sendfile`; otherwise it is read and
  encrypted in the process.
- `--hsts` adds `Strict-Transport-Security` to TLS responses. `--redirect-http`
  answers plain HTTP on another port with a redirect to https.

---

## HTTP/2

RFC 9113, HPACK RFC 7541 (`HTTP2.swift`, `HPACK.swift`).

### Connection start and settings

Cleartext HTTP/2 is served to a client that opens with the preface. The same
port serves HTTP/1.1, because the preface is matched in full first. A
connection that starts `PRI ` and diverges, or whose first byte cannot start an
HTTP/1 method, gets `GOAWAY(PROTOCOL_ERROR)` (RFC 9113 3.4). `--http2-only`
removes the HTTP/1 fallback; `--no-http2` disables HTTP/2. `Upgrade: h2c` is
not supported.

| Server setting | Value |
| --- | --- |
| `MAX_CONCURRENT_STREAMS` | 128 |
| `INITIAL_WINDOW_SIZE` | larger of 65,535 and the body high-water mark (256 KiB) |
| `MAX_FRAME_SIZE` | 16 KiB |
| `MAX_HEADER_LIST_SIZE` | `--max-header-size` |
| `ENABLE_PUSH` | 0 |

A WINDOW_UPDATE raises the connection window to match the stream window.
`ENABLE_CONNECT_PROTOCOL` is not advertised: no extended CONNECT on HTTP/2.

### Validation

- Oversized frames: `FRAME_SIZE_ERROR`. Stream IDs must be odd and increasing.
- A header block cannot be interleaved with other frames. CONTINUATION
  assembly past twice the header list limit: `GOAWAY(ENHANCE_YOUR_CALM)`.
- Pseudo-headers must come first, once each, from `:method`, `:path`,
  `:scheme`, `:authority`; the first three are required. Field names and values
  are validated. Connection-specific fields other than `te: trailers`, and
  `Transfer-Encoding: chunked`, are malformed. A malformed request gets
  `RST_STREAM(PROTOCOL_ERROR)`; an HPACK failure `GOAWAY(COMPRESSION_ERROR)`.
- A second HEADERS on an open stream must end it. It is a trailer section,
  decoded to keep HPACK in sync and dropped.
- Priority is parsed only to reject self-dependency. A client `PUSH_PROMISE`
  is a connection error. Unknown frames are ignored. SETTINGS values are
  range-checked; a changed `INITIAL_WINDOW_SIZE` applies to open streams.
- A new stream past the concurrency limit, with no free slot, or after the
  peer's GOAWAY is decoded and refused with `RST_STREAM(REFUSED_STREAM)`.

HPACK: static and dynamic tables (4,096 bytes), Huffman both ways, generated
from RFC 7541 by `scripts/gen-hpack-tables.py` and tested against Appendix C.
Decoding hands out borrowed pointers; the dynamic table is descriptors over an
append-only arena. The encoder never indexes and Huffman-codes a literal when
that is shorter.

### Flow control

**Sending.** `flushStream` moves a stream's buffered body to the parent as DATA
frames limited by the peer's frame size, the stream window and the connection
window. It pauses while the parent's write buffer is above the write
high-water mark (512 KiB). WINDOW_UPDATE, a settings change and socket
writability resume it. A static file is read in as the window opens.

**Receiving.** DATA is charged to both windows before anything can reject it.
Bytes count as consumed on arrival, since bodies are buffered before dispatch,
and WINDOW_UPDATE goes out once half the initial window has accumulated. DATA
for a closed stream still returns its bytes to the connection window.

**Body length.** A body longer or shorter than its `Content-Length` is
`RST_STREAM(PROTOCOL_ERROR)` (RFC 9113 8.1.1). Past `--max-body`, or a
route's own limit, declared or as it arrives: a 413 response, then
`RST_STREAM(NO_ERROR)` so the client stops sending (RFC 9113 8.1); a handler
that has already begun its response gets `RST_STREAM(ENHANCE_YOUR_CALM)`
instead. If the response finishes first, a remaining
upload up to the body high-water mark is still received and counted in
`closing`; a larger one gets `RST_STREAM(NO_ERROR)`. A response short of its
declared length is reset with `INTERNAL_ERROR`.

### Rapid reset (CVE-2023-44487)

`RST_STREAM` frees a stream at once, so a concurrency limit does not stop a
peer that opens and cancels streams in a loop. Each connection has an allowance
of `max(100, 2 × MAX_CONCURRENT_STREAMS)`. A stream reset before its response
ended spends one; a stream answered earns one back, up to the cap. At zero the
connection gets `GOAWAY(ENHANCE_YOUR_CALM)`. A reset after END_STREAM costs
nothing. A reset stream is closed through `closeConnection`, which cancels its
timer or handler task.

### Timeouts

A stream has no descriptor, so DATA in and out refresh its activity time.
`--request-timeout` detects a stalled stream instead of capping a long
transfer. A connection with no streams times out after `--keep-alive`.

---

## HTTP/3 and QUIC

QUIC is implemented in Swift (`Sources/AvianQUIC`). OpenSSL supplies only
primitives through `avian_crypto.c`: hashes, HKDF, AEAD, key exchange,
signatures.

| RFC | Implemented |
| --- | --- |
| 9000 | packets, frames, streams, flow control, connection IDs, version negotiation, 3× anti-amplification |
| 9001 | packet and header protection, key update |
| 9002 | loss detection by packet number and time, PTO, NewReno |
| 9369 | QUIC version 2 |
| 9114 | HTTP/3 frames, control and QPACK streams |
| 9204 | QPACK, static table and Huffman only |
| 9221, 9297, 9220 | datagrams, capsules, extended CONNECT (for WebTransport and WebSocket) |

### Handshake

`TLS13.swift` is a server TLS 1.3 handshake without a record layer: AES-128-GCM,
ChaCha20-Poly1305 and AES-256-GCM in that preference; X25519 or P-256; the
signature schemes the key supports; ALPN `h3` only.

SNI certificate selection is done here rather than by OpenSSL: the name in
the ClientHello is matched against each certificate's subject alternative
names, by the same RFC 6125 rule the TCP path uses, and the first pair is the
default for a client that sends no name or asks for one nothing covers.

Not supported: session resumption, 0-RTT, client certificates,
HelloRetryRequest (a client offering no supported group is refused), and Retry
packets.

Packet protection is tested against RFC 9001 Appendix A vectors
(`scripts/quic-vectors.py`), the QPACK static table is generated by
`scripts/gen-qpack-table.py`, and the whole stack is tested against `aioquic`.

### Sockets and connections

Each worker binds its own UDP socket with `SO_REUSEPORT`; the kernel hashes
datagrams to workers by four-tuple. A connection is found by destination
connection ID.

- An unsupported version gets Version Negotiation.
- A new connection needs a client Initial datagram of at least 1,200 bytes, and
  counts against `--max-connections`.
- Until a Handshake packet from the client decrypts, the server sends at most
  three times what it received.
- The peer address changes only after a packet from the new address
  authenticates and is newer than any seen. PATH_CHALLENGE is answered. A
  client whose new address hashes to another worker must reconnect.

`recvmmsg` reads up to 32 datagrams per call. One poller event services every
connection it touched. `quicTick` runs loss, acknowledgement and idle timers
at most every 4 ms, and the poll timeout is cut to the nearest QUIC deadline.

### Loss recovery and sending

Packet numbers are never reused. Each sent packet records what it carried, and
the data of a lost packet is queued again in a new one. A connection sends only
while its NewReno congestion window has room; beyond that only
acknowledgements and PTO probes go out.

On Linux, runs of equal-sized datagrams to one peer go out in one `sendmsg`
with UDP GSO, up to 32 per call. If the kernel refuses, the worker falls back
to one datagram per call; `AVIAN_UDP_GSO=0` forces that. A full socket keeps
the pending run and waits for writability.

### Transport parameters

Idle timeout `--keep-alive`. Initial stream data 256 KiB (the body high-water
mark), connection data eight times that, 128 bidirectional streams. Windows
extend as the application reads, once they have fallen by half. Retiring a
stream queues MAX_STREAMS and flushes it at once, since a peer at its limit may
have nothing of its own to send.

### HTTP/3

`HTTP3.swift`. The server opens a control stream and QPACK encoder and decoder
streams.

| Server setting | Value |
| --- | --- |
| `QPACK_MAX_TABLE_CAPACITY`, `QPACK_BLOCKED_STREAMS` | 0 |
| `MAX_FIELD_SECTION_SIZE` | `--max-header-size` |
| `ENABLE_CONNECT_PROTOCOL` | 1 |
| `H3_DATAGRAM`, WebTransport max sessions | 1 and 16, when the peer allows datagrams |

- A duplicate control or QPACK stream, a first control frame other than
  SETTINGS, or a second SETTINGS closes the connection. Losing the peer's
  control stream: `H3_CLOSED_CRITICAL_STREAM`.
- Unknown unidirectional stream types get `STOP_SENDING`.
- Malformed request: reset with `H3_MESSAGE_ERROR`. QPACK failure:
  `QPACK_DECOMPRESSION_FAILED`. No free slot: `H3_REQUEST_REJECTED`.
- A body that disagrees with its `Content-Length` is reset with
  `H3_MESSAGE_ERROR` (RFC 9114 4.1.2). Past `--max-body`: 413.
- `RESET_STREAM` and `STOP_SENDING` on request streams spend the same
  rapid-reset allowance as HTTP/2. At zero: `H3_EXCESSIVE_LOAD`.

**QPACK.** With a table capacity of zero, no header block can wait on another
stream. The encoder uses the static table and Huffman literals. The decoder
rejects dynamic references, and data on the peer's encoder stream closes the
connection with `QPACK_ENCODER_STREAM_ERROR`.

**Alt-Svc.** With `--http3`, HTTP/1.1 and HTTP/2 responses carry
`alt-svc: h3=":PORT"; ma=86400` (PORT is `--quic-port` or the TCP port),
unless the handler set its own.

---

## WebTransport

draft-ietf-webtrans-http3, HTTP/3 only (`WebTransport.swift`,
`WebTransportAPI.swift`).

- CONNECT with `:protocol: webtransport` goes to the routes; any other
  `:protocol` is 501. Middleware and extractors run first, so a refusal is an
  ordinary status. An `app.webTransport` route answers 200 and the stream
  becomes the session. Past 16 sessions on a connection: 503.
- Peer streams are recognised by prefix (unidirectional type `0x54`, or
  bidirectional opening with `0x41`) followed by the session ID. Datagrams name
  the session by quarter stream ID.
- Streams for a session not yet seen are held, 32 per connection, then reset
  with `WEBTRANSPORT_BUFFERED_STREAM_REJECTED`.
- Session streams take no slot. Bytes stay in the QUIC receive buffer until
  read, and reading extends the window, so an unread stream only blocks its
  own sender.
- Capsules on the CONNECT stream: `CLOSE_WEBTRANSPORT_SESSION` records the code
  and reason and ends the session; FIN also ends it; others, including `DRAIN`,
  are ignored.
- Ending a session resets and stops its streams with
  `WEBTRANSPORT_SESSION_GONE` and ends every wait on it. A session the handler
  did not close is closed when it returns.
- Incoming datagrams queue per session up to 64 or 256 KiB, dropping the
  oldest.
- One reader and one writer per stream, one stream acceptor and one datagram
  receiver per session; a second waiter gets `WebTransportError.busy`.

---

## Streaming responses and backpressure

An async handler can call `response.stream(...)` or return `StreamingBody` or
`EventStream` (`StreamingResponse.swift`, `EventStream.swift`). The head goes
through the normal sink with no `Content-Length` unless the handler set one.
The body is chunked on HTTP/1.1, close-delimited on HTTP/1.0, and DATA frames
ended by END_STREAM or FIN on HTTP/2 and HTTP/3.

A write queues its bytes and returns, unless the backlog is above the write
high-water mark (512 KiB). Then it waits on the worker until the backlog falls
to the low-water mark (128 KiB). The backlog is the connection or stream write
buffer, plus on HTTP/3 the bytes QUIC has not had acknowledged.

Every producer waits, not only the first to arrive at a full backlog. Bytes
are queued and then waited on, so each producer can carry the backlog past the
mark by its own last write and no further: with one producer the ceiling is
the mark plus that write, and with several it is the mark plus one write each.
The mark is where writers start waiting rather than a ceiling on the buffer.

- A client that disconnects ends the wait with `HandlerWaitError.cancelled`,
  and ends it for every producer waiting, not one of them.
- A client that stops reading is closed after `--request-timeout`.
- A body that passes its `Content-Length` is ended there. One that ends short,
  or a handler that throws after the head was sent, closes the HTTP/1.1
  connection or resets the stream.

Server-sent events use the HTML event-stream format: one `data:` line per line
of data, with line breaks in event names and IDs replaced. The worker's
once-a-second sweep sends `:` and a blank line to an event stream that has
been quiet for `--sse-keep-alive`, unless a writer is already waiting on its
backlog. Each write moves the next one along, and the stream starts and ends
on whole events, so a comment never splits one.

---

## WebSocket

RFC 6455 over HTTP/1.1, over HTTP/2 streams (RFC 8441) and over HTTP/3
streams (RFC 9220), with permessage-deflate (RFC 7692) under `--ws-compress`.
Framing, UTF-8 validation and deflate are aviancore's (`WebSocketFrame.swift`,
`WebSocketDeflate.swift`, `avian_wsdeflate.c`). The handshake, the connection
state and the handler API are Garuda's (`WebSocket.swift`, `WebSocketAPI.swift`,
and `WebSocketStreams.swift` for what differs on a stream).

- **Handshake.** A GET with `Upgrade: websocket`, `Connection: Upgrade`,
  version 13 and a 16-byte key. A plain GET to a WebSocket route is 426 with
  `Upgrade: websocket`; another version is 426 with `Sec-WebSocket-Version: 13`;
  a missing or malformed key is 400. Middleware and extractors run first, and
  headers middleware adds go out with the 101. The route's subprotocols are
  matched against the client's offer in the route's order of preference.
- **On a stream.** HTTP/2 connections send `SETTINGS_ENABLE_CONNECT_PROTOCOL`.
  A CONNECT with `:protocol: websocket`, `:scheme`, `:path`, `:authority` and
  version 13 is routed as the GET it would be on HTTP/1.1, and answered 200
  with no key. The stream is dispatched on its HEADERS, and DATA carries the
  frames. `:protocol` on an HTTP/2 connection that did not offer it, or with
  END_STREAM on the HEADERS, is `RST_STREAM(PROTOCOL_ERROR)`. A plain GET to the
  route is 400. Any other `:protocol` that is not WebTransport is 501.
- **Frames.** A frame is decoded once its whole payload is buffered, so a
  connection holds at most `--ws-max-message` plus a header. Unmasked client
  frames, RSV bits nothing negotiated, unknown opcodes, fragmented or oversized
  control frames, a continuation with no message and a new message during one
  are closed with 1002. Text is checked for UTF-8 frame by frame, and fails
  with 1007 at the frame that breaks it. A message over the limit, joined or
  inflated, is 1009.
- **Control frames** are answered as they arrive, whatever the handler is
  doing: a ping is answered with a pong carrying its payload, and a close with
  a close carrying its code. A WebSocket quiet for `--ws-ping-interval` is
  pinged, and closed if the pong does not come within `--ws-ping-timeout`.
- **Closing.** A close from the peer ends the handler's `receive` once every
  message before it has been read, with the code (1005 when there was none,
  1006 when the connection ended without a close). A close the server sends
  first waits `--ws-ping-timeout` for the answer. A handler that returns
  without closing closes with 1000, one that throws with 1011, and a draining
  worker with 1001. On a stream the peer's END_STREAM or FIN stands for the
  socket closing. Once the closes are exchanged the server ends its side the
  same way, and a WebSocket that is abandoned is reset with
  `RST_STREAM(CANCEL)` or `H3_REQUEST_CANCELLED`. Other streams on the
  connection carry on either way.
- **Flow.** Up to `--ws-max-queue` messages and `--ws-max-queue-bytes` bytes wait
  for a handler that is not reading. Past that, HTTP/1.1 stops reading the
  socket and TCP slows the sender. On a stream, bytes stop being credited back,
  so flow control stops that one stream and leaves the rest of the connection
  alone. A send waits while more than `writeHighWaterMark` is queued for a slow
  reader, and every concurrent sender waits, so a peer that reads nothing
  cannot be flooded into the server's memory by a second task.
- **Deflate** contexts are made on the first compressed message in each
  direction, and messages under 64 bytes go out uncompressed.

`scripts/websocket-test.py` drives all of this with a client built from a
socket, and checks the `websockets` library against it.
`scripts/websocket-streams-test.py` runs the same checks over HTTP/2 (`h2`) and
HTTP/3 (`aioquic`), along with flow control, several WebSockets on one
connection, and `--websocket-protocols`.

---

## Testing

Each protocol is tested against implementations that share none of its code:
`scripts/http2-test.py` (`h2`, each check cleartext and over TLS),
`scripts/http3-test.py` and `scripts/webtransport-test.py` (`aioquic`),
`scripts/router-streams-test.py` (routes, delays and cancellation on HTTP/2 and
HTTP/3), `scripts/handler-test.py` (handler framing on all three) and
`scripts/websocket-test.py` (WebSocket, with `websockets` for interoperability)
and `scripts/websocket-streams-test.py` (WebSocket over HTTP/2 and HTTP/3).
`swift test` covers the parser, HPACK, QUIC packet protection and streams, and
WebSocket framing. The parsers are fuzzed ([fuzz/README.md](fuzz/README.md)).

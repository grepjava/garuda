# Transports

What each protocol implementation does and enforces. The process model and
the runtime are in [ARCHITECTURE.md](ARCHITECTURE.md). Flags are in
[CONFIG.md](CONFIG.md). Linux and macOS are supported; Windows support is
experimental and serves from a single process.

| | Status |
| --- | --- |
| HTTP/1.1, HTTP/1.0 | cleartext and TLS |
| HTTP/2 | `h2` over TLS via ALPN, `h2c` with prior knowledge |
| HTTP/3 | with `--http3`, over Garuda's own QUIC (`Sources/GarudaQUIC`) |
| WebTransport | over HTTP/3, through `app.webTransport` routes |
| WebSocket | HTTP/1.1, HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220), through `app.webSocket` routes |

Some limits below have no flag. They are fields of `ServerConfig`, set by
building one and serving with `app.run(config:)` instead of `app.run()`,
which reads the command line:

```swift
import Garuda

let app = Application()
app.get("/") { _, response in response.send("hello\n") }

var config = ServerConfig()
config.host = "0.0.0.0"
config.port = 443
config.tlsCertificates = [TLSCertificateFiles(chain: "/etc/garuda/site.pem", key: "/etc/garuda/site.key")]
config.http3Enabled = true
config.h2MaxConcurrentStreams = 256
config.requestHeadTimeout = .seconds(10)
app.run(config: config)
```

[Limits and timeouts](#limits-and-timeouts) lists them.

---

## One request path

HTTP/2 and HTTP/3 change framing, multiplexing and header encoding, not what a
request is. A handler is handed the same `Request` and `Response` whichever
protocol carried them.

- **HTTP/1.1** is one task per connection. It reads into the connection's
  buffer, parses the head in place, reads the body, finds the route, runs the
  handler and writes the answer.
- **HTTP/2** is a reader task and a writer task per connection. The reader
  reads frames, owns the HPACK decoder and the stream table, keeps the
  receive windows and enforces the limits; the writer sends what nobody else
  does. Each stream's handler runs in a task from the shard's pool, so a
  handler that waits holds up no other stream.
- **HTTP/3** is one endpoint task per UDP socket. It owns every QUIC
  connection on that socket and the HTTP/3 state above them. Handlers run in
  pooled tasks, as HTTP/2's do.
- A request to a route that has run many times without ever suspending, and
  is not in the heavy lane, is answered by the reader (HTTP/2, when it is the
  connection's only stream) or the endpoint (HTTP/3) itself, without the
  hand-off to a task. One run that does suspend sends the route to the pool
  for good.

**The head is rebuilt as HTTP/1.1 text** in the stream's own buffer and
described exactly as the HTTP/1.1 parser would describe it, so routing,
middleware and extractors cannot tell the protocols apart. It is held to the
parser's rules: a method that is a token, a target with no space or control
byte, field values with no control byte, at most 100 fields, and the head
size limit. `:authority` becomes the one `Host` line. A Host field sent beside
it must name the same authority, ignoring case, or the request is malformed
(RFC 9113 8.3.1, RFC 9114 4.3.1), an empty `:authority` beside a Host
included. Cookie fields a client split are joined into one.

**Bodies are collected whole before dispatch** on all three protocols, held
to `--max-body` or the route's own limit (`app.maxBodySize`). On HTTP/2 and
HTTP/3 a request is dispatched when its stream ends (END_STREAM, a trailer
section, or FIN). An extended CONNECT (a WebSocket or a WebTransport session)
is dispatched on its head, because its stream does not end.

**The response is one answer with three encodings**: header text on
HTTP/1.1, HPACK on HTTP/2, QPACK on HTTP/3. The server adds `date` and
`server: garuda` unless the handler set them, and frames the body itself: a
`Content-Length`, `Transfer-Encoding` or `Connection` field the handler set on
a whole body is dropped and the real length sent. A streamed body is held to
a `Content-Length` the handler declared; see
[Streaming responses](#streaming-responses-and-backpressure).

---

## HTTP/1.1

RFC 9112. Keep-alive, pipelining, chunked request bodies,
`Expect: 100-continue`, `HEAD`, HTTP/1.0. The parser
(`Sources/GarudaWire/HTTPParser.swift`) is a single pass with no backtracking
or allocation, returning offsets into the read buffer. Nothing is copied on
the way in: the handler reads the request where it arrived.

### Framing and smuggling defences

- Whitespace between a header name and its colon: 400.
- `Content-Length` with `Transfer-Encoding`, or two different `Content-Length`
  values: 400.
- `Transfer-Encoding` is parsed as a list, and only a bare `chunked` frames a
  body. A last coding other than `chunked` (`xchunked`, `chunked;x=1`, `gzip`)
  is 400 (RFC 9112 6.3). `gzip, chunked` is 501 (RFC 9112 6.1). A second
  `Transfer-Encoding` field is 400.
- `obs-fold` lines and control characters in field values (including bare CR)
  are rejected with 400.
- HTTP/1.1 without `Host`, or with two: 400 (RFC 9112 3.2).
- A version other than HTTP/1.0 or HTTP/1.1: 505. Empty lines before the
  request line are skipped (RFC 9112 2.2).
- Chunk sizes are at most 15 hex digits, and size lines and chunk data end in
  CRLF. Extensions are skipped. The trailer section is read and dropped, and
  limited to 32 KiB (431 past it).
- A head larger than `ServerConfig.maxHeadSize` (32 KiB) is 431, and so is one
  with more than `ServerConfig.maxHeaders` (100) fields; a request target
  longer than the head limit is 414. A declared `Content-Length` past the body
  limit is 413 before any body is read. A chunked body is counted as it is
  decoded, and 413 once it passes the limit.
- Every refusal here closes the connection.

`Expect: 100-continue` is answered `100 Continue` when the server is about to
wait for the body, after the length has been checked: a body that would be
413 is refused without the 100.

### Keep-alive and pipelining

HTTP/1.1 defaults to keep-alive, HTTP/1.0 to close; `Connection` overrides
both. Keep-alive is off from the moment shutdown or `--drain-delay` begins,
and after `ServerConfig.maxRequestsPerConnection` requests when that is set
(it is 0, unlimited, by default).

The body is read whole, and never past its declared end. Bytes after it are
the next request, parsed once this one is answered. Answers to pipelined
requests are written together: when the connection is about to wait for
input, after `ServerConfig.pipelineDepth` answers (16), or once 64 KiB is
waiting. A body of 64 KiB or more is written from the response's own buffer
rather than copied behind the head.

### Timeouts

- An idle connection is closed after `--keep-alive` seconds (5).
- Once a head has begun, each read of the rest of it may wait
  `ServerConfig.requestHeadTimeout` (30 s).
- Each read of a body may wait `ServerConfig.bodyTimeout` (30 s).

---

## TLS

TLS over TCP is Vega's `VegaTLS` (`Sources/Garuda/TLS.swift`). The TLS library
is a vendored BoringSSL by default, or the system's OpenSSL 3 when built with
the `OpenSSL` package trait (`swift build --traits OpenSSL`). The library
never sees the socket: the stream feeds it ciphertext and takes ciphertext
from it. Once the handshake is done a TLS stream reads and writes like any
other, and the connection is served as a cleartext one is.

- The handshake must finish within `ServerConfig.tlsHandshakeTimeout`
  (10 s). A TLS connection ends with `close_notify`.
- TLS 1.2 minimum, compression and renegotiation off. There is no flag for
  cipher suites or versions; the library's defaults apply.
- **ALPN**: `h2` then `http/1.1`; `http/1.1` alone with `--no-http2`; `h2`
  alone with `--http2-only`. A connection that negotiated `h2` must send the
  HTTP/2 preface.
- **SNI**: `--tls-cert` and `--tls-key` repeat, one key for each certificate.
  The first pair is the default, for a client that names no host or one no
  certificate covers. Each other certificate serves the names in its subject
  alternative names (its common name when it has none), a wildcard covering
  one label. HTTP/3 chooses the same way, in its own handshake.
- **Session resumption**: session tickets are sealed with one key that every
  shard shares, so a client resumes on whichever shard its next connection
  reaches.
- **Reloading**: `--tls-reload SECS` looks at the certificate and key files
  every SECS seconds and serves them again when they change, to new TLS and
  QUIC handshakes; connections already open are untouched. Files that do not
  make a usable set are reported, and the ones in use kept.
- **ACME**: Garuda has no ACME client. An outside one (certbot `--webroot`)
  writes the files; `--tls-reload` picks them up. `--acme-webroot DIR` serves
  the HTTP-01 challenges it writes, from
  `DIR/.well-known/acme-challenge/TOKEN`, on the `--redirect-http` port, which
  it needs. A token must be base64url and the file at most 4 KiB.
- `--redirect-http PORT` also listens for plain HTTP on PORT and answers
  every request with a redirect to the same URL on https: 301 for GET and
  HEAD, 308 for anything else, so a POST stays a POST. It needs `--tls-cert`
  and a port of its own.
- `--hsts SECS` adds `Strict-Transport-Security: max-age=SECS` to every
  answer over TLS and HTTP/3 that does not set its own. It needs `--tls-cert`.

**Not available**: kernel TLS (`--ktls` and `--no-ktls` are not accepted),
`sendfile` over TLS (a `--static-dir` file goes out by `sendfile` over
cleartext HTTP/1.1 only, and is read and encrypted otherwise), and the
`tls-alpn-01` ACME challenge.

---

## HTTP/2

RFC 9113, HPACK RFC 7541 (`HTTP2.swift`, `HTTP2Writer.swift`,
`Sources/GarudaWire/HPACK.swift`).

### Connection start and settings

Cleartext HTTP/2 is served to a client that opens with the preface. The same
port serves HTTP/1.1, because the preface is matched in full first. A
connection that starts `PRI ` and diverges, or whose first byte cannot start
an HTTP/1 method, gets `GOAWAY(PROTOCOL_ERROR)` (RFC 9113 3.4).
`--http2-only` removes the HTTP/1 fallback: anything but the preface is
refused that way. `--no-http2` disables HTTP/2. `Upgrade: h2c` is not
supported.

| Server setting | Value | Set by |
| --- | --- | --- |
| `MAX_CONCURRENT_STREAMS` | 128 | `ServerConfig.h2MaxConcurrentStreams` |
| `INITIAL_WINDOW_SIZE` | 256 KiB | `ServerConfig.h2InitialWindowSize` (at least 65,535) |
| `MAX_FRAME_SIZE` | 16 KiB | `ServerConfig.h2MaxFrameSize` |
| `MAX_HEADER_LIST_SIZE` | 32 KiB | `ServerConfig.maxHeadSize` |
| `ENABLE_PUSH` | 0 | |
| `ENABLE_CONNECT_PROTOCOL` | 1, when WebSockets over HTTP/2 are on | `--websocket-protocols`, `--no-websockets` |

A WINDOW_UPDATE at the start raises the connection window to the stream
window, so one upload can use the link.

### Validation

- A frame larger than `MAX_FRAME_SIZE`: `GOAWAY(FRAME_SIZE_ERROR)`. Stream IDs
  must be odd and increasing.
- A header block cannot be interleaved with other frames. CONTINUATION
  assembly past twice the header list limit: `GOAWAY(ENHANCE_YOUR_CALM)`.
- A block that does not decode, or a decoded header list larger than
  `MAX_HEADER_LIST_SIZE` (counted as RFC 7541 counts it, 32 bytes a field
  on top of its name and value): `GOAWAY(COMPRESSION_ERROR)`. HPACK is
  stateful, so such a block ends the connection, not just the request.
- Pseudo-headers must come first, once each, from `:method`, `:path`,
  `:scheme`, `:authority`, and `:protocol` where it was offered; the first
  three are required, and a plain CONNECT is refused. Field names must be
  lower case tokens, and values may not start or end with whitespace or hold
  a control byte. Connection-specific fields other than `te: trailers`
  (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`,
  `upgrade`) are malformed, and so is a `Host` that differs from
  `:authority`. A malformed request gets `RST_STREAM(PROTOCOL_ERROR)`.
- A second HEADERS on an open stream must end it. It is a trailer section,
  decoded to keep HPACK in sync and dropped. Without END_STREAM it is
  `GOAWAY(PROTOCOL_ERROR)`.
- Priority is parsed only to reject self-dependency. A client `PUSH_PROMISE`
  is a connection error. Unknown frames are ignored. SETTINGS values are
  range-checked; a changed `INITIAL_WINDOW_SIZE` applies to open streams.
  PING is answered.
- A new stream past `MAX_CONCURRENT_STREAMS`, or after either side's GOAWAY,
  is decoded and refused with `RST_STREAM(REFUSED_STREAM)`. A peer's GOAWAY
  stops new streams; the ones open are still answered.

HPACK: static and dynamic tables (4,096 bytes), Huffman both ways, tested
against RFC 7541 Appendix C. Decoding hands out borrowed pointers; the dynamic
table is descriptors over an append-only arena. The encoder never indexes and
Huffman-codes a literal when that is shorter. Each connection keeps the
encodings of the response fields it sent last, so a repeated field is a copy.

### Flow control

**Sending.** A stream whose handler has finished, and whose whole body fits
the stream and connection windows (and 64 KiB), writes its own answer when
nobody else is writing. Everything else goes to the connection's writer,
which frames DATA limited by the peer's frame size, the stream window and
the connection window, at most 64 KiB a pass shared between streams in turn.
WINDOW_UPDATE and a settings change wake it.

**Receiving.** DATA is charged to both windows before anything can reject
it. Bytes count as consumed on arrival, since bodies are buffered before
dispatch, and WINDOW_UPDATE goes out, for the stream and for the connection,
once half the initial window has accumulated. DATA for a closed stream still
returns its bytes to the connection window, and is answered
`RST_STREAM(STREAM_CLOSED)`.

**Body length.** A body longer or shorter than its `Content-Length` is
`RST_STREAM(PROTOCOL_ERROR)` (RFC 9113 8.1.1), checked as it arrives and at
its end; HEADERS with END_STREAM and a non-zero `Content-Length` too. Past
`--max-body`, or a route's own limit, declared or as it arrives: a 413
response, then `RST_STREAM(NO_ERROR)` so the client stops sending (RFC 9113
8.1). A streamed response that ends short of its declared length, or whose
handler throws part-way, is reset with `INTERNAL_ERROR`.

### Rapid reset (CVE-2023-44487)

A reset frees a stream at once, so a concurrency limit does not stop a peer
that opens and cancels streams in a loop. Each connection has an allowance of
`max(100, 2 × MAX_CONCURRENT_STREAMS)`, 256 by default. A stream reset before
its answer was sent spends one; a stream answered earns one back, up to the
cap. At zero the connection gets `GOAWAY(ENHANCE_YOUR_CALM)`. A reset after
the answer costs nothing. A reset cancels the stream's handler task, so a
handler waiting on I/O or a sleep stops waiting, and whatever it answers is
dropped.

### Timeouts

The reader waits at most `--keep-alive` for the next bytes. When that passes
with no stream open and no handler running, the connection is sent
`GOAWAY(NO_ERROR)` and closed. When it passes with streams open, any stream
whose body has received nothing for `ServerConfig.bodyTimeout` (30 s) is
reset with `CANCEL`. A response the client stops reading has no time limit
on HTTP/2: its handler's writes wait until the client reads, resets the
stream or the connection ends.

---

## HTTP/3 and QUIC

QUIC is Garuda's own, in Swift (`Sources/GarudaQUIC`). It does no I/O: the
endpoint hands it datagrams and asks it for datagrams. Cryptographic
primitives (hashes, HKDF, AEAD, key exchange, signatures) come from Vega's
`VegaCrypto`, on the same TLS library as TCP.

| RFC | Implemented |
| --- | --- |
| 9000 | packets, frames, streams, flow control, connection IDs, version negotiation, path validation, 3× anti-amplification |
| 9001 | packet and header protection, key update |
| 9002 | loss detection by packet number and time, PTO, NewReno |
| 9369 | QUIC version 2 |
| 9114 | HTTP/3 frames, control and QPACK streams |
| 9204 | QPACK, static table and Huffman only |
| 9221, 9297, 9220 | datagrams, capsules, extended CONNECT (for WebTransport and WebSocket) |

`--http3` needs `--tls-cert`: QUIC has no cleartext form. It is served on UDP
`--quic-port`, or the TCP port when that is not given.

### Handshake

`TLS13.swift` is a server TLS 1.3 handshake without a record layer:
AES-128-GCM, ChaCha20-Poly1305 and AES-256-GCM in that preference; X25519 or
P-256; the signature schemes the key supports; ALPN `h3` only.

The certificate is chosen by the name in the ClientHello, matched against
each certificate by the same rule the TCP path uses; the first pair is the
default. A new connection takes the certificates as they are then, so
`--tls-reload` reaches it.

Not supported: session resumption, 0-RTT, client certificates,
HelloRetryRequest (a client offering no supported group is refused), and
Retry packets.

Packet protection is tested against RFC 9001's vectors and packets aioquic
protected (`scripts/quic-vectors.py`), and the whole stack against `aioquic`.

### Sockets and connections

Each shard binds a UDP socket per worker thread with `SO_REUSEPORT`; the
kernel hashes datagrams to sockets by four-tuple. A connection is found by
destination connection ID. The socket is set not to fragment, its buffers to
2 MiB, and a reply leaves from the local address the client wrote to.

- An unsupported version, in a datagram large enough to start a connection,
  gets Version Negotiation listing versions 1 and 2.
- A new connection needs a client Initial datagram of at least 1,200 bytes
  with a destination connection ID of at least 8 bytes, and room on its
  socket: `ServerConfig.maxQUICConnections` (4,096) each. Past that, and
  during shutdown, the datagram is dropped.
- Until a Handshake packet from the client decrypts, the server sends at most
  three times what it received.
- The peer's address changes only once a PATH_CHALLENGE to the new address
  has been answered. Until then the connection keeps sending where it was,
  and what goes to the new address is held to three times what came from it.
  A client whose new address hashes to another socket must reconnect.

Up to 32 datagrams are taken per receive call. The endpoint waits on the
socket no longer than the earliest QUIC timer, and at most a second.

### Loss recovery and sending

Packet numbers are never reused. Each sent packet records what it carried,
and the data of a lost packet is sent again in a new one. A connection sends
only while its NewReno congestion window has room; beyond that only
acknowledgements and probes go out.

A connection's datagrams are built straight into one buffer, and each run of
equal-sized datagrams to one peer goes out in a single segmented send, up to
32 at a time. With UDP GSO (Linux 4.18 and later) that is one system call;
where the kernel lacks it the segments go out as a batch. One connection
sends at most 4,096 datagrams before the others get a turn.

### Transport parameters

| Parameter | Value |
| --- | --- |
| `max_idle_timeout` | `--keep-alive` |
| `initial_max_stream_data_*` | 256 KiB, `ServerConfig.h2InitialWindowSize` |
| `initial_max_data` | eight times that |
| `initial_max_streams_bidi` | 128, `ServerConfig.h2MaxConcurrentStreams` |
| `initial_max_streams_uni` | 128 |
| `max_datagram_frame_size` | 1,200 |
| `active_connection_id_limit` | 4 |

Windows extend as the application reads, once they have fallen by half. A
request body counts as read when it arrives, since it is buffered whole.

### HTTP/3

`HTTP3.swift`, `HTTP3Connection.swift`, `HTTP3Stream.swift`. The server opens a
control stream and QPACK encoder and decoder streams.

| Server setting | Value |
| --- | --- |
| `QPACK_MAX_TABLE_CAPACITY`, `QPACK_BLOCKED_STREAMS` | 0 |
| `MAX_FIELD_SECTION_SIZE` | `ServerConfig.maxHeadSize` (32 KiB) |
| `ENABLE_CONNECT_PROTOCOL` | 1 |
| `H3_DATAGRAM`, `WEBTRANSPORT_MAX_SESSIONS` | 1 and 16, when the client allows QUIC datagrams |

- A second control or QPACK stream, or a client push stream:
  `H3_STREAM_CREATION_ERROR`. A first control frame other than SETTINGS:
  `H3_MISSING_SETTINGS`. A second SETTINGS, or DATA, HEADERS or PUSH_PROMISE
  on the control stream: `H3_FRAME_UNEXPECTED`. A repeated setting, or one of
  HTTP/2's: `H3_SETTINGS_ERROR`. Losing the peer's control or QPACK stream:
  `H3_CLOSED_CRITICAL_STREAM`. The client's GOAWAY is noted and its requests
  go on being answered.
- Unknown unidirectional stream types get `STOP_SENDING` and are let go of.
  Unknown frame types are skipped.
- A malformed request, including a `Host` that differs from `:authority`:
  reset with `H3_MESSAGE_ERROR`. A field section past
  `MAX_FIELD_SECTION_SIZE`: answered 431, and the connection goes on; a
  HEADERS frame over twice that is reset with `H3_EXCESSIVE_LOAD`. A block
  QPACK cannot decode: `QPACK_DECOMPRESSION_FAILED`.
- How many requests a client has open at once is QUIC's stream limit (128).
- A body that disagrees with its `Content-Length` is reset with
  `H3_MESSAGE_ERROR` (RFC 9114 4.1.2). Past `--max-body`, or the route's own
  limit: 413, then `STOP_SENDING(H3_NO_ERROR)`. A body that receives nothing
  for `ServerConfig.bodyTimeout` (30 s) is reset with
  `H3_REQUEST_INCOMPLETE`; the endpoint looks once a second.
- A stream that ends without a request: `H3_REQUEST_INCOMPLETE`; one whose end
  cuts a frame short: `H3_FRAME_ERROR`. A second HEADERS is the trailer
  section, decoded and dropped.
- `RESET_STREAM` and `STOP_SENDING` on a request not yet answered spend the
  same rapid-reset allowance as HTTP/2. At zero: `H3_EXCESSIVE_LOAD`.
- An answer sent before the request body is whole ends with
  `STOP_SENDING(H3_NO_ERROR)`, so the client stops sending the rest.

**QPACK.** With a table capacity of zero, no header block can wait on another
stream. The encoder uses the static table and literals, Huffman-coded when
that is shorter. The decoder rejects dynamic references, and anything on the
peer's encoder stream but a Set Dynamic Table Capacity of zero closes the
connection with `QPACK_ENCODER_STREAM_ERROR`.

**Alt-Svc.** With `--http3`, HTTP/1.1 and HTTP/2 answers carry
`alt-svc: h3=":PORT"; ma=86400` (PORT is `--quic-port` or `--port`), unless
the handler set its own. HTTP/3 answers do not.

---

## WebTransport

draft-ietf-webtrans-http3, over HTTP/3 only (`WebTransport.swift`,
`HTTP3WebTransport.swift`).

```swift
app.webTransport("/echo") { (session: WebTransportSession) async throws in
    while let stream = try await session.acceptStream() {
        while let bytes = try await stream.read() { try await stream.write(bytes) }
        stream.finish()
    }
}
```

Extractors follow the session, as in
`{ (session: WebTransportSession, room: Path<String>) async throws in … }`.
`app.onWebTransport(pattern) { request, session in … }` takes the raw
request instead.

- A CONNECT with `:protocol: webtransport` goes to the routes; any other
  `:protocol` is 501. Middleware and extractors run first, so a refusal is an
  ordinary status. A route answers 200 and the stream becomes the session.
  Past 16 sessions on a connection: 503. A request to a WebTransport route
  that is not such a CONNECT: 400.
- Peer streams are recognised by prefix (unidirectional type `0x54`, or
  bidirectional opening with `0x41`) followed by the session ID. Datagrams name
  the session by quarter stream ID.
- Streams for a session not yet seen are held, 32 per connection, then reset
  with `WEBTRANSPORT_BUFFERED_STREAM_REJECTED`.
- A stream's bytes are given back to its window only as the handler reads
  them, so an unread stream only blocks its own sender.
- Capsules on the CONNECT stream: `CLOSE_WEBTRANSPORT_SESSION` records the
  code and reason (at most 1,024 bytes) and ends the session; FIN also ends
  it; others, including `DRAIN`, are skipped.
- Ending a session resets and stops its streams with
  `WEBTRANSPORT_SESSION_GONE` and ends every wait on it. A session the handler
  did not close is closed, with code 0, when it returns. Shutdown closes every
  session the same way.
- Incoming datagrams queue per session up to 64 or 256 KiB, dropping the
  oldest. `sendDatagram` returns false, sending nothing, for one larger than
  `session.maxDatagramSize` (at most 1,100 bytes with its prefix).
- One reader and one writer per stream, one stream acceptor and one datagram
  receiver per session; a second waiter gets `WebTransportError.busy`.
  `openStream` throws `WebTransportError.streamLimit` when the client allows
  no more streams. A stream's `write` waits while more than
  `ServerConfig.writeHighWaterMark` is queued on it.

---

## Streaming responses and backpressure

A handler can call `response.stream(...)`, or return `StreamingBody` or
`EventStream` (`StreamingResponse.swift`, `EventStream.swift`):

```swift
app.get("/lines") { _, response in
    let body = response.stream(contentType: "text/plain")
    for i in 1...3 { try await body.write("line \(i)\n") }
}
```

The head is made as every other answer's is (middleware headers, `onSend`
hooks, the server's own), with no `Content-Length` unless the handler set
one. The body is chunked on HTTP/1.1, delimited by the close on HTTP/1.0,
and DATA frames ended by END_STREAM or FIN on HTTP/2 and HTTP/3. Over HTTP/2
and HTTP/3 the head goes at once; over HTTP/1 it goes with the first write,
or with `flush()`. Returning from the handler ends the body, as does
`finish()`. With `--compress`, each write is compressed and flushed, and no
length is stated.

A write queues its bytes and returns, unless the backlog is above
`ServerConfig.writeHighWaterMark` (512 KiB). Then it waits until the backlog
falls to `ServerConfig.writeLowWaterMark` (128 KiB). The backlog is, on
HTTP/1, what is queued and being written; on HTTP/2, what is written and not
yet sent within the flow-control windows; on HTTP/3, what is not yet on the
QUIC stream, which itself holds no more than the high-water mark (at least
64 KiB) sent and unacknowledged. Over HTTP/1, writes that leave the backlog
under the mark go out together when the handler next waits or returns: a run
of writes is one system call.

Every producer waits, not only the first to arrive at a full backlog. Bytes
are queued and then waited on, so each producer can carry the backlog past the
mark by its own last write and no further: with one producer the ceiling is
the mark plus that write, and with several it is the mark plus one write each.
The mark is where writers start waiting rather than a ceiling on the buffer.

- A client that disconnects or resets the stream ends every write with
  `HandlerWaitError.cancelled`.
- Over HTTP/1, a write that the client takes none of for
  `ServerConfig.writeTimeout` (30 s) fails the body and closes the
  connection. HTTP/2 and HTTP/3 have no such limit: the writes wait until the
  client reads, resets the stream or the connection ends.
- A body that passes its `Content-Length` is ended there, and the write that
  passed it throws `cancelled`. One that ends short, or a handler that throws
  after the head was sent, closes the HTTP/1.1 connection or resets the
  stream.

### Server-sent events

```swift
app.get("/events") { () async -> EventStream in
    EventStream { events in
        var tick = 0
        while events.isOpen {
            tick += 1
            try await events.send("\(tick)", event: "tick", id: "\(tick)")
            try await events.sleep(for: .seconds(1))
        }
    }
}
```

`response.eventStream()` does the same from a handler that writes its own
response. The head goes at once with `content-type: text/event-stream` and
`cache-control: no-cache`, unless the handler set its own cache-control.
Events use the HTML event-stream format: one `data:` line per line of data,
with line breaks in event names and IDs replaced, and an optional `retry:`.

A stream quiet for `--sse-keep-alive` seconds (15; 0 for none), or the
`keepAlive:` given to `EventStream`, is sent a comment, `:` and a blank line,
unless the client is already behind. Events and comments are written whole,
so a comment never splits an event.

### Interim responses

```swift
app.get("/page") { _, response in
    await response.sendInterim(status: HTTPStatus(103),
                               headers: [("link", "</app.css>; rel=preload; as=style")])
    response.send(html: "<!doctype html>…")
}
```

`sendInterim` sends a 1xx head at once, ahead of the final answer: on HTTP/1.1
behind any pipelined answers still to go, on HTTP/2 and HTTP/3 as a HEADERS
frame of its own. It returns false, sending nothing, for a status outside
100 to 199 or 101, for a field that is not valid, to an HTTP/1.0 client, and
once the final answer has been decided.

---

## WebSocket

RFC 6455 over HTTP/1.1, over HTTP/2 streams (RFC 8441) and over HTTP/3
streams (RFC 9220), with permessage-deflate (RFC 7692) under `--ws-compress`.
Framing, UTF-8 validation and the deflate negotiation are in `GarudaWire`
(`WebSocketFrame.swift`, `WebSocketDeflate.swift`); the handshake, the
connection's side and the handler API in `WebSocket.swift`,
`WebSocketSession.swift`, `HTTP2WebSocket.swift` and `HTTP3WebSocket.swift`.

```swift
app.webSocket("/echo") { (ws: WebSocket) async throws in
    for try await message in ws {
        try await ws.send(message)
    }
}
```

`--websocket-protocols` (`http1`, `http2`, `http3`, all three by default)
chooses which protocols carry WebSockets; `--no-websockets` turns them off.

- **Handshake.** A GET with `Upgrade: websocket`, `Connection: Upgrade`,
  HTTP/1.1, version 13 and a 24-character key. A plain GET to a WebSocket
  route is 426 with `Upgrade: websocket`; another version is 426 with
  `Sec-WebSocket-Version: 13`; HTTP/1.0, or a missing or malformed key, is 400;
  with WebSockets off for the protocol, 501. Middleware and extractors run
  first, and headers middleware adds go out with the 101. The route's
  `subprotocols` are matched against the client's offer in the route's order
  of preference; a client that offered none of them is still accepted, with
  `ws.subprotocol` nil.
- **On a stream.** HTTP/2 connections send `SETTINGS_ENABLE_CONNECT_PROTOCOL`
  when WebSockets over HTTP/2 are on; HTTP/3 connections always do, for
  WebTransport. A CONNECT with `:protocol: websocket`, `:scheme`, `:path`,
  `:authority` and version 13 is routed as the GET it would be on HTTP/1.1,
  and answered 200 with no key. The stream is dispatched on its HEADERS, and
  DATA carries the frames. `:protocol` on an HTTP/2 connection that did not
  offer it, or with END_STREAM on the HEADERS, is
  `RST_STREAM(PROTOCOL_ERROR)`. A plain GET to the route is 400. Any other
  `:protocol` is 501.
- **Frames.** A frame is decoded once its whole payload is buffered.
  Unmasked client frames, RSV bits nothing negotiated, unknown opcodes,
  fragmented or oversized control frames, length encodings that are not the
  shortest, a continuation with no message and a new message during one are
  closed with 1002. Text is checked for UTF-8 frame by frame, and fails with
  1007 at the frame that breaks it. A frame or message over
  `--ws-max-message` (16 MiB), joined or inflated, is 1009. Messages that
  arrived before a violation are still delivered, and the close waits until
  the handler has read them.
- **Control frames** are answered as they arrive, whatever the handler is
  doing: a ping with a pong carrying its payload, and a close with a close
  carrying its code (1000 for a close with none). A close with a code no
  endpoint may send is 1002, one whose reason is not UTF-8 1007. A WebSocket
  quiet for `--ws-ping-interval` milliseconds (20,000; 0 for never) is
  pinged, and given up on if the pong does not come within
  `--ws-ping-timeout` milliseconds (20,000).
- **Closing.** A close from the peer ends the handler's `receive` once every
  message before it has been read, with the code in `ws.closeCode` (1005 when
  there was none, 1006 when the connection ended without a close). A close
  the server sends first waits `--ws-ping-timeout` for the answer. A handler
  that returns without closing closes with 1000, one that throws with 1011,
  and shutdown sends 1001. On a stream the peer's END_STREAM or FIN stands
  for the socket closing. Once the closes are exchanged the server ends its
  side the same way; a WebSocket given up on (no pong, or no answer to a
  close) is reset with `RST_STREAM(CANCEL)` or `H3_REQUEST_CANCELLED`. Other
  streams on the connection carry on either way.
- **Flow.** Up to `--ws-max-queue` messages (32) and `--ws-max-queue-bytes`
  bytes (4 MiB) wait for a handler that is not reading. Past that, HTTP/1.1
  stops reading the socket and TCP slows the sender. On a stream, bytes stop
  being credited back to the stream's window, so flow control stops that one
  stream and leaves the rest of the connection alone. A send waits while more
  than `ServerConfig.writeHighWaterMark` is queued for a slow reader, and
  every concurrent sender waits, so a peer that reads nothing cannot be
  flooded into the server's memory by a second task. Over HTTP/1.1, once the
  peer has taken none of a write for `ServerConfig.writeTimeout`, that send
  and every later one throw `WebSocketError.closed`.
- **Deflate** contexts are made on the first compressed message in each
  direction, and messages under 64 bytes go out uncompressed.

`scripts/websocket-test.py` drives all of this with a client built from a
socket, and checks the `websockets` library against it.
`scripts/websocket-streams-test.py` runs the same checks over HTTP/2 (`h2`) and
HTTP/3 (`aioquic`), along with flow control, several WebSockets on one
connection, and `--websocket-protocols`.

---

## Shutdown

On SIGTERM the server first waits `--drain-delay` milliseconds (0) with the
health check failing and keep-alive off; SIGINT and SIGQUIT do not wait.
Then:

- HTTP/1.1 connections finish the request in hand and close.
- WebSockets are sent 1001.
- HTTP/2 connections are sent `GOAWAY(NO_ERROR)` naming the last stream
  taken, once their WebSockets have closed, take no new streams, and finish
  the ones they have.
- HTTP/3 connections are sent GOAWAY naming the first request that will not
  be served, take no new connections or requests, close their WebTransport
  sessions, and close with `H3_NO_ERROR` once their requests are answered.

Whatever is still running after `--graceful-timeout` seconds (10) is cut
off. On Windows the server does not handle these signals; it stops when the
process ends.

---

## Limits and timeouts

| `ServerConfig` field | Flag | Default | Applies to |
| --- | --- | --- | --- |
| `maxHeadSize` | none | 32 KiB | HTTP/1.1 head (431), HTTP/2 header list, HTTP/3 field section |
| `maxHeaders` | none | 100 | fields in a request head |
| `maxBodySize` | `--max-body BYTES` | 16 MiB | request bodies; `app.maxBodySize` sets a route's own |
| `maxRequestsPerConnection` | none | 0 (unlimited) | HTTP/1.1 requests before `Connection: close` |
| `pipelineDepth` | none | 16 | HTTP/1.1 answers written as one batch |
| `keepAliveTimeout` | `--keep-alive SECS` | 5 s | idle HTTP/1.1 and HTTP/2 connections, QUIC idle timeout |
| `requestHeadTimeout` | none | 30 s | each read of an HTTP/1.1 head once it has begun |
| `bodyTimeout` | none | 30 s | a request body that stops arriving, on all three |
| `tlsHandshakeTimeout` | none | 10 s | the TLS handshake over TCP |
| `writeTimeout` | none | 30 s | a streamed body's or WebSocket's write over HTTP/1.1 |
| `writeHighWaterMark`, `writeLowWaterMark` | none | 512 KiB, 128 KiB | streamed bodies, WebSocket and WebTransport sends |
| `eventKeepAlive` | `--sse-keep-alive SECS` | 15 s | event-stream keep-alive comments |
| `h2MaxConcurrentStreams` | none | 128 | HTTP/2 streams, HTTP/3 requests at once |
| `h2MaxFrameSize` | none | 16 KiB | HTTP/2 frames a client may send |
| `h2InitialWindowSize` | none | 256 KiB | HTTP/2 and HTTP/3 receive windows |
| `maxQUICConnections` | none | 4,096 | QUIC connections per UDP socket |
| `gracefulShutdown` | `--graceful-timeout SECS` | 10 s | shutdown |
| `drainDelay` | `--drain-delay MS` | 0 | SIGTERM's wait before draining |

A route can also be given a deadline on its I/O waits (`app.deadline`,
answered 504) and a limit on how many of its handlers run at once
(`app.concurrencyLimit`, answered 503); see [HANDLER-API.md](HANDLER-API.md).

---

## Testing

Each protocol is tested against implementations that share none of its code:
`scripts/http2-test.py` (`h2`, each check cleartext and over TLS),
`scripts/http3-test.py` and `scripts/webtransport-test.py` (`aioquic`),
`scripts/router-streams-test.py` (routes, delays and cancellation on HTTP/2 and
HTTP/3), `scripts/handler-test.py` (handler framing on all three),
`scripts/websocket-test.py` (WebSocket, with `websockets` for
interoperability) and `scripts/websocket-streams-test.py` (WebSocket over
HTTP/2 and HTTP/3). They run the `garuda` and `garuda-conformance` binaries.

`swift test` covers the HTTP/1.1 parser, HPACK, WebSocket framing and deflate
(`GarudaWireTests`); QUIC packet protection, the handshake and streams
(`GarudaQUICTests`); and each transport end to end (`GarudaTests`:
`HTTP2Tests`, `HTTP3Tests`, `HTTP3TunnelTests`, `HTTP2WebSocketTests`,
`WebSocketTests`, `TLSTests`, `StreamingResponseTests`, `EventStreamTests`,
`InterimTests`, `RequestLimitsTests`, `LargeBodyTests`).

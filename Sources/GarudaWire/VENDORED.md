# GarudaWire

The HTTP wire layer: the HTTP/1.1 request parser and response writer, chunked
framing, and the header-level policies (Forwarded trust, trace context,
content coding, cache policy). Pure Swift, no C, no I/O.

`ByteBuffer`, HPACK, QPACK, the HTTP/2, HTTP/3 and WebSocket frames and
permessage-deflate moved to Vega's `VegaWire` and `VegaHTTP3` in Vega 0.5.0;
this module re-exports them (`Exports.swift`).

Vendored from aviancore's `AvianHTTP` module (github.com/grepjava/aviancore,
commit d7a4ef3, 0.7.3), together with `Bytes.swift` and `CivilTime.swift` from `AvianCore`. Same author, same licence.

Changes from upstream:

- `ContentDecoder.swift` is left out: it wraps aviancore's C decompressors.
  Garuda decompresses with Vega's `VegaExtras`.
- `ForwardedTrust` parses addresses with `inet_pton` directly instead of
  aviancore's `av_parse_ip` C shim.
- `DateCache` is new: pure Swift, one per connection, instead of aviancore's
  C formatter.
- `HTTPResponseParser` refuses a status below 100, which upstream read as a
  final response (found by `pgfuzz`).


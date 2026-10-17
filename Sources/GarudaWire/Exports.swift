// The wire formats Garuda shares with Vega -- ByteBuffer and ByteSpan, HPACK,
// HTTP/2 and HTTP/3 frames, QPACK, WebSocket frames and permessage-deflate --
// live in Vega's VegaWire and VegaHTTP3. GarudaWire re-exports them, so code
// that imports GarudaWire sees them as before.

@_exported import VegaWire
@_exported import VegaHTTP3

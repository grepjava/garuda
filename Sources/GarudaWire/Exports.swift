// The wire formats Garuda shares with Vega -- ByteBuffer and ByteSpan, HPACK,
// HTTP/2 and HTTP/3 frames, QPACK, WebSocket frames and permessage-deflate --
// live in Vega's VegaWire and its protocols' Core modules, as Garuda's SPI.
// GarudaWire re-exports them, so code that imports GarudaWire sees them as
// before.

@_exported import VegaWire
@_spi(Garuda) @_exported import VegaHTTP2Core
@_spi(Garuda) @_exported import VegaHTTP3Core
@_spi(Garuda) @_exported import VegaWebSocketCore

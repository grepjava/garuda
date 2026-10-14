// The engine under construction: Garuda served by Vega's work-stealing
// runtime, built with `--traits VegaEngine`. Without the trait this file is
// empty and Garuda runs on its own event loop per worker process, as before.
//
// It arrives in stages, each with the aviancore engine still the default:
// HTTP/1 over TCP, async support, the database clients from vega-db, then
// TLS, HTTP/2, WebSocket, the outbound client and HTTP/3.

#if VegaEngine
import Vega
import VegaIO
import VegaTLS
// vega-db's clients are linked but not imported until they replace Garuda's
// own: both extend Optional and the integers with `sqliteValue` and the like,
// and with both imported every such use is ambiguous.

/// The Vega engine, while it is being built.
enum VegaEngine {}
#endif

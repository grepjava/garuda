//===----------------------------------------------------------------------===//
// garuda-conformance: the routes the end-to-end suites need a handler for.
//
// Not a benchmark and not an example to copy: each route exists to make one
// server behaviour observable from outside, for the scripts under scripts/.
// Garuda 1's had more; the rest come with the features they exercise.
//
//   GET  /                       200, empty
//   GET  /compress/...           scripts/compress-test.sh (CompressionRoutes.swift)
//   /cache/...                   scripts/cache-test.sh (CacheRoutes.swift)
//   /broadcast/...               scripts/broadcast-test.py (BroadcastRoutes.swift)
//   /ws/...                      scripts/websocket-test.py (WebSocketRoutes.swift)
//   /wt...                       scripts/webtransport-test.py (WebTransportRoutes.swift)
//
// One shard unless the command line asks for more: a script reads back what
// a handler saw on the shard it ran on.
//===----------------------------------------------------------------------===//

import Garuda

let app = Application()

app.get("/") { _, response in
    response.send(status: .ok)
}

addCompressionRoutes(app)
addCacheRoutes(app)
addBroadcastRoutes(app)
addWebSocketRoutes(app)
addWebTransportRoutes(app)

let arguments = CommandLine.arguments
let sharded = arguments.contains { $0 == "--shards" || $0 == "--workers" }
app.run(arguments: sharded ? arguments : arguments + ["--shards", "1"])

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
//===----------------------------------------------------------------------===//

import Garuda

let app = Application()

app.get("/") { _, response in
    response.send(status: .ok)
}

addCompressionRoutes(app)
addCacheRoutes(app)
addBroadcastRoutes(app)

app.run()

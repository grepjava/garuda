//===----------------------------------------------------------------------===//
// Routes for scripts/compress-test.sh: a response per case the compression
// decision has to get right.
//===----------------------------------------------------------------------===//

import Garuda
import VegaExtras

/// The text every compressible body is, so the test compares what it decodes
/// with one expected file.
let compressibleText: [UInt8] = {
    var text = ""
    for i in 0..<2000 { text += "line \(i) of a compressible response\n" }
    return Array(text.utf8)
}()

func addCompressionRoutes(_ app: Application) {
    let text = compressibleText
    let packed = (try? Compressor.compress(text, VegaExtras.ContentCoding.gzip)) ?? []

    func plain(_ pattern: String, _ headers: [(String, String)] = [], body: [UInt8]? = nil) {
        app.get(pattern) { _, response in
            response.addHeader("content-type", "text/plain; charset=utf-8")
            for (name, value) in headers { response.addHeader(name, value) }
            response.send(body ?? text)
        }
    }

    plain("/compress/text")
    plain("/compress/declared", [("content-length", "\(text.count)")])
    plain("/compress/small", [("content-length", "4")], body: Array("tiny".utf8))
    plain("/compress/encoded", [("content-encoding", "gzip")], body: packed)
    plain("/compress/no-transform", [("cache-control", "public, no-transform")])
    plain("/compress/vary", [("vary", "Accept-Encoding")])
    plain("/compress/etag", [("etag", "\"v1\"")])
    plain("/compress/weak-etag", [("etag", "W/\"v1\"")])
    app.get("/compress/png") { _, response in
        response.addHeader("content-type", "image/png")
        response.send(text)
    }
    app.get("/compress/events") { _, response in
        response.addHeader("content-type", "text/event-stream")
        response.send(text)
    }
    app.get("/compress/pieces") { () async -> StreamingBody in
        StreamingBody(contentType: "text/plain; charset=utf-8") { body in
            let step = text.count / 10 + 1
            var at = 0
            while at < text.count {
                try await body.write(Array(text[at..<min(text.count, at + step)]))
                at += step
            }
        }
    }
    // The first piece has to reach the client while the handler still
    // sleeps, which is what flushing each write through the compressor is
    // for.
    app.get("/compress/stream") { () async -> StreamingBody in
        StreamingBody(contentType: "text/plain; charset=utf-8") { body in
            try await body.write(Array(text[0..<100]))
            try await body.sleep(milliseconds: 1500)
            try await body.write(Array(text[100...]))
        }
    }
}

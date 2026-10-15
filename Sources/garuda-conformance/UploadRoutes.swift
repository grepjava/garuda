//===----------------------------------------------------------------------===//
// Routes for scripts/upload-test.py: request bodies read as they arrive,
// interim responses, and resumable uploads.
//
//   POST /body-stream            reads the body as it arrives, answers
//                                "<bytes> <fnv-1a hex>"; ?slow=1 waits 1 ms
//                                every 64 KiB read, ?hold=1 waits 1.5 s before
//                                reading anything
//   POST /body-limited           /body-stream, held to 1 KiB
//   POST /interim                a 103 with a Link, then 200
//   POST /files                  resumable uploads, kept in $GARUDA_UPLOAD_DIR;
//                                a finished one is answered 201 "<bytes>
//                                <fnv-1a hex>" and removed
//   HEAD, GET, PATCH, DELETE /uploads/:id   the uploads themselves
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import GarudaUploads
import Vega
import VegaFS

/// FNV-1a over everything added, with the count: what the script compares
/// with its own sum of what it sent.
struct Checksum {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    var count = 0

    mutating func add(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        count += bytes.count
    }

    var text: String {
        let hex = String(value, radix: 16)
        return "\(count) " + String(repeating: "0", count: 16 - hex.count) + hex
    }
}

func addUploadRoutes(_ app: Application) {
    app.onStreamingBody(.post, "/body-limited", maxBodySize: 1024) { _, response, body in
        var sum = Checksum()
        var buffer = IOBuffer(capacity: 64 * 1024)
        while try await body.read(into: &buffer) > 0 {
            buffer.withUnsafeBytes { sum.add($0) }
            buffer.clear()
        }
        response.send(sum.text)
    }

    app.onStreamingBody(.post, "/body-stream") { request, response, body in
        let slow = request.query.contains("slow=1")
        if request.query.contains("hold=1") { try await Runtime.sleep(for: .milliseconds(1500)) }
        var sum = Checksum()
        var sinceWait = 0
        var buffer = IOBuffer(capacity: 64 * 1024)
        while try await body.read(into: &buffer) > 0 {
            buffer.withUnsafeBytes { sum.add($0) }
            sinceWait += buffer.count
            buffer.clear()
            if slow && sinceWait >= 64 * 1024 {
                sinceWait = 0
                try await Runtime.sleep(for: .milliseconds(1))
            }
        }
        response.send(sum.text)
    }

    app.post("/interim") { _, response in
        await response.sendInterim(status: HTTPStatus(103), headers: [("Link", "</style.css>; rel=preload")])
        response.send("final")
    }

    guard let directory = getenv("GARUDA_UPLOAD_DIR").map({ String(cString: $0) }),
          let store = try? FileUploadStore(directory: directory) else { return }
    app.resumableUploads("/files", store: store, progressInterval: 1 << 20) { upload in
        var sum = Checksum()
        let file = try await File.open(upload.path)
        var buffer = IOBuffer(capacity: 1 << 16)
        while try await file.read(into: &buffer) > 0 {
            buffer.withUnsafeBytes { sum.add($0) }
            buffer.clear()
        }
        try await upload.remove()
        return Text(sum.text, status: .created)
    }
}

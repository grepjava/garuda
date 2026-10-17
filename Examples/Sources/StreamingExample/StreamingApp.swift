//===----------------------------------------------------------------------===//
// Streaming both ways: server-sent events, a large export, and uploads.
//
//   GET /countdown?from=10    server-sent events, one a second, then the end
//   GET /export.csv?rows=N    a CSV of N rows, written as it is produced
//   PUT /uploads/:name        the body written to disk as it arrives
//   GET /uploads/:name        how many bytes the upload holds
//
// What it shows:
//
// - `EventStream` for events, with keep-alive comments (`--sse-keep-alive`)
//   and the stream ending when the handler returns.
// - `StreamingBody` for a body too large to build in memory. A write waits
//   while the client is behind, so a slow reader slows the producer, not the
//   server's memory.
// - An upload read as it arrives (`onStreamingBody`), with a size limit of
//   its own, and written to disk a buffer at a time through VegaFS. The body
//   is never all in memory, and the disk sets the pace: the client is let
//   send more only as the handler reads.
// - An offloaded route (`app.offload`) for a handler that blocks on the file
//   system: it runs on Vega's blocking pool rather than on one of the shard's
//   worker threads.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Garuda
import Vega
import VegaFS

struct CountdownQuery: Decodable {
    let from: Int?
}

struct ExportQuery: Decodable {
    let rows: Int?
}

struct UploadInfo: Codable, Equatable {
    let name: String
    let bytes: Int
}

/// An upload's name is letters, digits, dots, dashes and underscores, and
/// does not start with a dot: nothing that walks out of the directory.
private func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 100 && !name.hasPrefix(".") && name.utf8.allSatisfy {
        ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
            || $0 == 46 || $0 == 45 || $0 == 95
    }
}

/// The streaming examples, storing uploads in `uploadDirectory`, which must
/// exist. `tick` is how far apart countdown events are.
public func streamingApp(uploadDirectory: String, tick: Duration = .seconds(1),
                         maxUploadBytes: Int = 64 << 20) -> Application {
    let app = Application()

    app.get("/countdown") { (query: Query<CountdownQuery>) in
        let from = min(max(query.value.from ?? 10, 0), 60)
        return EventStream { events in
            for n in stride(from: from, through: 1, by: -1) {
                try await events.send(String(n), event: "tick", id: String(n))
                // Throws when the client goes away, which ends the loop.
                try await events.sleep(for: tick)
            }
            try await events.send("liftoff", event: "done")
            // Returning ends the stream.
        }
    }

    app.get("/export.csv") { (query: Query<ExportQuery>) in
        let rows = min(max(query.value.rows ?? 1000, 0), 10_000_000)
        return StreamingBody(contentType: "text/csv") { body in
            try await body.write("id,square,label\n")
            // Rows are batched into writes of about 64 KiB, rather than one
            // write per row. A write waits while the client is behind.
            var batch = ""
            batch.reserveCapacity(70_000)
            for id in 0..<rows {
                batch += "\(id),\(id * id),row \(id)\n"
                if batch.utf8.count >= 64 * 1024 {
                    try await body.write(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { try await body.write(batch) }
        }
    }

    // Read as it arrives, never more than `maxUploadBytes`: a declared length
    // past it is answered 413 before the handler runs, and a body that grows
    // past it makes the read throw, which answers 413.
    app.onStreamingBody(.put, "/uploads/:name", maxBodySize: maxUploadBytes) { request, response, body in
        let name = request.parameter(0)
        guard validName(name) else { throw HTTPError(.badRequest, "not an upload name") }
        let final = uploadDirectory + "/" + name
        let partial = final + ".partial"
        // Written to a partial file and renamed when complete, so a reader
        // never sees half an upload under its name.
        var bytes = 0
        do {
            let file = try await File.create(partial, permissions: 0o644)
            var buffer = IOBuffer(capacity: 256 * 1024)
            // A read waits for the client, a write for the disk; neither holds
            // a worker thread meanwhile.
            while try await body.read(into: &buffer) > 0 {
                try await file.write(buffer)
                bytes += buffer.count
                buffer.clear()
            }
            try await file.sync()
            try await FileSystem.rename(partial, to: final)
        } catch {
            // Too large, cut off, or the disk said no: nothing is left behind.
            try? await FileSystem.removeFile(partial)
            throw error
        }
        try response.send(status: .created, json: UploadInfo(name: name, bytes: bytes))
    }

    // `stat` blocks on the disk, so this handler is offloaded: it runs on the
    // blocking pool, and the worker thread goes on serving.
    app.offload.get("/uploads/:name") { (name: Path<String>) throws -> JSON<UploadInfo>? in
        guard validName(name.value) else { throw HTTPError(.badRequest, "not an upload name") }
        var info = stat()
        guard stat(uploadDirectory + "/" + name.value, &info) == 0 else { return nil }
        return JSON(UploadInfo(name: name.value, bytes: Int(info.st_size)))
    }

    return app
}

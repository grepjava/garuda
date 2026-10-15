//===----------------------------------------------------------------------===//
// Streaming both ways: server-sent events, a large export, and uploads.
//
//   GET /countdown?from=10    server-sent events, one a second, then the end
//   GET /export.csv?rows=N    a CSV of N rows, written as it is produced
//   PUT /uploads/:name        the body written to disk
//   GET /uploads/:name        how many bytes the upload holds
//
// What it shows:
//
// - `EventStream` for events, with keep-alive comments (`--sse-keep-alive`)
//   and the stream ending when the handler returns.
// - `StreamingBody` for a body too large to build in memory. A write waits
//   while the client is behind, so a slow reader slows the producer, not the
//   server's memory.
// - An upload with a size limit of its own (`maxBodySize`), written to disk by
//   an offloaded route (`app.offload`): the handler blocks on the file
//   system, so it runs on Vega's blocking pool rather than on one of the
//   shard's worker threads.
//
// Garuda 1 read an upload as it arrived (`onStreamingBody`), so the disk set
// the pace and the body was never all in memory. Garuda 2 does not stream a
// request body yet: the body is read whole, within its route's limit, before
// the handler runs.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda

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

/// Why a file operation failed, with the errno.
struct FileError: Error {
    let operation: String
    let errno: Int32
}

/// The request body as it came, whatever its type: an upload is bytes, not
/// JSON. An extractor of its own is a few lines.
struct RawBody: RequestExtractor, Sendable {
    let bytes: [UInt8]

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> RawBody {
        RawBody(bytes: request.body)
    }
}

/// Writes `bytes` to `path` and makes them durable, or throws and leaves
/// nothing behind. Blocks: call it from the blocking pool.
private func writeFile(_ bytes: [UInt8], to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw FileError(operation: "open", errno: errno) }
    // Closed exactly once whatever happens: a second close could hit a file
    // another thread has opened since under the same number.
    defer { close(fd) }
    do {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw FileError(operation: "write", errno: errno) }
            offset += n
        }
        guard fsync(fd) == 0 else { throw FileError(operation: "fsync", errno: errno) }
    } catch {
        unlink(path)
        throw error
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

    // A body past the limit is answered 413 before the handler runs, and
    // before more of it than the limit is read.
    app.maxBodySize(maxUploadBytes) {
        app.offload.put("/uploads/:name") { (name: Path<String>, body: RawBody) throws -> JSON<UploadInfo> in
            guard validName(name.value) else { throw HTTPError(.badRequest, "not an upload name") }
            let final = uploadDirectory + "/" + name.value
            let partial = final + ".partial"
            // Written to a partial file and renamed when complete, so a reader
            // never sees half an upload under its name.
            try writeFile(body.bytes, to: partial)
            guard rename(partial, final) == 0 else {
                let failure = FileError(operation: "rename", errno: errno)
                unlink(partial)
                throw failure
            }
            return JSON(UploadInfo(name: name.value, bytes: body.bytes.count), status: .created)
        }
    }

    // `stat` blocks on the disk too, so this one is offloaded as well.
    app.offload.get("/uploads/:name") { (name: Path<String>) throws -> JSON<UploadInfo>? in
        guard validName(name.value) else { throw HTTPError(.badRequest, "not an upload name") }
        var info = stat()
        guard stat(uploadDirectory + "/" + name.value, &info) == 0 else { return nil }
        return JSON(UploadInfo(name: name.value, bytes: Int(info.st_size)))
    }

    return app
}

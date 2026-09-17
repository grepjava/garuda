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
// - `EventStream` for events, with keep-alive comments and the stream ending
//   when the handler returns.
// - `StreamingBody` for a body too large to build in memory. A write waits
//   while the client is behind, so a slow reader slows the producer, not the
//   server's memory.
// - `onStreamingBody` for an upload read as it arrives, with a size limit of
//   its own. Unread bytes hold back the client, so the disk sets the pace.
//   The file I/O runs on the blocking pool.
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

/// A file descriptor, handed to the blocking pool and back.
private struct Descriptor: Sendable {
    let fd: Int32
}

/// Why a file operation failed, with the errno.
struct FileError: Error {
    let operation: String
    let errno: Int32
}

/// The streaming examples, storing uploads in `uploadDirectory`, which must
/// exist. `tickMilliseconds` is how far apart countdown events are.
public func streamingApp(uploadDirectory: String, tickMilliseconds: UInt64 = 1000,
                         maxUploadBytes: Int = 1 << 30) -> Application {
    let app = Application()

    app.get("/countdown") { (query: Query<CountdownQuery>) async throws in
        let from = min(max(query.value.from ?? 10, 0), 60)
        return EventStream(keepAlive: 15_000) { events in
            for n in stride(from: from, through: 1, by: -1) {
                try await events.send(String(n), event: "tick", id: String(n))
                try await events.sleep(milliseconds: tickMilliseconds)
            }
            try await events.send("liftoff", event: "done")
            // Returning ends the stream.
        }
    }

    app.get("/export.csv") { (query: Query<ExportQuery>) async throws in
        let rows = min(max(query.value.rows ?? 1000, 0), 10_000_000)
        return StreamingBody(contentType: "text/csv") { body in
            try await body.write("id,square,label\n")
            // Rows are batched into writes of about 64 KiB, rather than one
            // write per row.
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

    app.onStreamingBody(.put, "/uploads/:name", maxBodySize: maxUploadBytes) { request, response, body in
        let name = request.parameter(0)
        guard validName(name) else {
            // Answered without reading the body; the engine discards it, or
            // closes an HTTP/1.1 connection with too much of it left.
            response.send(status: .badRequest)
            return
        }
        let final = uploadDirectory + "/" + name
        let partial = final + ".partial"

        // Written to a partial file and renamed when complete, so a reader
        // never sees half an upload under its name.
        let file = try await blocking { () throws -> Descriptor in
            let fd = open(partial, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { throw FileError(operation: "open", errno: errno) }
            return Descriptor(fd: fd)
        }
        var written = 0
        var descriptorOpen = true
        do {
            while let chunk = try await body.read() {
                try await blocking {
                    var offset = 0
                    while offset < chunk.count {
                        let n = chunk.withUnsafeBytes { write(file.fd, $0.baseAddress! + offset, $0.count - offset) }
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw FileError(operation: "write", errno: errno) }
                        offset += n
                    }
                }
                written += chunk.count
            }
            // Closed in here whatever happens, so the descriptor is never
            // closed twice -- a second close could hit a file opened since.
            descriptorOpen = false
            try await blocking {
                let synced = fsync(file.fd) == 0 ? 0 : errno
                close(file.fd)
                guard synced == 0 else { throw FileError(operation: "fsync", errno: synced) }
                guard rename(partial, final) == 0 else { throw FileError(operation: "rename", errno: errno) }
            }
        } catch {
            // Cut off, too large, or the disk refused: nothing is kept.
            let stillOpen = descriptorOpen
            try? await blocking {
                if stillOpen { close(file.fd) }
                unlink(partial)
            }
            throw error
        }
        try response.send(status: .created, json: UploadInfo(name: name, bytes: written))
    }

    app.get("/uploads/:name") { (name: Path<String>) async throws -> JSON<UploadInfo>? in
        guard validName(name.value) else { throw HTTPError(.badRequest, "not an upload name") }
        let path = uploadDirectory + "/" + name.value
        let size = try await blocking { () -> Int? in
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Int(info.st_size)
        }
        return size.map { JSON(UploadInfo(name: name.value, bytes: $0)) }
    }

    return app
}

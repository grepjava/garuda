//===----------------------------------------------------------------------===//
// A file service: uploads that survive a dropped connection, and downloads
// that can be resumed.
//
//   POST   /files                 upload, resumable, as the draft describes
//   GET    /files/                what is stored
//   GET    /files/<name>          one file, with byte ranges
//   DELETE /files/<name>          remove one
//   GET    /                      what to type to use it
//
// What it shows, and why each piece is here:
//
// - `app.resumableUploads` (GarudaUploads) for the upload itself. A client
//   that speaks the protocol (draft-ietf-httpbis-resumable-upload) is told
//   where its upload lives before a byte of the body is read, and can ask how
//   much arrived and send the rest as many times as it takes. One that does
//   not speak it sends an ordinary POST and never knows the difference. The
//   body is written to disk as it arrives, whatever its size: it is never all
//   in memory.
// - `UploadLimits` with both ends: nothing larger than `maxSize`, nothing
//   emptier than a byte, and no append smaller than 64 KiB except the one
//   that finishes an upload -- which is what stops a client resuming a large
//   file a few bytes per request.
// - Digests. A client that sends `Repr-Digest` has its upload checked against
//   it before the handler is called; one that sends `Want-Repr-Digest` is told
//   what the server made of it. Either way the handler stores the SHA-256
//   beside the file, so a later download can be checked too.
// - The file system through VegaFS, whose calls run on the blocking pool: a
//   rename or an unlink waits on the disk, and the shard's worker threads
//   keep serving meanwhile.
// - The download side is `--static-dir`: `main.swift` passes it, so the files
//   go out with `sendfile`, `ETag`, `Range` and a listing without this
//   application writing a line of it. A file service is the case where that
//   matters -- resumed downloads are ranges, and a browser seeking in a video
//   is ranges.
//
// Nothing here is kept in memory, so it works with any number of shards:
// uploads live in a directory as they arrive, and a finished one is renamed
// into place.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

import Garuda
import GarudaUploads
import VegaFS

/// What a finished upload became.
public struct StoredFile: Codable, Equatable, Sendable {
    public let name: String
    public let size: Int
    /// The SHA-256 of the bytes, in hex, so a client can check what it holds
    /// is what it sent.
    public let sha256: String
}

/// The upload store's directory and the one finished files are moved into.
/// Two directories rather than one, so a half-finished upload is never listed
/// as a file and never served.
public struct FilesConfiguration: Sendable {
    public var directory: String
    public var maximumBytes: Int
    public var maximumAgeSeconds: Int

    public init(directory: String, maximumBytes: Int = 1 << 30,
                maximumAgeSeconds: Int = 24 * 3600) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumAgeSeconds = maximumAgeSeconds
    }

    public var storeDirectory: String { directory + "/files" }
    public var uploadDirectory: String { directory + "/uploads" }

    /// The static route that serves what has been uploaded: `sendfile`,
    /// `ETag`, byte ranges and a listing, none of which this application has
    /// to write. `main.swift` adds it to the command line as `--static-dir`,
    /// and a test adds it to a `ServerConfig`.
    public var staticDirectory: (prefix: String, directory: String) { ("/files", storeDirectory) }
}

/// The file service. `configuration.directory` is made if it is not there.
public func filesApp(_ configuration: FilesConfiguration) -> Application {
    let app = Application()
    // Before the server starts, so on no worker thread: plain mkdir will do.
    for path in [configuration.directory, configuration.storeDirectory,
                 configuration.uploadDirectory] {
        #if os(Windows)
        // ucrt's mkdir takes no mode, and its errno is behind a function.
        if _mkdir(path) != 0 && _errno().pointee != EEXIST {
            fatalError("cannot make \(path): errno \(_errno().pointee)")
        }
        #else
        if mkdir(path, 0o755) != 0 && errno != EEXIST {
            fatalError("cannot make \(path): errno \(errno)")
        }
        #endif
    }
    let store = try! FileUploadStore(directory: configuration.uploadDirectory)
    let settled = configuration

    app.resumableUploads(
        "/files", uploads: "/uploads", store: store,
        limits: UploadLimits(maxSize: settled.maximumBytes, minSize: 1,
                             minAppendSize: 64 * 1024,
                             maxAge: settled.maximumAgeSeconds)) { upload in
        // The name the client asked for, or the upload's id when it asked for
        // nothing. `safeName` is the whole of the trust placed in it.
        let asked = filename(fromContentDisposition: upload.info.contentDisposition)
        let name = safeName(asked) ?? upload.info.id
        // Hashed on the blocking pool: a whole file takes long enough to hold
        // up every other request on the worker.
        let digest = hex(await upload.digest() ?? [])

        // Renamed rather than copied: the two directories are in the same
        // file system, so the file appears under its name whole or not at all.
        let destination = settled.storeDirectory + "/" + name
        do {
            try await FileSystem.rename(upload.path, to: destination)
            try await FileSystem.write(destination + ".sha256", contents: digest)
        } catch {
            throw HTTPError(.internalServerError, "the upload could not be stored")
        }
        // The bytes have moved, so what is left of the upload goes -- except
        // the answer below, which a client that loses it can ask for again
        // with GET on the upload's URL.
        try? await upload.remove()
        return JSON(StoredFile(name: name, size: upload.length, sha256: digest), status: .created)
    }

    // A file that exists never reaches this: the static route answers it
    // first. It is here so that one that does not is a 404, rather than the
    // 405 the DELETE below would otherwise make of a GET.
    app.get("/files/:name") { (_: Path<String>) async throws -> HTTPStatus in
        throw HTTPError.notFound
    }
        .summary("One file, served by the static route")

    app.delete("/files/:name") { (name: Path<String>) async throws -> HTTPStatus in
        guard let safe = safeName(name.value) else { throw HTTPError.notFound }
        let path = settled.storeDirectory + "/" + safe
        do {
            try await FileSystem.removeFile(path)
        } catch {
            throw HTTPError.notFound
        }
        try? await FileSystem.removeFile(path + ".sha256")
        return .noContent
    }
        .summary("Remove a file")

    app.get("/") { HTML(page(settled)) }

    return app
}

// MARK: - Names

/// A file name that cannot be anything else: no directory, no `..`, no dot at
/// the front, nothing but letters, digits and `.-_`, and not empty.
///
/// This is the only thing standing between a client's idea of a name and the
/// file system, so it says what is allowed rather than what is not.
func safeName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw.utf8.count <= 128, !raw.hasPrefix(".") else { return nil }
    for byte in raw.utf8 {
        let allowed = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        if !allowed { return nil }
    }
    return raw
}

/// The `filename="..."` of a Content-Disposition, or nil.
func filename(fromContentDisposition header: String?) -> String? {
    guard let header else { return nil }
    for part in header.split(separator: ";") {
        let trimmed = String(part).trimmingWhitespace()
        guard trimmed.lowercased().hasPrefix("filename=") else { continue }
        var value = String(trimmed.dropFirst("filename=".count))
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    return nil
}

func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return out
}

// MARK: - The page

private func page(_ configuration: FilesConfiguration) -> String {
    """
    <!doctype html>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Files</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;margin:2rem;max-width:44rem}
    pre{background:#f4f4f5;padding:.75rem 1rem;overflow-x:auto;border-radius:6px}
    code{font-size:13px}</style>
    <h1>Files</h1>
    <p>Uploads that survive a dropped connection, and downloads that can be resumed.
    At most \(configuration.maximumBytes / (1 << 20)) MiB, kept for
    \(configuration.maximumAgeSeconds / 3600) hours.</p>

    <h2>Upload</h2>
    <pre><code>curl -X POST --data-binary @photo.jpg \\
      -H 'Upload-Complete: ?1' \\
      -H 'Content-Disposition: attachment; filename="photo.jpg"' \\
      http://localhost:8080/files</code></pre>

    <p>With the digest of what you are sending, so the server refuses anything else:</p>
    <pre><code>curl -X POST --data-binary @photo.jpg \\
      -H 'Upload-Complete: ?1' \\
      -H "Repr-Digest: sha-256=:$(openssl dgst -sha256 -binary photo.jpg | base64):" \\
      http://localhost:8080/files</code></pre>

    <h2>Browse and fetch</h2>
    <pre><code>curl http://localhost:8080/files/
    curl -O http://localhost:8080/files/photo.jpg
    curl -r 0-1023 http://localhost:8080/files/photo.jpg   # the first kilobyte
    curl -C - -O http://localhost:8080/files/photo.jpg     # resume a download</code></pre>

    <p><a href="/files/">What is stored</a></p>
    """
}

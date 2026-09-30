//===----------------------------------------------------------------------===//
// Photo uploads that belong to someone, and survive a dropped connection.
//
//   POST   /users/:user/photos             upload one, resumable
//   HEAD   /users/:user/uploads/:id        how much of an upload arrived
//   PATCH  /users/:user/uploads/:id        send the rest
//   GET    /users/:user/uploads/:id        the answer, for a client that lost it
//   DELETE /users/:user/uploads/:id        give up on an upload
//   GET    /users/:user/photos             the user's photos
//   GET    /users/:user/photos/:id         one photo
//   DELETE /users/:user/photos/:id         remove one
//   GET    /                               what to type to use it
//
// Every route under /users/:user needs a bearer token, and only that user's
// token: the upload's own URL included, so nobody else can resume it, cancel
// it or read the answer it was given.
//
// What it shows, beyond the files example:
//
// - `resumableUploads` inside `group("/users/:user")`. The upload's URL is
//   made from the path the client used, so it lands under the same user, and
//   the upload's id is read after the parameters the group captured.
// - `onCreate`. The request that creates an upload and the one that completes
//   it are different requests, often minutes apart. The creating one has been
//   through the group's authentication, so `onCreate` records who it was, and
//   the completion handler reads that back from `upload.metadata` -- where no
//   client can write -- rather than trusting a header of the completing
//   request. It also refuses anything that does not say it is an image,
//   before a byte of it is stored.
// - Checking what the bytes are. `Content-Type` is the client's word. The
//   first bytes of the file are the file's, so a PNG is kept only if it
//   starts like one, and served back with the type that was checked.
// - `await upload.digest()`, which hashes on the blocking pool: a large file
//   would otherwise hold up every other request on the worker.
// - An answer with a `Location`. A client whose connection dies as the upload
//   completes asks the upload's URL again, and is given the same 201 with the
//   same `Location`, so it still learns where its photo went.
//
// Nothing is held in memory, so any number of workers can serve it: uploads
// live in one directory as they arrive, and a finished photo is renamed into
// its owner's.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import GarudaUploads

/// Who a request's bearer token belongs to.
public enum CurrentUser: RequestContextKey {
    public typealias Value = String
}

/// A stored photo, as the API describes it.
public struct Photo: Codable, Equatable, Sendable {
    public let id: String
    public let owner: String
    public let type: String
    public let size: Int
    /// The SHA-256 of the bytes, in hex.
    public let sha256: String
    public let url: String
}

public struct UploadsConfiguration: Sendable {
    /// Where uploads in progress and finished photos are kept.
    public var directory: String
    /// Bearer tokens and the users they belong to. A real application looks
    /// them up; the auth and starter examples show how.
    public var tokens: [String: String]
    public var maximumBytes: Int
    public var maximumAgeSeconds: Int

    public init(directory: String, tokens: [String: String],
                maximumBytes: Int = 50 << 20, maximumAgeSeconds: Int = 24 * 3600) {
        self.directory = directory
        self.tokens = tokens
        self.maximumBytes = maximumBytes
        self.maximumAgeSeconds = maximumAgeSeconds
    }

    public var uploadDirectory: String { directory + "/uploads" }
    public var photoDirectory: String { directory + "/photos" }
}

/// The photo service. `configuration.directory` is made if it is not there.
public func uploadsApp(_ configuration: UploadsConfiguration) -> Application {
    let app = Application()
    for path in [configuration.directory, configuration.uploadDirectory,
                 configuration.photoDirectory] {
        makeDirectory(path)
    }
    let store = try! FileUploadStore(directory: configuration.uploadDirectory)
    let settled = configuration

    app.get("/") { () -> HTML in HTML(page) }

    app.group("/users/:user") {
        app.authenticate(bearer: CurrentUser.self) { token in settled.tokens[token] }
        // A token is good for its own user's routes and nobody else's. The
        // group's `:user` is the request's first parameter.
        app.use { request, _ in
            guard request.parameterCount > 0,
                  request.parameter(0) == request[context: CurrentUser.self] else {
                throw AuthorizationError(needs: "the owner of these photos")
            }
            return nil
        }

        // Uploads are made at /users/:user/photos and live at
        // /users/:user/uploads/:id -- `uploads` is relative to the group.
        app.resumableUploads(
            "/photos", uploads: "/uploads", store: store,
            limits: UploadLimits(maxSize: settled.maximumBytes, minSize: 1,
                                 maxAge: settled.maximumAgeSeconds),
            onCreate: { request in
                // Refused here, the upload is never made: no id, no file.
                guard let type = imageType(request.header("content-type")) else {
                    throw HTTPError(.unsupportedMediaType, "only PNG, JPEG, GIF and WebP photos")
                }
                // Authentication ran before this, so there is always someone.
                let owner = request[context: CurrentUser.self] ?? ""
                return ["owner": owner, "type": type]
            }) { upload in
                try await file(upload, in: settled)
            }

        app.get("/photos") { (user: Context<CurrentUser>) async throws -> JSON<[Photo]> in
            JSON(try await photos(of: user.value, in: settled))
        }
            .summary("The user's photos")

        app.get("/photos/:id") { (user: Context<CurrentUser>, _: Path<String>, id: Path<String>)
            async throws -> StoredPhoto in
            guard let photo = try await load(id.value, of: user.value, in: settled) else {
                throw HTTPError.notFound
            }
            return photo
        }
            .summary("One photo")

        app.delete("/photos/:id") { (user: Context<CurrentUser>, _: Path<String>, id: Path<String>)
            async throws -> HTTPStatus in
            guard validID(id.value) else { throw HTTPError.notFound }
            let base = userDirectory(user.value, in: settled) + "/" + id.value
            guard unlink(base) == 0 else { throw HTTPError.notFound }
            _ = unlink(base + ".json")
            return .noContent
        }
            .summary("Remove a photo")
    }

    return app
}

// MARK: - Completing an upload

/// Checks a finished upload, moves it into its owner's directory, and answers
/// 201 with where it went.
func file(_ upload: CompletedUpload, in configuration: UploadsConfiguration) async throws -> Created<Photo> {
    // From `onCreate`, so from the server: the completing request is not asked
    // who it is, and a header it sends cannot change whose photo this is.
    guard let owner = upload.metadata["owner"], validUser(owner),
          let type = upload.metadata["type"] else {
        throw HTTPError(.internalServerError, "an upload with no owner")
    }
    guard sniff(upload.path) == type else {
        // What arrived is not what the client said it was. It goes, and the
        // answer says why; the answer is remembered like any other, so a
        // client that asks again hears the same.
        try? upload.remove()
        return Created(status: .unsupportedMediaType, location: nil,
                       error: "the file is not the \(type) it says it is")
    }

    // Hashed off the worker's thread. Computed already if the client sent
    // Repr-Digest or Want-Repr-Digest, in which case this costs nothing.
    let digest = hex(await upload.digest() ?? [])
    let id = upload.info.id
    let directory = userDirectory(owner, in: configuration)
    makeDirectory(directory)
    let destination = directory + "/" + id
    // A rename within one filesystem: the photo appears whole or not at all.
    guard rename(upload.path, destination) == 0 else {
        throw HTTPError(.internalServerError, "the photo could not be stored")
    }
    let url = "/users/\(owner)/photos/\(id)"
    let photo = Photo(id: id, owner: owner, type: type, size: upload.length,
                      sha256: digest, url: url)
    try writeFile(try JSONCoder.encode(photo), to: destination + ".json")
    // The bytes have moved; what is left of the upload goes, except the
    // answer below, which the upload's URL keeps giving until `maxAge`.
    try? upload.remove()
    return Created(photo, location: url)
}

/// 201 with a `Location` and the photo, or an error with a reason. The
/// `Location` is replayed with the rest of the answer to a client that asks
/// the upload's URL again.
struct Created<Value: Encodable>: ResponseConvertible {
    var value: Value?
    var status: HTTPStatus
    var location: String?
    var error: String?

    init(_ value: Value, location: String) {
        self.value = value
        status = .created
        self.location = location
    }

    init(status: HTTPStatus, location: String?, error: String) {
        self.status = status
        self.location = location
        self.error = error
    }

    func write(to response: borrowing Response) throws {
        if let location { _ = response.addHeader("Location", location) }
        if let value {
            try response.send(status: status, json: value)
        } else {
            try response.send(status: status, json: ["error": error ?? ""])
        }
    }
}

// MARK: - Reading photos back

/// A photo's bytes, sent with the type that was checked when it was stored.
struct StoredPhoto: ResponseConvertible {
    let type: String
    let bytes: [UInt8]

    func write(to response: borrowing Response) throws {
        _ = response.addHeader("Content-Type", type)
        _ = response.addHeader("X-Content-Type-Options", "nosniff")
        response.send(bytes)
    }
}

func load(_ id: String, of user: String, in configuration: UploadsConfiguration) async throws -> StoredPhoto? {
    guard validID(id) else { return nil }
    let base = userDirectory(user, in: configuration) + "/" + id
    // Reading a file is blocking work: a large one would hold the worker.
    return try await blocking { () -> StoredPhoto? in
        guard let about = readFile(base + ".json"),
              let photo = try? JSONCoder.decode(Photo.self, from: about),
              let bytes = readFile(base) else { return nil }
        return StoredPhoto(type: photo.type, bytes: bytes)
    }
}

func photos(of user: String, in configuration: UploadsConfiguration) async throws -> [Photo] {
    let directory = userDirectory(user, in: configuration)
    return try await blocking { () -> [Photo] in
        guard let dir = opendir(directory) else { return [] }
        defer { closedir(dir) }
        var found: [Photo] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            guard name.hasSuffix(".json"),
                  let about = readFile(directory + "/" + name),
                  let photo = try? JSONCoder.decode(Photo.self, from: about) else { continue }
            found.append(photo)
        }
        return found.sorted { $0.id < $1.id }
    }
}

// MARK: - What a file is

/// The image type a Content-Type names, if it is one this service keeps.
/// Parameters are dropped: `image/png; charset=x` is still a PNG.
func imageType(_ header: String?) -> String? {
    guard let header else { return nil }
    let bare = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
    let type = bare.trimmingWhitespace().lowercased()
    return ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(type) ? type : nil
}

/// The image type a file's first bytes say it is, or nil.
func sniff(_ path: String) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { _ = close(fd) }
    var head = [UInt8](repeating: 0, count: 12)
    let n = head.withUnsafeMutableBytes { read(fd, $0.baseAddress, 12) }
    guard n > 0 else { return nil }
    return imageType(ofBytes: Array(head[0..<n]))
}

func imageType(ofBytes head: [UInt8]) -> String? {
    func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
        head.count >= offset + prefix.count && Array(head[offset..<offset + prefix.count]) == prefix
    }
    if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
    if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
    return nil
}

// MARK: - Names and files

/// User names are 1 to 32 lowercase letters and digits: they become directory
/// names, so nothing else is allowed.
func validUser(_ name: String) -> Bool {
    (1...32).contains(name.utf8.count)
        && name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
}

/// An upload id: 32 hex digits, which is what the store makes.
func validID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
}

func userDirectory(_ user: String, in configuration: UploadsConfiguration) -> String {
    precondition(validUser(user), "a user name that is not a directory name")
    return configuration.photoDirectory + "/" + user
}

func makeDirectory(_ path: String) {
    if mkdir(path, 0o755) != 0 && errno != EEXIST {
        fatalError("cannot make \(path): errno \(errno)")
    }
}

func readFile(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { _ = close(fd) }
    var all: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 { return nil }
        if n == 0 { return all }
        all += chunk[0..<n]
    }
}

func writeFile(_ bytes: [UInt8], to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw HTTPError(.internalServerError, "cannot write \(path)") }
    defer { _ = close(fd) }
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, $0.count - done) }
        if n <= 0 { throw HTTPError(.internalServerError, "cannot write \(path)") }
        done += n
    }
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

private let page = """
    <!doctype html>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Photo uploads</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;margin:2rem;max-width:46rem}
    pre{background:#f4f4f5;padding:.75rem 1rem;overflow-x:auto;border-radius:6px}
    code{font-size:13px}</style>
    <h1>Photo uploads</h1>
    <p>Each user's photos, uploaded with the resumable upload protocol. Every
    route under <code>/users/NAME</code> needs that user's token.</p>

    <h2>Upload in one go</h2>
    <pre><code>curl -i -X POST --data-binary @cat.png \\
      -H 'Authorization: Bearer ada-token' \\
      -H 'Content-Type: image/png' -H 'Upload-Complete: ?1' \\
      http://localhost:8080/users/ada/photos</code></pre>

    <h2>Upload in pieces, as a client that lost its connection would</h2>
    <pre><code># the first part; the answer's Location is the upload
    head -c 100000 cat.png | curl -i -X POST --data-binary @- \\
      -H 'Authorization: Bearer ada-token' -H 'Content-Type: image/png' \\
      -H 'Upload-Complete: ?0' http://localhost:8080/users/ada/photos

    # how much arrived
    curl -I -H 'Authorization: Bearer ada-token' http://localhost:8080/users/ada/uploads/ID

    # the rest, from there
    tail -c +100001 cat.png | curl -i -X PATCH --data-binary @- \\
      -H 'Authorization: Bearer ada-token' \\
      -H 'Content-Type: application/partial-upload' \\
      -H 'Upload-Offset: 100000' -H 'Upload-Complete: ?1' \\
      http://localhost:8080/users/ada/uploads/ID</code></pre>

    <h2>Look</h2>
    <pre><code>curl -H 'Authorization: Bearer ada-token' http://localhost:8080/users/ada/photos
    curl -H 'Authorization: Bearer ada-token' -o cat.png http://localhost:8080/users/ada/photos/ID</code></pre>
    """

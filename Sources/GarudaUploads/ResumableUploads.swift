//===----------------------------------------------------------------------===//
// Resumable uploads for HTTP (draft-ietf-httpbis-resumable-upload-12).
//
//     let store = try FileUploadStore(directory: "/var/lib/app/uploads")
//     app.resumableUploads("/files", store: store,
//                          limits: UploadLimits(maxSize: 10 << 30)) { upload in
//         try await moveIntoPlace(upload.path, named: upload.info.contentDisposition)
//         try await upload.remove()
//         return JSON(["size": upload.length], status: .created)
//     }
//
// An upload made to `/files` whose client speaks the protocol -- it sends
// `Upload-Complete` -- is told where the upload lives with a 104 before a
// byte of the body is read, and everything that reaches the server is kept
// as it arrives. If the connection drops, the client asks the upload's URL
// how much arrived (HEAD), and sends the rest from there (PATCH, as
// `application/partial-upload`), as many times as it takes. A client that
// does not speak it gets an ordinary upload. Either way the handler is called
// once, with the whole body on disk, and its answer is the response to the
// request that finished the upload.
//
// The routes, relative to wherever the application mounts them:
//
//   POST    <pattern>            create, with some or all of the body (and
//                                PUT or PATCH, when `methods` includes them)
//   OPTIONS <pattern>            the limits, as Upload-Limit
//   HEAD    <uploads>/:id        the offset, whether it is complete, the length
//   GET     <uploads>/:id        the same, and once it is complete, the answer
//                                the handler gave, for a client whose
//                                connection died before it arrived
//   PATCH   <uploads>/:id        append at the offset the client names
//   DELETE  <uploads>/:id        cancel
//
// The bodies are read as they arrive (RequestBody.swift), over HTTP/1.1,
// HTTP/2 and HTTP/3 alike, and written to the store through VegaFS as they
// are read: an upload holds a window of its client's bytes and a buffer of
// its own, whatever its size, and a slow disk slows that upload alone.
//
// The draft is not an RFC yet, and a client says which iteration it speaks
// with `Upload-Draft-Interop-Version`. Only one that sends 9 is sent a 104:
// the draft forbids it otherwise, so that the RFC's clients and the draft's
// servers never mistake each other. Everything else works without it.
//
// What the draft leaves to the server:
//
//   * A request for an upload another request is still appending to. The
//     draft asks that the older request be ended first -- it is usually a
//     connection that died without either side noticing, and the client has
//     come back on a new one. When the older request is in the same shard it
//     is cancelled, what it received is stored, and the new request goes on.
//     When it is in another shard, the new request waits a moment for it, and
//     is answered 409 with Retry-After if it is still going; it ends by
//     itself once its connection has been silent for the body timeout.
//   * A request that completes the upload and whose handler throws. The
//     upload stays complete, and the client is answered 500.
//   * An answer that never arrived. The answer to the request that completed
//     an upload is remembered as it is sent, and given again to a GET of the
//     upload's URL until `maxAge` -- the one thing HEAD cannot say, since it
//     speaks about the upload and not about what the application made of it.
//     It outlives the bytes, so a handler that files them away and removes the
//     upload still answers the client that lost its answer. HEAD is left
//     exactly as the draft describes. An answer whose body is streamed is the
//     one kind that is not remembered: those bytes are written after the
//     answer has gone, so there is nothing yet to keep, and the GET answers as
//     it does for an upload nothing is remembered about. A handler whose
//     answer should survive a lost connection returns it whole.
//   * What the application knows about an upload. The request that creates
//     one and the request that completes it are different requests, so
//     `onCreate` is given the creating request -- already authenticated by
//     whatever guards the routes -- and what it returns is kept on the upload
//     and handed to `onComplete` as `metadata`. The server writes it and no
//     client can reach it, which is what makes it the place for whose upload
//     this is; `contentType` and `contentDisposition` come from the client and
//     are not. A throw from it refuses the upload before anything is written.
//   * Progress. A 104 with the current offset every `progressInterval` bytes.
//   * Expiry. Uploads older than `maxAge` are removed, complete or not, when
//     the next one is created; the handler should move a finished upload's
//     bytes to where they belong.
//===----------------------------------------------------------------------===//

import Garuda
import GarudaWire
import Synchronization
import Vega

/// The limits a server advertises and enforces, as `Upload-Limit`.
public struct UploadLimits: Sendable {
    /// The largest upload, in bytes.
    public var maxSize: Int?
    /// The smallest upload, in bytes. A client that declares a shorter one is
    /// refused before anything is stored, and one that ends shorter is refused
    /// the completion -- the upload stays as it was, so the client can send
    /// the rest or cancel it.
    public var minSize: Int?
    /// The most one request may carry, in bytes.
    public var maxAppendSize: Int?
    /// The least an *append* may carry, in bytes, except the one that
    /// completes the upload. It is what stops a client from resuming a
    /// gigabyte a byte at a time, where the bookkeeping costs more than the
    /// upload. Creating does not have to meet it: a client that creates an
    /// upload with an empty body and then appends is doing what the draft
    /// describes.
    public var minAppendSize: Int?
    /// How long an upload is kept, in seconds, from when it was created.
    public var maxAge: Int

    public init(maxSize: Int? = nil, minSize: Int? = nil,
                maxAppendSize: Int? = nil, minAppendSize: Int? = nil,
                maxAge: Int = 24 * 3600) {
        precondition(!(maxSize != nil && minSize != nil) || maxSize! >= minSize!,
                     "an upload cannot be both larger than maxSize and smaller than minSize")
        precondition(!(maxAppendSize != nil && minAppendSize != nil) || maxAppendSize! >= minAppendSize!,
                     "a request cannot carry both more than maxAppendSize and less than minAppendSize")
        self.maxSize = maxSize
        self.minSize = minSize
        self.maxAppendSize = maxAppendSize
        self.minAppendSize = minAppendSize
        self.maxAge = maxAge
    }

    /// In the order the draft's Appendix A lists them, so a client reading it
    /// beside the field sees the same order.
    func field(remaining: Int) -> String {
        var members: [(String, Int)] = []
        if let maxSize { members.append(("max-size", maxSize)) }
        if let minSize { members.append(("min-size", minSize)) }
        if let maxAppendSize { members.append(("max-append-size", maxAppendSize)) }
        if let minAppendSize { members.append(("min-append-size", minAppendSize)) }
        members.append(("max-age", max(0, remaining)))
        return StructuredField.dictionary(members)
    }
}

/// An upload that has all of its bytes.
public struct CompletedUpload: Sendable {
    public let info: UploadInfo
    public let store: FileUploadStore
    /// The SHA-256 of the bytes, when it has been computed already -- because
    /// the client declared one that was checked, or asked to be told it.
    public let sha256: [UInt8]?
    /// Where the bytes are.
    public var path: String { store.dataPath(info.id) }
    public var length: Int { info.offset }
    /// What `onCreate` recorded when this upload was created, and empty when
    /// there was no hook. It came from the server, so unlike `info.contentType`
    /// and `info.contentDisposition` -- which are whatever the client sent --
    /// it can be trusted: whose upload this is belongs here.
    public var metadata: [String: String] { info.metadata ?? [:] }

    /// The SHA-256 of the upload's bytes, read from the file when it has not
    /// been computed already. Nil only if the file cannot be read.
    ///
    /// Worth storing beside whatever the bytes become: it is what lets a
    /// client be told later that what it sent is what is held.
    ///
    /// The file is read and hashed on the blocking pool, so the worker goes on
    /// serving other requests meanwhile: hashed there, 15 MB takes about 30 ms
    /// on a CPU without SHA instructions, and every request waiting on that
    /// worker thread would wait for it.
    public func digest() async -> [UInt8]? {
        if let sha256 { return sha256 }
        return await fileSHA256(path)
    }

    /// The same, read on the calling thread, for code that is not a handler.
    /// In a handler the `async` one is chosen, so this cannot block a worker
    /// by accident.
    @available(*, noasync, message: "hashes on the calling thread; use 'await digest()'")
    public func digest() -> [UInt8]? {
        sha256 ?? Digest.sha256(contentsOfFile: path)
    }

    /// Removes the upload and its bytes, once they have been moved or used.
    public func remove() async throws { try await store.delete(info.id) }
}

/// What an application does with an upload once it has all of its bytes: its
/// answer is the response to the request that completed the upload.
public typealias UploadCompletion = @Sendable (CompletedUpload) async throws -> any ResponseConvertible

/// The SHA-256 of a whole file, read on the blocking pool. Hashing a large
/// upload on a worker thread holds every request waiting for that thread:
/// two clients sending 15 MB files back to back took a Garuda 1 worker from
/// 2,000 answers a second to 500, with the rest waiting seconds.
func fileSHA256(_ path: String) async -> [UInt8]? {
    await Runtime.blocking { Digest.sha256(contentsOfFile: path) }
}

/// What an application records on an upload as it is created, from the request
/// that creates it:
///
///     app.authenticate(jwt: Claims.self)
///     app.resumableUploads("/photos", store: store, onCreate: { request in
///         var parameter = 0
///         let jwt = try await JWT<Claims>.extract(from: request, parameter: &parameter)
///         return ["user": jwt.claims.sub]
///     }) { upload in
///         try await file(upload, for: upload.metadata["user"])
///         return JSON(["id": upload.info.id], status: .created)
///     }
///
/// The creating request has been through whatever middleware guards the
/// routes, so this is where the identity that established belongs: the request
/// that finishes the upload is a later one, and finds it as
/// `CompletedUpload.metadata`. Throwing refuses the upload before a byte of it
/// is written -- an `HTTPError` with the status it names.
public typealias UploadCreation = @Sendable (borrowing Request) async throws -> [String: String]

/// The draft iteration this implements (Appendix B).
public let uploadDraftInteropVersion = 9

extension RouteBuilder {
    /// Serves resumable uploads to `pattern`, keeping them in `store` and
    /// calling `onComplete` once each has all its bytes. `uploads` is the path
    /// each upload's own URL is made under, relative to wherever these routes
    /// are mounted: inside `group("/api")`, `uploads: "/uploads"` both serves
    /// and advertises `/api/uploads/:id`, and inside `group("/users/:user")` it
    /// is that user's path and then `/uploads`. `onCreate` is called on the
    /// request that creates an upload, and what it returns is kept on the
    /// upload for `onComplete` to read.
    public func resumableUploads(_ pattern: String, methods: [HTTPMethod] = [.post],
                                 uploads: String = "/uploads",
                                 store: FileUploadStore, limits: UploadLimits = UploadLimits(),
                                 progressInterval: Int = 8 << 20,
                                 onCreate: UploadCreation? = nil,
                                 onComplete: @escaping UploadCompletion) {
        var prefix = uploads
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        // An upload's URL is the creating request's path with this pattern's
        // segments taken off and `uploads` put on, so a pattern whose last
        // segment stands for any number of them leaves nothing to count.
        precondition(!pattern.contains("*"),
                     "resumableUploads cannot serve a pattern with *rest: \(pattern)")
        let service = UploadService(store: store, limits: limits, uploads: prefix,
                                    pattern: pattern, progressInterval: progressInterval,
                                    onCreate: onCreate, onComplete: onComplete)
        // Read as they arrive, with no limit of the route's own: the limits
        // are enforced by the service, so that a 413 says what they are.
        for method in methods {
            onStreamingBody(method, pattern) { request, response, body in
                try await service.create(request, response, body)
            }
        }
        options(pattern) { request, response in
            service.options(request, response)
        }
        head("\(prefix)/:id") { request, response in
            try await service.offset(request, response)
        }
        get("\(prefix)/:id") { request, response in
            try await service.offset(request, response, replaying: true)
        }
        onStreamingBody(.patch, "\(prefix)/:id") { request, response, body in
            try await service.append(request, response, body)
        }
        delete("\(prefix)/:id") { request, response in
            try await service.cancel(request, response)
        }
    }
}

enum UploadProblem {
    static let mismatchingOffset = "https://iana.org/assignments/http-problem-types#mismatching-upload-offset"
    static let inconsistentLength = "https://iana.org/assignments/http-problem-types#inconsistent-upload-length"
    /// Not one of the draft's: bytes that are not what the client's digest
    /// said, which the draft says nothing about.
    static let mismatchingDigest = "https://garuda.dev/problems/mismatching-digest"
}

enum UploadDigestError: Error {
    /// A digest field naming an algorithm this server does not check.
    case unreadable
}

/// What one appending request is, for a later request to supersede it: a
/// number of its own, since two requests' bodies are not comparable.
struct Appending: Sendable {
    let token: UInt64
    let body: RequestBody
}

/// Shared by an application's upload routes, in each shard -- each process
/// has its own copy -- and by every thread of it, so what changes is under a
/// lock.
final class UploadService: Sendable {
    let store: FileUploadStore
    let limits: UploadLimits
    let uploads: String
    /// The pattern the create routes were registered with, which says how much
    /// of a creating request's path belongs to the groups around them.
    let pattern: String
    let progressInterval: Int
    let onComplete: UploadCompletion
    /// Called on each request that creates an upload, for whatever the
    /// application wants kept with it.
    let onCreate: UploadCreation?

    private struct State {
        var lastExpiry = 0
        var nextToken: UInt64 = 0
        /// The request appending to each upload in this shard, by upload id.
        var appending: [String: Appending] = [:]
    }

    private let state = Mutex(State())

    init(store: FileUploadStore, limits: UploadLimits, uploads: String, pattern: String,
         progressInterval: Int, onCreate: UploadCreation? = nil,
         onComplete: @escaping UploadCompletion) {
        self.store = store
        self.limits = limits
        self.uploads = uploads
        self.pattern = pattern
        self.progressInterval = progressInterval
        self.onCreate = onCreate
        self.onComplete = onComplete
    }

    /// Where the upload lives, as the client sees it: the path this request
    /// arrived at, less the segments of the pattern the create routes were
    /// registered with, and then `uploads` and the id.
    ///
    /// Read from the request rather than assumed to be `uploads`, because the
    /// routes are mounted under the prefix of every group they were registered
    /// in and this module is never told what that is -- a `Router` does not
    /// know it either until it is merged, and a group's prefix can carry
    /// parameters of its own. A URL that left the prefix out was a URL the
    /// client could not resume from.
    func location(_ id: String, for request: borrowing Request) -> String {
        "\(mounted(request))/\(id)"
    }

    /// The uploads prefix as the client sees it, worked out from a request to
    /// a create route.
    func mounted(_ request: borrowing Request) -> String {
        var path = request.path
        // The route is the group's prefix and the pattern, so the pattern is
        // the end of the path, one slash for each of its own: empty segments
        // count, as the router keeps them. A pattern of `/` is a group's own
        // root, the prefix alone, and outside any group it is `/`.
        if pattern == "/" {
            while path.hasSuffix("/") { path.removeLast() }
            return path + uploads
        }
        // A pattern that does not end in a slash matched a path that does only
        // under trailingSlash(.ignore), which matched it with those slashes
        // taken off; the path still has them.
        if !pattern.hasSuffix("/") {
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        }
        var slashes = pattern.utf8.count(where: { $0 == UInt8(ascii: "/") })
        while slashes > 0, let slash = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<slash])
            slashes -= 1
        }
        return path + uploads
    }

    /// The upload's id, which is the last parameter the route captured: the
    /// uploads routes name one at the end, and anything before it was captured
    /// by a group the application mounted them in.
    func id(of request: borrowing Request) -> String {
        let count = request.parameterCount
        return count > 0 ? request.parameter(count - 1) : ""
    }

    /// Whether the client speaks the iteration of the draft this does.
    func speaksDraft(_ request: borrowing Request) -> Bool {
        (request.withHeader("upload-draft-interop-version") { StructuredField.integer($0) } ?? nil)
            == uploadDraftInteropVersion
    }

    // MARK: Who is appending

    /// Notes that `body`'s request is appending to `id`.
    private func register(_ id: String, _ body: RequestBody) -> UInt64 {
        state.withLock { state in
            state.nextToken &+= 1
            state.appending[id] = Appending(token: state.nextToken, body: body)
            return state.nextToken
        }
    }

    /// The request `token` names is done with `id`, unless a later one has
    /// taken its place.
    private func unregister(_ id: String, _ token: UInt64) {
        state.withLock { state in
            if state.appending[id]?.token == token { state.appending[id] = nil }
        }
    }

    /// Ends a request in this shard still appending to `id`, and waits for
    /// it to have stored what it received and let go.
    func supersede(_ id: String) async throws {
        guard let older = state.withLock({ $0.appending[id] }) else { return }
        older.body.cancel()
        var waited = 0
        while state.withLock({ $0.appending[id]?.token == older.token }) && waited < 1000 {
            try await Runtime.sleep(for: .milliseconds(5))
            waited += 5
        }
    }

    /// Takes `id` for appending, superseding an older request in this shard
    /// and waiting a moment for one in another. Nil if it is still held.
    func acquire(_ id: String) async throws -> UploadHandle? {
        try await supersede(id)
        for attempt in 0..<20 {
            if let handle = try await store.acquire(id) { return handle }
            if attempt < 19 { try await Runtime.sleep(for: .milliseconds(25)) }
        }
        return nil
    }

    // MARK: Creation

    func create(_ request: borrowing Request, _ response: borrowing Response,
                _ body: RequestBody) async throws {
        // Without the field the client does not know the protocol, and this
        // is an ordinary upload: complete in one request, and never resumed.
        let resumable: Bool
        var complete = true
        switch request.withHeader("upload-complete", { StructuredField.boolean($0) }) {
        case .none:
            resumable = false
        case .some(.none):
            return response.send(status: .badRequest, "Upload-Complete is not a Boolean")
        case .some(.some(let value)):
            resumable = true
            complete = value
        }
        var length: Int? = nil
        switch request.withHeader("upload-length", { StructuredField.integer($0) }) {
        case .none:
            break
        case .some(.none):
            return response.send(status: .badRequest, "Upload-Length is not an Integer")
        case .some(.some(let value)):
            length = value
        }
        if complete, let declared = body.expectedLength {
            if let length, length != declared {
                return problem(response, .badRequest, UploadProblem.inconsistentLength,
                               "the upload's length does not match the request's", [])
            }
            length = declared
        }
        if let maxSize = limits.maxSize, let length, length > maxSize {
            return tooLarge(response)
        }
        // A length the client declares below min-size is refused here, before
        // an upload exists: there is no point taking bytes for something that
        // can never be accepted.
        if let minSize = limits.minSize, let length, length < minSize {
            return tooSmall(response, "the upload is shorter than min-size")
        }
        if let maxAppendSize = limits.maxAppendSize, let declared = body.expectedLength,
           declared > maxAppendSize {
            return tooLarge(response)
        }
        let contentDigest: [UInt8]?
        do {
            contentDigest = try digestOf(request)
        } catch {
            return response.send(status: .badRequest,
                                 "Content-Digest names no digest this server checks")
        }
        // What the client says the whole upload will be, kept for when the
        // last byte is in, however many requests that takes.
        let reprDigest = request.header("repr-digest")
        if let reprDigest, Digest.sha256(field: reprDigest) == nil {
            return response.send(status: .badRequest,
                                 "Repr-Digest names no digest this server checks")
        }
        let now = store.now()
        let sweep = state.withLock { state -> Bool in
            guard now - state.lastExpiry >= 60 else { return false }
            state.lastExpiry = now
            return true
        }
        if sweep { await store.removeExpired(olderThan: limits.maxAge) }
        // Before anything is on disk: a hook that refuses this request --
        // because of who sent it, or what it asked for -- leaves nothing
        // behind to wait out `maxAge`.
        var metadata: [String: String] = [:]
        if let onCreate { metadata = try await onCreate(request) }
        let info = try await store.create(length: length, contentType: request.header("content-type"),
                                          contentDisposition: request.header("content-disposition"),
                                          reprDigest: reprDigest, metadata: metadata)
        guard let handle = try await store.acquire(info.id) else {
            return response.send(status: .serviceUnavailable)
        }
        let interim = resumable && speaksDraft(request)
        let url = location(info.id, for: request)
        if interim {
            await response.sendInterim(status: HTTPStatus(104), headers: [
                ("Upload-Draft-Interop-Version", "\(uploadDraftInteropVersion)"),
                ("Location", url),
                ("Upload-Limit", limits.field(remaining: limits.maxAge)),
            ])
        }
        try await transfer(handle, body, response, complete: complete, length: length,
                           resumable: resumable, interim: interim, creating: true, at: url,
                           contentDigest: contentDigest, wantsDigest: wantsSHA256(request))
    }

    // MARK: Appending

    func append(_ request: borrowing Request, _ response: borrowing Response,
                _ body: RequestBody) async throws {
        let id = id(of: request)
        guard let type = request.header("content-type"),
              type.split(separator: ";").first?.lowercased().filter({ $0 != " " }) == "application/partial-upload"
        else {
            return response.send(status: .unsupportedMediaType, "an append is application/partial-upload")
        }
        guard let offset = request.withHeader("upload-offset", { StructuredField.integer($0) }) ?? nil else {
            return response.send(status: .badRequest, "Upload-Offset is missing or not an Integer")
        }
        guard let complete = request.withHeader("upload-complete", { StructuredField.boolean($0) }) ?? nil else {
            return response.send(status: .badRequest, "Upload-Complete is missing or not a Boolean")
        }
        guard let info = try await live(id) else {
            return response.send(status: .notFound)
        }
        if info.complete {
            response.addHeader("Upload-Complete", "?1")
            response.addHeader("Upload-Offset", "\(info.offset)")
            return problem(response, .conflict, UploadProblem.mismatchingOffset,
                           "the upload is already complete",
                           [("expected-offset", info.offset), ("provided-offset", offset)])
        }
        var length = info.length
        switch request.withHeader("upload-length", { StructuredField.integer($0) }) {
        case .none:
            break
        case .some(.none):
            return response.send(status: .badRequest, "Upload-Length is not an Integer")
        case .some(.some(let value)):
            if let length, length != value {
                return problem(response, .badRequest, UploadProblem.inconsistentLength,
                               "the upload's length changed", [])
            }
            length = value
        }
        if complete, let declared = body.expectedLength {
            if let length, length != offset + declared {
                return problem(response, .badRequest, UploadProblem.inconsistentLength,
                               "the upload's length does not match what this request completes it with", [])
            }
            length = offset + declared
        }
        if let maxSize = limits.maxSize, let length, length > maxSize {
            return tooLarge(response)
        }
        if let minSize = limits.minSize, let length, length < minSize {
            return tooSmall(response, "the upload is shorter than min-size")
        }
        if let maxAppendSize = limits.maxAppendSize, let declared = body.expectedLength,
           declared > maxAppendSize {
            return tooLarge(response)
        }
        // Not the request that completes the upload: that one may be as short
        // as the upload's last bytes are.
        if let minAppendSize = limits.minAppendSize, !complete,
           let declared = body.expectedLength, declared < minAppendSize {
            return tooSmall(response, "this append is shorter than min-append-size")
        }
        let contentDigest: [UInt8]?
        do {
            contentDigest = try digestOf(request)
        } catch {
            return response.send(status: .badRequest,
                                 "Content-Digest names no digest this server checks")
        }
        let interim = speaksDraft(request)
        let handle: UploadHandle
        do {
            guard let held = try await acquire(id) else {
                response.addHeader("Retry-After", "1")
                return response.send(status: .conflict, "another request is appending to this upload")
            }
            handle = held
        } catch UploadStoreError.notFound {
            return response.send(status: .notFound)
        }
        // Taking the lock can wait on a request that is still appending, and
        // what that request did is not in the `info` read before the wait: it
        // may have completed the upload, or declared its length. Reading it
        // again under the lock is what makes the checks above hold now.
        guard let current = try await store.info(id) else {
            handle.release()
            return response.send(status: .notFound)
        }
        if current.complete {
            handle.release()
            response.addHeader("Upload-Complete", "?1")
            response.addHeader("Upload-Offset", "\(current.offset)")
            return problem(response, .conflict, UploadProblem.mismatchingOffset,
                           "the upload is already complete",
                           [("expected-offset", current.offset), ("provided-offset", offset)])
        }
        if handle.offset != offset {
            handle.release()
            response.addHeader("Upload-Offset", "\(handle.offset)")
            response.addHeader("Upload-Complete", "?0")
            return problem(response, .conflict, UploadProblem.mismatchingOffset,
                           "the offset does not match the upload's",
                           [("expected-offset", handle.offset), ("provided-offset", offset)])
        }
        // A length declared while this request waited is one it never saw, and
        // taking it is what holds these bytes to it: without it the transfer
        // below has nothing to stop at.
        if let declared = current.length {
            if let length, length != declared {
                handle.release()
                return problem(response, .badRequest, UploadProblem.inconsistentLength,
                               "the upload's length changed", [])
            }
            length = declared
        } else if let length {
            try await store.update(id, length: length, complete: false)
        }
        try await transfer(handle, body, response, complete: complete, length: length,
                           resumable: true, interim: interim, creating: false,
                           contentDigest: contentDigest, wantsDigest: wantsSHA256(request))
    }

    /// Stores the body as it arrives, and answers once it has all come.
    func transfer(_ handle: UploadHandle, _ body: RequestBody, _ response: borrowing Response,
                  complete: Bool, length: Int?, resumable: Bool, interim: Bool,
                  creating: Bool, at url: String? = nil,
                  contentDigest: [UInt8]?, wantsDigest: Bool) async throws {
        let id = handle.id
        let token = register(id, body)
        defer {
            handle.release()
            unregister(id, token)
        }
        var sinceProgress = 0
        let start = handle.offset
        // The Repr-Digest the upload was created with, checked once it has all
        // come -- which it has only if this request says so.
        let declared = complete
            ? (try? await store.info(id))?.reprDigest.flatMap({ Digest.sha256(field: $0) }) : nil
        // A request that carries the whole upload -- most do, a photo sent in
        // one go -- hashes it as it arrives, so the digest is ready when the
        // last byte is, rather than the file being read back to make it.
        let whole = start == 0 && complete
        let wantsWhole = declared != nil || wantsDigest
        // Otherwise only when the client said what these bytes should be:
        // hashing what nobody will check is a pass over every byte for nothing.
        let running = contentDigest != nil || (whole && wantsWhole) ? SHA256Digest() : nil
        // One buffer for the whole request: what is read goes to the disk
        // before the next read.
        var buffer = IOBuffer(capacity: 256 * 1024)
        while true {
            buffer.clear()
            // A request that ends part-way -- the client gone, or superseded
            // -- throws from here once what arrived has been read and stored:
            // that is where the upload resumes from, and there is nobody to
            // answer.
            let n = try await body.read(into: &buffer)
            if n == 0 { break }
            if let length, handle.offset + n > length {
                return problem(response, .badRequest, UploadProblem.inconsistentLength,
                               "the upload is longer than its length", [])
            }
            if let maxSize = limits.maxSize, handle.offset + n > maxSize {
                return tooLarge(response)
            }
            if let maxAppendSize = limits.maxAppendSize, handle.offset - start + n > maxAppendSize {
                return tooLarge(response)
            }
            try await handle.append(buffer)
            if let running { buffer.withUnsafeBytes { running.update($0) } }
            sinceProgress += n
            if interim && progressInterval > 0 && sinceProgress >= progressInterval {
                sinceProgress = 0
                await response.sendInterim(status: HTTPStatus(104), headers: [
                    ("Upload-Draft-Interop-Version", "\(uploadDraftInteropVersion)"),
                    ("Upload-Offset", "\(handle.offset)"),
                ])
            }
        }

        // What this request carried, before anything else is decided about
        // it. Bytes that are not what the client said they are were corrupted
        // on the way, so they are dropped and the upload stays where it began
        // this request -- the client sends them again from there.
        if let contentDigest, let running, !Digest.equal(running.digest(), contentDigest) {
            try? await handle.truncate(to: start)
            response.addHeader("Upload-Offset", "\(start)")
            return problem(response, .badRequest, UploadProblem.mismatchingDigest,
                           "the bytes are not what Content-Digest says", [])
        }

        let offset = handle.offset
        // A body of no declared length is only measured once it has all
        // arrived, so this append is held to min-append-size here. What came
        // is kept, at the offset it reached: the protocol is driven by the
        // offset, and the client's next request reads it from a HEAD.
        if !complete, !creating, let minAppendSize = limits.minAppendSize,
           offset - start < minAppendSize {
            response.addHeader("Upload-Offset", "\(offset)")
            return tooSmall(response, "this append is shorter than min-append-size")
        }
        guard complete else {
            response.addHeader("Upload-Complete", "?0")
            response.addHeader("Upload-Offset", "\(offset)")
            if creating {
                if let url { response.addHeader("Location", url) }
                response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
                return response.send(status: .created)
            }
            return response.send(status: .noContent)
        }
        if let length, length != offset {
            return problem(response, .badRequest, UploadProblem.inconsistentLength,
                           "the upload ended short of its length", [])
        }
        // Refused the completion, not deleted: the upload stays where it is,
        // so a client that ended it early can send the rest or cancel it.
        if let minSize = limits.minSize, offset < minSize {
            response.addHeader("Upload-Offset", "\(offset)")
            return tooSmall(response, "the upload is shorter than min-size")
        }
        // The whole upload, now that there is a whole upload, and only when
        // somebody asked for it: hashed already if this request carried all
        // of it, or one pass over the file if it took several.
        var sha256: [UInt8]? = nil
        if wantsWhole {
            if whole, let running {
                sha256 = running.digest()
            } else {
                sha256 = await fileSHA256(store.dataPath(id))
            }
        }
        if let declared {
            guard let actual = sha256, Digest.equal(actual, declared) else {
                // Whole and wrong: appending cannot mend it, so it goes, and
                // the client starts again rather than holding a name for
                // bytes nobody will accept.
                handle.release()
                try? await store.delete(id)
                return problem(response, .badRequest, UploadProblem.mismatchingDigest,
                               "the upload is not what Repr-Digest says", [])
            }
        }
        try await store.update(id, length: offset, complete: true)
        handle.release()
        guard let info = try await store.info(id) else { return response.send(status: .notFound) }
        if wantsDigest, let sha256 { response.addHeader("Repr-Digest", Digest.field(sha256)) }
        let answer = try await onComplete(CompletedUpload(info: info, store: store, sha256: sha256))
        if resumable { response.addHeader("Upload-Complete", "?1") }
        // What the handler answers is remembered on its way out, whatever kind
        // of answer it is and whatever middleware made of it, so a client
        // whose connection dies before it arrives can ask for it again with
        // GET. It is kept even after the handler removes the upload: the bytes
        // have gone somewhere, and the answer is what says where.
        let store = self.store
        let created = info.createdAt
        response.onSend { outgoing in
            // A streamed body is written after this runs, so there is nothing
            // here to remember: storing the status with an empty body would
            // answer a client that came back for its receipt with a success
            // that says nothing. Nothing is stored instead, and the GET
            // answers as it does for an upload that has no remembered answer.
            if outgoing.isStreaming {
                AppLog.warning("a streamed answer to a completed upload is not remembered",
                               ["upload": .string(id)])
                return
            }
            let body = outgoing.withBody { span in span.withUnsafeBufferPointer { Array($0) } }
            try? store.remember(id, status: outgoing.status.code, contentType: outgoing.header("content-type"),
                                location: outgoing.header("location"), body: body, createdAt: created)
        }
        try answer.write(to: response)
    }

    // MARK: Offset, limits, cancellation

    func offset(_ request: borrowing Request, _ response: borrowing Response,
                replaying: Bool = false) async throws {
        response.addHeader("Cache-Control", "no-store")
        let id = id(of: request)
        // An offset is only worth giving once nothing is still adding to it.
        try await supersede(id)
        // A GET for an upload that finished is the client asking for the
        // answer it did not get. HEAD is left as the draft describes it, so a
        // client following the draft sees exactly what the draft says.
        if replaying, let answer = try? await store.answer(id),
           store.now() - answer.createdAt <= limits.maxAge {
            if let type = answer.contentType { response.addHeader("Content-Type", type) }
            // A handler that answered with a redirect said where the upload
            // went. Without the field the status alone says nothing.
            if let location = answer.location { response.addHeader("Location", location) }
            response.addHeader("Upload-Complete", "?1")
            return response.send(status: HTTPStatus(answer.status), answer.body)
        }
        guard let info = try? await live(id) else {
            return response.send(status: .notFound)
        }
        response.addHeader("Upload-Offset", "\(info.offset)")
        response.addHeader("Upload-Complete", info.complete ? "?1" : "?0")
        if let length = info.length { response.addHeader("Upload-Length", "\(length)") }
        let remaining = info.createdAt + limits.maxAge - store.now()
        response.addHeader("Upload-Limit", limits.field(remaining: remaining))
        response.send(status: .noContent)
    }

    func options(_ request: borrowing Request, _ response: borrowing Response) {
        if request.withHeader("upload-complete", { _ in true }) == nil {
            response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
        }
        response.send(status: .noContent)
    }

    func cancel(_ request: borrowing Request, _ response: borrowing Response) async throws {
        let id = id(of: request)
        try await supersede(id)
        do {
            // Everything, the answer included: the client asked for this
            // upload to be gone.
            try await store.forget(id)
            response.send(status: .noContent)
        } catch {
            response.send(status: .notFound)
        }
    }

    /// The SHA-256 this request says its own bytes are, or nil when it says
    /// nothing. Throws when it says something in a language this does not
    /// speak, which is not the same as saying nothing: a client that asked for
    /// a check should not be told silently that there was none.
    func digestOf(_ request: borrowing Request) throws -> [UInt8]? {
        guard let field = request.header("content-digest") else { return nil }
        guard let digest = Digest.sha256(field: field) else { throw UploadDigestError.unreadable }
        return digest
    }

    /// Whether the request asked to be told the upload's digest (RFC 9530's
    /// `Want-Repr-Digest`). A preference of 0 is a client saying it does not
    /// want one.
    func wantsSHA256(_ request: borrowing Request) -> Bool {
        guard let field = request.header("want-repr-digest") else { return false }
        for member in field.split(separator: ",") {
            let parts = member.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard trimmed(parts[0]).lowercased() == "sha-256" else { continue }
            if parts.count == 2, trimmed(parts[1]) == "0" { return false }
            return true
        }
        return false
    }

    private func trimmed(_ text: Substring) -> Substring {
        var s = text
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }

    /// The upload, unless it does not exist or has outlived `maxAge`.
    func live(_ id: String) async throws -> UploadInfo? {
        guard let info = try await store.info(id) else { return nil }
        if store.now() - info.createdAt > limits.maxAge {
            try? await store.forget(id)
            return nil
        }
        return info
    }

    // MARK: Answers

    func tooLarge(_ response: borrowing Response) {
        response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
        response.send(status: .contentTooLarge)
    }

    /// Under a limit the server advertised. HTTP has no opposite of 413, so
    /// this is a 400 carrying `Upload-Limit`: the client sent what the limits
    /// had already said it should not, and the answer says so again.
    func tooSmall(_ response: borrowing Response, _ why: String) {
        response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
        response.send(status: .badRequest, why)
    }

    func problem(_ response: borrowing Response, _ status: HTTPStatus, _ type: String,
                 _ title: String, _ members: [(String, Int)]) {
        response.addHeader("Content-Type", "application/problem+json")
        var json = "{\"type\":\"\(type)\",\"title\":\"\(title)\""
        for (name, value) in members { json += ",\"\(name)\":\(value)" }
        json += "}"
        response.send(status: status, json)
    }
}

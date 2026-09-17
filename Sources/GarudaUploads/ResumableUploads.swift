//===----------------------------------------------------------------------===//
// Resumable uploads for HTTP (draft-ietf-httpbis-resumable-upload-12).
//
//     let store = try FileUploadStore(directory: "/var/lib/app/uploads")
//     app.resumableUploads("/files", store: store,
//                          limits: UploadLimits(maxSize: 10 << 30)) { upload in
//         try moveIntoPlace(upload.path, named: upload.info.contentDisposition)
//         try upload.remove()
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
//   GET     <uploads>/:id        the same
//   PATCH   <uploads>/:id        append at the offset the client names
//   DELETE  <uploads>/:id        cancel
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
//     come back on a new one. When the older request is on the same worker
//     it is ended, what it received is stored, and the new request goes on.
//     When it is on another worker, the new request waits a moment for it,
//     and is answered 409 with Retry-After if it is still going; it ends by
//     itself once its connection has been silent for --request-timeout.
//   * A request that completes the upload and whose handler throws. The
//     upload stays complete, and the client is answered 500.
//   * Progress. A 104 with the current offset every `progressInterval` bytes.
//   * Expiry. Uploads older than `maxAge` are removed, complete or not, when
//     the next one is created; the handler should move a finished upload's
//     bytes to where they belong.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import AvianHTTP

/// The limits a server advertises and enforces, as `Upload-Limit`.
public struct UploadLimits: Sendable {
    /// The largest upload, in bytes.
    public var maxSize: Int?
    /// The most one request may carry, in bytes.
    public var maxAppendSize: Int?
    /// How long an upload is kept, in seconds, from when it was created.
    public var maxAge: Int

    public init(maxSize: Int? = nil, maxAppendSize: Int? = nil, maxAge: Int = 24 * 3600) {
        self.maxSize = maxSize
        self.maxAppendSize = maxAppendSize
        self.maxAge = maxAge
    }

    func field(remaining: Int) -> String {
        var members: [(String, Int)] = []
        if let maxSize { members.append(("max-size", maxSize)) }
        if let maxAppendSize { members.append(("max-append-size", maxAppendSize)) }
        members.append(("max-age", max(0, remaining)))
        return StructuredField.dictionary(members)
    }
}

/// An upload that has all of its bytes.
public struct CompletedUpload: Sendable {
    public let info: UploadInfo
    public let store: FileUploadStore
    /// Where the bytes are.
    public var path: String { store.dataPath(info.id) }
    public var length: Int { info.offset }

    /// Removes the upload and its bytes, once they have been moved or used.
    public func remove() throws { try store.delete(info.id) }
}

public typealias UploadCompletion = (CompletedUpload) async throws -> any ResponseConvertible

/// The draft iteration this implements (Appendix B).
public let uploadDraftInteropVersion = 9

extension RouteBuilder {
    /// Serves resumable uploads to `pattern`, keeping them in `store` and
    /// calling `onComplete` once each has all its bytes. `uploads` is the path
    /// each upload's own URL is made under, and has to be as the client sees
    /// it.
    public func resumableUploads(_ pattern: String, methods: [HTTPMethod] = [.post],
                                 uploads: String = "/uploads",
                                 store: FileUploadStore, limits: UploadLimits = UploadLimits(),
                                 progressInterval: Int = 8 << 20,
                                 onComplete: sending @escaping UploadCompletion) {
        var prefix = uploads
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        let service = UploadService(store: store, limits: limits, uploads: prefix,
                                    progressInterval: progressInterval, onComplete: onComplete)
        // The limits are enforced here rather than by the engine, so that a
        // 413 says what they are.
        for method in methods {
            onStreamingBody(method, pattern) { request, response, body in
                try await service.create(request, &response, body)
            }
        }
        onAsync(.options, pattern) { request, response in
            service.options(request, &response)
        }
        onAsync(.head, "\(prefix)/:id") { request, response in
            try await service.offset(request, &response)
        }
        onAsync(.get, "\(prefix)/:id") { request, response in
            try await service.offset(request, &response)
        }
        onStreamingBody(.patch, "\(prefix)/:id") { request, response, body in
            try await service.append(request, &response, body)
        }
        onAsync(.delete, "\(prefix)/:id") { request, response in
            try await service.cancel(request, &response)
        }
    }
}

enum UploadProblem {
    static let mismatchingOffset = "https://iana.org/assignments/http-problem-types#mismatching-upload-offset"
    static let inconsistentLength = "https://iana.org/assignments/http-problem-types#inconsistent-upload-length"
}

/// Shared by an application's upload routes. A worker is one thread, and
/// each process has its own copy, so nothing here needs a lock.
final class UploadService: @unchecked Sendable {
    let store: FileUploadStore
    let limits: UploadLimits
    let uploads: String
    let progressInterval: Int
    let onComplete: UploadCompletion
    private var lastExpiry = 0
    /// The request appending to each upload on this worker, by upload id.
    private var appending: [String: RequestBodyStream] = [:]

    init(store: FileUploadStore, limits: UploadLimits, uploads: String, progressInterval: Int,
         onComplete: @escaping UploadCompletion) {
        self.store = store
        self.limits = limits
        self.uploads = uploads
        self.progressInterval = progressInterval
        self.onComplete = onComplete
    }

    func location(_ id: String) -> String { "\(uploads)/\(id)" }

    /// Whether the client speaks the iteration of the draft this does.
    func speaksDraft(_ request: borrowing Request) -> Bool {
        request.header("upload-draft-interop-version").flatMap(StructuredField.integer)
            == uploadDraftInteropVersion
    }

    /// Ends a request on this worker still appending to `id`, and waits for
    /// it to have stored what it received and let go.
    func supersede(_ id: String, _ response: borrowing Response) async throws {
        guard let older = appending[id] else { return }
        older.cancel()
        var waited = 0
        while appending[id] === older && waited < 1000 {
            try await response.sleep(milliseconds: 5)
            waited += 5
        }
    }

    /// Takes `id` for appending, superseding an older request on this worker
    /// and waiting a moment for one on another. Nil if it is still held.
    func acquire(_ id: String, _ response: borrowing Response) async throws -> UploadHandle? {
        try await supersede(id, response)
        for attempt in 0..<20 {
            if let handle = try store.acquire(id) { return handle }
            if attempt < 19 { try await response.sleep(milliseconds: 25) }
        }
        return nil
    }

    // MARK: Creation

    func create(_ request: borrowing Request, _ response: inout Response,
                _ body: RequestBodyStream) async throws {
        // Without the field the client does not know the protocol, and this
        // is an ordinary upload: complete in one request, and never resumed.
        let resumable: Bool
        var complete = true
        if let text = request.header("upload-complete") {
            guard let value = StructuredField.boolean(text) else {
                return response.send(status: .badRequest, "Upload-Complete is not a Boolean")
            }
            resumable = true
            complete = value
        } else {
            resumable = false
        }
        var length: Int? = nil
        if let text = request.header("upload-length") {
            guard let value = StructuredField.integer(text) else {
                return response.send(status: .badRequest, "Upload-Length is not an Integer")
            }
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
        if let maxAppendSize = limits.maxAppendSize, let declared = body.expectedLength,
           declared > maxAppendSize {
            return tooLarge(response)
        }
        let now = Int(time(nil))
        if now - lastExpiry >= 60 {
            lastExpiry = now
            store.removeExpired(olderThan: limits.maxAge)
        }
        let info = try store.create(length: length, contentType: request.header("content-type"),
                                    contentDisposition: request.header("content-disposition"))
        guard let handle = try store.acquire(info.id) else {
            return response.send(status: .serviceUnavailable)
        }
        let interim = resumable && speaksDraft(request)
        if interim {
            response.sendInterim(status: HTTPStatus(104), headers: [
                ("Upload-Draft-Interop-Version", "\(uploadDraftInteropVersion)"),
                ("Location", location(info.id)),
                ("Upload-Limit", limits.field(remaining: limits.maxAge)),
            ])
        }
        try await transfer(handle, body, &response, complete: complete, length: length,
                           resumable: resumable, interim: interim, creating: true)
    }

    // MARK: Appending

    func append(_ request: borrowing Request, _ response: inout Response,
                _ body: RequestBodyStream) async throws {
        let id = request.parameter(0)
        guard let type = request.header("content-type"),
              type.split(separator: ";").first?.lowercased().filter({ $0 != " " }) == "application/partial-upload"
        else {
            return response.send(status: .unsupportedMediaType, "an append is application/partial-upload")
        }
        guard let offsetText = request.header("upload-offset"),
              let offset = StructuredField.integer(offsetText) else {
            return response.send(status: .badRequest, "Upload-Offset is missing or not an Integer")
        }
        guard let completeText = request.header("upload-complete"),
              let complete = StructuredField.boolean(completeText) else {
            return response.send(status: .badRequest, "Upload-Complete is missing or not a Boolean")
        }
        guard let info = try live(id) else {
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
        if let text = request.header("upload-length") {
            guard let value = StructuredField.integer(text) else {
                return response.send(status: .badRequest, "Upload-Length is not an Integer")
            }
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
        if let maxAppendSize = limits.maxAppendSize, let declared = body.expectedLength,
           declared > maxAppendSize {
            return tooLarge(response)
        }
        let interim = speaksDraft(request)
        let handle: UploadHandle
        do {
            guard let held = try await acquire(id, response) else {
                response.addHeader("Retry-After", "1")
                return response.send(status: .conflict, "another request is appending to this upload")
            }
            handle = held
        } catch UploadStoreError.notFound {
            return response.send(status: .notFound)
        }
        if handle.offset != offset {
            handle.release()
            response.addHeader("Upload-Offset", "\(handle.offset)")
            response.addHeader("Upload-Complete", "?0")
            return problem(response, .conflict, UploadProblem.mismatchingOffset,
                           "the offset does not match the upload's",
                           [("expected-offset", handle.offset), ("provided-offset", offset)])
        }
        if length != info.length { try store.update(id, length: length, complete: false) }
        try await transfer(handle, body, &response, complete: complete, length: length,
                           resumable: true, interim: interim, creating: false)
    }

    /// Stores the body as it arrives, and answers once it has all come.
    func transfer(_ handle: UploadHandle, _ body: RequestBodyStream, _ response: inout Response,
                  complete: Bool, length: Int?, resumable: Bool, interim: Bool,
                  creating: Bool) async throws {
        let id = handle.id
        appending[id] = body
        defer {
            handle.release()
            if appending[id] === body { appending[id] = nil }
        }
        var sinceProgress = 0
        let start = handle.offset
        do {
            while let bytes = try await body.read(maxBytes: 256 * 1024) {
                if let length, handle.offset + bytes.count > length {
                    return problem(response, .badRequest, UploadProblem.inconsistentLength,
                                   "the upload is longer than its length", [])
                }
                if let maxSize = limits.maxSize, handle.offset + bytes.count > maxSize {
                    return tooLarge(response)
                }
                if let maxAppendSize = limits.maxAppendSize,
                   handle.offset - start + bytes.count > maxAppendSize {
                    return tooLarge(response)
                }
                try handle.append(bytes)
                sinceProgress += bytes.count
                if interim && progressInterval > 0 && sinceProgress >= progressInterval {
                    sinceProgress = 0
                    response.sendInterim(status: HTTPStatus(104), headers: [
                        ("Upload-Draft-Interop-Version", "\(uploadDraftInteropVersion)"),
                        ("Upload-Offset", "\(handle.offset)"),
                    ])
                }
            }
        } catch is RequestBodyError {
            // The client went away, or sent more than a request may. What
            // arrived is stored, and is where it resumes from; there is
            // nobody to answer, or the engine already has.
            return
        }

        let offset = handle.offset
        guard complete else {
            response.addHeader("Upload-Complete", "?0")
            response.addHeader("Upload-Offset", "\(offset)")
            if creating {
                response.addHeader("Location", location(id))
                response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
                return response.send(status: .created)
            }
            return response.send(status: .noContent)
        }
        if let length, length != offset {
            return problem(response, .badRequest, UploadProblem.inconsistentLength,
                           "the upload ended short of its length", [])
        }
        try store.update(id, length: offset, complete: true)
        handle.release()
        guard let info = try store.info(id) else { return response.send(status: .notFound) }
        let answer = try await onComplete(CompletedUpload(info: info, store: store))
        if resumable { response.addHeader("Upload-Complete", "?1") }
        try answer.write(to: response)
    }

    // MARK: Offset, limits, cancellation

    func offset(_ request: borrowing Request, _ response: inout Response) async throws {
        response.addHeader("Cache-Control", "no-store")
        let id = request.parameter(0)
        // An offset is only worth giving once nothing is still adding to it.
        try await supersede(id, response)
        guard let info = try? live(id) else {
            return response.send(status: .notFound)
        }
        response.addHeader("Upload-Offset", "\(info.offset)")
        response.addHeader("Upload-Complete", info.complete ? "?1" : "?0")
        if let length = info.length { response.addHeader("Upload-Length", "\(length)") }
        let remaining = info.createdAt + limits.maxAge - Int(time(nil))
        response.addHeader("Upload-Limit", limits.field(remaining: remaining))
        response.send(status: .noContent)
    }

    func options(_ request: borrowing Request, _ response: inout Response) {
        if request.header("upload-complete") == nil {
            response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
        }
        response.send(status: .noContent)
    }

    func cancel(_ request: borrowing Request, _ response: inout Response) async throws {
        let id = request.parameter(0)
        try await supersede(id, response)
        do {
            try store.delete(id)
            response.send(status: .noContent)
        } catch {
            response.send(status: .notFound)
        }
    }

    /// The upload, unless it does not exist or has outlived `maxAge`.
    func live(_ id: String) throws -> UploadInfo? {
        guard let info = try store.info(id) else { return nil }
        if Int(time(nil)) - info.createdAt > limits.maxAge {
            try? store.delete(id)
            return nil
        }
        return info
    }

    // MARK: Answers

    func tooLarge(_ response: borrowing Response) {
        response.addHeader("Upload-Limit", limits.field(remaining: limits.maxAge))
        response.send(status: .contentTooLarge)
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

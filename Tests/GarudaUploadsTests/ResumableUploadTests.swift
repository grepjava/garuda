import Testing
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#endif
import Garuda
import GarudaTesting
import GarudaWire
import Vega
@testable import GarudaUploads

/// The store's own calls are async, through VegaFS, and run here; so do the
/// tests' stand-ins for a request in another shard.
private let runtime = Runtime(workers: 1)

private func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    try runtime.block(operation)
}

/// Every upload the application in `uploadApp` completed, with its bytes.
private final class Completed: Sendable {
    private let uploads = Mutex<[(info: UploadInfo, bytes: [UInt8])]>([])

    func add(_ upload: CompletedUpload) {
        let bytes = contents(upload.path)
        uploads.withLock { $0.append((upload.info, bytes)) }
    }

    func clear() { uploads.withLock { $0 = [] } }
    var count: Int { uploads.withLock { $0.count } }
    var isEmpty: Bool { count == 0 }
    var bytes: [[UInt8]] { uploads.withLock { $0.map(\.bytes) } }
    var first: (info: UploadInfo, bytes: [UInt8])? { uploads.withLock { $0.first } }
}

private let completed = Completed()

private func pattern(_ count: Int, from start: Int = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 + start) &* 197 &+ 3) }
}

#if os(Windows)
private func temporaryDirectory() -> String {
    var base = getenv("TEMP").map { String(cString: $0) } ?? "C:/Windows/Temp"
    base = String(base.map { $0 == "\\" ? "/" : $0 })
    while base.hasSuffix("/") { base.removeLast() }
    let path = "\(base)/garuda-uploads-\(_getpid())-\(UInt64.random(in: 0...UInt64.max))"
    precondition(_mkdir(path) == 0)
    return path
}

private func contents(_ path: String) -> [UInt8] {
    guard let file = fopen(path, "rb") else { return [] }
    defer { _ = fclose(file) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { fread($0.baseAddress!, 1, $0.count, file) }
        if n == 0 { break }
        out += chunk[0..<n]
    }
    return out
}

private func writeBytes(_ bytes: [UInt8], to path: String) {
    let file = fopen(path, "wb")
    precondition(file != nil)
    defer { _ = fclose(file) }
    _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress!, 1, $0.count, file) }
}

/// The names in `directory` that end in `suffix`, without it.
private func names(in directory: String, endingIn suffix: String) -> [String] {
    var data = WIN32_FIND_DATAW()
    let find = (directory + "/*").withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
    guard let find, find != INVALID_HANDLE_VALUE else { return [] }
    defer { FindClose(find) }
    var found: [String] = []
    repeat {
        let name = withUnsafeBytes(of: data.cFileName) {
            String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
        }
        if name.hasSuffix(suffix) { found.append(String(name.dropLast(suffix.count))) }
    } while FindNextFileW(find, &data)
    return found
}
#else
private func temporaryDirectory() -> String {
    var template = Array("/tmp/garuda-uploads-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil)
    return String(cString: template)
}

private func contents(_ path: String) -> [UInt8] {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return [] }
    defer { _ = close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
        if n <= 0 { break }
        out += chunk[0..<n]
    }
    return out
}

private func writeBytes(_ bytes: [UInt8], to path: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    precondition(fd >= 0)
    defer { _ = close(fd) }
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
}

/// The names in `directory` that end in `suffix`, without it.
private func names(in directory: String, endingIn suffix: String) -> [String] {
    guard let dir = opendir(directory) else { return [] }
    defer { closedir(dir) }
    var found: [String] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name.hasSuffix(suffix) { found.append(String(name.dropLast(suffix.count))) }
    }
    return found
}
#endif

private func listUploads(_ store: FileUploadStore) -> [String] {
    names(in: store.directory, endingIn: ".info")
}

/// An application serving uploads to /files, recording each one it completes.
private func uploadApp(_ store: FileUploadStore, limits: UploadLimits = UploadLimits()) -> Application {
    completed.clear()
    let app = Application()
    app.resumableUploads("/files", store: store, limits: limits, progressInterval: 0) { upload in
        completed.add(upload)
        return Text("stored \(upload.length)", status: .created)
    }
    return app
}

/// The id at the end of an upload's URL under /uploads.
private func id(_ location: String) -> String {
    String(location.dropFirst("/uploads/".count))
}

private func info(_ store: FileUploadStore, _ id: String) throws -> UploadInfo? {
    try run { try await store.info(id) }
}

/// Where the upload lives: in the final response while it is still open, and
/// in the 104 for a client that completed it in one request.
private func uploadURL(_ response: TestResponse) -> String? {
    if let there = response.header("location") { return there }
    for interim in response.interim {
        if let there = interim.headers.first(where: { $0.name.lowercased() == "location" })?.value {
            return there
        }
    }
    return nil
}

private func partial(_ offset: Int, complete: Bool) -> [(String, String)] {
    [("Content-Type", "application/partial-upload"), ("Upload-Offset", "\(offset)"),
     ("Upload-Complete", complete ? "?1" : "?0")]
}

/// A complete upload made the way a client of the draft makes one, so the
/// answer names where it lives.
private let draft = [("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")]

/// Somewhere for an upload handler to record what it saw.
private final class DigestsSeen: Sendable {
    let digests = Mutex<[[UInt8]?]>([])
}

private func digestOnThisThread(_ upload: CompletedUpload) -> [UInt8]? {
    upload.digest()
}

/// A clock a test moves by hand.
private final class HandClock: Sendable {
    let now = Atomic<Int>(1_000_000)
}

/// Waits, up to a few seconds, for an upload to have `offset` bytes stored.
private func waitForOffset(_ store: FileUploadStore, _ id: String, _ offset: Int) throws {
    for _ in 0..<500 {
        if try info(store, id)?.offset == offset { return }
        usleep(10_000)
    }
    Issue.record("the upload never reached \(offset) bytes")
}

@Suite("Structured fields")
struct StructuredFieldTests {
    @Test func booleansIntegersAndDictionaries() {
        #expect(StructuredField.boolean("?1") == true)
        #expect(StructuredField.boolean(" ?0 ") == false)
        #expect(StructuredField.boolean("1") == nil)
        #expect(StructuredField.boolean("?true") == nil)
        #expect(StructuredField.integer("0") == 0)
        #expect(StructuredField.integer("123456789012345") == 123456789012345)
        #expect(StructuredField.integer("1234567890123456") == nil)
        #expect(StructuredField.integer("-1") == nil)
        #expect(StructuredField.integer("1.5") == nil)
        #expect(StructuredField.integer("") == nil)
        #expect(StructuredField.dictionary([("max-size", 10), ("max-age", 60)]) == "max-size=10, max-age=60")
    }
}

@Suite("Digests")
struct DigestTests {
    @Test func aFieldCarriesTheDigestItNames() {
        let sha = Digest.sha256(Array("abc".utf8))
        #expect(Digest.field(sha) == "sha-256=:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=:")
        #expect(Digest.sha256(field: Digest.field(sha)) == sha)
        #expect(Digest.sha256(field: "md5=:AAAA:, sha-256=:\(Digest.base64(sha)):") == sha)
        #expect(Digest.sha256(field: "sha-512=:AAAA:") == nil)
        #expect(Digest.sha256(field: "sha-256=AAAA") == nil)
        #expect(Digest.sha256(field: "sha-256=:AAAA:") == nil, "not 32 bytes")
    }

    @Test func aDigestMadeInPiecesIsTheDigestOfTheWhole() {
        let whole = pattern(100_000)
        let running = SHA256Digest()
        running.update(Array(whole[..<33_333]))
        whole[33_333...].withUnsafeBytes { running.update($0) }
        #expect(running.digest() == Digest.sha256(whole))
    }
}

@Suite("File upload store", .serialized)
struct FileUploadStoreTests {
    @Test func anUploadIsItsBytesAndItsState() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: 10, contentType: "text/plain", contentDisposition: nil)
            #expect(info.offset == 0 && info.length == 10 && !info.complete)
            let handle = try #require(try await store.acquire(info.id))
            try await handle.append(Array("hello".utf8))
            #expect(handle.offset == 5)
            #expect(try await store.info(info.id)?.offset == 5)
            handle.release()
            try await store.update(info.id, length: 5, complete: true)
            let after = try #require(try await store.info(info.id))
            #expect(after.complete && after.length == 5 && after.contentType == "text/plain")
            #expect(contents(store.dataPath(info.id)) == Array("hello".utf8))
            try await store.delete(info.id)
            #expect(try await store.info(info.id) == nil)
            await #expect(throws: UploadStoreError.notFound) { try await store.delete(info.id) }
        }
    }

    @Test func oneRequestAppendsAtATime() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: nil, contentType: nil, contentDisposition: nil)
            let first = try #require(try await store.acquire(info.id))
            #expect(try await store.acquire(info.id) == nil)
            first.release()
            #expect(try await store.acquire(info.id) != nil)
        }
    }

    @Test func aPathIsNeverTakenForAnID() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let real = try await store.create(length: nil, contentType: nil, contentDisposition: nil)
            // Names that reach a real upload's file, but are not its id.
            await #expect(throws: UploadStoreError.notFound) { try await store.acquire("./" + real.id) }
            await #expect(throws: UploadStoreError.notFound) { try await store.acquire(real.id + "/.") }
        }
    }

    @Test func idsThatAreNotTheStoresAreNotFound() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run { () async throws in
            #expect(try await store.info("../../etc/passwd") == nil)
            await #expect(throws: UploadStoreError.notFound) { try await store.acquire("nothex") }
        }
    }

    @Test func aTruncatedUploadIsWhereItWas() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: nil, contentType: nil, contentDisposition: nil)
            let handle = try #require(try await store.acquire(info.id))
            try await handle.append(pattern(10))
            try await handle.append(pattern(5))
            try await handle.truncate(to: 10)
            #expect(handle.offset == 10)
            #expect(try await store.info(info.id)?.offset == 10)
            #expect(contents(store.dataPath(info.id)) == pattern(10))
        }
    }

    @Test func anAnswerIsRememberedWithWhereItPointed() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: 3, contentType: nil, contentDisposition: nil)
            try store.remember(info.id, status: 303, contentType: "text/plain", location: "/pictures/1",
                               body: Array("moved".utf8), createdAt: 42)
            #expect(try await store.answer(info.id) == UploadAnswer(status: 303, contentType: "text/plain",
                                                                    location: "/pictures/1",
                                                                    body: Array("moved".utf8), createdAt: 42))
        }
    }

    @Test func anAnswerWrittenBeforeTheVersionLineIsStillRead() throws {
        // Answers outlive the build that wrote them: they are in the
        // directory when the server restarts on a newer one.
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: 10, contentType: nil, contentDisposition: nil)
            writeBytes(Array("201 1700000000 text/plain; charset=utf-8\nstored 10".utf8),
                       to: store.donePath(info.id))
            let answer = try #require(try await store.answer(info.id))
            #expect(answer.status == 201)
            #expect(answer.contentType == "text/plain; charset=utf-8")
            #expect(answer.location == nil)
            #expect(answer.body == Array("stored 10".utf8))
            #expect(answer.createdAt == 1_700_000_000)
        }
    }

    @Test func metadataIsKeptForAsLongAsTheUploadIs() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: nil, contentType: nil, contentDisposition: nil,
                                              metadata: ["user": "ada"])
            #expect(try await store.info(info.id)?.metadata == ["user": "ada"])
            // Every write to an upload's state goes through a read of it, so
            // this is where metadata would be dropped if it were dropped
            // anywhere.
            try await store.update(info.id, length: 5, complete: true)
            #expect(try await store.info(info.id)?.metadata == ["user": "ada"])

            // An upload a build without metadata created: its state is in the
            // directory when the server restarts on a newer one.
            let older = try await store.create(length: nil, contentType: nil, contentDisposition: nil)
            writeBytes(Array("{\"id\":\"\(older.id)\",\"offset\":0,\"complete\":false,\"createdAt\":1700000000}".utf8),
                       to: store.infoPath(older.id))
            let read = try #require(try await store.info(older.id))
            #expect(read.metadata == nil && read.createdAt == 1_700_000_000)
        }
    }

    @Test func expiredUploadsAreRemoved() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        try run {
            let info = try await store.create(length: nil, contentType: nil, contentDisposition: nil)
            #expect(await store.removeExpired(olderThan: 3600) == 0)
            #expect(await store.removeExpired(olderThan: -1) == 1)
            #expect(try await store.info(info.id) == nil)
        }
    }
}

@Suite("Resumable uploads", .serialized)
struct ResumableUploadTests {

    @Test func aClientThatDoesNotSpeakTheProtocolGetsAnOrdinaryUpload() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: "plain body")
        #expect(response.status == .created)
        #expect(response.text == "stored 10")
        #expect(response.interim.isEmpty)
        #expect(response.header("upload-complete") == nil)
        #expect(completed.bytes == [Array("plain body".utf8)])
    }

    @Test func aCompleteUploadIsToldWhereItLivesFirst() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 1000, maxAge: 600))
        let response = try app.test.post("/files", body: "all at once",
                                         headers: [("Upload-Complete", "?1"), ("Content-Type", "text/plain"),
                                                   ("Upload-Draft-Interop-Version", "9")])
        #expect(response.status == .created)
        #expect(response.header("upload-complete") == "?1")
        #expect(response.interim.map { $0.status.code } == [104])
        let fields = response.interim.first?.headers ?? []
        #expect(fields.first { $0.name.lowercased() == "upload-draft-interop-version" }?.value == "9")
        #expect(fields.first { $0.name.lowercased() == "location" }?.value.hasPrefix("/uploads/") == true)
        #expect(fields.first { $0.name.lowercased() == "upload-limit" }?.value == "max-size=1000, max-age=600")
        #expect(completed.count == 1)
        #expect(completed.first?.info.contentType == "text/plain")
    }

    @Test func onlyAClientOfThisDraftIsSentA104() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        for version in [nil, "8", "ten"] {
            var headers = [("Upload-Complete", "?0")]
            if let version { headers.append(("Upload-Draft-Interop-Version", version)) }
            let response = try app.test.post("/files", body: pattern(5), headers: headers)
            #expect(response.interim.isEmpty)
            // Still an upload that can be resumed: the final answer says where.
            #expect(response.status == .created)
            #expect(response.header("location")?.hasPrefix("/uploads/") == true)
        }
    }

    @Test func theOffsetCanBeReadWithGETAndAnUploadCreatedWithPUT() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", methods: [.put, .post], store: store, progressInterval: 0) { _ in
            Text("ok")
        }
        let created = try app.test.put("/files", body: pattern(8), headers: [("Upload-Complete", "?0")])
        #expect(created.status == .created)
        let location = try #require(created.header("location"))
        let probe = try app.test.get(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "8")
    }

    @Test func anUploadInPartsIsCreatedQueriedAndCompleted() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "250")])
        #expect(created.status == .created)
        #expect(created.header("upload-complete") == "?0")
        #expect(created.header("upload-offset") == "100")
        let location = try #require(created.header("location"))
        #expect(completed.isEmpty)

        let probe = try app.test.head(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "100")
        #expect(probe.header("upload-complete") == "?0")
        #expect(probe.header("upload-length") == "250")
        #expect(probe.header("cache-control") == "no-store")
        #expect(probe.header("upload-limit")?.contains("max-age=") == true)

        let wrong = try app.test.request("PATCH", location, headers: partial(90, complete: false),
                                         body: pattern(10, from: 90))
        #expect(wrong.status == .conflict)
        #expect(wrong.header("upload-offset") == "100")
        #expect(wrong.header("content-type") == "application/problem+json")
        #expect(wrong.text.contains("\"expected-offset\":100"))
        #expect(wrong.text.contains("\"provided-offset\":90"))
        #expect(wrong.text.contains("mismatching-upload-offset"))

        let middle = try app.test.request("PATCH", location, headers: partial(100, complete: false),
                                          body: pattern(100, from: 100))
        #expect(middle.status == .noContent)
        #expect(middle.header("upload-offset") == "200")

        let last = try app.test.request("PATCH", location, headers: partial(200, complete: true),
                                        body: pattern(50, from: 200))
        #expect(last.status == .created)
        #expect(last.text == "stored 250")
        #expect(last.header("upload-complete") == "?1")
        #expect(completed.bytes == [pattern(250)])

        let done = try app.test.head(location)
        #expect(done.header("upload-complete") == "?1")
        #expect(done.header("upload-offset") == "250")

        let again = try app.test.request("PATCH", location, headers: partial(250, complete: true))
        #expect(again.status == .conflict)
        #expect(again.header("upload-complete") == "?1")
    }

    @Test func anInterruptedUploadKeepsWhatArrivedAndResumesFromIt() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        // The client's side ends after 400 of the 1000 bytes.
        let head = "POST /files HTTP/1.1\r\nHost: x\r\nUpload-Complete: ?1\r\nContent-Length: 1000\r\n\r\n"
        _ = try? client.send(raw: Array(head.utf8) + pattern(400))
        #expect(completed.isEmpty)

        // The client would have its Location from the 104; the test finds it.
        let ids = listUploads(store)
        try #require(ids.count == 1)
        let location = "/uploads/\(ids[0])"
        let probe = try client.head(location)
        #expect(probe.header("upload-offset") == "400")
        #expect(probe.header("upload-complete") == "?0")
        #expect(probe.header("upload-length") == "1000")

        let rest = try client.request("PATCH", location, headers: partial(400, complete: true),
                                      body: pattern(600, from: 400))
        #expect(rest.status == .created)
        #expect(completed.bytes == [pattern(1000)])
    }

    @Test func anAppendIsCheckedBeforeAByteIsStored() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))

        let untyped = try app.test.request("PATCH", location, headers: [
            ("Upload-Offset", "10"), ("Upload-Complete", "?0")], body: pattern(5))
        #expect(untyped.status == .unsupportedMediaType)
        let noOffset = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Complete", "?0")], body: pattern(5))
        #expect(noOffset.status == .badRequest)
        let badComplete = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "10"),
            ("Upload-Complete", "yes")], body: pattern(5))
        #expect(badComplete.status == .badRequest)
        let unknown = try app.test.request("PATCH", "/uploads/0123456789abcdef0123456789abcdef",
                                           headers: partial(0, complete: false), body: pattern(5))
        #expect(unknown.status == .notFound)
        let huge = try app.test.request("PATCH", location, headers: partial(10, complete: true), body: pattern(60))
        #expect(huge.status == .contentTooLarge)
        #expect(huge.header("upload-limit")?.contains("max-size=50") == true)
        #expect(try info(store, id(location))?.offset == 10)
    }

    @Test func aSecondAppendWhileOneIsInProgressIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        // Held as a request in another shard holds it.
        let busy = try #require(try run { try await store.acquire(id(location)) })
        let refused = try app.test.request("PATCH", location, headers: partial(10, complete: true),
                                           body: pattern(5))
        #expect(refused.status == .conflict)
        #expect(refused.header("retry-after") == "1")
        busy.release()
    }

    @Test func anAppendWaitsBrieflyForAnotherShardToLetGo() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let busy = try #require(try run { try await store.acquire(id(location)) })
        // Held for 100 ms, as a request in another shard finishing would.
        runtime.spawn {
            try? await Runtime.sleep(for: .milliseconds(100))
            busy.release()
        }
        let answer = try app.test.request("PATCH", location, headers: partial(10, complete: true),
                                          body: pattern(5, from: 10))
        #expect(answer.status == .created)
        #expect(completed.bytes == [pattern(15)])
    }

    @Test func anAppendThatWaitedOutACompletionIsRefused() throws {
        // The request this one waits for can be the one that completes the
        // upload. What it read before the wait says the upload is still
        // going; only what it reads under the lock says what it is now.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let upload = id(location)
        let busy = try #require(try run { try await store.acquire(upload) })
        // The holder completes the upload while this request is waiting on it.
        runtime.spawn {
            try? await Runtime.sleep(for: .milliseconds(100))
            try? await store.update(upload, length: 10, complete: true)
            busy.release()
        }
        let refused = try app.test.request("PATCH", location, headers: partial(10, complete: true))
        #expect(refused.status == .conflict)
        #expect(refused.header("upload-complete") == "?1")
        #expect(refused.header("upload-offset") == "10")
        #expect(completed.isEmpty, "the handler did not run for an upload another request completed")
    }

    @Test func anAppendTakesALengthDeclaredWhileItWaited() throws {
        // The request this one waits for can be the one that declares how
        // long the upload is. Nothing told this one, so unless it reads the
        // length under the lock it has nothing to stop its bytes at.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let upload = id(location)
        let busy = try #require(try run { try await store.acquire(upload) })
        // The holder declares a length this request would run past.
        runtime.spawn {
            try? await Runtime.sleep(for: .milliseconds(100))
            try? await store.update(upload, length: 20, complete: false)
            busy.release()
        }
        let answer = try app.test.request("PATCH", location, headers: partial(10, complete: false),
                                          body: pattern(20, from: 10))
        #expect(answer.status == .badRequest)
        #expect(try #require(try info(store, upload)).offset <= 20, "it stopped at the length")
    }

    @Test func aResumeSupersedesAnAppendStillGoingOverHTTP1() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))

        // An append whose client has gone quiet: half its body, and a
        // connection nobody has closed.
        let quiet = try app.test.http2(handshake: false)
        let head = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nContent-Length: 90\r\n\r\n"
        try quiet.send(raw: Array(head.utf8) + pattern(40, from: 10))
        try waitForOffset(store, id(location), 50)

        // The client, back on a new connection, asks where to go on from:
        // the older request is ended, and what it received is kept.
        let probe = try app.test.head(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "50")
        #expect((try? quiet.readUntilClose()) != nil, "the superseded request's connection is closed")

        let rest = try app.test.request("PATCH", location, headers: partial(50, complete: true),
                                        body: pattern(50, from: 50))
        #expect(rest.status == .created)
        #expect(completed.bytes == [pattern(100)])
    }

    @Test func aResumeSupersedesAnAppendStillGoingOverHTTP2() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))

        let quiet = try app.test.http2()
        let stream = try quiet.request("PATCH", location,
                                       headers: partial(10, complete: true) + [("Content-Length", "90")],
                                       body: pattern(40, from: 10), endStream: false)
        try waitForOffset(store, id(location), 50)

        let probe = try app.test.head(location)
        #expect(probe.header("upload-offset") == "50")
        // Reset as cancelled: the client is told to stop sending.
        #expect(try quiet.response(stream).reset == H2Error.cancel.rawValue)

        let rest = try app.test.request("PATCH", location, headers: partial(50, complete: true),
                                        body: pattern(50, from: 50))
        #expect(rest.status == .created)
        #expect(completed.bytes == [pattern(100)])
    }

    @Test func anUploadOverHTTP2IsToldWhereItLivesAndCompletes() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let whole = pattern(300 * 1024)
        let h2 = try app.test.http2()
        let response = try h2.post("/files", body: whole, headers: draft)
        #expect(response.status == .created)
        #expect(response.interim.map { $0.status.code } == [104])
        #expect(response.text == "stored \(whole.count)")
        #expect(completed.bytes == [whole])
    }

    @Test func anAppendPastTheLengthIsRefusedAndStoresNothing() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "20")])
        let location = try #require(created.header("location"))
        let over = try app.test.request("PATCH", location, headers: partial(10, complete: false),
                                        body: pattern(30, from: 10))
        #expect(over.status == .badRequest)
        #expect(over.text.contains("inconsistent-upload-length"))
        #expect(try info(store, id(location))?.offset == 10)
    }

    @Test func aLastAppendShortOfTheLengthDoesNotComplete() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "100")])
        let location = try #require(created.header("location"))
        // Chunked, so its length is only known once it has ended.
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nabcde\r\n0\r\n\r\n"
        let short = try app.test.send(raw: Array(raw.utf8))
        #expect(short.status == .badRequest)
        #expect(completed.isEmpty)
        #expect(try info(store, id(location))?.complete == false)
    }

    @Test func anUploadOfNoDeclaredLengthIsHeldToTheMaximumAsItArrives() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let body = String(repeating: "x", count: 60)
        let raw = "POST /files HTTP/1.1\r\nHost: x\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3c\r\n\(body)\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == .contentTooLarge)
        #expect(response.header("upload-limit")?.contains("max-size=50") == true)
        #expect(completed.isEmpty)
    }

    @Test func progressIsReportedAsTheBodyArrives() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 8) { upload in
            Text("stored \(upload.length)", status: .created)
        }
        let response = try app.test.post("/files", body: String(repeating: "y", count: 20), headers: draft)
        #expect(response.status == .created)
        let offsets = response.interim.compactMap { r in
            r.headers.first { $0.name.lowercased() == "upload-offset" }?.value
        }
        #expect(offsets == ["20"])
    }

    @Test func anAppendOfAnotherTypeIsUnsupported() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let typed = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "text/plain"), ("Upload-Offset", "10"), ("Upload-Complete", "?1")],
            body: pattern(5))
        #expect(typed.status == .unsupportedMediaType)
        #expect(try info(store, id(location))?.offset == 10)
    }

    @Test func anUploadDeclaredTooLargeIsRefusedBeforeOneIsMade() throws {
        let directory = temporaryDirectory()
        let store = try FileUploadStore(directory: directory)
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let response = try app.test.post("/files", body: String(repeating: "z", count: 60),
                                         headers: [("Upload-Complete", "?1")])
        #expect(response.status == .contentTooLarge)
        #expect(names(in: directory, endingIn: ".data").isEmpty)
    }

    @Test func anAppendOfNoDeclaredLengthIsHeldToTheAppendLimit() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxAppendSize: 10))
        let created = try app.test.post("/files", body: pattern(5), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 5\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "14\r\n\(String(repeating: "a", count: 20))\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == .contentTooLarge)
        #expect(try info(store, id(location))?.offset == 5)
    }

    @Test func anUploadShorterThanMinSizeIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minSize: 10))

        // Declared too short: refused before an upload exists.
        let declared = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?1")])
        #expect(declared.status == .badRequest)
        #expect(declared.text.contains("min-size"))
        #expect(declared.header("upload-limit") == "min-size=10, max-age=86400")
        #expect(listUploads(store).isEmpty, "nothing was stored for it")
        #expect(completed.isEmpty)

        // An append that says it completes the upload at 6 bytes says so
        // before it sends them, so it too is refused before anything is
        // stored: the upload stays where it was.
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let upload = id(location)
        let short = try app.test.request("PATCH", location, headers: partial(4, complete: true),
                                         body: pattern(2, from: 4))
        #expect(short.status == .badRequest)
        #expect(short.text.contains("min-size"))
        #expect(completed.isEmpty, "the handler was not called")
        #expect(try info(store, upload)?.complete == false, "still open")
        #expect(try info(store, upload)?.offset == 4, "and nothing was taken from it")

        // The rest of it, and now it is long enough.
        let rest = try app.test.request("PATCH", location, headers: partial(4, complete: true),
                                        body: pattern(6, from: 4))
        #expect(rest.status == .created, "\(rest.status) \(rest.text)")
        #expect(completed.bytes == [pattern(10)])
    }

    @Test func anUploadThatEndsShortOfMinSizeKeepsWhatItHas() throws {
        // Chunked, so how short it is only becomes known once it has all
        // arrived. The completion is refused, the upload stays open, and what
        // came is kept -- the client can send the rest.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minSize: 10))
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let upload = id(location)
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 4\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "2\r\nab\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == .badRequest)
        #expect(response.text.contains("min-size"))
        #expect(response.header("upload-offset") == "6")
        #expect(completed.isEmpty)
        #expect(try info(store, upload)?.complete == false)
        #expect(try info(store, upload)?.offset == 6, "what arrived is kept")
    }

    @Test func anAppendShorterThanMinAppendSizeIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minAppendSize: 8))

        // Creating with an empty body is how a client starts, so creation is
        // not held to it.
        let created = try app.test.post("/files", body: [], headers: [("Upload-Complete", "?0")])
        #expect(created.status == .created)
        let location = try #require(created.header("location"))

        let small = try app.test.request("PATCH", location, headers: partial(0, complete: false), body: pattern(3))
        #expect(small.status == .badRequest)
        #expect(small.text.contains("min-append-size"))
        #expect(small.header("upload-limit") == "min-append-size=8, max-age=86400")
        #expect(try info(store, id(location))?.offset == 0, "nothing was stored")

        // A big enough one is taken.
        #expect(try app.test.request("PATCH", location, headers: partial(0, complete: false),
                                     body: pattern(8)).status == .noContent)

        // And the one that completes the upload may be as short as what is
        // left of it.
        let last = try app.test.request("PATCH", location, headers: partial(8, complete: true),
                                        body: pattern(1, from: 8))
        #expect(last.status == .created, "\(last.status) \(last.text)")
        #expect(completed.bytes == [pattern(9)])
    }

    @Test func anAppendOfNoDeclaredLengthIsHeldToTheMinimumToo() throws {
        // Chunked: how much came is only known once it has, so what arrived is
        // kept at the offset it reached and the request is still refused.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minAppendSize: 8))
        let created = try app.test.post("/files", body: [], headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 0\r\nUpload-Complete: ?0\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3\r\nabc\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == .badRequest)
        #expect(response.text.contains("min-append-size"))
        #expect(response.header("upload-offset") == "3", "what arrived is where it resumes from")
        #expect(try info(store, id(location))?.offset == 3)
    }

    @Test func bytesThatAreNotWhatContentDigestSaysAreDropped() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let upload = id(location)

        // A digest of bytes other than the ones sent: the append is refused
        // and the upload stays where it was, so the client can send again.
        let wrong = try app.test.request("PATCH", location, headers: partial(4, complete: false) + [
            ("Content-Digest", Digest.field(Digest.sha256(pattern(6, from: 99)))),
        ], body: pattern(6, from: 4))
        #expect(wrong.status == .badRequest)
        #expect(wrong.text.contains("mismatching-digest"))
        #expect(wrong.header("upload-offset") == "4")
        #expect(try info(store, upload)?.offset == 4, "nothing of that request was kept")

        // The same bytes with the digest they really have.
        let right = try app.test.request("PATCH", location, headers: partial(4, complete: true) + [
            ("Content-Digest", Digest.field(Digest.sha256(pattern(6, from: 4)))),
        ], body: pattern(6, from: 4))
        #expect(right.status == .created, "\(right.status) \(right.text)")
        #expect(completed.bytes == [pattern(10)])
    }

    @Test func aDigestInALanguageTheServerDoesNotSpeakIsRefused() throws {
        // Saying nothing is fine; asking for a check that cannot happen is
        // not, because the client would take silence for a yes.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: pattern(4), headers: [
            ("Upload-Complete", "?1"), ("Content-Digest", "sha-512=:AAAA:"),
        ])
        #expect(response.status == .badRequest)
        #expect(response.text.contains("Content-Digest"))
        #expect(completed.isEmpty)
        #expect(listUploads(store).isEmpty)

        let declared = try app.test.post("/files", body: pattern(4), headers: [
            ("Upload-Complete", "?1"), ("Repr-Digest", "md5=:AAAA:"),
        ])
        #expect(declared.status == .badRequest)
        #expect(declared.text.contains("Repr-Digest"))
    }

    @Test func anUploadIsCheckedAgainstTheDigestItWasCreatedWith() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let whole = pattern(10)

        // Declared at creation, checked when the last byte is in -- three
        // requests later, and it holds across all of them.
        let created = try app.test.post("/files", body: Array(whole[0..<4]), headers: [
            ("Upload-Complete", "?0"), ("Upload-Length", "10"),
            ("Repr-Digest", Digest.field(Digest.sha256(whole))),
        ])
        let location = try #require(created.header("location"))
        #expect(try app.test.request("PATCH", location, headers: partial(4, complete: false),
                                     body: Array(whole[4..<7])).status == .noContent)
        let done = try app.test.request("PATCH", location, headers: partial(7, complete: true),
                                        body: Array(whole[7...]))
        #expect(done.status == .created, "\(done.status) \(done.text)")
        #expect(completed.bytes == [whole])
    }

    @Test func anUploadThatIsNotItsReprDigestIsRefusedAndRemoved() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        // A digest of something else: each request's own bytes are fine, and
        // what they add up to is not what was promised.
        let response = try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"),
            ("Repr-Digest", Digest.field(Digest.sha256(pattern(10, from: 5)))),
        ])
        #expect(response.status == .badRequest)
        #expect(response.text.contains("mismatching-digest"))
        #expect(completed.isEmpty, "the handler never saw it")
        // Whole and wrong: appending cannot mend it, so it is gone.
        #expect(listUploads(store).isEmpty)
    }

    @Test func anUploadInOneRequestIsHashedAsItArrives() throws {
        // Several reads' worth, so the hash is made a piece at a time and the
        // pieces have to add up to what the file holds.
        let whole = pattern(700 * 1024 + 13)
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let asked = try app.test.post("/files", body: whole, headers: [
            ("Upload-Complete", "?1"), ("Want-Repr-Digest", "sha-256=1"),
            ("Repr-Digest", Digest.field(Digest.sha256(whole))),
        ])
        #expect(asked.status == .created, "\(asked.status) \(asked.text)")
        #expect(asked.header("repr-digest") == Digest.field(Digest.sha256(whole)))
        #expect(completed.bytes == [whole])
    }

    @Test func aClientCanAskWhatTheUploadsDigestIs() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let asked = try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"), ("Want-Repr-Digest", "sha-256=1"),
        ])
        #expect(asked.status == .created)
        #expect(asked.header("repr-digest") == Digest.field(Digest.sha256(pattern(10))))

        // Not asked for, not computed, not sent.
        let quiet = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?1")])
        #expect(quiet.header("repr-digest") == nil)
        // And a client that says it does not want one.
        let declined = try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"), ("Want-Repr-Digest", "sha-256=0"),
        ])
        #expect(declined.header("repr-digest") == nil)
    }

    @Test func theHandlerCanHaveTheDigestWithoutAskingTwice() throws {
        let seen = DigestsSeen()
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
            let digest = await upload.digest()
            // The same, hashed on the calling thread, from code that is not
            // async -- the only place that overload can be called.
            let here = digestOnThisThread(upload)
            seen.digests.withLock { $0 += [digest, here] }
            return Text("ok", status: .created)
        }
        // Computed for the check, and handed on rather than computed again.
        #expect(try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"),
            ("Repr-Digest", Digest.field(Digest.sha256(pattern(10)))),
        ]).status == .created)
        #expect(seen.digests.withLock { $0 } == [Digest.sha256(pattern(10)), Digest.sha256(pattern(10))])

        // Nobody asked, so it is read from the file when the handler wants it.
        seen.digests.withLock { $0 = [] }
        #expect(try app.test.post("/files", body: pattern(6), headers: [("Upload-Complete", "?1")]).status
                == .created)
        #expect(seen.digests.withLock { $0 } == [Digest.sha256(pattern(6)), Digest.sha256(pattern(6))])
    }

    @Test func aFinishedUploadIsAnsweredAgainToAClientThatAsks() throws {
        // The answer to the request that finished an upload is the one thing
        // the protocol cannot give a client a second time: HEAD says it is
        // complete, and says nothing about what the application made of it.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: draft)
        #expect(created.status == .created)
        #expect(created.text == "stored 10")
        let location = try #require(uploadURL(created))

        let again = try app.test.get(location)
        #expect(again.status == .created, "the same status")
        #expect(again.text == "stored 10", "and the same body")
        #expect(again.header("upload-complete") == "?1")
        #expect(again.header("content-type") == created.header("content-type"))
        #expect(completed.count == 1, "and the handler did not run again")

        // HEAD is what the draft describes, and stays that way.
        let head = try app.test.head(location)
        #expect(head.status == .noContent)
        #expect(head.header("upload-offset") == "10")
        #expect(head.header("upload-complete") == "?1")
    }

    @Test func anAnswerThatRedirectsIsReplayedWithWhereItPoints() throws {
        // A handler that put the bytes somewhere answers with where they
        // went. A replay that keeps only the status is a redirect to nowhere.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { _ in
            Redirect(to: "/pictures/1", status: .seeOther)
        }
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        let finished = try app.test.request("PATCH", location, headers: partial(10, complete: true))
        #expect(finished.status == .seeOther)
        #expect(finished.header("location") == "/pictures/1")

        let again = try app.test.get(location)
        #expect(again.status == .seeOther)
        #expect(again.header("location") == "/pictures/1")
        #expect(again.header("upload-complete") == "?1")
    }

    @Test func anAnswerOutlivesTheBytesItIsAbout() throws {
        // What a real handler does: move the bytes somewhere and remove the
        // upload. The answer is still owed to a client that lost it.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
            try await upload.remove()
            return Text("filed \(upload.length)", status: .created)
        }
        let created = try app.test.post("/files", body: pattern(7), headers: draft)
        let location = try #require(uploadURL(created))
        #expect(try info(store, id(location)) == nil, "the upload itself is gone")

        let again = try app.test.get(location)
        #expect(again.status == .created)
        #expect(again.text == "filed 7")
        // And a HEAD, which is about the upload rather than the answer, says
        // it is not there any more.
        #expect(try app.test.head(location).status == .notFound)
    }

    @Test func anUploadStillGoingIsNotReplayed() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        // A GET before it finishes is the offset, as it always was.
        let response = try app.test.get(location)
        #expect(response.status == .noContent)
        #expect(response.header("upload-offset") == "4")
        #expect(response.header("upload-complete") == "?0")
    }

    @Test func cancellingTakesTheAnswerWithIt() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(5), headers: draft)
        let location = try #require(uploadURL(created))
        #expect(try app.test.get(location).status == .created)
        // The client asked for it to be gone, so it is gone.
        #expect(try app.test.delete(location).status == .noContent)
        #expect(try app.test.get(location).status == .notFound)
        #expect(listUploads(store).isEmpty)
    }

    @Test func anAnswerExpiresWithTheUploadItIsAbout() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let clock = HandClock()
        store.clock = { clock.now.load(ordering: .relaxed) }
        let app = uploadApp(store, limits: UploadLimits(maxAge: 0))
        let created = try app.test.post("/files", body: pattern(5), headers: draft)
        let location = try #require(uploadURL(created))
        clock.now.add(1, ordering: .relaxed)
        #expect(try app.test.get(location).status == .notFound, "past maxAge, there is nothing to replay")
        // And the next sweep takes the file with it.
        try run { _ = await store.removeExpired(olderThan: 0) }
        #expect(try run { try await store.answer(id(location)) } == nil)
    }

    @Test func anUploadPastItsAgeIsGone() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let clock = HandClock()
        store.clock = { clock.now.load(ordering: .relaxed) }
        let app = uploadApp(store, limits: UploadLimits(maxAge: 0))
        let created = try app.test.post("/files", body: pattern(5), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        clock.now.add(1, ordering: .relaxed)
        #expect(try app.test.head(location).status == .notFound)
    }

    @Test func lengthsThatDisagreeAreInconsistent() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: pattern(10),
                                         headers: [("Upload-Complete", "?1"), ("Upload-Length", "20")])
        #expect(response.status == .badRequest)
        #expect(response.text.contains("inconsistent-upload-length"))
        #expect(completed.isEmpty)
    }

    @Test func anUploadCanBeCancelled() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(created.header("location"))
        #expect(try app.test.delete(location).status == .noContent)
        #expect(try app.test.head(location).status == .notFound)
        #expect(try app.test.delete(location).status == .notFound)
    }

    @Test func whatOnCreateRecordsIsThereWhenTheUploadCompletes() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed.clear()
        let app = Application()
        // What an application behind `authenticate` does: the identity the
        // middleware established is read where there is a request to read it
        // from, and kept for the request that has none.
        app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
            // The extractors a handler uses work here too.
            var parameter = 0
            let bearer = try await BearerToken.extract(from: request, parameter: &parameter)
            return ["user": bearer.token, "album": request.query]
        }) { upload in
            completed.add(upload)
            return Text("\(upload.metadata["user"] ?? "-") \(upload.metadata["album"] ?? "-")",
                        status: .created)
        }
        let created = try app.test.post("/files?album=sea", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150"),
                                                  ("Authorization", "Bearer ada")])
        #expect(created.status == .created)
        let location = try #require(created.header("location"))

        // The request that finishes the upload carries no identity at all.
        let last = try app.test.request("PATCH", location, headers: partial(100, complete: true),
                                        body: pattern(50, from: 100))
        #expect(last.status == .created)
        #expect(last.text == "ada album=sea")
        #expect(completed.bytes == [pattern(150)])
        #expect(completed.first?.info.metadata == ["user": "ada", "album": "album=sea"])
    }

    @Test func anUploadWithoutTheHookHasNoMetadata() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        #expect(try app.test.post("/files", body: "plain body").status == .created)
        #expect(completed.first?.info.metadata == nil)
        #expect(completed.first.map { CompletedUpload(info: $0.info, store: store, sha256: nil).metadata } == [:])
    }

    @Test func anUploadOnCreateRefusesIsNeverCreated() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed.clear()
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
            guard request.header("authorization") != nil else {
                throw HTTPError(.forbidden, "who is uploading this")
            }
            return [:]
        }) { upload in
            completed.add(upload)
            return Text("stored \(upload.length)", status: .created)
        }
        let refused = try app.test.post("/files", body: pattern(10), headers: draft)
        #expect(refused.status == .forbidden)
        // Nothing to sweep up: the hook ran before the upload existed.
        #expect(listUploads(store).isEmpty)
        #expect(completed.isEmpty)

        let allowed = try app.test.post("/files", body: pattern(10),
                                        headers: draft + [("Authorization", "Bearer ada")])
        #expect(allowed.status == .created)
        #expect(completed.count == 1)
    }

    @Test func uploadsMountedInAGroupSayWhereTheyReallyAre() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed.clear()
        let app = Application()
        app.group("/api") {
            app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
                completed.add(upload)
                return Text("stored \(upload.length)", status: .created)
            }
        }
        let created = try app.test.post("/api/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150"),
                                                  ("Upload-Draft-Interop-Version", "9")])
        #expect(created.status == .created)
        let location = try #require(created.header("location"))
        #expect(location.hasPrefix("/api/uploads/"))
        // The 104 and the 201 name the same place.
        #expect(created.interim.first?.headers.first { $0.name.lowercased() == "location" }?.value == location)

        // And it is a URL the client can use: everything the draft asks of an
        // upload's own URL works there.
        let probe = try app.test.head(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "100")
        let last = try app.test.request("PATCH", location, headers: partial(100, complete: true),
                                        body: pattern(50, from: 100))
        #expect(last.status == .created)
        #expect(completed.bytes == [pattern(150)])
        #expect(try app.test.get(location).text == "stored 150")
        #expect(try app.test.delete(location).status == .noContent)
    }

    @Test(arguments: [
        // Empty segments are kept by the router, so they are counted.
        ("/api", "/files/", "/api/files/", "/api/uploads/"),
        ("/api", "/files//new", "/api/files//new", "/api/uploads/"),
        // A group's own root is the prefix itself.
        ("/api", "/", "/api", "/api/uploads/"),
        ("", "/", "/", "/uploads/"),
        ("", "/files/", "/files/", "/uploads/"),
    ])
    func anUploadsURLIsRightWhateverSlashesThePatternHas(group: String, route: String, post: String,
                                                         prefix: String) throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        let register = {
            app.resumableUploads(route, store: store, progressInterval: 0) { upload in
                Text("stored \(upload.length)", status: .created)
            }
        }
        if group.isEmpty { register() } else { app.group(group, register) }
        let created = try app.test.post(post, body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150")])
        #expect(created.status == .created)
        let location = try #require(created.header("location"))
        #expect(location.hasPrefix(prefix))
        #expect(location.dropFirst(prefix.count).allSatisfy { $0 != "/" })
        let probe = try app.test.head(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "100")
    }

    @Test func aTrailingSlashTheRouterIgnoredIsNotTakenForAPatternSegment() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.trailingSlash(.ignore)
        app.group("/api") {
            app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
                Text("stored \(upload.length)", status: .created)
            }
        }
        let created = try app.test.post("/api/files//", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150")])
        #expect(created.status == .created)
        #expect(created.header("upload-offset") == "100", "the body was read as it arrived")
        let location = try #require(created.header("location"))
        #expect(location.hasPrefix("/api/uploads/"))
        #expect(try app.test.head(location).status == .noContent)
    }

    @Test func aGroupsOwnParametersDoNotTakeTheUploadsPlace() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed.clear()
        let app = Application()
        app.group("/users/:user") {
            app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
                // The group's parameter, which is still the first one.
                ["user": request.parameter(0)]
            }) { upload in
                completed.add(upload)
                return Text("stored for \(upload.metadata["user"] ?? "-")", status: .created)
            }
        }
        let created = try app.test.post("/users/ada/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150")])
        let location = try #require(created.header("location"))
        #expect(location.hasPrefix("/users/ada/uploads/"))

        let probe = try app.test.head(location)
        #expect(probe.status == .noContent)
        #expect(probe.header("upload-offset") == "100")
        let last = try app.test.request("PATCH", location, headers: partial(100, complete: true),
                                        body: pattern(50, from: 100))
        #expect(last.status == .created)
        #expect(last.text == "stored for ada")
        #expect(completed.bytes == [pattern(150)])

        // Another user's path is another upload's URL, and the id is read from
        // the right end of it either way.
        #expect(try app.test.head("/users/bob/uploads/0123456789abcdef0123456789abcdef").status == .notFound)
    }

    @Test func aStreamedAnswerIsNotRememberedAsAnEmptyOne() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { _ in
            StreamingBody(contentType: "text/plain") { body in
                try await body.write("receipt")
            }
        }
        let created = try app.test.post("/files", body: pattern(10), headers: draft)
        #expect(created.text == "receipt")
        let location = try #require(uploadURL(created))

        // The receipt was written after the answer was already on its way, so
        // there was nothing to remember. Better the upload's state than a
        // success with an empty body where the receipt should be.
        let replay = try app.test.get(location)
        #expect(replay.status == .noContent)
        #expect(replay.text.isEmpty)
        #expect(replay.header("upload-complete") == "?1")
        #expect(replay.header("upload-offset") == "10")
    }

    @Test func optionsAdvertisesTheLimits() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 5, minSize: 2, maxAppendSize: 3,
                                                         minAppendSize: 1, maxAge: 9))
        let response = try app.test.request("OPTIONS", "/files")
        #expect(response.header("upload-limit")
                == "max-size=5, min-size=2, max-append-size=3, min-append-size=1, max-age=9")
    }
}

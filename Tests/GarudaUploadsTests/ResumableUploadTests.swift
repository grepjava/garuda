import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import CAvian
@testable import Garuda
import AvianHTTP
@testable import GarudaUploads

nonisolated(unsafe) private var completed: [(info: UploadInfo, bytes: [UInt8])] = []

private func pattern(_ count: Int, from start: Int = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 + start) &* 197 &+ 3) }
}

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

/// An application serving uploads to /files, recording each one it completes.
private func uploadApp(_ store: FileUploadStore, limits: UploadLimits = UploadLimits()) -> Application {
    completed = []
    let app = Application()
    app.resumableUploads("/files", store: store, limits: limits, progressInterval: 0) { upload in
        completed.append((upload.info, contents(upload.path)))
        return Text("stored \(upload.length)", status: .created)
    }
    return app
}

private func header(_ response: TestResponse, _ name: String) -> String? { response.header(name) }

/// Somewhere for an upload handler to record what it saw.
private final class DigestsSeen: @unchecked Sendable {
    var digests: [[UInt8]?] = []
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

/// A complete upload made the way a client of the draft makes one, so the
/// answer names where it lives.
private let draft = [("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")]

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

@Suite("File upload store", .serialized)
struct FileUploadStoreTests {
    @Test func anUploadIsItsBytesAndItsState() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let info = try store.create(length: 10, contentType: "text/plain", contentDisposition: nil)
        #expect(info.offset == 0 && info.length == 10 && !info.complete)
        let handle = try #require(try store.acquire(info.id))
        try handle.append(Array("hello".utf8))
        #expect(handle.offset == 5)
        #expect(try store.info(info.id)?.offset == 5)
        handle.release()
        try store.update(info.id, length: 5, complete: true)
        let after = try #require(try store.info(info.id))
        #expect(after.complete && after.length == 5 && after.contentType == "text/plain")
        #expect(contents(store.dataPath(info.id)) == Array("hello".utf8))
        try store.delete(info.id)
        #expect(try store.info(info.id) == nil)
        #expect(throws: UploadStoreError.notFound) { try store.delete(info.id) }
    }

    @Test func oneRequestAppendsAtATime() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let info = try store.create(length: nil, contentType: nil, contentDisposition: nil)
        let first = try #require(try store.acquire(info.id))
        #expect(try store.acquire(info.id) == nil)
        first.release()
        #expect(try store.acquire(info.id) != nil)
    }

    @Test func aPathIsNeverTakenForAnID() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let real = try store.create(length: nil, contentType: nil, contentDisposition: nil)
        // Names that reach a real upload's file, but are not its id.
        #expect(throws: UploadStoreError.notFound) { try store.acquire("./" + real.id) }
        #expect(throws: UploadStoreError.notFound) { try store.acquire(real.id + "/.") }
    }

    @Test func idsThatAreNotTheStoresAreNotFound() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        #expect(try store.info("../../etc/passwd") == nil)
        #expect(throws: UploadStoreError.notFound) { try store.acquire("nothex") }
    }

    @Test func anAnswerWrittenBeforeTheVersionLineIsStillRead() throws {
        // Answers outlive the build that wrote them: they are in the
        // directory when the server restarts on a newer one.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let info = try store.create(length: 10, contentType: nil, contentDisposition: nil)
        writeBytes(Array("201 1700000000 text/plain; charset=utf-8\nstored 10".utf8),
                   to: store.donePath(info.id))
        let answer = try #require(try store.answer(info.id))
        #expect(answer.status == 201)
        #expect(answer.contentType == "text/plain; charset=utf-8")
        #expect(answer.location == nil)
        #expect(answer.body == Array("stored 10".utf8))
        #expect(answer.createdAt == 1_700_000_000)
    }

    @Test func metadataIsKeptForAsLongAsTheUploadIs() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let info = try store.create(length: nil, contentType: nil, contentDisposition: nil,
                                    metadata: ["user": "ada"])
        #expect(try store.info(info.id)?.metadata == ["user": "ada"])
        // Every write to an upload's state goes through a read of it, so this
        // is where metadata would be dropped if it were dropped anywhere.
        try store.update(info.id, length: 5, complete: true)
        #expect(try store.info(info.id)?.metadata == ["user": "ada"])

        // An upload a build without metadata created: its state is in the
        // directory when the server restarts on a newer one.
        let older = try store.create(length: nil, contentType: nil, contentDisposition: nil)
        writeBytes(Array("{\"id\":\"\(older.id)\",\"offset\":0,\"complete\":false,\"createdAt\":1700000000}".utf8),
                   to: store.infoPath(older.id))
        let read = try #require(try store.info(older.id))
        #expect(read.metadata == nil && read.createdAt == 1_700_000_000)
    }

    @Test func expiredUploadsAreRemoved() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let info = try store.create(length: nil, contentType: nil, contentDisposition: nil)
        #expect(store.removeExpired(olderThan: 3600) == 0)
        #expect(store.removeExpired(olderThan: -1) == 1)
        #expect(try store.info(info.id) == nil)
    }
}

@Suite("Resumable uploads", .serialized)
struct ResumableUploadTests {

    @Test func aClientThatDoesNotSpeakTheProtocolGetsAnOrdinaryUpload() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: "plain body")
        #expect(response.status == 201)
        #expect(response.text == "stored 10")
        #expect(response.interim.isEmpty)
        #expect(header(response, "upload-complete") == nil)
        #expect(completed.map(\.bytes) == [Array("plain body".utf8)])
    }

    @Test func aCompleteUploadIsToldWhereItLivesFirst() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 1000, maxAge: 600))
        let response = try app.test.post("/files", body: "all at once",
                                         headers: [("Upload-Complete", "?1"), ("Content-Type", "text/plain"),
                                                   ("Upload-Draft-Interop-Version", "9")])
        #expect(response.status == 201)
        #expect(header(response, "upload-complete") == "?1")
        #expect(response.interim.map { $0.status.code } == [104])
        #expect(response.interim.first?.headers.first { $0.name.lowercased() == "upload-draft-interop-version" }?.value == "9")
        let location = response.interim.first?.headers.first { $0.name.lowercased() == "location" }?.value
        #expect(location?.hasPrefix("/uploads/") == true)
        let limit = response.interim.first?.headers.first { $0.name.lowercased() == "upload-limit" }?.value
        #expect(limit == "max-size=1000, max-age=600")
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
            #expect(response.status == 201)
            #expect(header(response, "location")?.hasPrefix("/uploads/") == true)
        }
    }

    @Test func theOffsetCanBeReadWithGETAndAnUploadCreatedWithPUT() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        app.resumableUploads("/files", methods: [.put, .post], store: store, progressInterval: 0) { upload in
            completed.append((upload.info, contents(upload.path)))
            return Text("ok")
        }
        let created = try app.test.put("/files", body: pattern(8), headers: [("Upload-Complete", "?0")])
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))
        let probe = try app.test.get(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "8")
    }

    @Test func anUploadInPartsIsCreatedQueriedAndCompleted() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "250")])
        #expect(created.status == 201)
        #expect(header(created, "upload-complete") == "?0")
        #expect(header(created, "upload-offset") == "100")
        let location = try #require(header(created, "location"))
        #expect(completed.isEmpty)

        let probe = try app.test.head(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "100")
        #expect(header(probe, "upload-complete") == "?0")
        #expect(header(probe, "upload-length") == "250")
        #expect(header(probe, "cache-control") == "no-store")
        #expect(header(probe, "upload-limit")?.contains("max-age=") == true)

        let wrong = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "90"),
            ("Upload-Complete", "?0")], body: pattern(10, from: 90))
        #expect(wrong.status == 409)
        #expect(header(wrong, "upload-offset") == "100")
        #expect(header(wrong, "content-type") == "application/problem+json")
        #expect(wrong.text.contains("\"expected-offset\":100"))
        #expect(wrong.text.contains("\"provided-offset\":90"))
        #expect(wrong.text.contains("mismatching-upload-offset"))

        let middle = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "100"),
            ("Upload-Complete", "?0")], body: pattern(100, from: 100))
        #expect(middle.status == 204)
        #expect(header(middle, "upload-offset") == "200")

        let last = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "200"),
            ("Upload-Complete", "?1")], body: pattern(50, from: 200))
        #expect(last.status == 201)
        #expect(last.text == "stored 250")
        #expect(header(last, "upload-complete") == "?1")
        #expect(completed.map(\.bytes) == [pattern(250)])

        let done = try app.test.head(location)
        #expect(header(done, "upload-complete") == "?1")
        #expect(header(done, "upload-offset") == "250")

        let again = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "250"),
            ("Upload-Complete", "?1")], body: [])
        #expect(again.status == 409)
        #expect(header(again, "upload-complete") == "?1")
    }

    @Test func anInterruptedUploadKeepsWhatArrivedAndResumesFromIt() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        let head = "POST /files HTTP/1.1\r\nHost: x\r\nUpload-Complete: ?1\r\nContent-Length: 1000\r\n\r\n"
        try client.abandon(Array(head.utf8) + pattern(400), turns: 10)
        for _ in 0..<10 { client.turn() }
        #expect(completed.isEmpty)

        // The client would have its Location from the 104; the test finds it.
        let ids = try listUploads(store)
        #expect(ids.count == 1)
        let location = "/uploads/\(ids[0])"
        let probe = try client.head(location)
        #expect(header(probe, "upload-offset") == "400")
        #expect(header(probe, "upload-complete") == "?0")
        #expect(header(probe, "upload-length") == "1000")

        let rest = try client.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "400"),
            ("Upload-Complete", "?1")], body: pattern(600, from: 400))
        #expect(rest.status == 201)
        #expect(completed.map(\.bytes) == [pattern(1000)])
    }

    @Test func anAppendIsCheckedBeforeAByteIsStored() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))

        let untyped = try app.test.request("PATCH", location, headers: [
            ("Upload-Offset", "10"), ("Upload-Complete", "?0")], body: pattern(5))
        #expect(untyped.status == 415)
        let noOffset = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Complete", "?0")], body: pattern(5))
        #expect(noOffset.status == 400)
        let badComplete = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "10"),
            ("Upload-Complete", "yes")], body: pattern(5))
        #expect(badComplete.status == 400)
        let unknown = try app.test.request("PATCH", "/uploads/0123456789abcdef0123456789abcdef", headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "0"),
            ("Upload-Complete", "?0")], body: pattern(5))
        #expect(unknown.status == 404)
        let huge = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "10"),
            ("Upload-Complete", "?1")], body: pattern(60))
        #expect(huge.status == 413)
        #expect(header(huge, "upload-limit")?.contains("max-size=50") == true)
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 10)
    }

    @Test func aSecondAppendWhileOneIsInProgressIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let busy = try #require(try store.acquire(String(location.dropFirst(9))))
        let refused = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "10"),
            ("Upload-Complete", "?1")], body: pattern(5))
        #expect(refused.status == 409)
        #expect(header(refused, "retry-after") == "1")
        busy.release()
    }

    @Test func anAppendWaitsBrieflyForAnotherWorkerToLetGo() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        let created = try client.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let busy = try #require(try store.acquire(String(location.dropFirst(9))))

        let (socket, _, _) = try client.connect()
        let head = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nContent-Length: 5\r\n\r\n"
        let request = Array(head.utf8) + pattern(5, from: 10)
        _ = request.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        // Held for 100 ms, as a request on another worker finishing would.
        let released = av_monotonic_ms() + 100
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var answer: TestResponse? = nil
        let deadline = av_monotonic_ms() + 5000
        while answer == nil && av_monotonic_ms() < deadline {
            if av_monotonic_ms() >= released { busy.release() }
            client.turn()
            let n = chunk.withUnsafeMutableBufferPointer { av_read(socket, $0.baseAddress!, $0.count) }
            if n > 0 { received += chunk[0..<n] }
            answer = try TestResponse.parse(received, bodyless: false, closed: false)
        }
        busy.release()
        _ = close(socket)
        #expect(answer?.status == 201)
        #expect(completed.map(\.bytes) == [pattern(15)])
    }

    @Test func anAppendThatWaitedOutACompletionIsRefused() throws {
        // The request this one waits for can be the one that completes the
        // upload. What it read before the wait says the upload is still
        // going; only what it reads under the lock says what it is now.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        let created = try client.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let id = String(location.dropFirst(9))
        let busy = try #require(try store.acquire(id))

        let (socket, _, _) = try client.connect()
        let head = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nContent-Length: 0\r\n\r\n"
        _ = Array(head.utf8).withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        // The holder completes the upload while this request is waiting on it.
        let released = av_monotonic_ms() + 100
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var answer: TestResponse? = nil
        let deadline = av_monotonic_ms() + 5000
        while answer == nil && av_monotonic_ms() < deadline {
            if av_monotonic_ms() >= released {
                try store.update(id, length: 10, complete: true)
                busy.release()
            }
            client.turn()
            let n = chunk.withUnsafeMutableBufferPointer { av_read(socket, $0.baseAddress!, $0.count) }
            if n > 0 { received += chunk[0..<n] }
            answer = try TestResponse.parse(received, bodyless: false, closed: false)
        }
        busy.release()
        _ = close(socket)
        let refused = try #require(answer)
        #expect(refused.status == 409)
        #expect(header(refused, "upload-complete") == "?1")
        #expect(header(refused, "upload-offset") == "10")
        #expect(completed.isEmpty, "the handler did not run for an upload another request completed")
    }

    @Test func anAppendTakesALengthDeclaredWhileItWaited() throws {
        // The request this one waits for can be the one that declares how
        // long the upload is. Nothing told this one, so unless it reads the
        // length under the lock it has nothing to stop its bytes at.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        let created = try client.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let id = String(location.dropFirst(9))
        let busy = try #require(try store.acquire(id))

        let (socket, _, _) = try client.connect()
        let head = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?0\r\nContent-Length: 20\r\n\r\n"
        let request = Array(head.utf8) + pattern(20, from: 10)
        _ = request.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        // The holder declares a length this request would run past.
        let released = av_monotonic_ms() + 100
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var answer: TestResponse? = nil
        let deadline = av_monotonic_ms() + 5000
        while answer == nil && av_monotonic_ms() < deadline {
            if av_monotonic_ms() >= released {
                try store.update(id, length: 20, complete: false)
                busy.release()
            }
            client.turn()
            let n = chunk.withUnsafeMutableBufferPointer { av_read(socket, $0.baseAddress!, $0.count) }
            if n > 0 { received += chunk[0..<n] }
            answer = try TestResponse.parse(received, bodyless: false, closed: false)
        }
        busy.release()
        _ = close(socket)
        #expect(try #require(answer).status == 400)
        #expect(try #require(try store.info(id)).offset <= 20, "it stopped at the length")
    }

    @Test func aResumeSupersedesAnAppendStillWaitingOnThisWorker() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let client = app.test
        let created = try client.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))

        // An append whose client has gone quiet: half its body, and a
        // connection nobody has closed.
        let (socket, slot, _) = try client.connect()
        let head = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nContent-Length: 90\r\n\r\n"
        let stalled = Array(head.utf8) + pattern(40, from: 10)
        _ = stalled.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        for _ in 0..<10 { client.turn() }

        let probe = try client.head(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "50")
        #expect(client.worker.pointee.table[slot].pointee.state == .free)

        let rest = try client.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "50"),
            ("Upload-Complete", "?1")], body: pattern(50, from: 50))
        #expect(rest.status == 201)
        #expect(completed.map(\.bytes) == [pattern(100)])
        _ = close(socket)
    }

    @Test func anAppendPastTheLengthIsRefusedAndStoresNothing() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "20")])
        let location = try #require(header(created, "location"))
        let over = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "10"),
            ("Upload-Complete", "?0")], body: pattern(30, from: 10))
        #expect(over.status == 400)
        #expect(over.text.contains("inconsistent-upload-length"))
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 10)
    }

    @Test func aLastAppendShortOfTheLengthDoesNotComplete() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "100")])
        let location = try #require(header(created, "location"))
        // Chunked, so its length is only known once it has ended.
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 10\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nabcde\r\n0\r\n\r\n"
        let short = try app.test.send(raw: Array(raw.utf8))
        #expect(short.status == 400)
        #expect(completed.isEmpty)
        #expect(try store.info(String(location.dropFirst(9)))?.complete == false)
    }

    @Test func anUploadOfNoDeclaredLengthIsHeldToTheMaximumAsItArrives() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let body = String(repeating: "x", count: 60)
        let raw = "POST /files HTTP/1.1\r\nHost: x\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3c\r\n\(body)\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == 413)
        #expect(header(response, "upload-limit")?.contains("max-size=50") == true)
        #expect(completed.isEmpty)
    }

    @Test func progressIsReportedAsTheBodyArrives() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 8) { upload in
            Text("stored \(upload.length)", status: .created)
        }
        let response = try app.test.post("/files", body: String(repeating: "y", count: 20), headers: [
            ("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")])
        #expect(response.status == 201)
        let offsets = response.interim.compactMap { r in
            r.headers.first { $0.name.lowercased() == "upload-offset" }?.value
        }
        #expect(offsets == ["20"])
    }

    @Test func anAppendOfAnotherTypeIsUnsupported() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let typed = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "text/plain"), ("Upload-Offset", "10"), ("Upload-Complete", "?1")],
            body: pattern(5))
        #expect(typed.status == 415)
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 10)
    }

    @Test func anUploadDeclaredTooLargeIsRefusedBeforeOneIsMade() throws {
        let directory = temporaryDirectory()
        let store = try FileUploadStore(directory: directory)
        let app = uploadApp(store, limits: UploadLimits(maxSize: 50))
        let response = try app.test.post("/files", body: String(repeating: "z", count: 60),
                                         headers: [("Upload-Complete", "?1")])
        #expect(response.status == 413)
        let entries = try #require(opendir(directory))
        var made = 0
        while let entry = readdir(entries) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.hasSuffix(".data") { made += 1 }
        }
        closedir(entries)
        #expect(made == 0)
    }

    @Test func anAppendOfNoDeclaredLengthIsHeldToTheAppendLimit() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxAppendSize: 10))
        let created = try app.test.post("/files", body: pattern(5), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 5\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "14\r\n\(String(repeating: "a", count: 20))\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == 413)
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 5)
    }

    @Test func anUploadShorterThanMinSizeIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minSize: 10))

        // Declared too short: refused before an upload exists.
        let declared = try app.test.post("/files", body: pattern(4),
                                         headers: [("Upload-Complete", "?1")])
        #expect(declared.status == 400)
        #expect(declared.text.contains("min-size"))
        #expect(header(declared, "upload-limit") == "min-size=10, max-age=86400")
        #expect(try listUploads(store).isEmpty, "nothing was stored for it")
        #expect(completed.isEmpty)

        // An append that says it completes the upload at 6 bytes says so
        // before it sends them, so it too is refused before anything is
        // stored: the upload stays where it was.
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let id = String(location.dropFirst(9))
        let short = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "4"),
            ("Upload-Complete", "?1"),
        ], body: pattern(2, from: 4))
        #expect(short.status == 400)
        #expect(short.text.contains("min-size"))
        #expect(completed.isEmpty, "the handler was not called")
        #expect(try store.info(id)?.complete == false, "still open")
        #expect(try store.info(id)?.offset == 4, "and nothing was taken from it")

        // The rest of it, and now it is long enough.
        let rest = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "4"),
            ("Upload-Complete", "?1"),
        ], body: pattern(6, from: 4))
        #expect(rest.status == 201, "\(rest.status) \(rest.text)")
        #expect(completed.count == 1)
        #expect(completed.first?.bytes == pattern(10))
    }

    @Test func anUploadThatEndsShortOfMinSizeKeepsWhatItHas() throws {
        // Chunked, so how short it is only becomes known once it has all
        // arrived. The completion is refused, the upload stays open, and what
        // came is kept -- the client can send the rest.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minSize: 10))
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let id = String(location.dropFirst(9))
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 4\r\nUpload-Complete: ?1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "2\r\nab\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == 400)
        #expect(response.text.contains("min-size"))
        #expect(header(response, "upload-offset") == "6")
        #expect(completed.isEmpty)
        #expect(try store.info(id)?.complete == false)
        #expect(try store.info(id)?.offset == 6, "what arrived is kept")
    }

    @Test func anAppendShorterThanMinAppendSizeIsRefused() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minAppendSize: 8))

        // Creating with an empty body is how a client starts, so creation is
        // not held to it.
        let created = try app.test.post("/files", body: [], headers: [("Upload-Complete", "?0")])
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))

        let small = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "0"),
            ("Upload-Complete", "?0"),
        ], body: pattern(3))
        #expect(small.status == 400)
        #expect(small.text.contains("min-append-size"))
        #expect(header(small, "upload-limit") == "min-append-size=8, max-age=86400")
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 0, "nothing was stored")

        // A big enough one is taken.
        #expect(try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "0"),
            ("Upload-Complete", "?0"),
        ], body: pattern(8)).status == 204)

        // And the one that completes the upload may be as short as what is
        // left of it.
        let last = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "8"),
            ("Upload-Complete", "?1"),
        ], body: pattern(1, from: 8))
        #expect(last.status == 201, "\(last.status) \(last.text)")
        #expect(completed.first?.bytes == pattern(9))
    }

    @Test func anAppendOfNoDeclaredLengthIsHeldToTheMinimumToo() throws {
        // Chunked: how much came is only known once it has, so what arrived is
        // kept at the offset it reached and the request is still refused.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(minAppendSize: 8))
        let created = try app.test.post("/files", body: [], headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let raw = "PATCH \(location) HTTP/1.1\r\nHost: x\r\nContent-Type: application/partial-upload\r\n"
            + "Upload-Offset: 0\r\nUpload-Complete: ?0\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3\r\nabc\r\n0\r\n\r\n"
        let response = try app.test.send(raw: Array(raw.utf8))
        #expect(response.status == 400)
        #expect(response.text.contains("min-append-size"))
        #expect(header(response, "upload-offset") == "3", "what arrived is where it resumes from")
        #expect(try store.info(String(location.dropFirst(9)))?.offset == 3)
    }

    @Test func bytesThatAreNotWhatContentDigestSaysAreDropped() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let id = String(location.dropFirst(9))

        // A digest of bytes other than the ones sent: the append is refused
        // and the upload stays where it was, so the client can send again.
        let wrong = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "4"),
            ("Upload-Complete", "?0"),
            ("Content-Digest", Digest.field(Digest.sha256(pattern(6, from: 99)))),
        ], body: pattern(6, from: 4))
        #expect(wrong.status == 400)
        #expect(wrong.text.contains("mismatching-digest"))
        #expect(header(wrong, "upload-offset") == "4")
        #expect(try store.info(id)?.offset == 4, "nothing of that request was kept")

        // The same bytes with the digest they really have.
        let right = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "4"),
            ("Upload-Complete", "?1"),
            ("Content-Digest", Digest.field(Digest.sha256(pattern(6, from: 4)))),
        ], body: pattern(6, from: 4))
        #expect(right.status == 201, "\(right.status) \(right.text)")
        #expect(completed.first?.bytes == pattern(10))
    }

    @Test func aDigestInALanguageTheServerDoesNotSpeakIsRefused() throws {
        // Saying nothing is fine; asking for a check that cannot happen is
        // not, because the client would take silence for a yes.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: pattern(4), headers: [
            ("Upload-Complete", "?1"), ("Content-Digest", "sha-512=:AAAA:"),
        ])
        #expect(response.status == 400)
        #expect(response.text.contains("Content-Digest"))
        #expect(completed.isEmpty)
        #expect(try listUploads(store).isEmpty)

        let declared = try app.test.post("/files", body: pattern(4), headers: [
            ("Upload-Complete", "?1"), ("Repr-Digest", "md5=:AAAA:"),
        ])
        #expect(declared.status == 400)
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
        let location = try #require(header(created, "location"))
        #expect(try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "4"),
            ("Upload-Complete", "?0"),
        ], body: Array(whole[4..<7])).status == 204)
        let done = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "7"),
            ("Upload-Complete", "?1"),
        ], body: Array(whole[7...]))
        #expect(done.status == 201, "\(done.status) \(done.text)")
        #expect(completed.first?.bytes == whole)
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
        #expect(response.status == 400)
        #expect(response.text.contains("mismatching-digest"))
        #expect(completed.isEmpty, "the handler never saw it")
        // Whole and wrong: appending cannot mend it, so it is gone.
        #expect(try listUploads(store).isEmpty)
    }

    @Test func aClientCanAskWhatTheUploadsDigestIs() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let asked = try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"), ("Want-Repr-Digest", "sha-256=1"),
        ])
        #expect(asked.status == 201)
        #expect(header(asked, "repr-digest") == Digest.field(Digest.sha256(pattern(10))))

        // Not asked for, not computed, not sent.
        let quiet = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?1")])
        #expect(header(quiet, "repr-digest") == nil)
        // And a client that says it does not want one.
        let declined = try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"), ("Want-Repr-Digest", "sha-256=0"),
        ])
        #expect(header(declined, "repr-digest") == nil)
    }

    @Test func theHandlerCanHaveTheDigestWithoutAskingTwice() throws {
        // A box rather than a captured local: the handler is a `sending`
        // closure, and a local is still reachable from here, which Swift 6.2
        // reads as a race even though both run on the one worker thread.
        let seen = DigestsSeen()
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
            seen.digests.append(upload.digest())
            return Text("ok", status: .created)
        }
        // Computed for the check, and handed on rather than computed again.
        #expect(try app.test.post("/files", body: pattern(10), headers: [
            ("Upload-Complete", "?1"),
            ("Repr-Digest", Digest.field(Digest.sha256(pattern(10)))),
        ]).status == 201)
        #expect(seen.digests == [Digest.sha256(pattern(10))])

        // Nobody asked, so it is read from the file when the handler wants it.
        seen.digests = []
        #expect(try app.test.post("/files", body: pattern(6), headers: [("Upload-Complete", "?1")]).status == 201)
        #expect(seen.digests == [Digest.sha256(pattern(6))])
    }

    @Test func aFinishedUploadIsAnsweredAgainToAClientThatAsks() throws {
        // The answer to the request that finished an upload is the one thing
        // the protocol cannot give a client a second time: HEAD says it is
        // complete, and says nothing about what the application made of it.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: draft)
        #expect(created.status == 201)
        #expect(created.text == "stored 10")
        let location = try #require(uploadURL(created))

        let again = try app.test.get(location)
        #expect(again.status == 201, "the same status")
        #expect(again.text == "stored 10", "and the same body")
        #expect(header(again, "upload-complete") == "?1")
        #expect(header(again, "content-type") == "text/plain; charset=utf-8")
        #expect(completed.count == 1, "and the handler did not run again")

        // HEAD is what the draft describes, and stays that way.
        let head = try app.test.head(location)
        #expect(head.status == 204)
        #expect(header(head, "upload-offset") == "10")
        #expect(header(head, "upload-complete") == "?1")
    }

    @Test func anAnswerThatRedirectsIsReplayedWithWhereItPoints() throws {
        // A handler that put the bytes somewhere answers with where they
        // went. A replay that keeps only the status is a redirect to nowhere.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { _ in
            Redirect(to: "/pictures/1", status: .seeOther)
        }
        let client = app.test
        let created = try client.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        let finished = try client.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"),
            ("Upload-Offset", "10"), ("Upload-Complete", "?1"),
        ])
        #expect(finished.status == 303)
        #expect(header(finished, "location") == "/pictures/1")

        let again = try client.get(location)
        #expect(again.status == 303)
        #expect(header(again, "location") == "/pictures/1")
        #expect(header(again, "upload-complete") == "?1")
    }

    @Test func anAnswerOutlivesTheBytesItIsAbout() throws {
        // What a real handler does: move the bytes somewhere and remove the
        // upload. The answer is still owed to a client that lost it.
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
            try upload.remove()
            return Text("filed \(upload.length)", status: .created)
        }
        let created = try app.test.post("/files", body: pattern(7), headers: draft)
        let location = try #require(uploadURL(created))
        let id = String(location.dropFirst(9))
        #expect(try store.info(id) == nil, "the upload itself is gone")

        let again = try app.test.get(location)
        #expect(again.status == 201)
        #expect(again.text == "filed 7")
        // And a HEAD, which is about the upload rather than the answer, says
        // it is not there any more.
        #expect(try app.test.head(location).status == 404)
    }

    @Test func anUploadStillGoingIsNotReplayed() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(4), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        // A GET before it finishes is the offset, as it always was.
        let response = try app.test.get(location)
        #expect(response.status == 204)
        #expect(header(response, "upload-offset") == "4")
        #expect(header(response, "upload-complete") == "?0")
    }

    @Test func cancellingTakesTheAnswerWithIt() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(5), headers: draft)
        let location = try #require(uploadURL(created))
        #expect(try app.test.get(location).status == 201)
        // The client asked for it to be gone, so it is gone.
        #expect(try app.test.delete(location).status == 204)
        #expect(try app.test.get(location).status == 404)
        #expect(try listUploads(store).isEmpty)
    }

    @Test func anAnswerExpiresWithTheUploadItIsAbout() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxAge: 0))
        let created = try app.test.post("/files", body: pattern(5), headers: draft)
        let location = try #require(uploadURL(created))
        usleep(1_100_000)
        #expect(try app.test.get(location).status == 404, "past maxAge, there is nothing to replay")
        // And the next sweep takes the file with it.
        _ = store.removeExpired(olderThan: 0)
        #expect(try store.answer(String(location.dropFirst(9))) == nil)
    }

    @Test func anUploadPastItsAgeIsGone() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxAge: 0))
        let created = try app.test.post("/files", body: pattern(5), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        usleep(1_100_000)
        #expect(try app.test.head(location).status == 404)
    }

    @Test func lengthsThatDisagreeAreInconsistent() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let response = try app.test.post("/files", body: pattern(10),
                                         headers: [("Upload-Complete", "?1"), ("Upload-Length", "20")])
        #expect(response.status == 400)
        #expect(response.text.contains("inconsistent-upload-length"))
        #expect(completed.isEmpty)
    }

    @Test func anUploadCanBeCancelled() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        let created = try app.test.post("/files", body: pattern(10), headers: [("Upload-Complete", "?0")])
        let location = try #require(header(created, "location"))
        #expect(try app.test.delete(location).status == 204)
        #expect(try app.test.head(location).status == 404)
        #expect(try app.test.delete(location).status == 404)
    }

    @Test func whatOnCreateRecordsIsThereWhenTheUploadCompletes() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        // What an application behind `authenticate` does: the identity the
        // middleware established is read where there is a request to read it
        // from, and kept for the request that has none.
        app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
            // The extractors a handler uses work here too: `JWT<Claims>` reads
            // what `authenticate(jwt:)` established exactly like this.
            var parameter = 0
            let bearer = try BearerToken.extract(from: request, parameter: &parameter)
            return ["user": bearer.token, "album": request.query]
        }) { upload in
            completed.append((upload.info, contents(upload.path)))
            return Text("\(upload.metadata["user"] ?? "-") \(upload.metadata["album"] ?? "-")",
                        status: .created)
        }
        let created = try app.test.post("/files?album=sea", body: pattern(100),
                                       headers: [("Upload-Complete", "?0"), ("Upload-Length", "150"),
                                                 ("Authorization", "Bearer ada")])
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))

        // The request that finishes the upload carries no identity at all.
        let last = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "100"),
            ("Upload-Complete", "?1")], body: pattern(50, from: 100))
        #expect(last.status == 201)
        #expect(last.text == "ada album=sea")
        #expect(completed.map(\.bytes) == [pattern(150)])
        #expect(completed.first?.info.metadata == ["user": "ada", "album": "album=sea"])
    }

    @Test func anUploadWithoutTheHookHasNoMetadata() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store)
        #expect(try app.test.post("/files", body: "plain body").status == 201)
        #expect(completed.first?.info.metadata == nil)
        #expect(completed.first.map { CompletedUpload(info: $0.info, store: store, sha256: nil).metadata } == [:])
    }

    @Test func anUploadOnCreateRefusesIsNeverCreated() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
            guard request.header("authorization") != nil else {
                throw HTTPError(.forbidden, "who is uploading this")
            }
            return [:]
        }) { upload in
            completed.append((upload.info, contents(upload.path)))
            return Text("stored \(upload.length)", status: .created)
        }
        let refused = try app.test.post("/files", body: pattern(10), headers: draft)
        #expect(refused.status == 403)
        // Nothing to sweep up: the hook ran before the upload existed.
        #expect(try listUploads(store).isEmpty)
        #expect(completed.isEmpty)

        let allowed = try app.test.post("/files", body: pattern(10),
                                        headers: draft + [("Authorization", "Bearer ada")])
        #expect(allowed.status == 201)
        #expect(completed.count == 1)
    }

    @Test func uploadsMountedInAGroupSayWhereTheyReallyAre() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        app.group("/api") {
            app.resumableUploads("/files", store: store, progressInterval: 0) { upload in
                completed.append((upload.info, contents(upload.path)))
                return Text("stored \(upload.length)", status: .created)
            }
        }
        let created = try app.test.post("/api/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150"),
                                                  ("Upload-Draft-Interop-Version", "9")])
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))
        #expect(location.hasPrefix("/api/uploads/"))
        // The 104 and the 201 name the same place.
        #expect(created.interim.first?.headers.first { $0.name.lowercased() == "location" }?.value == location)

        // And it is a URL the client can use: everything the draft asks of an
        // upload's own URL works there.
        let probe = try app.test.head(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "100")
        let last = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "100"),
            ("Upload-Complete", "?1")], body: pattern(50, from: 100))
        #expect(last.status == 201)
        #expect(completed.map(\.bytes) == [pattern(150)])
        #expect(try app.test.get(location).text == "stored 150")
        #expect(try app.test.delete(location).status == 204)
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
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))
        #expect(location.hasPrefix(prefix))
        #expect(location.dropFirst(prefix.count).allSatisfy { $0 != "/" })
        let probe = try app.test.head(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "100")
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
        #expect(created.status == 201)
        let location = try #require(header(created, "location"))
        #expect(location.hasPrefix("/api/uploads/"))
        #expect(try app.test.head(location).status == 204)
    }

    @Test func aGroupsOwnParametersDoNotTakeTheUploadsPlace() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        completed = []
        let app = Application()
        app.group("/users/:user") {
            app.resumableUploads("/files", store: store, progressInterval: 0, onCreate: { request in
                // The group's parameter, which is still the first one.
                ["user": request.parameter(0)]
            }) { upload in
                completed.append((upload.info, contents(upload.path)))
                return Text("stored for \(upload.metadata["user"] ?? "-")", status: .created)
            }
        }
        let created = try app.test.post("/users/ada/files", body: pattern(100),
                                        headers: [("Upload-Complete", "?0"), ("Upload-Length", "150")])
        let location = try #require(header(created, "location"))
        #expect(location.hasPrefix("/users/ada/uploads/"))

        let probe = try app.test.head(location)
        #expect(probe.status == 204)
        #expect(header(probe, "upload-offset") == "100")
        let last = try app.test.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"), ("Upload-Offset", "100"),
            ("Upload-Complete", "?1")], body: pattern(50, from: 100))
        #expect(last.status == 201)
        #expect(last.text == "stored for ada")
        #expect(completed.map(\.bytes) == [pattern(150)])

        // Another user's path is another upload's URL, and the id is read from
        // the right end of it either way.
        #expect(try app.test.head("/users/bob/uploads/0123456789abcdef0123456789abcdef").status == 404)
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
        #expect(replay.status == 204)
        #expect(replay.text.isEmpty)
        #expect(header(replay, "upload-complete") == "?1")
        #expect(header(replay, "upload-offset") == "10")
    }

    @Test func optionsAdvertisesTheLimits() throws {
        let store = try FileUploadStore(directory: temporaryDirectory())
        let app = uploadApp(store, limits: UploadLimits(maxSize: 5, minSize: 2, maxAppendSize: 3, minAppendSize: 1, maxAge: 9))
        let response = try app.test.request("OPTIONS", "/files")
        #expect(header(response, "upload-limit") == "max-size=5, min-size=2, max-append-size=3, min-append-size=1, max-age=9")
    }
}

private func listUploads(_ store: FileUploadStore) throws -> [String] {
    guard let dir = opendir(store.directory) else { return [] }
    defer { closedir(dir) }
    var ids: [String] = []
    while let entry = readdir(dir) {
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if name.hasSuffix(".info") { ids.append(String(name.dropLast(5))) }
    }
    return ids
}

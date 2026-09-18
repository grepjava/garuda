#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import Garuda
@testable import FilesExample

// The file service end to end: an upload that is cut off and resumed, what is
// refused, and the downloads the static route serves.

private func temporaryDirectory() -> String {
    var template = Array("/tmp/garuda-files-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil)
    return String(cString: template)
}

/// A client for the service, with the static route its `main.swift` adds, so
/// the downloads are served here as they are when it is run.
private func client(_ configuration: FilesConfiguration) -> TestClient {
    var config = ServerConfig()
    config.maxConnections = 16
    config.staticRoutes = [filesStaticRoute(configuration)]
    config.staticListing = true
    config.staticIndex = true
    let client = filesApp(configuration).testClient(configuration: config)
    client.timeoutMillis = 20_000
    return client
}

private func bytes(_ count: Int, from start: Int = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 + start) &* 131 &+ 7) }
}

private func named(_ name: String) -> (String, String) {
    ("Content-Disposition", "attachment; filename=\"\(name)\"")
}

@Suite("Files example", .serialized)
struct FilesExampleTests {
    @Test func anUploadIsStoredAndServedBack() throws {
        let configuration = FilesConfiguration(directory: temporaryDirectory())
        let http = client(configuration)
        let content = bytes(4000)

        let created = try http.post("/files", body: content,
                                    headers: [("Upload-Complete", "?1"), named("photo.jpg")])
        #expect(created.status == .created, "\(created.status) \(created.text)")
        let stored = try created.json(StoredFile.self)
        #expect(stored.name == "photo.jpg")
        #expect(stored.size == 4000)
        #expect(stored.sha256 == hex(Digest.sha256(content)))

        // Served by the static route: the whole file, and a range of it.
        let whole = try http.get("/files/photo.jpg")
        #expect(whole.status == .ok)
        #expect(whole.body == content)
        #expect(whole.header("accept-ranges") == "bytes")

        let part = try http.get("/files/photo.jpg", headers: [("Range", "bytes=1000-1099")])
        #expect(part.status == 206)
        #expect(part.body == Array(content[1000..<1100]))
        #expect(part.header("content-range") == "bytes 1000-1099/4000")

        // And listed, with the digest beside it.
        let listing = try http.get("/files/")
        #expect(listing.status == .ok)
        #expect(listing.text.contains("photo.jpg"))
        #expect(listing.text.contains("photo.jpg.sha256"))

        #expect(try http.delete("/files/photo.jpg").status == .noContent)
        #expect(try http.get("/files/photo.jpg").status == .notFound)
        #expect(try http.delete("/files/photo.jpg").status == .notFound)
    }

    @Test func anUploadThatIsCutOffIsResumed() throws {
        let configuration = FilesConfiguration(directory: temporaryDirectory())
        let http = client(configuration)
        let content = bytes(200_000)

        // The client speaks the protocol, so it is told where the upload
        // lives before the body is read.
        let begun = try http.post("/files", body: Array(content[0..<120_000]),
                                  headers: [("Upload-Complete", "?0"),
                                            ("Upload-Draft-Interop-Version", "9"),
                                            named("big.bin")])
        #expect(begun.status == .created, "\(begun.status) \(begun.text)")
        let location = try #require(begun.header("location"))

        // Where it got to, as a client that lost its connection would ask.
        let head = try http.head(location)
        #expect(head.status == .noContent)
        #expect(head.header("upload-offset") == "120000")
        #expect(head.header("upload-complete") == "?0")

        // The rest of it, with the digest of the whole thing, which the
        // server checks before the handler sees it.
        let finished = try http.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"),
            ("Upload-Offset", "120000"),
            ("Upload-Complete", "?1"),
        ], body: Array(content[120_000...]))
        #expect(finished.status == .created, "\(finished.status) \(finished.text)")
        let stored = try finished.json(StoredFile.self)
        #expect(stored.size == 200_000)
        #expect(stored.sha256 == hex(Digest.sha256(content)))
        #expect(try http.get("/files/big.bin").body == content)

        // The answer to the request that finished it is owed to a client that
        // lost it, so asking the upload's URL gives it again.
        let again = try http.get(location)
        #expect(again.status == .created)
        #expect(try again.json(StoredFile.self) == stored)
    }

    @Test func whatTheServiceRefuses() throws {
        var configuration = FilesConfiguration(directory: temporaryDirectory())
        configuration.maximumBytes = 10_000
        let http = client(configuration)

        // Too big, by what the client declares.
        let big = try http.post("/files", body: bytes(20_000), headers: [("Upload-Complete", "?1")])
        #expect(big.status == .contentTooLarge)
        #expect(big.header("upload-limit")?.contains("max-size=10000") == true)

        // Empty, which min-size refuses.
        #expect(try http.post("/files", body: [], headers: [("Upload-Complete", "?1")]).status
                    == .badRequest)

        // Bytes that are not what the digest says: nothing is stored.
        let wrong = try http.post("/files", body: bytes(500), headers: [
            ("Upload-Complete", "?1"),
            ("Repr-Digest", Digest.field(Digest.sha256(bytes(500, from: 9)))),
            named("wrong.bin"),
        ])
        #expect(wrong.status == .badRequest)
        #expect(wrong.text.contains("mismatching-digest"))
        #expect(try http.get("/files/wrong.bin").status == .notFound)

        // An append too small to be worth a request, except the last.
        let begun = try http.post("/files", body: [], headers: [
            ("Upload-Complete", "?0"), ("Upload-Draft-Interop-Version", "9"),
        ])
        let location = try #require(begun.header("location"))
        let tiny = try http.request("PATCH", location, headers: [
            ("Content-Type", "application/partial-upload"),
            ("Upload-Offset", "0"), ("Upload-Complete", "?0"),
        ], body: bytes(100))
        #expect(tiny.status == .badRequest)
        #expect(tiny.text.contains("min-append-size"))
    }

    @Test func aNameTheClientSendsCannotBeAPath() throws {
        // The one place a client's idea of a name reaches the filesystem.
        #expect(safeName("photo.jpg") == "photo.jpg")
        #expect(safeName("a-b_c.1.tar.gz") == "a-b_c.1.tar.gz")
        #expect(safeName(nil) == nil)
        #expect(safeName("") == nil)
        #expect(safeName("../../etc/passwd") == nil)
        #expect(safeName("/etc/passwd") == nil)
        #expect(safeName("dir/file") == nil)
        #expect(safeName(".hidden") == nil, "and nothing that starts with a dot")
        #expect(safeName("..") == nil)
        #expect(safeName("space name") == nil)
        #expect(safeName("semi;colon") == nil)
        #expect(safeName(String(repeating: "a", count: 200)) == nil)

        #expect(filename(fromContentDisposition: #"attachment; filename="photo.jpg""#) == "photo.jpg")
        #expect(filename(fromContentDisposition: "attachment; filename=photo.jpg") == "photo.jpg")
        #expect(filename(fromContentDisposition: "attachment") == nil)
        #expect(filename(fromContentDisposition: nil) == nil)
    }

    @Test func anUploadWithNoNameIsStoredUnderItsOwnID() throws {
        let configuration = FilesConfiguration(directory: temporaryDirectory())
        let http = client(configuration)
        let created = try http.post("/files", body: bytes(64), headers: [("Upload-Complete", "?1")])
        #expect(created.status == .created)
        let stored = try created.json(StoredFile.self)
        #expect(stored.name.count == 32, "the upload's id")
        #expect(try http.get("/files/\(stored.name)").body == bytes(64))

        // A name that is not allowed is not an error either: it is simply not
        // used, since the client is given the name it ended up with.
        let odd = try http.post("/files", body: bytes(32), headers: [
            ("Upload-Complete", "?1"), named("../escape"),
        ])
        #expect(try odd.json(StoredFile.self).name.count == 32)
    }
}

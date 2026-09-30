#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import Garuda
@testable import UploadsExample

// The photo service end to end: whose an upload is, what is refused before a
// byte is stored, an upload resumed under the group's prefix, and an answer
// replayed with its Location.

private func temporaryDirectory() -> String {
    var template = Array("/tmp/garuda-uploads-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil)
    return String(cString: template)
}

private func client(_ configuration: UploadsConfiguration) -> TestClient {
    var config = ServerConfig()
    config.maxConnections = 16
    let client = uploadsApp(configuration).testClient(configuration: config)
    client.timeoutMillis = 20_000
    return client
}

private func service() -> (TestClient, UploadsConfiguration) {
    let configuration = UploadsConfiguration(directory: temporaryDirectory(),
                                             tokens: ["ada-token": "ada", "grace-token": "grace"])
    return (client(configuration), configuration)
}

/// A PNG as far as its first bytes go, which is all the service checks.
private func png(_ count: Int) -> [UInt8] {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    return signature + (0..<(count - signature.count)).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }
}

private let ada = ("Authorization", "Bearer ada-token")
private let grace = ("Authorization", "Bearer grace-token")
private let pngType = ("Content-Type", "image/png")

@Suite("Uploads example", .serialized)
struct UploadsExampleTests {
    @Test func aPhotoIsFiledUnderWhoeverCreatedTheUpload() throws {
        let (http, configuration) = service()
        let content = png(5000)

        let created = try http.post("/users/ada/photos", body: content,
                                    headers: [ada, pngType, ("Upload-Complete", "?1")])
        #expect(created.status == .created, "\(created.status) \(created.text)")
        let photo = try created.json(Photo.self)
        #expect(photo.owner == "ada")
        #expect(photo.type == "image/png")
        #expect(photo.size == 5000)
        #expect(photo.sha256 == hex(Digest.sha256(content)))
        #expect(created.header("location") == photo.url)
        #expect(photo.url == "/users/ada/photos/\(photo.id)")

        // Filed in ada's directory, and served back with the checked type.
        #expect(access(configuration.photoDirectory + "/ada/" + photo.id, F_OK) == 0)
        let fetched = try http.get(photo.url, headers: [ada])
        #expect(fetched.status == .ok)
        #expect(fetched.body == content)
        #expect(fetched.header("content-type") == "image/png")
        #expect(try http.get("/users/ada/photos", headers: [ada]).json([Photo].self) == [photo])

        #expect(try http.delete(photo.url, headers: [ada]).status == .noContent)
        #expect(try http.get(photo.url, headers: [ada]).status == .notFound)
    }

    @Test func onlyTheOwnerReachesAUsersRoutes() throws {
        let (http, _) = service()
        // No token, a token nobody has, and someone else's token.
        #expect(try http.post("/users/ada/photos", body: png(100),
                              headers: [pngType, ("Upload-Complete", "?1")]).status == .unauthorized)
        #expect(try http.get("/users/ada/photos",
                             headers: [("Authorization", "Bearer nope")]).status == .unauthorized)
        #expect(try http.post("/users/ada/photos", body: png(100),
                              headers: [grace, pngType, ("Upload-Complete", "?1")]).status == .forbidden)

        // An upload's own URL is under the same guard: grace cannot ask how
        // far ada's got, finish it, or cancel it.
        let begun = try http.post("/users/ada/photos", body: Array(png(2000)[0..<1000]),
                                  headers: [ada, pngType, ("Upload-Complete", "?0")])
        #expect(begun.status == .created, "\(begun.status) \(begun.text)")
        let location = try #require(begun.header("location"))
        #expect(try http.head(location, headers: [grace]).status == .forbidden)
        #expect(try http.delete(location, headers: [grace]).status == .forbidden)
        #expect(try http.head(location, headers: [ada]).header("upload-offset") == "1000")
    }

    @Test func whatIsNotAnImageIsRefused() throws {
        let (http, configuration) = service()

        // Refused by `onCreate`: no upload is made, so nothing is stored.
        let html = try http.post("/users/ada/photos", body: Array("<script>".utf8),
                                 headers: [ada, ("Content-Type", "text/html"), ("Upload-Complete", "?1")])
        #expect(html.status == .unsupportedMediaType, "\(html.status) \(html.text)")
        #expect(listing(configuration.uploadDirectory).isEmpty)

        // Says it is a PNG and is not: stored, checked, and thrown away.
        let liar = try http.post("/users/ada/photos", body: Array(repeating: 0x41, count: 500),
                                 headers: [ada, pngType, ("Upload-Complete", "?1")])
        #expect(liar.status == .unsupportedMediaType, "\(liar.status) \(liar.text)")
        #expect(try http.get("/users/ada/photos", headers: [ada]).json([Photo].self).isEmpty)
    }

    @Test func anUploadCutOffIsResumedUnderTheUsersPrefix() throws {
        let (http, _) = service()
        let content = png(300_000)

        let begun = try http.post("/users/ada/photos", body: Array(content[0..<120_000]),
                                  headers: [ada, pngType, ("Upload-Complete", "?0"),
                                            ("Upload-Draft-Interop-Version", "9")])
        #expect(begun.status == .created, "\(begun.status) \(begun.text)")
        // Inside the group, `uploads` is relative to it.
        let location = try #require(begun.header("location"))
        #expect(location.hasPrefix("/users/ada/uploads/"), "\(location)")

        let head = try http.head(location, headers: [ada])
        #expect(head.status == .noContent)
        #expect(head.header("upload-offset") == "120000")

        let finished = try http.request("PATCH", location, headers: [
            ada,
            ("Content-Type", "application/partial-upload"),
            ("Upload-Offset", "120000"),
            ("Upload-Complete", "?1"),
        ], body: Array(content[120_000...]))
        #expect(finished.status == .created, "\(finished.status) \(finished.text)")
        let photo = try finished.json(Photo.self)
        // The completing request is a PATCH with no Content-Type of its own:
        // the owner and the type came from `onCreate`.
        #expect(photo.owner == "ada")
        #expect(photo.type == "image/png")
        #expect(photo.size == 300_000)
        #expect(try http.get(photo.url, headers: [ada]).body == content)

        // A client that lost that answer asks the upload's URL, and is told
        // the same, Location included.
        let again = try http.get(location, headers: [ada])
        #expect(again.status == .created)
        #expect(again.header("location") == photo.url)
        #expect(try again.json(Photo.self) == photo)
    }

    @Test func typesAreReadFromTheBytes() {
        #expect(imageType("image/png") == "image/png")
        #expect(imageType("Image/JPEG; q=1") == "image/jpeg")
        #expect(imageType("image/svg+xml") == nil, "an SVG can carry script")
        #expect(imageType("text/html") == nil)
        #expect(imageType(nil) == nil)

        #expect(imageType(ofBytes: [0xFF, 0xD8, 0xFF, 0xE0]) == "image/jpeg")
        #expect(imageType(ofBytes: Array("GIF89a".utf8)) == "image/gif")
        #expect(imageType(ofBytes: Array("RIFF\0\0\0\0WEBP".utf8)) == "image/webp")
        #expect(imageType(ofBytes: Array("RIFF\0\0\0\0WAVE".utf8)) == nil)
        #expect(imageType(ofBytes: [0x89, 0x50]) == nil)

        #expect(validUser("ada"))
        #expect(!validUser("../ada"))
        #expect(!validUser(""))
        #expect(validID(String(repeating: "a", count: 32)))
        #expect(!validID("../../etc/passwd"))
    }
}

private func listing(_ directory: String) -> [String] {
    guard let dir = opendir(directory) else { return [] }
    defer { closedir(dir) }
    var names: [String] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

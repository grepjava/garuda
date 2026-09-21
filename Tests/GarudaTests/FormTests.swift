import Testing
import AvianCore
@testable import Garuda

private struct Credentials: Codable, Equatable {
    var user: String
    var password: String
    var remember: Bool?
    var tag: [String]?
}

private struct Summary: Codable, Equatable {
    var names: [String]
    var title: String?
    var filename: String?
    var contentType: String?
    var size: Int
    var tags: [String]
}

private let formType = ("content-type", "application/x-www-form-urlencoded")

private func formApp() -> Application {
    let app = Application()
    app.post("/login") { (form: Form<Credentials>) in
        JSON(form.value)
    }
    app.post("/upload") { (form: Multipart) in
        JSON(Summary(names: form.parts.map(\.name),
                     title: form.text("title"),
                     filename: form.file("avatar")?.filename,
                     contentType: form.file("avatar")?.contentType,
                     size: form.file("avatar")?.bytes.count ?? 0,
                     tags: form.all("tag").map(\.text)))
    }
    app.post("/avatar") { (form: Multipart) in
        Bytes(form.file("avatar")?.bytes ?? [])
    }
    return app
}

/// A multipart body, framed as a client sends it.
private func multipart(boundary: String, _ parts: [(headers: String, bytes: [UInt8])]) -> [UInt8] {
    var out: [UInt8] = []
    for part in parts {
        out += Array("--\(boundary)\r\n\(part.headers)\r\n\r\n".utf8)
        out += part.bytes
        out += Array("\r\n".utf8)
    }
    out += Array("--\(boundary)--\r\n".utf8)
    return out
}

private func field(_ name: String, _ value: String) -> (headers: String, bytes: [UInt8]) {
    ("Content-Disposition: form-data; name=\"\(name)\"", Array(value.utf8))
}

@Suite("Forms and multipart", .serialized)
struct FormTests {
    @Test func aFormBodyDecodesIntoAType() throws {
        let client = formApp().test
        let response = try client.post("/login", body: "user=ada&password=secret",
                                       headers: [formType])
        #expect(response.status == .ok)
        #expect(try response.json(Credentials.self)
            == Credentials(user: "ada", password: "secret", remember: nil, tag: nil))
    }

    @Test func aFormIsEncodedTheWayAFormIsSent() throws {
        let client = formApp().test
        let response = try client.post("/login",
                                       body: "user=a+b&password=two%20words%21&remember=on&tag=x&tag=y",
                                       headers: [formType])
        #expect(try response.json(Credentials.self)
            == Credentials(user: "a b", password: "two words!", remember: true, tag: ["x", "y"]))
    }

    @Test func aFormMissingAFieldIs400() throws {
        let response = try formApp().test.post("/login", body: "user=ada", headers: [formType])
        #expect(response.status == .badRequest)
        #expect(try response.json(ErrorBody.self).error == "password is missing")
    }

    @Test func aBodySentAsSomethingElseIs415() throws {
        let client = formApp().test
        let asJSON = try client.post("/login", body: #"{"user":"ada"}"#,
                                     headers: [("content-type", "application/json")])
        #expect(asJSON.status == .unsupportedMediaType)
        #expect(try asJSON.json(ErrorBody.self).error
            == "this route takes application/x-www-form-urlencoded, and the body has \"application/json\"")

        let untyped = try client.post("/login", body: "user=ada")
        #expect(untyped.status == .unsupportedMediaType)
    }

    @Test func multipartPartsKeepTheirNamesFilesAndBytes() throws {
        // Binary that holds a line ending and something boundary-shaped, so
        // the parse cannot be fooled by either.
        var picture: [UInt8] = [0x89, 0x50, 0x4E, 0x47, cCR, cLF, 0x1A, 0x0A]
        picture += Array("--not-the-boundary".utf8)
        picture += [0x00, 0xFF]

        let boundary = "----GarudaTest7"
        let body = multipart(boundary: boundary, [
            field("title", "a picture"),
            ("Content-Disposition: form-data; name=\"avatar\"; filename=\"cat.png\"\r\n"
                + "Content-Type: image/png", picture),
            field("tag", "one"),
            field("tag", "two"),
        ])
        let client = formApp().test
        let headers = [("content-type", "multipart/form-data; boundary=\(boundary)")]
        let response = try client.post("/upload", body: body, headers: headers)
        #expect(response.status == .ok)
        #expect(try response.json(Summary.self) == Summary(
            names: ["title", "avatar", "tag", "tag"],
            title: "a picture",
            filename: "cat.png",
            contentType: "image/png",
            size: picture.count,
            tags: ["one", "two"]))

        // The bytes come back exactly as they went in.
        let echoed = try client.post("/avatar", body: body, headers: headers)
        #expect(echoed.body == picture)
    }

    @Test func boundaryBytesInsideAPartAreContent() throws {
        // A file that holds the delimiter without the framing that makes one:
        // RFC 2046 gives a delimiter a line of its own, so neither of these
        // ends the part, and cutting there would lose the rest of the file.
        let boundary = "GarudaTest9"
        var file = Array("prefix--\(boundary)--suffix\r\n".utf8)
        file += Array("--\(boundary)tail\r\n".utf8)
        file += Array("end".utf8)

        let body = multipart(boundary: boundary, [
            ("Content-Disposition: form-data; name=\"avatar\"; filename=\"log.txt\"", file),
            field("title", "kept whole"),
        ])
        let client = formApp().test
        let headers = [("content-type", "multipart/form-data; boundary=\(boundary)")]
        #expect(try client.post("/avatar", body: body, headers: headers).body == file)
        #expect(try client.post("/upload", body: body, headers: headers)
            .json(Summary.self).title == "kept whole")
    }

    @Test func aQuotedBoundaryIsRead() throws {
        let boundary = "simple-boundary"
        let body = multipart(boundary: boundary, [field("title", "quoted")])
        let response = try formApp().test.post(
            "/upload", body: body,
            headers: [("content-type", "multipart/form-data; charset=utf-8; boundary=\"\(boundary)\"")])
        #expect(try response.json(Summary.self).title == "quoted")
    }

    @Test func aMultipartBodyWithoutABoundaryIs400() throws {
        let response = try formApp().test.post(
            "/upload", body: Array("--x\r\n\r\n".utf8),
            headers: [("content-type", "multipart/form-data")])
        #expect(response.status == .badRequest)
        #expect(try response.json(ErrorBody.self).error
            == "the content type is multipart/form-data with no boundary")
    }

    @Test func aMultipartBodyThatIsNotOneIs400() throws {
        let client = formApp().test
        let headers = [("content-type", "multipart/form-data; boundary=zz")]

        let noBoundary = try client.post("/upload", body: "nothing like a part", headers: headers)
        #expect(noBoundary.status == .badRequest)
        #expect(try noBoundary.json(ErrorBody.self).error
            == "the multipart body is malformed: no boundary in the body")

        // A part that opens and never closes.
        let unfinished = try client.post(
            "/upload",
            body: Array("--zz\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue".utf8),
            headers: headers)
        #expect(unfinished.status == .badRequest)

        let wrongType = try client.post("/upload", body: "x=1", headers: [formType])
        #expect(wrongType.status == .unsupportedMediaType)
    }
}

import Testing
import Garuda
@testable import WebTransportExample

// What of the probe can be reached without QUIC: the page, the certificate
// hash, a session asked for over HTTP/1.1, and the pieces a session is built
// from. Sessions themselves are driven by `scripts/webtransport-test.py` for
// the engine, over aioquic.

@Suite("WebTransport example")
struct WebTransportExampleTests {
    @Test func thePageAndTheCertificateHash() throws {
        let http = webTransportApp(certificateHash: Digest.sha256(Array("cert".utf8))).test
        let page = try http.get("/")
        #expect(page.status == .ok)
        #expect(page.text.contains("new WebTransport("))

        let hash = try http.get("/certificate-hash")
        #expect(hash.status == .ok)
        #expect(try hash.json([String: String].self)["sha256"] == hex(Digest.sha256(Array("cert".utf8))))

        // With no certificate to describe, there is nothing to publish.
        #expect(try webTransportApp().test.get("/certificate-hash").status == .notFound)
    }

    @Test func aSessionIsOnlyEverHTTP3() throws {
        let http = webTransportApp().test
        // The route exists for CONNECT alone, and a CONNECT that is not an
        // HTTP/3 extended CONNECT is refused before any session is made.
        #expect(try http.get("/probe?name=ada").status == .methodNotAllowed)
        #expect(try http.request("CONNECT", "/probe?name=ada").status.code >= 400)
    }

    @Test func commands() {
        #expect(ProbeCommand("echo") == .echo)
        #expect(ProbeCommand("upload") == .upload)
        #expect(ProbeCommand("download 1024") == .download(1024))
        #expect(ProbeCommand("download  0") == .download(0))
        #expect(ProbeCommand("download \(maximumDownload)") == .download(maximumDownload))
        #expect(ProbeCommand("download \(maximumDownload + 1)") == nil)
        #expect(ProbeCommand("download -1") == nil)
        #expect(ProbeCommand("download") == nil)
        #expect(ProbeCommand("echo please") == nil)
        #expect(ProbeCommand("") == nil)
        #expect(ProbeCommand("DELETE") == nil)
    }

    @Test func aCertificateIsHashedAsDER() {
        #expect(decodeBase64("TWFu") == Array("Man".utf8))
        #expect(decodeBase64("TWE=") == Array("Ma".utf8))
        #expect(decodeBase64("TQ==") == Array("M".utf8))
        #expect(decodeBase64("TW\nFu") == Array("Man".utf8), "PEM wraps its lines")
        #expect(decodeBase64("TW*u") == nil)
        #expect(decodeBase64("TQ==TQ==") == nil, "nothing after padding")

        let der: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x05]
        let pem = """
            -----BEGIN CERTIFICATE-----
            MAMCAQU=
            -----END CERTIFICATE-----
            """
        #expect(certificateHash(pem: pem) == Digest.sha256(der))
        #expect(certificateHash(pem: "-----BEGIN PRIVATE KEY-----\nMAMCAQU=\n-----END PRIVATE KEY-----") == nil)
        #expect(certificateHash(pem: "") == nil)
    }
}

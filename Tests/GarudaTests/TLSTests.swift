#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
@testable import Garuda
import GarudaTesting
import GarudaWire
import Testing
import Vega
import VegaCrypto
import VegaTLS

/// A self-signed certificate for `names`, written to files.
struct TestCertificate {
    let identity: TLSIdentity
    let files: TLSCertificateFiles

    init(_ names: [String], tag: String) throws {
        identity = try TLSIdentity.selfSigned(names: names)
        let stem = "\(temporaryDirectory)/garuda-tls-\(getpid())-\(tag)"
        files = TLSCertificateFiles(chain: stem + ".crt", key: stem + ".key")
        try write(identity.certificateChain, to: files.chain)
        try write(identity.privateKey, to: files.key)
    }

    /// The certificate as DER, as a client sees it.
    var der: [UInt8] {
        get throws { try CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey).certificateChain[0] }
    }

    func remove() {
        unlink(files.chain)
        unlink(files.key)
    }
}

struct WriteFailed: Error {}

func write(_ text: String, to path: String) throws {
    guard let file = fopen(path, "wb") else { throw WriteFailed() }
    defer { fclose(file) }
    guard fputs(text, file) >= 0 else { throw WriteFailed() }
}

/// One HTTPS request to `app` served through `store`, as a real client makes
/// it over loopback: what came back, and the certificate the server showed.
func https(_ app: Application, _ store: CertificateStore, serverName: String?, trusting pem: String?,
           _ request: String) throws -> (response: String, certificate: [UInt8]?, alpn: String?) {
    let compiled = app.compile()
    let limits = ConnectionLimits(ServerConfig())
    var configuration = TLSConfiguration.client(trustRoots: pem.map { .certificates($0) } ?? .system,
                                                applicationProtocols: ["http/1.1"])
    if pem == nil { configuration.verification = .disabled }
    let client = try TLSContext(configuration)
    let rt = TLSTestRuntime.shared
    return try rt.block { () async throws -> (String, [UInt8]?, String?) in
        let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
        let port = listener.localPort
        let server = try TCPServer.serve(listener) { stream in
            let peer = socketPeer(stream)
            await serveTLS(stream, store, handshakeTimeout: .seconds(5)) { secured in
                await serveHTTP1(secured, app: compiled, limits: limits, peer: peer, secure: true)
            }
        }
        defer { Task { await server.shutdown(gracePeriod: .seconds(1)) } }
        let tcp = try await TCPStream.connect(to: SocketAddress(host: "127.0.0.1", port: port))
        let tls = try await TLSStream.connect(tcp, serverName: serverName, context: client)
        var out = IOBuffer(capacity: request.utf8.count)
        out.append(request)
        try await tls.write(out)
        var buffer = IOBuffer(capacity: 64 * 1024)
        while try await tls.read(into: &buffer) > 0 {}
        return (buffer.string, tls.peerCertificate, tls.applicationProtocol)
    }
}

enum TLSTestRuntime {
    static let shared = Runtime(workers: 2)
}

let closingGet = "GET /secure HTTP/1.1\r\nHost: a.test\r\nConnection: close\r\n\r\n"

@Suite(.serialized) struct TLSTests {
    func secureApp() -> Application {
        let app = Application()
        app.securityHeaders(SecurityHeaders())
        app.get("/secure") { request, response in
            response.send(request.arrivedOverHTTPS ? "https" : "plain")
        }
        return app
    }

    @Test func servesHTTPSAndKnowsIt() throws {
        let cert = try TestCertificate(["a.test"], tag: "serve")
        defer { cert.remove() }
        let store = try CertificateStore(files: [cert.files], protocols: Application.alpn, ticketKey: nil)
        let (response, certificate, alpn) = try https(secureApp(), store, serverName: "a.test",
                                                      trusting: cert.identity.certificateChain, closingGet)
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.hasSuffix("https"))
        #expect(response.contains("strict-transport-security: max-age=31536000; includeSubDomains"))
        #expect(try certificate == cert.der)
        #expect(alpn == "http/1.1")
    }

    @Test func sniPicksTheCertificateCoveringTheName() throws {
        let a = try TestCertificate(["a.test"], tag: "sni-a")
        let b = try TestCertificate(["b.test", "*.b.test"], tag: "sni-b")
        defer { a.remove(); b.remove() }
        let store = try CertificateStore(files: [a.files, b.files], protocols: Application.alpn, ticketKey: nil)
        let app = secureApp()
        #expect(try https(app, store, serverName: "b.test", trusting: b.identity.certificateChain, closingGet).certificate == b.der)
        #expect(try https(app, store, serverName: "api.b.test", trusting: b.identity.certificateChain, closingGet).certificate == b.der)
        #expect(try https(app, store, serverName: "a.test", trusting: a.identity.certificateChain, closingGet).certificate == a.der)
        // A name nobody covers, and no name at all: the first certificate.
        #expect(try https(app, store, serverName: "c.test", trusting: nil, closingGet).certificate == a.der)
        #expect(try https(app, store, serverName: nil, trusting: nil, closingGet).certificate == a.der)
    }

    @Test func aReloadServesTheNewCertificate() throws {
        let old = try TestCertificate(["a.test"], tag: "reload")
        defer { old.remove() }
        let store = try CertificateStore(files: [old.files], protocols: Application.alpn, ticketKey: nil)
        #expect(try https(secureApp(), store, serverName: "a.test", trusting: nil, closingGet).certificate == old.der)
        // Renewed in place, as a CA client would.
        let renewed = try TestCertificate(["a.test"], tag: "reload")
        try store.reload()
        #expect(try https(secureApp(), store, serverName: "a.test", trusting: nil, closingGet).certificate == renewed.der)
    }

    @Test func aBrokenRenewalKeepsTheCertificateInUse() throws {
        let cert = try TestCertificate(["a.test"], tag: "broken")
        defer { cert.remove() }
        let store = try CertificateStore(files: [cert.files], protocols: Application.alpn, ticketKey: nil)
        try write("not a key", to: cert.files.key)
        #expect(throws: (any Error).self) { try store.reload() }
        #expect(try https(secureApp(), store, serverName: "a.test", trusting: nil, closingGet).certificate == cert.der)
    }

    @Test func aKeyThatIsNotTheCertificatesIsRefused() throws {
        let a = try TestCertificate(["a.test"], tag: "mismatch-a")
        let b = try TestCertificate(["b.test"], tag: "mismatch-b")
        defer { a.remove(); b.remove() }
        #expect(throws: (any Error).self) {
            try CertificateStore(files: [TLSCertificateFiles(chain: a.files.chain, key: b.files.key)],
                                 protocols: Application.alpn, ticketKey: nil)
        }
    }

    @Test func theTicketKeyIsDrawnOnceAndSharedAfter() {
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: TicketKey.regionSize, alignment: 64)
        defer { region.deallocate() }
        region.initializeMemory(as: UInt8.self, repeating: 0)
        let first = TicketKey.shared(in: region)
        let second = TicketKey.shared(in: region)
        #expect(first.count == TicketKey.keyLength)
        #expect(first == second)
        #expect(first.contains { $0 != 0 })
        #expect(TicketKey.ownKey() != first)
    }
}

@Suite struct HTTPSRedirectTests {
    @Test func getAndHeadAreMovedPermanently() throws {
        let client = httpsRedirectApplication(httpsPort: 8443).test
        let response = try client.get("/a/b?c=1", headers: [("host", "example.com:8080")])
        #expect(response.status == 301)
        #expect(response.header("location") == "https://example.com:8443/a/b?c=1")
    }

    @Test func otherMethodsKeepTheirBody() throws {
        let response = try httpsRedirectApplication(httpsPort: 443).test
            .post("/form", body: "x=1", headers: [("host", "example.com")])
        #expect(response.status == 308)
        #expect(response.header("location") == "https://example.com/form")
    }

    @Test func noHostIsABadRequest() throws {
        let response = try httpsRedirectApplication(httpsPort: 443).test
            .send(raw: Array("GET / HTTP/1.0\r\n\r\n".utf8))
        #expect(response.status == 400)
    }

    @Test func acmeChallengesAreAnsweredNotRedirected() throws {
        let site = Site()
        site.directory("/.well-known")
        site.directory("/.well-known/acme-challenge")
        site.write("/.well-known/acme-challenge/tok-EN_1", "tok-EN_1.thumbprint\n")
        site.write("/secret", "no")
        let client = httpsRedirectApplication(httpsPort: 443, acmeWebroot: site.path).test
        let host = [("host", "example.com")]

        let found = try client.get("/.well-known/acme-challenge/tok-EN_1", headers: host)
        #expect(found.status == 200)
        #expect(found.text == "tok-EN_1.thumbprint")
        #expect(found.header("content-type")?.hasPrefix("text/plain") == true)

        #expect(try client.get("/.well-known/acme-challenge/missing", headers: host).status == 404)
        #expect(try client.get("/.well-known/acme-challenge/..%2F..%2Fsecret", headers: host).status == 404)
        #expect(try client.get("/.well-known/acme-challenge/a.b", headers: host).status == 404)

        // Everything else is still sent to https.
        let other = try client.get("/.well-known/other", headers: host)
        #expect(other.status == 301)
        #expect(other.header("location") == "https://example.com/.well-known/other")
    }

    @Test func withoutAWebrootChallengesAreRedirected() throws {
        let response = try httpsRedirectApplication(httpsPort: 443).test
            .get("/.well-known/acme-challenge/tok", headers: [("host", "example.com")])
        #expect(response.status == 301)
    }

    @Test func oversizedChallengeFilesAreRefused() {
        let site = Site()
        site.directory("/.well-known")
        site.directory("/.well-known/acme-challenge")
        site.write("/.well-known/acme-challenge/big", [UInt8](repeating: 0x41, count: 5000))
        #expect(acmeChallenge(in: site.path, token: "big") == nil)
    }
}

@Suite struct ForwardedTests {
    func app() -> Application {
        let app = Application()
        app.get("/who") { request, response in
            response.send("\(request.remoteAddress) \(request.remotePort) \(request.arrivedOverHTTPS)")
        }
        return app
    }

    let proxied: [(String, String)] = [("x-forwarded-for", "203.0.113.7"), ("x-forwarded-proto", "https")]

    @Test func aTrustedProxyNamesTheClientAndScheme() throws {
        var config = ServerConfig()
        let parsed = config.trust.parse("127.0.0.1")
        #expect(parsed)
        let response = try app().testClient(configuration: config).get("/who", headers: proxied)
        #expect(response.text == "203.0.113.7 0 true")
    }

    @Test func anUntrustedPeerIsNotBelieved() throws {
        var config = ServerConfig()
        let parsed = config.trust.parse("10.0.0.0/8")
        #expect(parsed)
        let response = try app().testClient(configuration: config).get("/who", headers: proxied)
        #expect(response.text == "127.0.0.1 49152 false")
    }

    @Test func withNoTrustListNothingIsRead() throws {
        #expect(try app().test.get("/who", headers: proxied).text == "127.0.0.1 49152 false")
    }

    @Test func aTrustedProxySayingNothingLeavesThePeer() throws {
        var config = ServerConfig()
        let parsed = config.trust.parse("127.0.0.1")
        #expect(parsed)
        #expect(try app().testClient(configuration: config).get("/who").text == "127.0.0.1 49152 false")
    }
}

@Suite struct TLSCommandLineTests {
    func parse(_ args: String...) -> ServerConfig? {
        if case .run(let config) = ServerConfig.parse(["garuda"] + args) { return config }
        return nil
    }

    @Test func certificatesPairWithKeysInOrder() {
        let config = parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--tls-cert", "b.crt", "--tls-key", "b.key",
                           "--tls-reload", "30", "--redirect-http", "8080", "--port", "8443")
        #expect(config?.tlsCertificates == [TLSCertificateFiles(chain: "a.crt", key: "a.key"),
                                            TLSCertificateFiles(chain: "b.crt", key: "b.key")])
        #expect(config?.tlsReloadInterval == .seconds(30))
        #expect(config?.redirectHTTPPort == 8080)
    }

    @Test func mistakesAreRefused() {
        #expect(parse("--tls-cert", "a.crt") == nil)
        #expect(parse("--redirect-http", "8080") == nil)
        #expect(parse("--tls-cert", "a.crt", "--tls-key", "a.key", "--redirect-http", "8000") == nil)
        #expect(parse("--tls-reload", "5") == nil)
    }
}

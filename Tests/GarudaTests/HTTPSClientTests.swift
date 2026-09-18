import Testing
import CAvian
import AvianCore
import AvianHTTP
@testable import Garuda

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The HTTP client over real TLS, end to end.
//
// Everything in HTTP2ClientTests forces HTTP/2 on plaintext, which tests the
// framing without OpenSSL in the way. This is the other half: a real
// handshake, ALPN choosing the protocol, the certificate checked against what
// was asked for -- a name, or an address -- and the client speaking whatever
// was agreed.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var urlWanted = ""

private let certPath = "/tmp/garuda-https-client-cert.pem"
private let keyPath = "/tmp/garuda-https-client-key.pem"

/// Self-signed for `alpha.example` *and* the address 127.0.0.1, its own CA,
/// valid until 2126. The address is what lets `https://127.0.0.1/` be tested
/// at all: a certificate naming only a DNS name can never verify for one.
private let certificatePEM = """
-----BEGIN CERTIFICATE-----
MIIBpjCCAU2gAwIBAgIULfSm2Os0o9Y8AFMmHNxperi5keAwCgYIKoZIzj0EAwIw
GDEWMBQGA1UEAwwNYWxwaGEuZXhhbXBsZTAgFw0yNjA5MTYwOTQ2MzdaGA8yMTI2
MDgyMzA5NDYzN1owGDEWMBQGA1UEAwwNYWxwaGEuZXhhbXBsZTBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABPjBye55/BGUrJT4aGAtxEkCyZzTu+v8EbXZSF6uhU3k
Na1/nl9A5tnme4BYvKEV4tYqOgV2QB4YHdGjlXGbU2CjczBxMB0GA1UdDgQWBBQp
djSzPKCTmfzV/pkkPGFUdIwaQzAfBgNVHSMEGDAWgBQpdjSzPKCTmfzV/pkkPGFU
dIwaQzAeBgNVHREEFzAVgg1hbHBoYS5leGFtcGxlhwR/AAABMA8GA1UdEwEB/wQF
MAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgHIG2Y5ZnF2+6EcvPPmkygzEfdYNJRywt
EZB0T+chfjICIHBbXXtAqijAhZD0uJoXL50Dh0yTcQRgnrcc43ZcNNpf
-----END CERTIFICATE-----
"""

private let privateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgxnKgXRxeQKVo1MPE
KzqjcKiz4lHIb4rn9U2Zovrn9NqhRANCAAT4wcnuefwRlKyU+GhgLcRJAsmc07vr
/BG12UheroVN5DWtf55fQObZ5nuAWLyhFeLWKjoFdkAeGB3Ro5Vxm1Ng
-----END PRIVATE KEY-----
"""

private func writeText(_ text: String, to path: String) -> Bool {
    guard let file = fopen(path, "w") else { return false }
    defer { fclose(file) }
    return (text + "\n").withCString { fputs($0, file) >= 0 }
}

private func installCertificate() -> Bool {
    writeText(certificatePEM, to: certPath) && writeText(privateKeyPEM, to: keyPath)
}

/// One connection the origin accepted, with its TLS session.
private final class TLSPeer {
    let fd: Int32
    let tls: OpaquePointer
    var handshaken = false
    var failed = false
    var http2 = false
    var inbox: [UInt8] = []
    var sawPreface = false

    init(fd: Int32, tls: OpaquePointer) {
        self.fd = fd
        self.tls = tls
    }

    deinit {
        av_tls_free(tls)
        _ = av_close(fd)
    }

    func write(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { av_tls_write(tls, $0.baseAddress, $0.count) }
    }
}

/// A TLS origin that speaks whichever protocol its handshake settled on:
/// just enough HTTP/2 to answer a GET, or a canned HTTP/1.1 response.
private final class TLSOrigin {
    let fd: Int32
    let port: UInt16
    let ctx: OpaquePointer
    private(set) var peers: [TLSPeer] = []
    private(set) var accepted = 0
    /// What each connection's handshake settled on, in the order accepted.
    private(set) var negotiated: [String] = []
    /// The SNI each connection sent, or "" for none.
    private(set) var serverNames: [String] = []
    private(set) var http2Requests = 0
    private(set) var http1Requests = 0
    private var error = [CChar](repeating: 0, count: 256)

    init?(alpn: String, address: String = "127.0.0.1") {
        let opened = address.withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = av_local_port(opened)
        var made = [CChar](repeating: 0, count: 256)
        let context: OpaquePointer? = certPath.withCString { cert in
            keyPath.withCString { key in
                alpn.withCString { protocols in
                    made.withUnsafeMutableBufferPointer {
                        av_tls_ctx_new(cert, key, protocols, nil, $0.baseAddress, 256)
                    }
                }
            }
        }
        guard got != 0, let context else {
            _ = av_close(opened)
            return nil
        }
        fd = opened
        port = got
        ctx = context
    }

    deinit {
        peers.removeAll()
        av_tls_ctx_free(ctx)
        _ = av_close(fd)
    }

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let client = av_accept(fd, &address, 64, &peerPort)
        if client >= 0 {
            if let session = av_tls_new(ctx, client) {
                peers.append(TLSPeer(fd: client, tls: session))
                accepted += 1
            } else {
                _ = av_close(client)
            }
        }

        for peer in peers where !peer.failed {
            if !peer.handshaken {
                let step = error.withUnsafeMutableBufferPointer {
                    av_tls_handshake(peer.tls, $0.baseAddress, 256)
                }
                if step == 1 {
                    peer.handshaken = true
                    peer.http2 = av_tls_is_h2(peer.tls) != 0
                    negotiated.append(peer.http2 ? "h2" : "http/1.1")
                    serverNames.append(av_tls_server_name(peer.tls).map { String(cString: $0) } ?? "")
                } else if step == -2 {
                    peer.failed = true
                }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = buffer.withUnsafeMutableBytes { av_tls_read(peer.tls, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                peer.inbox.append(contentsOf: buffer.prefix(Int(n)))
            }
            if peer.http2 { serveHTTP2(peer) } else { serveHTTP1(peer) }
        }
    }

    private func serveHTTP1(_ peer: TLSPeer) {
        let end: [UInt8] = [13, 10, 13, 10]
        while let at = find(end, in: peer.inbox) {
            peer.inbox.removeFirst(at + 4)
            http1Requests += 1
            peer.write(Array("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nh1ok".utf8))
        }
    }

    private func serveHTTP2(_ peer: TLSPeer) {
        if !peer.sawPreface {
            guard peer.inbox.count >= HTTP2.preface.count else { return }
            peer.sawPreface = true
            peer.inbox.removeFirst(HTTP2.preface.count)
        }
        while peer.inbox.count >= H2FrameHeader.size {
            let header = peer.inbox.withUnsafeBufferPointer { H2FrameHeader.parse($0.baseAddress!) }
            guard peer.inbox.count >= H2FrameHeader.size + header.length else { return }
            peer.inbox.removeFirst(H2FrameHeader.size + header.length)
            switch H2FrameType(rawValue: header.type) {
            case .settings where !header.flags.contains(.ack):
                peer.write(frame(.settings, flags: .ack, stream: 0, []))
            case .headers where header.flags.contains(.endStream):
                // A GET, whole. Answered without decoding its block: the
                // requests here are all the same, and a real server's reading
                // of a block is what HTTP2ClientTests is for.
                http2Requests += 1
                var status = ByteBuffer(capacity: 8)
                HPACKEncoder().encodeStatus(200, into: &status)
                let block = Array(UnsafeBufferPointer(start: status.readPointer,
                                                      count: status.readableBytes))
                status.destroy()
                peer.write(frame(.headers, flags: .endHeaders, stream: header.streamID, block)
                    + frame(.data, flags: .endStream, stream: header.streamID, Array("h2".utf8)))
            default:
                break
            }
        }
    }

    private func frame(_ type: H2FrameType, flags: H2Flags, stream: UInt32,
                       _ payload: [UInt8]) -> [UInt8] {
        var out = ByteBuffer(capacity: payload.count + 16)
        defer { out.destroy() }
        H2FrameHeader(length: payload.count, type: type, flags: flags, streamID: stream)
            .write(into: &out)
        if !payload.isEmpty { payload.withUnsafeBufferPointer { out.write($0.baseAddress!, $0.count) } }
        return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count)
            where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            return i
        }
        return nil
    }
}

private func httpsApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/get") { request, response in
        var client = request.client
        client.caFile = certPath
        client.timeoutMilliseconds = 3_000
        do {
            let answer = try await client.get(urlWanted)
            outcome = "\(answer.status)|\(answer.text)|\(answer.reusedConnection)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    return app
}

@Suite("HTTPS client", .serialized)
struct HTTPSClientTests {

    /// Points `name` at `address` in the worker's resolver cache, so a test can
    /// use a name the certificate is for without a nameserver to answer it.
    private func pretend(_ client: TestClient, _ name: String, is address: [UInt8]) {
        client.worker.pointee.resolverCache.store(
            ResolverCacheKey(name: name, type: DNSRecordType.a.rawValue),
            addresses: [ResolvedAddress(bytes: address)], ttl: 3_600, now: av_monotonic_ms())
    }

    private func get(_ client: TestClient, _ origin: TLSOrigin, _ url: String) throws -> String {
        outcome = ""
        urlWanted = url
        let wire = try TestWire(client)
        wire.send("GET /get HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 200_000)
        _ = wire.receive()
        return outcome
    }

    @Test func httpsSpeaksHTTP2WhenTheServerOffersIt() throws {
        #expect(installCertificate())
        guard let origin = TLSOrigin(alpn: "h2,http/1.1") else { Issue.record("no origin"); return }
        let client = httpsApp().test
        pretend(client, "alpha.example", is: [127, 0, 0, 1])
        let url = "https://alpha.example:\(origin.port)/x"
        #expect(try get(client, origin, url) == "200|h2|true")
        #expect(try get(client, origin, url) == "200|h2|true")
        #expect(origin.negotiated == ["h2"])
        // A name goes out as SNI, which is how a server with several
        // certificates knows which one to present.
        #expect(origin.serverNames == ["alpha.example"])
        #expect(origin.http2Requests == 2)
        // Both requests down one connection: kept, shared, and found again by
        // the identity it was verified under.
        #expect(origin.accepted == 1)
    }

    @Test func httpsSpeaksHTTP11WhenThatIsAllTheServerOffers() throws {
        #expect(installCertificate())
        guard let origin = TLSOrigin(alpn: "http/1.1") else { Issue.record("no origin"); return }
        let client = httpsApp().test
        pretend(client, "alpha.example", is: [127, 0, 0, 1])
        let url = "https://alpha.example:\(origin.port)/x"
        #expect(try get(client, origin, url) == "200|h1ok|true")
        #expect(try get(client, origin, url) == "200|h1ok|true")
        #expect(origin.negotiated == ["http/1.1"])
        #expect(origin.http1Requests == 2)
        #expect(origin.accepted == 1)
    }

    @Test func anAddressIsVerifiedAgainstTheAddressesInTheCertificate() throws {
        // `https://127.0.0.1/` asks for a certificate issued to that address,
        // which this one is. Checked as a DNS name it would match nothing.
        #expect(installCertificate())
        guard let origin = TLSOrigin(alpn: "h2,http/1.1") else { Issue.record("no origin"); return }
        let client = httpsApp().test
        #expect(try get(client, origin, "https://127.0.0.1:\(origin.port)/x") == "200|h2|true")
        // And no SNI. RFC 6066 section 3 allows only a DNS name there, never a
        // literal address. On an OpenSSL whose SSL_set1_host already accepts
        // addresses -- this box's 3.0.13 does -- handing the literal to the
        // name path verifies just as well, so the verification above cannot
        // tell the two paths apart. This is what can.
        #expect(origin.serverNames == [""])
    }

    @Test(.enabled(if: loopbackAliasAvailable, "an address check \(loopbackAliasReason)"))
    func anAddressTheCertificateDoesNotNameIsRefused() throws {
        // The same certificate, reached at 127.0.0.2. The chain is trusted and
        // the address is not the one it was issued to, so this must fail --
        // otherwise the check above passed because nothing was checked.
        #expect(installCertificate())
        let origin = try #require(TLSOrigin(alpn: "h2,http/1.1", address: "127.0.0.2"))
        let client = httpsApp().test
        let text = try get(client, origin, "https://127.0.0.2:\(origin.port)/x")
        #expect(text.hasPrefix("connect("), "got \(text)")
    }

    @Test func aNameTheCertificateDoesNotNameIsRefused() throws {
        #expect(installCertificate())
        guard let origin = TLSOrigin(alpn: "h2,http/1.1") else { Issue.record("no origin"); return }
        let client = httpsApp().test
        pretend(client, "beta.example", is: [127, 0, 0, 1])
        let text = try get(client, origin, "https://beta.example:\(origin.port)/x")
        #expect(text.hasPrefix("connect("), "got \(text)")
    }
}

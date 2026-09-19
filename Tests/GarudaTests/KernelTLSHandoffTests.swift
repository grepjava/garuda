import Testing
import CAvian
import AvianCore
@testable import Garuda

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// An HTTPS connection carried on by another worker. The OpenSSL session stays
// behind -- it is memory in the worker that did the handshake -- so this works
// only where the kernel encrypts and decrypts: Linux, with the tls module
// loaded and an OpenSSL built for it. Elsewhere there is nothing to test.

private let certPath = "/tmp/garuda-ktls-handoff-cert.pem"
private let keyPath = "/tmp/garuda-ktls-handoff-key.pem"

/// Self-signed for `alpha.example` and 127.0.0.1, valid until 2126.
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

private let kernelTLSAvailable: Bool = av_tls_kernel_ready() != 0 && {
    // Whether this OpenSSL can at all, without leaving it asked for.
    let can = av_tls_enable_ktls(1) != 0
    _ = av_tls_enable_ktls(0)
    return can
}()

/// A server context that asks for kernel TLS, built without leaving every
/// context the rest of the run builds asking for it too.
private func kernelTLSContext() -> TLSContext? {
    guard writeText(certificatePEM, to: certPath), writeText(privateKeyPEM, to: keyPath)
    else { return nil }
    _ = av_tls_enable_ktls(1)
    defer { _ = av_tls_enable_ktls(0) }
    return certPath.withCString { cert in
        keyPath.withCString { key in
            TLSContext.make(certPath: cert, keyPath: key,
                            alpn: staticCString("http/1.1"), ciphers: nil)
        }
    }
}

/// The client's side: a real TCP connection and OpenSSL session.
private final class Browser {
    let fd: Int32
    let context: OpaquePointer
    let tls: OpaquePointer

    init?(port: UInt16, listener: Int32, adoptInto client: TestClient) {
        var progress: Int32 = 0
        let fd = av_connect_tcp("127.0.0.1", port, &progress)
        guard fd >= 0 else { return nil }
        var accepted: Int32 = -1
        for _ in 0..<200 where accepted < 0 {
            accepted = av_accept(listener, nil, 0, nil)
            if accepted < 0 { usleep(1_000) }
        }
        guard accepted >= 0 else { _ = av_close(fd); return nil }
        let address: StaticString = "127.0.0.1"
        let slot = client.onWorker {
            client.worker.pointee.adoptConnection(accepted, address: address.utf8Start,
                                                  addressLength: address.utf8CodeUnitCount,
                                                  port: 1)
        }
        guard slot >= 0 else { _ = av_close(fd); return nil }
        var error = [CChar](repeating: 0, count: 256)
        guard let context = certPath.withCString({ ca in
            error.withUnsafeMutableBufferPointer {
                av_tls_client_ctx_new(ca, "http/1.1", $0.baseAddress, 256)
            }
        }) else { _ = av_close(fd); return nil }
        guard let tls = av_tls_client_new(context, fd, "alpha.example") else {
            av_tls_ctx_free(context)
            _ = av_close(fd)
            return nil
        }
        self.fd = fd
        self.context = context
        self.tls = tls
    }

    deinit {
        av_tls_free(tls)
        av_tls_ctx_free(context)
        _ = av_close(fd)
    }

    func handshake(turning client: TestClient) -> Bool {
        var error = [CChar](repeating: 0, count: 256)
        for _ in 0..<2_000 {
            let rc = error.withUnsafeMutableBufferPointer {
                av_tls_handshake(tls, $0.baseAddress, 256)
            }
            if rc == 1 { return true }
            if rc == -2 { return false }
            client.turn()
        }
        return false
    }

    /// Sends a request and reads one response, turning `client` meanwhile.
    /// `closed` is set when the server ended the session cleanly after it.
    func exchange(_ request: String, turning client: TestClient) -> (text: String?, closed: Bool) {
        var request = request
        let wrote = request.withUTF8 { av_tls_write(tls, $0.baseAddress!, $0.count) }
        guard wrote > 0 else { return (nil, false) }
        var got: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var closed = false
        for _ in 0..<2_000 {
            client.turn()
            while true {
                let n = buffer.withUnsafeMutableBytes { av_tls_read(tls, $0.baseAddress!, 4096) }
                if n > 0 { got += buffer[0..<n]; continue }
                if n == 0 { closed = true }
                break
            }
            let text = String(decoding: got, as: UTF8.self)
            if text.hasSuffix("https") && (closed || !request.contains("close")) {
                return (text, closed)
            }
        }
        return (got.isEmpty ? nil : String(decoding: got, as: UTF8.self), closed)
    }
}

private func handoffPair() throws -> (receive: Int32, send: Int32) {
    var pair: (Int32, Int32) = (-1, -1)
    let made = withUnsafeMutableBytes(of: &pair) {
        av_handoff_pair($0.baseAddress!.assumingMemoryBound(to: Int32.self))
    }
    try #require(made == 0)
    return (pair.0, pair.1)
}

@Suite("Kernel TLS hand-off", .serialized)
struct KernelTLSHandoffTests {

    @Test(.enabled(if: kernelTLSAvailable, "needs the kernel tls module and an OpenSSL built for it"))
    func anHTTPSConnectionIsCarriedOnByAnotherWorker() throws {
        #expect(av_load_init(8) == 0)
        let app = Application()
        app.get("/scheme") { request, response in response.send("\(request.scheme)") }
        app.get("/work") { _, response in
            let until = av_monotonic_us() + 3_000
            while av_monotonic_us() < until {}
            response.send("worked")
        }
        let a = app.test
        let b = app.test
        let toA = try handoffPair()
        let toB = try handoffPair()
        defer { for fd in [toA.receive, toA.send, toB.receive, toB.send] { _ = av_close(fd) } }
        a.onWorker {
            a.worker.pointee.startBalancing(loadSlot: 4, channel: 0, receiveFD: toA.receive,
                                            sendFDs: [], sharedListener: false)
        }
        defer { a.onWorker { a.worker.pointee.leaveBalancing() } }
        // A costlier connection beside it, in the clear, made before the
        // worker serves TLS: a worker never hands away its costliest.
        let costly = try TestWire(a)
        costly.send("GET /work HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(costly.receive()?.hasSuffix("worked") == true)
        let context = try #require(kernelTLSContext())
        a.worker.pointee.tlsContext = context
        b.onWorker {
            b.worker.pointee.startBalancing(loadSlot: 5, channel: 1, receiveFD: toB.receive,
                                            sendFDs: [], sharedListener: false)
        }
        defer { b.onWorker { b.worker.pointee.leaveBalancing() } }

        let listener = av_listen_tcp("127.0.0.1", 0, 16, 0, 0)
        try #require(listener >= 0)
        defer { _ = av_close(listener) }
        var port: UInt16 = 0
        _ = av_local_addr(listener, nil, 0, &port)
        let browser = try #require(Browser(port: port, listener: listener, adoptInto: a))
        #expect(browser.handshake(turning: a))

        let first = browser.exchange("GET /scheme HTTP/1.1\r\nHost: alpha.example\r\n\r\n", turning: a)
        #expect(first.text?.hasSuffix("https") == true)

        // The server's session is the kernel's both ways, or nothing can move.
        var slot = -1
        let initialized = a.worker.pointee.table.initialized
        for s in 0..<initialized
        where a.worker.pointee.table[s].pointee.state != .free && s != costly.slot { slot = s }
        try #require(slot >= 0)
        let session = try #require(a.worker.pointee.table[slot].pointee.tls)
        let sends = av_tls_ktls_send(session) != 0
        let receives = av_tls_ktls_recv(session) != 0
        #expect(sends, "the kernel is not encrypting what this session sends")
        guard sends && receives else {
            // An OpenSSL that cannot hand the kernel the receiving side: the
            // connection must stay where it is.
            let movable = a.worker.pointee.isMovable(slot, now: av_monotonic_ms())
            #expect(!movable)
            return
        }

        let moved = a.onWorker { a.worker.pointee.handOff(count: 1, to: toB.send, now: av_monotonic_ms()) }
        #expect(moved == 1)
        #expect(a.worker.pointee.table.liveCount == 1)

        // The same session, now encrypted by the kernel for another worker --
        // and still HTTPS as far as the application is concerned.
        let second = browser.exchange("GET /scheme HTTP/1.1\r\nHost: alpha.example\r\n\r\n", turning: b)
        #expect(second.text?.hasSuffix("https") == true)
        #expect(b.worker.pointee.table.liveCount == 1)

        // And it ends the way TLS should: close_notify, not a bare hang-up.
        let last = browser.exchange(
            "GET /scheme HTTP/1.1\r\nHost: alpha.example\r\nConnection: close\r\n\r\n", turning: b)
        #expect(last.text?.hasSuffix("https") == true)
        #expect(last.closed, "the session ended without close_notify")
    }
}

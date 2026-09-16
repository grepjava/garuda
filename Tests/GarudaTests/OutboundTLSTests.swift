import Testing
import CGaruda
import GarudaCore
@testable import Garuda

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the handler under test saw, read back by the test.
nonisolated(unsafe) private var outcome = ""
/// What the handler should ask for. Set before the request, since the route is
/// registered once and the interesting part is which name and which trust
/// store it is told to check against.
nonisolated(unsafe) private var caFileWanted = ""
nonisolated(unsafe) private var hostnameWanted = ""

private let socketPath = "/tmp/garuda-outbound-tls.sock"
private let certPath = "/tmp/garuda-outbound-tls-cert.pem"
private let keyPath = "/tmp/garuda-outbound-tls-key.pem"

/// A self-signed certificate for `alpha.example`, which is also its own CA,
/// valid until 2126.
///
/// Checked in rather than generated at run time: shelling out to `openssl`
/// would make this a test of whether openssl is installed as much as of
/// anything here, and a fixture with a short life is a test that goes red on a
/// date nobody chose.
private let certificatePEM = """
-----BEGIN CERTIFICATE-----
MIIBoTCCAUegAwIBAgIUaZsMSQ2qQ58/qeOElQHKiCv3JDUwCgYIKoZIzj0EAwIw
GDEWMBQGA1UEAwwNYWxwaGEuZXhhbXBsZTAgFw0yNjA5MTYwNDIxMTNaGA8yMTI2
MDgyMzA0MjExM1owGDEWMBQGA1UEAwwNYWxwaGEuZXhhbXBsZTBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABL+uSIsa0a2GhjYcgYrfp5YWzpE6ng9M7QlqC6QpQn98
DTyDLnBJRQGYkCj87iBKCN2E8LbaAKwynCWBkhggFwijbTBrMB0GA1UdDgQWBBR4
QhOdquxvA3qL1kPH4XZA9CFBADAfBgNVHSMEGDAWgBR4QhOdquxvA3qL1kPH4XZA
9CFBADAYBgNVHREEETAPgg1hbHBoYS5leGFtcGxlMA8GA1UdEwEB/wQFMAMBAf8w
CgYIKoZIzj0EAwIDSAAwRQIgTzOHmGnPLaxd/ZPBbCxmfV49k1BjYIMwIoSIGPFz
AiQCIQDpdmCfw/Y8XfAPk1dmEnYurZ/VDeddFHlTPHrZReJkYg==
-----END CERTIFICATE-----
"""

private let privateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgF8ohFIuitqQ0Dyuk
vBjJnT1xXa9CIvgECbre5Kt4jNahRANCAAS/rkiLGtGthoY2HIGK36eWFs6ROp4P
TO0JagukKUJ/fA08gy5wSUUBmJAo/O4gSgjdhPC22gCsMpwlgZIYIBcI
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

private func outboundTLSApp() -> Application {
    let app = Application()
    // Connects, secures, reports whether the peer was believed, and goes.
    app.onAsync(.get, "/tls") { request, response in
        // Read before the first await: the request is a view of a slot, and
        // the worker pointer is what outlives the wait.
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 2_000)
            do {
                try await socket.startTLS(hostname: hostnameWanted, caFile: caFileWanted,
                                          milliseconds: 2_000)
                outcome = "secure"
            } catch {
                outcome = "refused"
            }
            socket.close()
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    // Says something and waits to be answered, so the read and write paths go
    // through OpenSSL rather than only the handshake.
    app.onAsync(.get, "/tls-echo") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 2_000)
            do {
                try await socket.startTLS(hostname: hostnameWanted, caFile: caFileWanted,
                                          milliseconds: 2_000)
                let payload = Array("ping".utf8)
                _ = try payload.withUnsafeBytes { try socket.write($0) }
                try await socket.readable(milliseconds: 2_000)
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = try buffer.withUnsafeMutableBytes { try socket.read(into: $0) }
                outcome = "read \(String(decoding: buffer.prefix(n), as: UTF8.self))"
            } catch {
                outcome = "refused"
            }
            socket.close()
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    // Secures a connection and hands it back, so a later caller can be shown
    // to get -- or not get -- that same connection.
    app.onAsync(.get, "/tls-pool") { request, response in
        let worker = request.worker
        let identity = OutboundKey.tlsIdentity(hostname: hostnameWanted, caFile: caFileWanted)
        do {
            let socket = try await Worker.connect(worker, path: socketPath, tls: identity,
                                                  milliseconds: 2_000)
            do {
                try await socket.startTLS(hostname: hostnameWanted, caFile: caFileWanted,
                                          milliseconds: 2_000)
                socket.release()
                outcome = "released"
            } catch {
                outcome = "refused"
                socket.close()
            }
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    // Hands a connection back and asks for another inside one handler run, so
    // the worker never goes round the poller in between. That is the window
    // takeIdle has a guard of its own for: the idle-event path cannot help
    // when nothing has polled.
    app.onAsync(.get, "/tls-churn") { request, response in
        let worker = request.worker
        let identity = OutboundKey.tlsIdentity(hostname: hostnameWanted, caFile: caFileWanted)
        do {
            let first = try await Worker.connect(worker, path: socketPath, tls: identity,
                                                 milliseconds: 2_000)
            try await first.startTLS(hostname: hostnameWanted, caFile: caFileWanted,
                                     milliseconds: 2_000)
            // Waits for the session ticket to actually arrive, so the socket
            // is provably unread-and-readable at the moment it is handed back.
            // Without this the test would be a race on whether the ticket beat
            // the release, and would pass for whichever reason it liked.
            try await first.readable(milliseconds: 2_000)
            first.release()
            // Nothing suspends between the release and this, so no poll has
            // happened: takeIdle is the only thing that can tell a ticket from
            // a peer that has gone.
            let second = try await Worker.connect(worker, path: socketPath, tls: identity,
                                                  milliseconds: 2_000)
            second.release()
            outcome = "churned"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // Plaintext, to the same place. If the pool keyed on destination alone,
    // this would be handed the encrypted connection the route above released.
    app.onAsync(.get, "/plain-pool") { request, response in
        let worker = request.worker
        do {
            let socket = try await Worker.connect(worker, path: socketPath, milliseconds: 2_000)
            outcome = socket.isOpen ? "plain" : "closed"
            socket.release()
        } catch {
            outcome = "connect \(error)"
        }
        response.send(outcome)
    }
    return app
}

/// The other end: a listening unix socket and a server TLS context, holding
/// every session it has accepted for as long as the test needs them.
///
/// It has to be pumped rather than run, because both ends are on this thread:
/// the handler only advances when the worker is turned, and the server
/// handshake only advances when it is asked.
private final class Peer {
    let listener: Int32
    let ctx: OpaquePointer
    private var fds: [Int32] = []
    private var sessions: [OpaquePointer] = []
    private var settled: [Bool] = []
    private var shook: [Bool] = []
    private var error = [CChar](repeating: 0, count: 256)

    init?() {
        let opened = socketPath.withCString { pg_listen_unix($0, 16, 1) }
        guard opened >= 0 else { return nil }
        _ = pg_set_nonblock(opened)
        var made = [CChar](repeating: 0, count: 256)
        let context: OpaquePointer? = certPath.withCString { cert in
            keyPath.withCString { key in
                made.withUnsafeMutableBufferPointer {
                    pg_tls_ctx_new(cert, key, nil, nil, $0.baseAddress, 256)
                }
            }
        }
        guard let context else {
            _ = pg_close(opened)
            return nil
        }
        listener = opened
        ctx = context
    }

    deinit {
        for session in sessions { pg_tls_free(session) }
        for fd in fds { _ = pg_close(fd) }
        pg_tls_ctx_free(ctx)
        _ = pg_close(listener)
        _ = socketPath.withCString { pg_unlink($0) }
    }

    /// Takes anything waiting to be accepted and gives it a session.
    func accept() {
        var address = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        let fd = pg_accept(listener, &address, 64, &port)
        guard fd >= 0 else { return }
        fds.append(fd)
        guard let session = pg_tls_new(ctx, fd) else { return }
        sessions.append(session)
        settled.append(false)
        shook.append(false)
    }

    /// One handshake step on every session that has not finished one way or
    /// the other.
    func pump() {
        for i in sessions.indices where !settled[i] {
            let step = error.withUnsafeMutableBufferPointer {
                pg_tls_handshake(sessions[i], $0.baseAddress, 256)
            }
            if step == 1 {
                settled[i] = true
                shook[i] = true
            } else if step == -2 {
                settled[i] = true
            }
        }
    }

    /// The most recent session whose handshake actually succeeded.
    var ready: OpaquePointer? {
        for i in sessions.indices.reversed() where shook[i] { return sessions[i] }
        return nil
    }
}

@Suite("Outbound TLS", .serialized)
struct OutboundTLSTests {
    /// Runs one request while being the TLS server on the other end, and
    /// returns the whole response.
    private func exchange(_ client: TestClient, _ peer: Peer, _ path: String,
                          after: ((OpaquePointer) -> Bool)? = nil) throws -> String {
        outcome = ""
        let wire = try TestWire(client)
        wire.send("GET \(path) HTTP/1.1\r\nHost: test\r\n\r\n")
        var served = false
        _ = wire.turn(until: {
            peer.accept()
            peer.pump()
            if !served, let after, let session = peer.ready { served = after(session) }
            return !outcome.isEmpty
        }, turns: 20_000)
        return wire.receive() ?? "no response"
    }

    /// Nothing signed this but itself, and the system trust store has never
    /// heard of it. A client that carries on from here is not doing TLS.
    @Test func aSelfSignedPeerIsRefusedByTheSystemStore() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = ""
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls").hasSuffix("refused"))
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// The same certificate, named as the trust anchor. Now it verifies --
    /// which is what makes the refusals above mean something rather than
    /// being a handshake that never worked at all.
    @Test func aPeerIsAcceptedAgainstTheCAItWasGiven() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls").hasSuffix("secure"))
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// A trusted chain for somebody else. This is the whole reason
    /// `SSL_set1_host` is called: without it verification proves only that
    /// some CA signed some certificate, which is the quiet hole that makes
    /// TLS look like it is working while it protects nothing.
    @Test func aTrustedChainForTheWrongNameIsRefused() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "beta.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls").hasSuffix("refused"))
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// Past the handshake: bytes in both directions go through the session,
    /// not round it.
    @Test func bytesGoThroughTheSession() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        let text = try exchange(client, peer, "/tls-echo") { session in
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = buffer.withUnsafeMutableBytes { pg_tls_read(session, $0.baseAddress, $0.count) }
            guard n > 0 else { return false }
            var sent = 0
            while sent < n {
                let wrote = buffer.withUnsafeBytes {
                    pg_tls_write(session, $0.baseAddress! + sent, n - sent)
                }
                if wrote <= 0 { break }
                sent += wrote
            }
            return sent == n
        }
        #expect(text.hasSuffix("read ping"))
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    /// The pool keys on where a connection goes *and* on what was checked to
    /// get there. A caller asking for plaintext must not be handed a session
    /// somebody else had verified, and must open its own socket.
    @Test func aSecuredConnectionIsNotHandedToAPlaintextCaller() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls-pool").hasSuffix("released"))
        let opened = client.worker.pointee.outboundOpened
        #expect(opened == 1)
        // Without this the test cannot tell the pool key doing its job from
        // the connection having been dropped while idle: a caller that opens
        // its own socket because nothing was there proves nothing.
        #expect(client.worker.pointee.outbound?.liveCount == 1)
        #expect(try exchange(client, peer, "/plain-pool").hasSuffix("plain"))
        // A new socket, not the encrypted one sitting idle to the same path.
        #expect(client.worker.pointee.outboundOpened == opened + 1)
    }

    /// The same hazard in the window where the poller never runs: a connection
    /// handed back and taken again inside one handler, with the session ticket
    /// already sitting unread in the socket. The idle-event guard cannot cover
    /// this -- nothing has polled -- so it is what takeIdle's own guard is for.
    @Test func aTicketDoesNotSpoilAConnectionTakenStraightBack() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls-churn").hasSuffix("churned"))
        #expect(client.worker.pointee.outboundOpened == 1)
    }

    /// And the other half of that: a caller asking for the same name against
    /// the same trust store is handed the session back, rather than paying
    /// for a handshake that has already been done.
    @Test func aSecuredConnectionIsUsedAgainForTheSameName() throws {
        #expect(installCertificate())
        let peer = Peer()
        #expect(peer != nil)
        guard let peer else { return }
        caFileWanted = certPath
        hostnameWanted = "alpha.example"
        let client = outboundTLSApp().test
        #expect(try exchange(client, peer, "/tls-pool").hasSuffix("released"))
        #expect(client.worker.pointee.outboundOpened == 1)
        // Which half fails matters: still here means it was pooled and the
        // next caller threw it away, rather than it never having been pooled.
        #expect(client.worker.pointee.outbound?.liveCount == 1)
        #expect(try exchange(client, peer, "/tls-pool").hasSuffix("released"))
        #expect(client.worker.pointee.outboundOpened == 1)
    }
}

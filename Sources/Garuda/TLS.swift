//===----------------------------------------------------------------------===//
// TLS: certificates, the handshake, and what goes with HTTPS.
//
//     garuda --port 443 --tls-cert site.pem --tls-key site.key \
//            --tls-cert api.pem --tls-key api.key --redirect-http 80
//
// A connection is accepted as TCP, handed to Vega's TLSStream for the
// handshake (bounded by the head timeout), and then served as plain text is:
// TLSStream reads and writes like any stream. A client that chose "h2" by
// ALPN gets HTTP/2 (HTTP2.swift), any other the HTTP/1 task. The connection
// is marked secure, which is what Strict-Transport-Security and a cookie's
// default `Secure` follow.
//
// Several certificates: each covers the names in it (its subject alternative
// names, wildcards one label deep). The client's SNI picks the first that
// covers it, and the first certificate answers a client that names nothing
// or something none covers.
//
// The certificates live in a store every handshake asks, so they can be
// replaced while the server runs -- by --tls-reload when the files change
// -- without touching a connection already open. Garuda does not fetch
// certificates itself: whatever issues them (certbot, a proxy, an operator)
// writes the files, and the reload picks them up. The one thing such a tool
// needs from the server is its HTTP-01 challenges answered on port 80, which
// is the --redirect-http port: --acme-webroot serves them from the directory
// the tool writes them into (certbot's --webroot -w).
//
// Session tickets let a returning client skip the full handshake. A ticket
// is sealed with a key, and every shard must hold the same one, or a client
// whose next connection lands on another shard is turned away to a full
// handshake. The key lives in memory the shards share (Vega's
// ShardOptions.sharedRegions): the first shard to start draws it, and the
// others, and any shard restarted later, read it.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import GarudaWire
import Synchronization
import Vega
import VegaCrypto
import VegaFS
import VegaTLS

/// A certificate chain and its private key, as PEM files.
public struct TLSCertificateFiles: Sendable, Hashable {
    /// The certificate, then any intermediates, leaf first.
    public var chain: String
    public var key: String

    public init(chain: String, key: String) {
        self.chain = chain
        self.key = key
    }
}

/// The server's certificates, as every handshake asks for them.
final class CertificateStore: Sendable {
    struct Entry: Sendable {
        /// What the certificate covers.
        let certificate: CertificateKey
        let context: TLSContext
    }

    let files: [TLSCertificateFiles]
    let protocols: [String]
    let ticketKey: [UInt8]?
    /// --tls-ciphers, or nil for the library's.
    let ciphers: String?
    private let entries: Mutex<[Entry]>
    /// The context every handshake starts in; its hook picks the real one.
    private(set) nonisolated(unsafe) var handshakeContext: TLSContext!

    /// Loads `files`, offering `protocols` by ALPN. Throws what is wrong with
    /// a file, a pair, or a key that does not match its certificate.
    init(files: [TLSCertificateFiles], protocols: [String], ticketKey: [UInt8]?, ciphers: String? = nil) throws {
        precondition(!files.isEmpty, "TLS with no certificate")
        self.files = files
        self.protocols = protocols
        self.ticketKey = ticketKey
        self.ciphers = ciphers
        entries = Mutex(try CertificateStore.load(files, protocols: protocols, ticketKey: ticketKey, ciphers: ciphers))
        let first = entries.withLock { $0[0] }
        var configuration = first.context.configuration
        configuration.selectContext = { [unowned self] hello in self.context(for: hello.serverName) }
        handshakeContext = try TLSContext(configuration)
    }

    private static func load(_ files: [TLSCertificateFiles], protocols: [String],
                             ticketKey: [UInt8]?, ciphers: String?) throws -> [Entry] {
        try files.map { pair in
            let certificate: CertificateKey
            do {
                certificate = try CertificateKey(chainFile: pair.chain, keyFile: pair.key)
            } catch {
                throw TLSSetupError("\(pair.chain) and \(pair.key): \(error)")
            }
            var configuration = TLSConfiguration.server(identity: try TLSIdentity.files(chain: pair.chain, key: pair.key),
                                                        applicationProtocols: protocols)
            configuration.ticketKey = ticketKey
            configuration.cipherList = ciphers
            let context: TLSContext
            do {
                context = try TLSContext(configuration)
            } catch {
                guard let ciphers else { throw error }
                // Most likely the list: name it, as the library's error may not.
                throw TLSSetupError("\(pair.chain): --tls-ciphers \(ciphers): \(error)")
            }
            return Entry(certificate: certificate, context: context)
        }
    }

    /// The context for a client that named `serverName`: the first
    /// certificate covering it, or the first of all.
    func context(for serverName: String?) -> TLSContext {
        entries.withLock { entries in
            if let serverName, let entry = entries.first(where: { $0.certificate.matches(host: serverName) }) {
                return entry.context
            }
            return entries[0].context
        }
    }

    /// The certificates as they are now, the default first: what a QUIC
    /// handshake chooses among by SNI, as a TLS one does by `context(for:)`.
    func certificateKeys() -> [CertificateKey] {
        entries.withLock { $0.map(\.certificate) }
    }

    /// Logs the names each certificate covers, when there are several: a
    /// name served by the wrong one shows up here at start-up rather than as
    /// a browser's warning.
    func logNames() {
        let keys = certificateKeys()
        guard keys.count > 1 else { return }
        for (i, key) in keys.enumerated() {
            for name in key.serverNames {
                Log.info("tls: certificate \(i + 1)\(i == 0 ? " (default)" : "") serves \(name)")
            }
        }
    }

    /// Reads the files again and serves what they hold from the next
    /// handshake on. Throws, and keeps serving the old ones, when they are
    /// not a usable set.
    func reload() throws {
        let fresh = try CertificateStore.load(files, protocols: protocols, ticketKey: ticketKey, ciphers: ciphers)
        entries.withLock { $0 = fresh }
    }

    /// When any of the files last changed, to notice a renewal.
    func modified() -> [Int] {
        files.flatMap { [modificationTime($0.chain), modificationTime($0.key)] }
    }
}

/// Why TLS could not be set up.
struct TLSSetupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func modificationTime(_ path: String) -> Int {
    #if canImport(Glibc) || canImport(Darwin)
    var info = stat()
    guard stat(path, &info) == 0 else { return -1 }
    #if canImport(Darwin)
    return Int(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int(info.st_mtimespec.tv_nsec)
    #else
    return Int(info.st_mtim.tv_sec) &* 1_000_000_000 &+ Int(info.st_mtim.tv_nsec)
    #endif
    #else
    return -1
    #endif
}

// MARK: - Serving a connection

/// The peer of an accepted socket, looked up only if a handler asks.
func socketPeer(_ stream: borrowing TCPStream) -> SocketPeer {
    #if os(Windows)
    return (try? stream.peerAddress).map { SocketPeer(address: $0.host, port: $0.port ?? 0) } ?? .none
    #else
    return SocketPeer(socket: stream.fileDescriptor)
    #endif
}

/// Shakes hands on `stream` -- giving up on a client that takes longer than
/// `handshakeTimeout` -- then hands the secured stream to `body`, and says
/// goodbye with close_notify on the stream it gives back.
func serveTLS(_ stream: consuming TCPStream, _ store: CertificateStore, handshakeTimeout: Duration,
              _ body: (consuming TLSStream<TCPStream>) async -> TLSStream<TCPStream>) async {
    guard let secured = await handshake(stream, store, handshakeTimeout: handshakeTimeout) else { return }
    let back = await body(secured)
    _ = try? await back.close()
}

/// Shakes hands on `stream`, giving up on a client that takes longer than
/// `handshakeTimeout`. Nil for a client that went away, timed out, or spoke
/// something else.
func handshake(_ stream: consuming TCPStream, _ store: CertificateStore,
               handshakeTimeout: Duration) async -> TLSStream<TCPStream>? {
    var pending: TCPStream? = consume stream
    do {
        return try await Runtime.withIODeadline(handshakeTimeout) { () async throws(IOError) -> TLSStream<TCPStream> in
            try await TLSStream.accept(pending.take()!, context: store.handshakeContext)
        }
    } catch {
        return nil
    }
}

/// Serves an accepted TCP connection: HTTP/1, or HTTP/2 by prior knowledge
/// (HTTP2.swift).
func serveTCP(_ stream: consuming TCPStream, app: CompiledApplication, limits: ConnectionLimits,
              http2: HTTP2Service?) async {
    let peer = socketPeer(stream)
    await serveConnection(stream, app: app, limits: limits, peer: peer, secure: false, http2: http2,
                          halves: { $0.halves() }, close: { _ in }, closeWriter: { _ in },
                          heldWriter: HeldTCPStream.self)
}

/// Serves an accepted connection over TLS: HTTP/2 when the client chose
/// "h2" by ALPN, otherwise as `serveTCP` does. Says goodbye with
/// close_notify.
func serveTLSConnection(_ stream: consuming TCPStream, _ store: CertificateStore, handshakeTimeout: Duration,
                        app: CompiledApplication, limits: ConnectionLimits, http2: HTTP2Service?) async {
    let peer = socketPeer(stream)
    guard let secured = await handshake(stream, store, handshakeTimeout: handshakeTimeout) else { return }
    let h2 = http2 != nil && secured.applicationProtocol == "h2"
    await serveConnection(secured, app: app, limits: limits, peer: peer, secure: true, http2: http2,
                          negotiatedH2: h2,
                          halves: { $0.halves() },
                          close: { secured in _ = try? await secured.close() },
                          closeWriter: { writer in try? await writer.close() })
}

/// Looks at the certificate files every `interval`, and serves them again
/// when one has changed: a renewal reaches new connections without a
/// restart. Files that do not make a usable set are reported, and the ones
/// in use kept.
func watchCertificates(_ store: CertificateStore, every interval: Duration) async {
    var seen = store.modified()
    while true {
        do {
            try await Runtime.sleep(for: interval)
        } catch {
            return
        }
        let now = store.modified()
        guard now != seen else { continue }
        seen = now
        do {
            try store.reload()
            Log.info("TLS: certificates reloaded")
        } catch {
            Log.error("TLS: kept the certificates in use: \(error)")
        }
    }
}

// MARK: - The shared ticket key

/// The session-ticket key every shard uses, kept in shared memory.
enum TicketKey {
    /// Bytes of the region: a state word, then the key at `keyOffset`.
    static let regionSize = 4096
    static let keyOffset = 64
    static let keyLength = 80
    private static let empty: UInt64 = 0, drawing: UInt64 = 1, ready: UInt64 = 2

    /// The key in `region`: drawn by the first shard to ask, read by the rest.
    static func shared(in region: UnsafeMutableRawBufferPointer) -> [UInt8] {
        precondition(region.count >= keyOffset + keyLength)
        let state = region.baseAddress!.assumingMemoryBound(to: Atomic<UInt64>.self)
        let key = region.baseAddress! + keyOffset
        if state.pointee.compareExchange(expected: empty, desired: drawing, ordering: .acquiring).exchanged {
            let drawn = SecureRandom.bytes(keyLength)
            drawn.withUnsafeBytes { key.copyMemory(from: $0.baseAddress!, byteCount: keyLength) }
            state.pointee.store(ready, ordering: .releasing)
            return drawn
        }
        // Another shard is drawing it: a few microseconds.
        while state.pointee.load(ordering: .acquiring) != ready { sched_yield() }
        return Array(UnsafeRawBufferPointer(start: key, count: keyLength))
    }

    /// A key for one process alone, when there is no shared memory.
    static func ownKey() -> [UInt8] { SecureRandom.bytes(keyLength) }
}

// MARK: - Plain HTTP sent to HTTPS

/// What the --redirect-http port serves: every request answered with a
/// redirect to the same URL on https, 301 for GET and HEAD and 308 for the
/// rest, so a POST is not turned into a GET on the way. With `acmeWebroot`,
/// the HTTP-01 challenges an outside ACME client left there are answered
/// instead: a certificate authority asks for them over plain HTTP and does
/// not follow a redirect to a certificate that may not exist yet.
func httpsRedirectApplication(httpsPort: Int, acmeWebroot: String? = nil) -> Application {
    let app = Application()
    if let acmeWebroot {
        app.get("/.well-known/acme-challenge/:token") { request, response in
            let token = request.parameter(0)
            guard let body = acmeChallenge(in: acmeWebroot, token: token) else {
                return response.send(status: .notFound)
            }
            response.send(bytes: body, contentType: "text/plain")
        }
    }
    app.fallback { request, response in
        let x = request.exchange
        // A client sent to https has no more use for this connection, and a
        // plain-HTTP one kept open is only something to hold.
        x.pointee.keepAlive = false
        var location = ByteBuffer()
        defer { location.destroy() }
        let host = x.pointee.header(hostName.utf8Start, hostName.utf8CodeUnitCount)
        guard HTTPSRedirect.location(host: host, target: x.pointee.slice(x.pointee.head.target),
                                     httpsPort: UInt16(clamping: httpsPort), into: &location) else {
            return response.send(status: .badRequest)
        }
        x.pointee.addHeader(ByteSpan(locationName.utf8Start, locationName.utf8CodeUnitCount),
                            ByteSpan(UnsafePointer(location.readPointer), location.readableBytes))
        response.send(status: HTTPStatus(HTTPSRedirect.status(for: x.pointee.head.method)))
    }
    return app
}

/// The key authorization an ACME client wrote for `token`, or nil. A token
/// is base64url (RFC 8555 8.1), so one with anything else -- a dot, a slash,
/// an escape -- names nothing, and the file is opened beneath the webroot
/// besides. A key authorization is a hundred bytes or so; a file far larger
/// is not one.
func acmeChallenge(in webroot: String, token: String) -> [UInt8]? {
    let utf8 = token.utf8
    guard (1...256).contains(utf8.count), utf8.allSatisfy({ base64URL($0) }) else { return nil }
    guard let file = try? File.open(beneath: webroot, ".well-known/acme-challenge/" + token),
          let size = try? file.metadataNow().size, size <= maxChallengeBytes else { return nil }
    var body = [UInt8](repeating: 0, count: size)
    var got = 0
    while got < size {
        let n = body.withUnsafeMutableBytes { bytes in
            (try? file.readNow(into: UnsafeMutableRawBufferPointer(rebasing: bytes[got...]), at: got)) ?? 0
        }
        if n <= 0 { break }
        got += n
    }
    guard got == size else { return nil }
    // Clients write the key authorization alone; some add a newline.
    while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
    return body.isEmpty ? nil : body
}

private let maxChallengeBytes = 4096

private func base64URL(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
}

private let hostName: StaticString = "host"
private let locationName: StaticString = "location"

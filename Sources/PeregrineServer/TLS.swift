//===----------------------------------------------------------------------===//
// TLS.
//
// OpenSSL owns the descriptor, so a TLS connection reads and writes through
// SSL_read and SSL_write instead of read(2) and write(2) and is otherwise the
// same connection as any other: same slab slot, same poller interest, same
// buffers, same state machine. The wrappers report EAGAIN the way a socket
// would, which is what keeps that true.
//
// Two things about OpenSSL do leak into the loop and cannot be wrapped away:
//
//  * The handshake happens before any request exists, and can want either
//    readability or writability at each step.
//  * A record is decrypted whole. After a read, OpenSSL can be holding bytes
//    the socket no longer has, and a level-triggered poller will not mention
//    them again -- so anything that reads has to keep asking until OpenSSL says
//    it has nothing pending.
//
// ALPN is where HTTP/2 becomes reachable from a browser: the protocol is
// settled during the handshake, and a connection that negotiated `h2` expects
// the client preface rather than a request line.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// A server-wide TLS configuration. One per worker: an SSL_CTX is shareable,
/// but a worker is a process and sharing it across a fork buys nothing.
public final class TLSContext {
    let raw: OpaquePointer

    /// Loads a certificate and key, or explains why it could not.
    public static func make(certPath: UnsafePointer<CChar>,
                            keyPath: UnsafePointer<CChar>,
                            alpn: UnsafePointer<CChar>?,
                            ciphers: UnsafePointer<CChar>?) -> TLSContext? {
        var error = [CChar](repeating: 0, count: 256)
        let ctx: OpaquePointer? = error.withUnsafeMutableBufferPointer { buffer in
            pg_tls_ctx_new(certPath, keyPath, alpn, ciphers, buffer.baseAddress, 256)
        }
        guard let ctx else {
            error.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var n = 0
                while n < 256 && base[n] != 0 { n += 1 }
                Log.error { line in
                    line.str("tls: ")
                    base.withMemoryRebound(to: UInt8.self, capacity: n) { p in
                        line.bytes(p, n)
                    }
                }
            }
            return nil
        }
        return TLSContext(raw: ctx)
    }

    /// Adds another certificate for SNI to choose from.
    public func add(certPath: UnsafePointer<CChar>,
                    keyPath: UnsafePointer<CChar>,
                    ciphers: UnsafePointer<CChar>?) -> Bool {
        var error = [CChar](repeating: 0, count: 256)
        let ok = error.withUnsafeMutableBufferPointer { buffer in
            pg_tls_ctx_add(raw, certPath, keyPath, ciphers, buffer.baseAddress, 256)
        }
        if ok == 0 {
            error.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var n = 0
                while n < 256 && base[n] != 0 { n += 1 }
                Log.error { line in
                    line.str("tls: ")
                    base.withMemoryRebound(to: UInt8.self, capacity: n) { p in
                        line.bytes(p, n)
                    }
                }
            }
            return false
        }
        return true
    }

    /// Logs what each loaded certificate claims to be good for, so that a
    /// name served by the wrong certificate is visible at start-up rather
    /// than in a browser warning.
    public func logCertificateNames() {
        let hosts = Int(pg_tls_ctx_host_count(raw))
        guard hosts > 1 else { return }
        var name = [CChar](repeating: 0, count: 256)
        for host in 0..<hosts {
            var index = 0
            while true {
                let found = name.withUnsafeMutableBufferPointer { buffer -> Bool in
                    guard let base = buffer.baseAddress else { return false }
                    guard pg_tls_ctx_names(raw, Int32(host), Int32(index), base, 256) != 0
                    else { return false }
                    Log.info { line in
                        line.str("tls: certificate ")
                        line.int(host + 1)
                        if host == 0 { line.str(" (default)") }
                        line.str(" serves ")
                        line.cstr(base)
                    }
                    return true
                }
                if !found { break }
                index += 1
            }
        }
    }

    init(raw: OpaquePointer) { self.raw = raw }

    deinit { pg_tls_ctx_free(raw) }
}

extension Worker {

    // MARK: - Transport

    /// Reads from the connection, whatever it is underneath.
    @inline(__always)
    func connRead(_ slot: Int, _ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
        let c = table[slot]
        if let tls = c.pointee.tls { return pg_tls_read(tls, p, n) }
        return pg_read(c.pointee.fd, p, n)
    }

    @inline(__always)
    func connWrite(_ slot: Int, _ p: UnsafeRawPointer, _ n: Int) -> Int {
        let c = table[slot]
        if let tls = c.pointee.tls { return pg_tls_write(tls, p, n) }
        return pg_write(c.pointee.fd, p, n)
    }

    /// Whether the transport is still holding data the poller will not
    /// announce, because it has already been read off the socket.
    @inline(__always)
    func connHasBufferedInput(_ slot: Int) -> Bool {
        guard let tls = table[slot].pointee.tls else { return false }
        return pg_tls_pending(tls) > 0
    }

    /// Whether a read could not finish until the socket is writable, which is
    /// how a TLS key update surfaces in the middle of a request.
    @inline(__always)
    func connWantsWrite(_ slot: Int) -> Bool {
        guard let tls = table[slot].pointee.tls else { return false }
        return pg_tls_wants_write(tls) != 0
    }

    // MARK: - Handshake

    /// Starts TLS on a freshly accepted connection. Returns false if the
    /// session could not be created, in which case the connection is gone.
    mutating func beginTLS(_ slot: Int) -> Bool {
        guard let context = tlsContext else { return true }
        let c = table[slot]
        guard let session = pg_tls_new(context.raw, c.pointee.fd) else {
            Log.error("tls: cannot start a session")
            closeConnection(slot)
            return false
        }
        c.pointee.tls = session
        c.pointee.flags.insert(.tlsHandshake)
        return true
    }

    /// Moves the handshake along. Returns true once it is finished; false means
    /// it needs another event, or the connection has been closed.
    mutating func driveHandshake(_ slot: Int) -> Bool {
        let c = table[slot]
        guard let session = c.pointee.tls else { return true }
        var error = [CChar](repeating: 0, count: 256)
        let outcome = error.withUnsafeMutableBufferPointer { buffer in
            pg_tls_handshake(session, buffer.baseAddress, 256)
        }
        switch outcome {
        case 1:
            c.pointee.flags.remove(.tlsHandshake)
            // ALPN has already decided which protocol this connection speaks.
            if pg_tls_is_h2(session) != 0 { c.pointee.flags.insert(.alpnH2) }
            setInterest(slot, .read)
            return true
        case 0:
            setInterest(slot, .read)
            return false
        case -1:
            setInterest(slot, [.read, .write])
            return false
        default:
            // A failed handshake is ordinary traffic on a public port: a
            // scanner, a plaintext request to an https port, a client with no
            // shared cipher. Worth a line only when asked for.
            Log.debug { line in
                line.str("tls: ")
                error.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var n = 0
                    while n < 256 && base[n] != 0 { n += 1 }
                    base.withMemoryRebound(to: UInt8.self, capacity: n) { p in
                        line.bytes(p, n)
                    }
                }
            }
            closeConnection(slot)
            return false
        }
    }

    /// Ends the session, best effort. The socket itself is closed by the caller.
    mutating func endTLS(_ slot: Int) {
        let c = table[slot]
        guard let session = c.pointee.tls else { return }
        c.pointee.tls = nil
        if c.pointee.fd >= 0 { pg_tls_shutdown(session) }
        pg_tls_free(session)
    }
}

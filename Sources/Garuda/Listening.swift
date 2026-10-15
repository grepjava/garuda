//===----------------------------------------------------------------------===//
// Where a shard listens: --unix, and --max-connections.
//
// A Unix socket is one of Vega's shard listeners like a TCP port: the
// supervisor binds it before the first shard starts and every shard accepts
// on it, the kernel handing each connection to whichever is waiting. Vega
// gives a shard the socket as a `TCPListener`, so its connections are served
// by exactly the code TCP's are -- HTTP/1, HTTP/2, TLS -- and their peer is
// "unix", which --forwarded-allow-ips can name.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Vega

extension ServerConfig {
    /// What each of a shard's accept loops is held to: --max-connections,
    /// shared among `acceptors` loops. A loop at its share stops accepting,
    /// and new connections wait in the backlog for one of them to close.
    func serverConfiguration(acceptors: Int) -> TCPServer.Configuration {
        TCPServer.Configuration(maxConnections: maxConnections.map { max(1, ($0 + acceptors - 1) / acceptors) })
    }

    /// Where the server says it is serving: the socket's path, or the
    /// address and the port it took.
    func listeningName(port: Int) -> String {
        unixPath.map { "unix:" + $0 } ?? "\(host):\(port)"
    }
}

#if os(Linux) || os(macOS)
/// --unix: the socket is removed when the server exits. Vega leaves one
/// behind, as a Unix listener does, and replaces it at the next start; but a
/// proxy pointed at a stale socket is told "connection refused" when "no
/// such file" would say what is wrong.
///
/// The process that bound it removes it: the supervisor, or the server itself
/// with no shards. A shard -- a fork of the supervisor, or under an exec
/// launch a new run of it -- has a pid of its own, and leaves it to the
/// others still serving on it.
enum UnixSocketRemoval {
    nonisolated(unsafe) private static var path: [CChar] = []
    nonisolated(unsafe) private static var owner: pid_t = 0

    static func atExit(_ socket: String) {
        // A shard Vega started by exec runs `main` again up to here.
        guard getenv("VEGA_SHARD") == nil else { return }
        path = Array(socket.utf8CString)
        owner = getpid()
        atexit {
            guard getpid() == UnixSocketRemoval.owner else { return }
            _ = UnixSocketRemoval.path.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        }
    }
}
#endif

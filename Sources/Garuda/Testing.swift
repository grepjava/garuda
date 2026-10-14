//===----------------------------------------------------------------------===//
// What GarudaTesting drives: the HTTP/1 connection task, on any stream.
//
// A test serves a connection exactly as a shard does -- the same parser, the
// same routing, the same response writer -- over an in-memory stream instead
// of a socket.
//===----------------------------------------------------------------------===//

import VegaIO

extension Application {
    /// Makes the routes servable, as `run` does. Call once, from the thread
    /// that registered them, before any connection is served.
    @_spi(Testing)
    public func prepareForTesting() {
        _ = compile()
    }

    /// Serves HTTP/1.1 on `stream` until it closes. `prepareForTesting` must
    /// have been called.
    @_spi(Testing)
    public func serveConnection<S: AsyncReader & AsyncWriter & ~Copyable>(
        _ stream: borrowing S, config: ServerConfig, remoteAddress: String, remotePort: Int
    ) async {
        guard let app = compiledApplication else {
            preconditionFailure("serveConnection before prepareForTesting")
        }
        await serveHTTP1(stream, app: app, limits: ConnectionLimits(config),
                         peer: SocketPeer(address: remoteAddress, port: remotePort))
    }
}

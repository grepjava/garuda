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
    public func prepareForTesting(_ config: ServerConfig, threads: Int) {
        let app = compile()
        if app.costs.lane == nil { app.costs.configure(config, threads: threads) }
    }

    /// Route `pattern`'s smoothed thread-hold time, and whether it runs in
    /// the heavy lane now. Nil before the routes are compiled.
    @_spi(Testing)
    public func routeCost(_ method: HTTPMethod, _ pattern: String) -> (average: Duration, heavy: Bool)? {
        guard let app = compiledApplication,
              let index = routes.firstIndex(where: { $0.method == method && $0.pattern == pattern }) else {
            return nil
        }
        return (.nanoseconds(Int64(app.costs.averageNanos(index))), app.costs.isHeavy(index))
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

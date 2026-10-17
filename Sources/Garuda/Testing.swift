//===----------------------------------------------------------------------===//
// What GarudaTesting drives: the HTTP/1 connection task, on any stream.
//
// A test serves a connection exactly as a shard does -- the same parser, the
// same routing, the same response writer -- over an in-memory stream instead
// of a socket.
//===----------------------------------------------------------------------===//

import Synchronization
import Vega
import VegaCrypto
import VegaIO

extension Application {
    /// Makes the routes servable, as `run` does. Call once, from the thread
    /// that registered them, before any connection is served.
    @_spi(Testing)
    public func prepareForTesting(_ config: ServerConfig, threads: Int) {
        let app = compile()
        if app.costs.lane == nil { app.costs.configure(config, threads: threads) }
        app.rootPath = config.rootPath.isEmpty ? nil : Array(config.rootPath.utf8)
    }

    /// Builds the state and runs the start hooks, as shard 0 of 1, the first
    /// time it is called for this application; later calls report how that
    /// went. `prepareForTesting` must have been called.
    @_spi(Testing)
    public func startForTesting(on runtime: Runtime) throws {
        guard let app = compiledApplication else { preconditionFailure("startForTesting before prepareForTesting") }
        if app.runtime == nil { app.runtime = runtime }
        let outcome = app.testStart.withLock { outcome -> Result<Void, any Error> in
            if let outcome { return outcome }
            let shard = ShardInfo(index: 0, count: 1, threads: runtime.workerCount)
            let result: Result<Void, any Error>
            do {
                try runtime.block { () async throws -> Void in try await app.startShard(shard) }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            outcome = result
            return result
        }
        try outcome.get()
    }

    /// Runs the stop hooks and shuts the state down, as a shard stopping.
    @_spi(Testing)
    public func stopForTesting(on runtime: Runtime) {
        guard let app = compiledApplication else { return }
        runtime.block { () async -> Void in await app.stopShard(ShardInfo(index: 0, count: 1, threads: runtime.workerCount)) }
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
        _ stream: consuming S, config: ServerConfig, remoteAddress: String, remotePort: Int
    ) async {
        guard let app = compiledApplication else {
            preconditionFailure("serveConnection before prepareForTesting")
        }
        await serveHTTP1(stream, app: app, limits: ConnectionLimits(config),
                         peer: SocketPeer(address: remoteAddress, port: remotePort))
    }

    /// Serves HTTP/1.1 on `stream` until it closes, and a WebSocket a
    /// request upgrades to on the halves `halves` splits it into.
    @_spi(Testing)
    public func serveConnection<S: AsyncReader & AsyncWriter & ~Copyable, R: AsyncReader & ~Copyable,
                                W: AsyncWriter & ~Copyable & Sendable>(
        _ stream: consuming S, halves: (consuming S) -> StreamHalves<R, W>, config: ServerConfig,
        remoteAddress: String, remotePort: Int
    ) async {
        guard let app = compiledApplication else {
            preconditionFailure("serveConnection before prepareForTesting")
        }
        await Garuda.serveConnection(stream, app: app, limits: ConnectionLimits(config),
                                     peer: SocketPeer(address: remoteAddress, port: remotePort), secure: false,
                                     http2: nil, halves: halves, close: { _ in }, closeWriter: { _ in })
    }

    /// Serves `stream` as a shard serves a cleartext socket: HTTP/2 when it
    /// opens with the preface, HTTP/1.1 otherwise. HTTP/2's streams run in
    /// a pool on `runtime`. `prepareForTesting` must have been called.
    @_spi(Testing)
    public func serveConnection<S: AsyncReader & AsyncWriter & ~Copyable, R: AsyncReader & ~Copyable,
                                W: AsyncWriter & ~Copyable & Sendable>(
        _ stream: consuming S, halves: (consuming S) -> StreamHalves<R, W>, config: ServerConfig,
        runtime: Runtime, remoteAddress: String, remotePort: Int
    ) async {
        guard let app = compiledApplication else {
            preconditionFailure("serveConnection before prepareForTesting")
        }
        let limits = ConnectionLimits(config)
        await Garuda.serveConnection(stream, app: app, limits: limits,
                                     peer: SocketPeer(address: remoteAddress, port: remotePort), secure: false,
                                     http2: limits.http2.enabled ? HTTP2Service.forTesting(runtime) : nil,
                                     halves: halves, close: { _ in }, closeWriter: { _ in })
    }
}

/// HTTP/3 for `app` on a UDP socket of 127.0.0.1, served as a shard serves
/// it: for a test that needs whole connections over a real socket, such as
/// the `h3` fuzz target. `prepareForTesting` must have been called.
@_spi(Testing)
public final class HTTP3TestServer: @unchecked Sendable {
    let service: HTTP3Service
    /// The port it is listening on.
    public let port: Int

    public init(_ app: Application, config: ServerConfig, on runtime: Runtime,
                certificate: CertificateKey) throws {
        guard let compiled = app.compiledApplication else {
            preconditionFailure("HTTP3TestServer before prepareForTesting")
        }
        try app.startForTesting(on: runtime)
        let service = HTTP3Service(runtime: runtime, app: compiled, limits: ConnectionLimits(config),
                                   certificates: { [certificate] })
        self.service = service
        port = try runtime.block { () async throws -> Int in
            try service.start(host: "127.0.0.1", port: 0, count: 1)
        }
    }

    /// Closes every connection at once and returns when the endpoint has
    /// ended.
    public func stop() async {
        service.shutdown(grace: .zero)
        await service.wait()
    }
}

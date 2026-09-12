//===----------------------------------------------------------------------===//
// Server configuration.
//
// Every string here points into `argv`, which the kernel keeps alive for the
// life of the process. Configuration therefore owns no memory and copies no
// strings.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

/// Where the ASGI lifespan runs when workers are threads (`--free-threaded`).
///
/// With workers as processes the question does not arise: one process, one
/// event loop, one lifespan. With workers as threads there are N loops in one
/// interpreter, and ASGI has no answer for that -- the specification is written
/// for a server with one loop, and says the lifespan runs on the loop that will
/// process requests.
public enum LifespanScope: Sendable {
    /// One lifespan per worker loop, the reading that keeps the specification's
    /// promise: whatever `startup` binds to the running loop -- an asyncpg pool,
    /// an httpx client, a background task -- is awaited on that same loop.
    ///
    /// The cost is that `startup` runs N times against a single application
    /// object, so an application that stores its pool in a module global or on
    /// `app.state` keeps only the last one, and the workers that ran earlier are
    /// back to reaching across loops. Such an application should put the pool in
    /// the `state` mapping the lifespan scope hands it, which is per loop here,
    /// or run with `.once` and no async resources.
    case perWorker
    /// One lifespan on the supervising thread's loop, which processes no
    /// requests. `startup` runs exactly once, which is what an application that
    /// opens a global resource in it expects, but nothing that resource binds to
    /// its loop is then safe to await from a worker.
    ///
    /// Correct for applications whose `startup` only reads configuration, builds
    /// synchronous objects, or opens connections that are not loop-bound.
    case once
}

public struct ServerConfig {
    // --- listening ---
    public var host: UnsafePointer<CChar> = staticCString("127.0.0.1")
    public var port: UInt16 = 8000
    public var unixPath: UnsafePointer<CChar>? = nil
    public var backlog: Int32 = 2048
    public var tcpNoDelay = true
    public var ipv6Only = false

    // --- concurrency ---
    /// Worker processes. Each gets its own interpreter, its own poller and,
    /// via SO_REUSEPORT, its own accept queue -- so there is no shared lock and
    /// no thundering herd. 0 means "one per CPU".
    public var workers = 1
    /// Run the workers as threads of one process rather than as processes.
    ///
    /// Only meaningful on a free-threaded CPython (PEP 703, `python3.13t` and
    /// later), where threads of one interpreter genuinely run in parallel. What
    /// it buys is what a process could not: one copy of the application, one
    /// set of import-time caches, one connection pool, one warm JIT -- and
    /// `--reload`, HTTP/3 connection migration and shared in-process state all
    /// stop being cross-process problems. What it costs is that a crash takes
    /// every worker with it, so the process supervisor is worth keeping in
    /// front of it in production.
    public var freeThreaded = false
    /// `workers` with 0 resolved to the CPU count, which is what every part of
    /// start-up actually wants.
    public var resolvedWorkers: Int { workers > 0 ? workers : Int(pg_cpu_count()) }
    public var maxConnections = 4096

    // --- limits ---
    public var readBufferSize = 16 * 1024
    public var maxHeadSize = 32 * 1024
    public var maxHeaders = 100
    public var maxBodySize = 16 * 1024 * 1024
    /// Response bytes buffered before the worker starts applying backpressure.
    public var writeHighWaterMark = 512 * 1024
    /// Buffered bytes an ASGI producer must fall back to before `await send()`
    /// completes again. Resuming at the high water mark would wake the producer
    /// for every single socket write; a gap gives it a whole batch to refill.
    public var writeLowWaterMark = 128 * 1024
    /// Request bytes buffered ahead of an ASGI application before the worker
    /// stops reading the socket. An application that streams an upload without
    /// reading it as fast as it arrives should cost TCP window, not memory.
    public var bodyHighWaterMark = 256 * 1024
    /// Requests per connection before a polite close, to bound memory growth
    /// from long-lived keep-alive clients.
    public var maxRequestsPerConnection: UInt32 = 0    // 0 = unlimited

    // --- timeouts (milliseconds) ---
    public var keepAliveTimeoutMs: UInt64 = 5_000
    public var requestHeadTimeoutMs: UInt64 = 30_000
    public var gracefulShutdownMs: UInt64 = 10_000

    // --- application ---
    public var appSpec: UnsafePointer<CChar> = staticCString("app:application")
    public var appProtocol: AppProtocol? = nil        // nil = autodetect
    /// The resolved object is a factory to call for the real application,
    /// rather than the application itself.
    public var appIsFactory = false
    public var rootPath: UnsafePointer<CChar> = staticCString("")
    public var scheme: UnsafePointer<CChar> = staticCString("http")
    public var serverName: UnsafePointer<CChar> = staticCString("localhost")
    public var serverPortString: UnsafePointer<CChar> = staticCString("8000")
    public var pythonHome: UnsafePointer<CChar>? = nil
    /// Directories to prepend to `sys.path`, in the order they were given.
    /// Repeatable, because an application and the packages it needs are not
    /// always in the same place.
    public var pythonPaths: [UnsafePointer<CChar>] = []
    @inlinable public var pythonPath: UnsafePointer<CChar>? { pythonPaths.first }
    public var preferUvloop = true
    public var callLifespan = true
    /// Only consulted under `--free-threaded`; a worker process always runs its
    /// own lifespan on the one loop it has.
    public var lifespanScope: LifespanScope = .perWorker
    /// Directory of a virtualenv whose site-packages should be made importable.
    /// nil means "use VIRTUAL_ENV if it is set".
    public var venvPath: UnsafePointer<CChar>? = nil
    public var noAutoVenv = false

    // --- WSGI execution ---
    /// Threads that may run the WSGI application concurrently. 1 keeps the
    /// original inline model, where the worker loop itself calls the
    /// application; anything higher hands requests to a pool so that a request
    /// blocked on database or network I/O does not stall the whole worker.
    public var wsgiThreads = 1

    // --- reverse proxy ---
    /// Peers whose forwarded headers are believed. Empty means "trust nobody",
    /// which is the only safe default: an untrusted X-Forwarded-For is a client
    /// address spoof and an untrusted X-Forwarded-Proto is a scheme spoof.
    public var trust = ForwardedTrust()

    // --- tls ---
    /// PEM certificate chain and private key. Both or neither.
    ///
    /// This is the default pair: what a client that sends no SNI, or asks for
    /// a name no certificate claims, is served.
    public var tlsCertPath: UnsafePointer<CChar>? = nil
    public var tlsKeyPath: UnsafePointer<CChar>? = nil
    /// Further certificate/key pairs, chosen per connection by SNI.
    ///
    /// Which names each one covers is read out of the certificate itself --
    /// its subject alternative names, or its common name if it has none --
    /// rather than configured alongside it. The certificate already carries
    /// that list, and a second copy of it in a command line is a second copy
    /// to get wrong.
    ///
    /// TCP only. HTTP/3 serves the default pair whatever the client asks for:
    /// the QUIC handshake here is written from the primitives rather than
    /// driven by OpenSSL, and it has no SNI selection of its own yet.
    public var tlsExtraCerts: [(cert: UnsafePointer<CChar>, key: UnsafePointer<CChar>)] = []
    /// OpenSSL cipher list for TLS 1.2. TLS 1.3 suites are not configurable
    /// here and do not need to be.
    public var tlsCiphers: UnsafePointer<CChar>? = nil
    public var tlsEnabled: Bool { tlsCertPath != nil && tlsKeyPath != nil }

    // --- http/2 ---
    /// Serve HTTP/2 to clients that ask for it. Over cleartext that means the
    /// connection preface; over TLS it means ALPN.
    /// HTTP/3, which is HTTP over QUIC over UDP. It needs a certificate: QUIC
    /// has no cleartext form at all.
    public var http3Enabled = false
    /// The UDP port, when it differs from the TCP one. Zero means the same.
    public var quicPort: UInt16 = 0
    /// The `Alt-Svc` value telling a client that reached us over TCP where
    /// HTTP/3 lives, or nil when there is nothing to advertise.
    ///
    /// Built once at start-up rather than per response: it goes on every
    /// response served over TCP and never changes.
    public var altSvc: UnsafePointer<UInt8>? = nil
    public var altSvcLength = 0
    public var http2Enabled = true
    /// Speak only HTTP/2 on this port, with no HTTP/1.1 fallback. What a
    /// proxy that talks h2c upstream (Envoy, Caddy) and a gRPC client expect,
    /// and the only way an invalid preface can be answered in HTTP/2 rather
    /// than mistaken for a malformed HTTP/1 request line.
    public var http2Only = false
    /// Streams one connection may have in flight. Each costs a connection slot.
    public var h2MaxConcurrentStreams = 128
    /// The largest frame we will accept. 16 KiB is the floor every
    /// implementation must support, and larger frames only add latency.
    public var h2MaxFrameSize = 16 * 1024

    // --- websockets ---
    public var websocketsEnabled = true
    public var maxWebsocketMessageSize = 16 * 1024 * 1024
    /// Idle time before the server sends a ping. 0 disables keepalive pings.
    public var websocketPingIntervalMs: UInt64 = 20_000
    /// How long an unanswered ping may go before the connection is dropped.
    public var websocketPingTimeoutMs: UInt64 = 20_000
    /// Decoded messages held for an application that has not asked for them
    /// yet. Frames are decoded on arrival so that control frames are answered
    /// promptly, so data messages need somewhere to wait; when the queue fills,
    /// the read side is switched off and the peer feels it as TCP backpressure.
    public var maxWebsocketQueue = 32
    public var maxWebsocketQueueBytes = 4 * 1024 * 1024

    // --- development ---
    /// Restart workers when a watched source file changes.
    public var reload = false
    public var reloadIntervalMs: UInt64 = 500

    // --- diagnostics ---
    /// URL prefixes served from disk by the server, longest prefix first.
    ///
    /// `--static-dir /static=/var/www/static`. A request whose path starts with
    /// the prefix is answered from the directory without the application being
    /// called; anything else, including a path that matches but has no file
    /// behind it, goes to the application as usual. A miss falling through
    /// rather than 404ing is what lets a route be added in front of an
    /// application that already serves the same prefix.
    ///
    /// Kept longest-first so that a more specific prefix wins over a shorter
    /// one covering the same paths.
    public var staticRoutes: [(prefix: UnsafePointer<CChar>, directory: UnsafePointer<CChar>)] = []

    /// A path the server answers itself, with 200 and an empty body, or nil.
    ///
    /// For an orchestrator's liveness probe. It is answered in the worker
    /// before anything reaches Python, which is the point: a probe that runs
    /// through the application measures the application, so it goes unanswered
    /// exactly when every worker is busy -- and an orchestrator reads an
    /// unanswered liveness probe as a process to kill. This one says the
    /// accept loop is running, which is what liveness is.
    ///
    /// Off unless asked for. Answering a path the application also serves would
    /// shadow it, and the server has no business guessing that /healthz is free.
    public var healthPath: UnsafePointer<CChar>? = nil
    public var logLevel: LogLevel = .info
    public var accessLog = false
    /// Emit the access log as one JSON object per line, for a collector that
    /// would otherwise be handed a regex.
    public var accessLogJSON = false
    /// Port for the Prometheus scrape listener, or 0 for none. A port of its
    /// own rather than a path on the service port: the application owns its
    /// own routes, and monitoring must not be reachable through them.
    public var metricsPort: UInt16 = 0
    /// What the scrape listener binds. nil follows --host; see CONFIG.md for
    /// why that is usually not what you want on a public interface.
    public var metricsHost: UnsafePointer<CChar>? = nil

    public init() {}
}

/// Turns a Swift string literal into a pointer with static storage duration.
/// Literals are already NUL-terminated constants in the binary, so this is a
/// pointer cast, not an allocation.
@inlinable
public func staticCString(_ s: StaticString) -> UnsafePointer<CChar> {
    UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}

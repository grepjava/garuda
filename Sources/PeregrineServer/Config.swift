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
    public var pythonPath: UnsafePointer<CChar>? = nil
    public var preferUvloop = true
    public var callLifespan = true
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
    public var logLevel: LogLevel = .info
    public var accessLog = false

    public init() {}
}

/// Turns a Swift string literal into a pointer with static storage duration.
/// Literals are already NUL-terminated constants in the binary, so this is a
/// pointer cast, not an allocation.
@inlinable
public func staticCString(_ s: StaticString) -> UnsafePointer<CChar> {
    UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}

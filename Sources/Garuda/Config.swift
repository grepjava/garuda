//===----------------------------------------------------------------------===//
// Server configuration.
//
// Every string here points into `argv`, which the kernel keeps alive for the
// life of the process. Configuration therefore owns no memory and copies no
// strings.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

public struct ServerConfig {
    // --- listening ---
    public var host: UnsafePointer<CChar> = staticCString("127.0.0.1")
    public var port: UInt16 = 8000
    public var unixPath: UnsafePointer<CChar>? = nil
    public var backlog: Int32 = 2048
    public var tcpNoDelay = true
    public var ipv6Only = false

    // --- concurrency ---
    /// Worker processes. Each gets its own poller, its own connection slab and,
    /// via SO_REUSEPORT, its own accept queue -- so there is no shared lock and
    /// no thundering herd. 0 means "one per CPU".
    public var workers = 1
    /// `workers` with 0 resolved to the CPU count, which is what every part of
    /// start-up actually wants.
    public var resolvedWorkers: Int { workers > 0 ? workers : Int(av_cpu_count()) }
    public var maxConnections = 4096

    // --- limits ---
    public var readBufferSize = 16 * 1024
    public var maxHeadSize = 32 * 1024
    public var maxHeaders = 100
    public var maxBodySize = 16 * 1024 * 1024
    /// Response bytes buffered before the worker starts applying backpressure.
    public var writeHighWaterMark = 512 * 1024
    /// Buffered bytes a producer held at the high water mark must fall back to
    /// before it is resumed. Resuming at the high water mark would wake the
    /// producer for every single socket write; a gap gives it a whole batch to
    /// refill.
    public var writeLowWaterMark = 128 * 1024
    /// Request bytes buffered ahead of the application before the worker stops
    /// reading the socket. An upload that arrives faster than it is taken
    /// should cost TCP window, not memory.
    public var bodyHighWaterMark = 256 * 1024
    /// Requests per connection before a polite close, to bound memory growth
    /// from long-lived keep-alive clients.
    public var maxRequestsPerConnection: UInt32 = 0    // 0 = unlimited

    // --- timeouts (milliseconds) ---
    public var keepAliveTimeoutMs: UInt64 = 5_000
    public var requestHeadTimeoutMs: UInt64 = 30_000
    public var gracefulShutdownMs: UInt64 = 10_000
    /// How long SIGTERM leaves the server serving normally, with only the
    /// health check failing, before the drain starts.
    ///
    /// A load balancer or a Kubernetes Service keeps sending a pod traffic for
    /// a few seconds after it is told to stop, because taking an endpoint out
    /// of rotation has to propagate. A server that stops accepting the moment
    /// SIGTERM arrives refuses that traffic. This is the gap that closes it:
    /// the probe says 503, the balancer stops routing, and only then does the
    /// server stop taking connections. SIGINT and SIGQUIT do not wait, and a
    /// reload does not either.
    public var drainDelayMs: UInt64 = 0

    public var rootPath: UnsafePointer<CChar> = staticCString("")
    public var scheme: UnsafePointer<CChar> = staticCString("http")
    public var serverName: UnsafePointer<CChar> = staticCString("localhost")
    public var serverPortString: UnsafePointer<CChar> = staticCString("8000")

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
    /// A plain-HTTP port that answers everything with a redirect to https on
    /// `port`, or 0 for none. Bound by every worker with SO_REUSEPORT, like
    /// the metrics port, and never handed to the application.
    public var redirectHTTPPort: UInt16 = 0
    /// The `Strict-Transport-Security` value for every TLS response, or nil.
    /// Built once at start-up, like `altSvc`.
    public var hsts: UnsafePointer<UInt8>? = nil
    public var hstsLength = 0

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
    /// Negotiate permessage-deflate (RFC 7692) with clients that offer it.
    /// Off by default: it costs memory per connection and CPU per message,
    /// and like any compression over TLS it can leak a secret that shares a
    /// message with something the peer controls.
    public var wsCompress = false
    public var maxWebsocketQueueBytes = 4 * 1024 * 1024

    // --- compression ---
    /// Compress application responses for clients that accept it.
    ///
    /// Off by default, and not only because it costs CPU. A response over TLS
    /// that reflects something the client sent next to a secret -- a CSRF
    /// token on a page that echoes a search term -- leaks the secret a byte at
    /// a time to anyone who can watch the compressed length (BREACH). Whether
    /// an application has such a page is its own knowledge, so turning this
    /// on is its decision. See CONFIG.md.
    public var compress = false
    /// Serve `file.br`, `file.zst` or `file.gz` next to a `--static-dir` file
    /// to a client that accepts it. A static file reflects nothing, so this is
    /// safe wherever the files themselves are.
    public var compressStatic = false
    /// A response declaring fewer bytes than this is sent as it is. Below
    /// about a kilobyte the saving is smaller than the framing.
    public var compressMinimumLength = 1024

    // --- acme ---
    /// Names to get a certificate for from an ACME CA, or empty for none.
    ///
    /// With any name here the server gets its own certificate: a helper
    /// process registers an account, answers tls-alpn-01 on the port being
    /// served, installs what the CA issues in `acmeCacheDir`, and reloads the
    /// workers onto it -- then renews it a month before it expires, the same
    /// way. `tlsCertPath` and `tlsKeyPath` point into the cache.
    public var acmeDomains: [UnsafePointer<CChar>] = []
    public var acmeEmail: UnsafePointer<CChar>? = nil
    public var acmeDirectory: UnsafePointer<CChar> =
        staticCString("https://acme-v02.api.letsencrypt.org/directory")
    public var acmeCacheDir: UnsafePointer<CChar>? = nil
    /// Trusted roots for the CA's own HTTPS, for a private or test CA. nil
    /// uses the system's.
    public var acmeCABundle: UnsafePointer<CChar>? = nil
    public var acmeEnabled: Bool { !acmeDomains.isEmpty }

    // --- rate limiting ---
    /// Requests each client may make per `rateLimitPeriodMs`, or 0 for no
    /// limit. Counted across every worker, not per worker; see
    /// avian_ratelimit.h.
    public var rateLimitCount = 0
    public var rateLimitPeriodMs: UInt64 = 1000
    /// Requests a client may make at once before the rate applies. 0 means
    /// one period's worth, the count itself.
    public var rateLimitBurst = 0
    /// --cache-size: mebibytes of memory, shared by every worker, for
    /// responses the application marks fresh; 0 for no cache.
    public var cacheSizeMiB = 0
    /// The largest response body the cache keeps, in bytes.
    public var cacheMaxObject = 1024 * 1024
    /// The longest a response is kept, whatever it says, in seconds.
    public var cacheTTLMaxSeconds = 300

    // --- development ---
    /// Restart on the executable when it is rebuilt, and replace the workers
    /// when a certificate or key file changes.
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
    /// before the request reaches a handler, which is the point: a probe that runs
    /// through the application measures the application, so it goes unanswered
    /// exactly when every worker is busy -- and an orchestrator reads an
    /// unanswered liveness probe as a process to kill. This one says the
    /// accept loop is running, which is what liveness is.
    ///
    /// Off unless asked for. Answering a path the application also serves would
    /// shadow it, and the server has no business guessing that /healthz is free.
    public var healthPath: UnsafePointer<CChar>? = nil
    /// Hand the application `X-Request-Start: t=<microseconds since the
    /// epoch>` for when the request's first byte arrived, unless a proxy in
    /// front already sent one.
    ///
    /// It is the header APM agents -- New Relic, Datadog, Scout -- read to
    /// report queue time, and queue time is the one part of a request's
    /// latency no middleware can measure: it is everything that happened
    /// before the application was called. A worker busy with the requests
    /// ahead of it, a connection waiting in the accept queue -- all of it
    /// shows up here and nowhere else.
    public var requestStartHeader = false
    /// Give every request an `X-Request-ID`: hand it to the application, echo
    /// it on the response and put it in the access log, so that a line in the
    /// application's own log, a line in the access log and what the client
    /// was told can be matched up. One a trusted proxy sent is kept; any other
    /// is replaced, since a client can put anything it likes in a header.
    public var requestID = false
    /// Record the W3C `traceparent` a request carries -- the trace it belongs
    /// to and the span that sent it -- in the access log. Never generated, and
    /// never changed on its way to the application.
    public var traceContext = false
    /// --ktls: have the kernel encrypt TLS where it can, so a --static-dir file
    /// goes out with sendfile over HTTPS as it does in the clear.
    public var ktls = false
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

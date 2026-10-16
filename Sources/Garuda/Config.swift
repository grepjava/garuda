//===----------------------------------------------------------------------===//
// How the server runs: where it listens, how many processes and threads
// serve, and the limits every connection is held to.
//===----------------------------------------------------------------------===//

import GarudaWire

public struct ServerConfig: Sendable {
    // --- listening ---
    public var host = "127.0.0.1"
    public var port = 8000
    public var backlog = 2048
    /// A Unix socket to listen on in place of `host` and `port`, for a proxy
    /// on the same machine; nil listens on TCP. Every shard accepts on the
    /// one socket, and it is removed when the server exits.
    public var unixPath: String? = nil

    // --- processes and threads ---
    /// Shard processes. Each is a whole runtime with its own threads and its
    /// own listening socket; a crash takes one shard's connections down, and
    /// the supervisor starts it again. `nil` lets Vega choose from the
    /// machine's cache domains. 0 serves in this process, with no supervisor
    /// -- what tests and development want.
    public var shards: Int? = nil
    /// How shards share the listening port: each its own SO_REUSEPORT
    /// socket, hashed by the kernel, or one socket all of them accept on.
    /// Nil for Vega's choice: the first on Linux, the second elsewhere.
    public var balance: ConnectionBalance? = nil
    /// Worker threads per shard; nil divides the CPUs among the shards.
    public var threads: Int? = nil
    /// Accept loops per shard; nil: one per thread.
    public var acceptors: Int? = nil
    /// Pin each shard's threads to its CPUs.
    public var pinThreads = true
    /// The I/O driver: `uring` or `epoll`; nil for io_uring where the kernel
    /// has it, else epoll.
    public var io: String? = nil
    /// The lowest level the server logs; nil keeps info.
    public var logLevel: LogLevel? = nil

    /// A route whose handler holds a thread longer than this, on average,
    /// runs in the heavy lane: no more than half of a shard's threads at
    /// once (HeavyLane.swift).
    public var heavyThreshold: Duration = .microseconds(500)
    /// Turns the heavy lane off: every route runs on every thread.
    public var heavyLane = true
    /// Threads per shard that `app.offload` routes run on; nil for Vega's
    /// default. A thread is started when work arrives and none is free.
    public var blockingThreads: Int? = nil
    /// Blocking work per shard (`app.offload`, `Runtime.blocking`) that may
    /// wait for one of those threads before more is refused with 503; nil
    /// waits for as long as it takes.
    public var blockingQueue: Int? = nil

    // --- limits ---
    public var readBufferSize = 16 * 1024
    public var maxHeadSize = 32 * 1024
    public var maxHeaders = 100
    public var maxBodySize = 16 * 1024 * 1024
    /// Requests per connection before a polite close; 0 is unlimited.
    public var maxRequestsPerConnection = 0
    /// Responses written as one batch when a client pipelines requests.
    public var pipelineDepth = 16
    /// Connections a shard has open at once; past it, new ones wait in the
    /// listen backlog until one closes. Nil for no limit.
    public var maxConnections: Int? = nil

    // --- timeouts ---
    /// How long an idle keep-alive connection is kept.
    public var keepAliveTimeout: Duration = .seconds(5)
    /// How long a client has to send a whole request head once it has
    /// started one -- the slowloris bound.
    public var requestHeadTimeout: Duration = .seconds(30)
    /// How long a request body may take to arrive.
    public var bodyTimeout: Duration = .seconds(30)
    /// How long a write may wait on a client that is not reading -- one of
    /// a streamed body, or of a whole answer while the client takes none
    /// of it: the connection is closed on it after that.
    public var writeTimeout: Duration = .seconds(30)
    /// A streamed body's writes wait once this much of it is still on its
    /// way to the client (StreamingResponse.swift)...
    public var writeHighWaterMark = 512 * 1024
    /// ...until it is down to this much.
    public var writeLowWaterMark = 128 * 1024
    /// An event stream quiet this long is sent a comment, so a proxy that
    /// closes idle connections sees traffic and a client that has gone is
    /// noticed (EventStream.swift). Zero sends none.
    public var eventKeepAlive: Duration = .seconds(15)
    /// The ring, in MiB, that messages a `Topic` publishes cross shards in
    /// (Broadcast.swift); 0 turns topics off. A message may be a quarter of it.
    public var broadcastSizeMiB = 4
    /// Messages a subscriber may fall behind by before it is handed
    /// `.missed` in place of the rest.
    public var broadcastQueue = 1024
    /// How long shutting down waits for requests in progress.
    public var gracefulShutdown: Duration = .seconds(10)
    /// --reload: restart on the executable when it is rebuilt, and replace
    /// the shards when a --tls-cert or --tls-key file changes. A development
    /// convenience; the supervisor watches, and no shard does any work for it.
    public var reload = false
    /// How often --reload looks at the files, where the kernel sends no
    /// notification of a change.
    public var reloadInterval: Duration = .milliseconds(500)
    /// How long SIGTERM leaves the server serving, with only the health
    /// check failing, before it stops accepting and drains.
    ///
    /// A load balancer or a Kubernetes Service goes on sending traffic for
    /// a few seconds after it is told to stop: taking an endpoint out of
    /// rotation has to propagate. A server that stops accepting the moment
    /// SIGTERM arrives refuses that traffic. In this gap the probe says
    /// 503, the balancer stops routing, and only then does the server stop
    /// taking connections. SIGINT and SIGQUIT do not wait, and neither does
    /// a reload.
    public var drainDelay: Duration = .zero

    // --- compression (Compression.swift) ---
    /// Compress responses for clients that accept it: text and its kin, and
    /// only those worth it. Off by default: a page that reflects a secret
    /// and something an attacker controls leaks the secret a byte at a time
    /// to anyone who can watch the compressed length (BREACH), and whether an
    /// application has such a page is its own knowledge.
    public var compress = false
    /// Serve `file.br`, `file.zst` or `file.gz` next to a `--static-dir` file
    /// to a client that accepts it. A static file reflects nothing, so this
    /// is safe wherever the files themselves are.
    public var compressStatic = false
    /// A body declaring fewer bytes than this is sent as it is. Below about
    /// a kilobyte the saving is smaller than the framing.
    public var compressMinimumLength = 1024

    // --- before the application (RateLimit.swift, Metrics.swift) ---
    /// Requests each client may make per `rateLimitPeriodMs`, or 0 for no
    /// limit. Counted across every shard and thread, not per one.
    public var rateLimitCount = 0
    public var rateLimitPeriodMs: UInt64 = 1000
    /// Requests a client may make at once before the rate applies. 0 means
    /// one period's worth, the count itself.
    public var rateLimitBurst = 0
    /// A path answered 200 before routing and before --rate-limit, for a
    /// load balancer's or an orchestrator's probe; nil for none.
    public var healthCheckPath: String? = nil
    /// The port the Prometheus page is served on, at /metrics; nil for none.
    public var metricsPort: Int? = nil
    /// The interface it listens on; nil for `host`'s.
    public var metricsHost: String? = nil

    // --- the response cache (ResponseCache.swift) ---
    /// Mebibytes of memory, shared by every shard, for responses the
    /// application marks fresh; 0 for no cache.
    public var cacheSizeMiB = 0
    /// The largest response body the cache keeps, in bytes.
    public var cacheMaxObject = 1024 * 1024
    /// The longest a response is kept, whatever it says, in seconds.
    public var cacheTTLMaxSeconds = 300

    // --- static files (StaticFiles.swift) ---
    /// URL prefixes answered from directories, `--static-dir /static=/srv/www`:
    /// a GET or HEAD under a prefix is served the file it names, and one
    /// naming no file falls through to the routes.
    public var staticDirectories: [(prefix: String, directory: String)] = []
    /// A single-page application's page, served for browser navigations no
    /// route answers: `--spa-fallback /app=/srv/app/index.html`. `file` is
    /// its name under `directory`.
    public var spaFallbacks: [(prefix: String, directory: String, file: String)] = []
    /// Answer a request for a `--static-dir` directory with its `index.html`.
    /// Off by default: a directory that is not served falls through to the
    /// application, and taking that path away is the operator's decision.
    public var staticIndex = false
    /// Answer a request for a directory that has no index with a listing of
    /// what is in it. Implies `staticIndex`. Off by default, and deliberately:
    /// a listing tells whoever asks every name in the directory.
    public var staticListing = false
    /// The most entries a listing shows; 0 for no limit. Past it the
    /// directory is not read further, and the page says there are more.
    public var staticListingLimit = 10_000

    // --- TLS (TLS.swift) ---
    /// The certificates served, each with its key; none serves plain HTTP.
    /// The client's SNI picks the first that covers the name it asks for,
    /// and the first answers a client that names none.
    public var tlsCertificates: [TLSCertificateFiles] = []
    /// A plain-HTTP port that answers everything with a redirect to the same
    /// URL on https, or nil for none.
    public var redirectHTTPPort: Int? = nil
    /// A directory an outside ACME client (certbot --webroot) writes its
    /// HTTP-01 challenges under, served at /.well-known/acme-challenge/ on
    /// the redirectHTTPPort, or nil for none.
    public var acmeWebroot: String? = nil
    /// How often to look at the certificate files and serve them again when
    /// they have changed; nil never looks.
    public var tlsReloadInterval: Duration? = nil
    /// How long a client has to finish the TLS handshake.
    public var tlsHandshakeTimeout: Duration = .seconds(10)
    /// The TLS 1.2 cipher suites, as an OpenSSL cipher list; nil for the
    /// library's. TLS 1.3's suites are fixed.
    public var tlsCiphers: String? = nil

    // --- HTTP/2 (HTTP2.swift) ---
    /// Serve HTTP/2: to a TLS client that asks for "h2" by ALPN, and to a
    /// cleartext client that opens with the HTTP/2 preface (prior knowledge).
    public var http2Enabled = true
    /// Serve only HTTP/2 in cleartext (h2c), with no HTTP/1 fallback: what a
    /// proxy that talks h2c upstream (Envoy, Caddy) and a gRPC client expect.
    public var http2Only = false

    // --- WebSockets (WebSocket.swift) ---
    /// --no-websockets: upgrades are refused with 501.
    public var websocketsEnabled = true
    /// The largest message taken from a peer, after inflating.
    public var maxWebsocketMessageSize = 16 * 1024 * 1024
    /// How long a WebSocket may be quiet before it is pinged; zero for never.
    public var websocketPingInterval: Duration = .seconds(20)
    /// How long a ping, or a close the server sent, may go unanswered.
    public var websocketPingTimeout: Duration = .seconds(20)
    /// Messages, and bytes, held for a handler that is not reading before
    /// the socket stops being read.
    public var maxWebsocketQueue = 32
    public var maxWebsocketQueueBytes = 4 * 1024 * 1024
    /// --ws-compress: permessage-deflate with clients that offer it.
    public var websocketCompress = false
    /// --websocket-protocols: which protocols carry WebSockets. HTTP/1.1's
    /// upgrade, HTTP/2's extended CONNECT (RFC 8441), and HTTP/3's (RFC
    /// 9220); a WebSocket over one left out is refused with 501, and over
    /// HTTP/2 extended CONNECT is not offered at all.
    public var websocketProtocols: WebSocketProtocols = .all
    /// Streams a client may have open at once on one connection.
    public var h2MaxConcurrentStreams = 128
    /// The largest frame payload a client may send.
    public var h2MaxFrameSize = 16 * 1024
    /// How much request body a client may send on a stream, and on the
    /// connection, before the server gives the window back. The body is
    /// held whole until dispatch, and the body limit bounds it, so a large
    /// window costs nothing but lets an upload use the link.
    public var h2InitialWindowSize = 256 * 1024

    // --- HTTP/3 (HTTP3.swift) ---
    /// Serve HTTP/3 over QUIC as well, on UDP. It needs a certificate: QUIC
    /// has no cleartext form. Clients learn of it from the Alt-Svc header
    /// every TCP response then carries.
    public var http3Enabled = false
    /// The UDP port HTTP/3 is served on; nil for the TCP port.
    public var quicPort: Int? = nil
    /// QUIC connections one UDP socket serves at once; a new one past this
    /// is not answered. A shard has a socket per thread.
    public var maxQUICConnections = 4096

    // --- Strict-Transport-Security ---
    /// --hsts: `strict-transport-security: max-age=N` on every answer over
    /// TLS that does not set its own; nil for none.
    public var hstsMaxAge: Int? = nil

    // --- request IDs and logging (RequestID.swift, Logging.swift) ---
    /// Peers whose forwarded headers are believed (--forwarded-allow-ips).
    /// Empty means "trust nobody", which is the only safe default: a header
    /// any client can set is not one anybody else can rely on.
    public var trust = ForwardedTrust()
    /// Give every request an `X-Request-ID`: hand it to the application, echo
    /// it on the response and put it in the access log, so that a line in the
    /// application's own log, a line in the access log and what the client
    /// was told can be matched up. One a trusted proxy sent is kept; any other
    /// is replaced, since a client can put anything it likes in a header.
    public var requestID = false
    /// A mount prefix a proxy in front leaves on the path: taken off before
    /// routing, so `/app/users` reaches the `/users` route under
    /// `--root-path /app`. A path outside it is routed as it came, as from a
    /// proxy that took the prefix off itself. Empty for none.
    public var rootPath = ""
    /// Take every request that arrived without TLS, and without a trusted
    /// proxy saying otherwise, as HTTPS (`--scheme https`): for a proxy that
    /// terminates TLS and says nothing about it. `Request.arrivedOverHTTPS`,
    /// and what follows it, then say so.
    public var assumeHTTPS = false
    /// Give handlers `Request.requestStart`: when the request arrived, in
    /// microseconds since the epoch, for an APM agent that reports the time
    /// a request waited before the application saw it.
    public var requestStartHeader = false
    /// Record the W3C `traceparent` a request carries -- the trace it belongs
    /// to and the span that sent it -- in the logs and for response
    /// observers. Never generated, and never changed on its way to the
    /// application.
    public var traceContext = false
    /// One line per request, on standard error, at info.
    public var accessLog = false
    /// Write the access log as one JSON object per line, for a collector that
    /// would otherwise be handed a regex.
    public var accessLogJSON = false
    /// Write the application log -- `request.log` and `AppLog` -- as one JSON
    /// object per line. The command line has the access log follow it unless
    /// --access-log-format says otherwise.
    public var logJSON = false

    /// Garuda 1 flags that mean nothing here, given on the command line:
    /// warned about once at start-up, so an old command line still starts.
    var ignoredFlags: [String] = []

    public init() {}

}

/// How shards share the listening port (`--balance`).
public enum ConnectionBalance: Sendable, Hashable {
    /// Each shard binds its own SO_REUSEPORT socket and the kernel hashes
    /// connections across them.
    case reusePort
    /// One socket every shard accepts on: a connection goes to a shard
    /// waiting in accept.
    case shared
}

/// The protocols WebSockets are served over (--websocket-protocols).
public struct WebSocketProtocols: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let http1 = WebSocketProtocols(rawValue: 1)
    public static let http2 = WebSocketProtocols(rawValue: 2)
    public static let http3 = WebSocketProtocols(rawValue: 4)
    public static let all: WebSocketProtocols = [.http1, .http2, .http3]

    /// "http1,http2", as the flag takes it; nil for a name it does not know.
    public init?(parsing list: String) {
        var set: WebSocketProtocols = []
        for name in list.split(separator: ",") {
            switch String(name).trimmingSpaces {
            case "http1", "http1.1", "h1": set.insert(.http1)
            case "http2", "h2": set.insert(.http2)
            case "http3", "h3": set.insert(.http3)
            default: return nil
            }
        }
        self = set
    }
}

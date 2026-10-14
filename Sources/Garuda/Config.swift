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

    // --- processes and threads ---
    /// Shard processes. Each is a whole runtime with its own threads and its
    /// own listening socket; a crash takes one shard's connections down, and
    /// the supervisor starts it again. `nil` lets Vega choose from the
    /// machine's cache domains. 0 serves in this process, with no supervisor
    /// -- what tests and development want.
    public var shards: Int? = nil
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

    // --- limits ---
    public var readBufferSize = 16 * 1024
    public var maxHeadSize = 32 * 1024
    public var maxHeaders = 100
    public var maxBodySize = 16 * 1024 * 1024
    /// Requests per connection before a polite close; 0 is unlimited.
    public var maxRequestsPerConnection = 0
    /// Responses written as one batch when a client pipelines requests.
    public var pipelineDepth = 16

    // --- timeouts ---
    /// How long an idle keep-alive connection is kept.
    public var keepAliveTimeout: Duration = .seconds(5)
    /// How long a client has to send a whole request head once it has
    /// started one -- the slowloris bound.
    public var requestHeadTimeout: Duration = .seconds(30)
    /// How long a request body may take to arrive.
    public var bodyTimeout: Duration = .seconds(30)
    /// How long a response may take to write.
    public var writeTimeout: Duration = .seconds(30)
    /// How long shutting down waits for requests in progress.
    public var gracefulShutdown: Duration = .seconds(10)

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

    public init() {}

}

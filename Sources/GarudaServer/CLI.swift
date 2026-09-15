//===----------------------------------------------------------------------===//
// The command line for the garuda executable.
//
// Arguments are read straight out of argv, which the kernel keeps alive, so
// configuration parsing allocates nothing and every configured string is a
// pointer into memory nobody has to manage.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CGaruda
import GarudaCore

public enum GarudaCLI {

    /// Parses `argv` and runs the server, returning the exit status rather than
    /// exiting, so that the caller decides how the process ends.
    public static func main(argc: Int,
                            argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
        @inline(__always)
        func matches(_ arg: UnsafePointer<CChar>, _ name: StaticString) -> Bool {
            strcmp(arg, staticCString(name)) == 0
        }

        func parseInt(_ s: UnsafePointer<CChar>) -> Int {
            Int(strtol(s, nil, 10))
        }

        /// Formats an integer into a permanently-allocated C string. Used only for the
        /// SERVER_PORT environ value, once per process.
        func makeCString(_ value: Int) -> UnsafePointer<CChar> {
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 24)
            var n = 0
            buf.withMemoryRebound(to: UInt8.self, capacity: 24) { p in
                n = writeDecimal(value, p)
            }
            buf[n] = 0
            return UnsafePointer(buf)
        }

        /// `dir` followed by `suffix`, in permanently allocated memory. Once per
        /// process, for the paths --acme-cache implies.
        func joinPath(_ dir: UnsafePointer<CChar>, _ suffix: StaticString) -> UnsafePointer<CChar> {
            let head = Int(strlen(dir))
            let tail = suffix.utf8CodeUnitCount
            let out = UnsafeMutablePointer<CChar>.allocate(capacity: head + tail + 1)
            out.update(from: dir, count: head)
            UnsafeRawPointer(suffix.utf8Start).withMemoryRebound(to: CChar.self, capacity: tail) {
                (out + head).update(from: $0, count: tail)
            }
            out[head + tail] = 0
            return UnsafePointer(out)
        }

        /// `h3=":443"; ma=86400` -- the Alt-Svc value advertising HTTP/3 on the UDP
        /// port. The lifetime is a day, long enough to be worth caching and short
        /// enough that turning HTTP/3 off is not a decision clients keep honouring.
        func makeAltSvc(port: UInt16) -> (UnsafePointer<UInt8>, Int) {
            var buf = ByteBuffer(capacity: 32)
            defer { buf.destroy() }
            buf.write("h3=\":")
            buf.writeDecimal(Int(port))
            buf.write("\"; ma=86400")
            let n = buf.readableBytes
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            out.update(from: buf.readPointer, count: n)
            return (UnsafePointer(out), n)
        }

        /// `max-age=N`, the Strict-Transport-Security value --hsts asks for.
        /// includeSubDomains and preload are left out: they commit other hosts to
        /// https, which is a decision for whoever owns them, not a server flag.
        func makeHSTS(seconds: Int) -> (UnsafePointer<UInt8>, Int) {
            var buf = ByteBuffer(capacity: 32)
            defer { buf.destroy() }
            buf.write("max-age=")
            buf.writeDecimal(seconds)
            let n = buf.readableBytes
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            out.update(from: buf.readPointer, count: n)
            return (UnsafePointer(out), n)
        }

        func printUsage() {
            let usage: StaticString = """
            garuda -- a Swift web server

            usage: garuda [options]

              --host HOST              interface to bind (default 127.0.0.1)
              --port PORT              port to bind (default 8000)
              --unix PATH              listen on a unix socket instead
              --workers N              worker processes, 0 = one per CPU (default 1)
              --root-path PATH         mount prefix, taken off paths before routing
              --scheme http|https      scheme taken as the request's, behind a proxy
                                       that terminates TLS (keys --cache-size)
              --backlog N              listen backlog (default 2048)
              --max-connections N      concurrent connections per worker (default 4096)
              --max-body BYTES         largest accepted request body (default 16 MiB)
              --max-header-size BYTES  largest accepted request head (default 32 KiB)
              --keep-alive MS          idle keep-alive timeout (default 5000)
              --request-timeout MS     how long a request may stall mid-message (30000)
              --graceful-timeout MS    time in-flight requests get on shutdown (10000)
              --drain-delay MS         on SIGTERM, keep serving for MS with the health
                                       check answering 503, so a load balancer stops
                                       routing here before connections are refused
                                       (default 0; SIGINT and SIGQUIT do not wait)
              --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted:
                                       a comma-separated list of addresses or CIDR
                                       blocks, "unix", or "*" for every peer
              --reload                 when the executable is rebuilt, restart on it
                                       without dropping a connection; when a
                                       --tls-cert or --tls-key file changes, replace
                                       the workers
              --reload-interval MS     how often --reload looks, where the kernel
                                       sends no notification (default 500)
              --tls-cert PATH          PEM certificate chain; enables TLS with ALPN.
                                       Repeatable, with a --tls-key each: the first
                                       pair is the default and the rest are picked by
                                       SNI, using the names inside each certificate
              --tls-key PATH           PEM private key for the preceding --tls-cert
              --tls-ciphers LIST       OpenSSL cipher list for TLS 1.2
              --ktls                   let the Linux kernel encrypt TLS, so --static-dir
                                       files go out with sendfile over HTTPS too
                                       (needs the tls module: modprobe tls)
              --acme-domain NAME       get and renew a certificate for NAME from an
                                       ACME CA (Let's Encrypt by default), answering
                                       tls-alpn-01 on this port (repeatable)
              --acme-email ADDR        contact address for the ACME account
              --acme-cache DIR         where the account key and certificate live
                                       (default ./acme)
              --acme-staging           use Let's Encrypt's staging CA
              --acme-directory URL     use another ACME CA
              --acme-ca-bundle PATH    roots to trust for the CA's own HTTPS
              --redirect-http PORT     answer plain HTTP on PORT with a redirect to
                                       https on the TLS port (301, or 308 for methods
                                       other than GET and HEAD)
              --hsts SECONDS           send Strict-Transport-Security: max-age=SECONDS
                                       on every TLS response
              --no-http2               refuse HTTP/2 and answer HTTP/1.1 only
              --http2-only             serve only HTTP/2 (h2c), with no HTTP/1 fallback
              --http3                  also serve HTTP/3 over QUIC (needs TLS)
              --quic-port PORT         UDP port for HTTP/3 (default: the TCP port)
              --no-websockets          reject WebSocket upgrades with 501
              --ws-max-message BYTES   largest accepted WebSocket message (16 MiB)
              --ws-ping-interval MS    keepalive ping period, 0 to disable (20000)
              --ws-ping-timeout MS     how long an unanswered ping may go (20000)
              --ws-max-queue N         messages buffered for a slow handler (default 32)
              --ws-max-queue-bytes N   bytes buffered for a slow handler (4 MiB)
              --ws-compress            negotiate permessage-deflate with WebSocket
                                       clients that offer it
                                       (the --ws-* settings have no effect until
                                       WebSocket handlers exist)
              --static-dir P=DIR       serve URL prefix P from DIR with sendfile,
                                       before routing (repeatable). A path with no
                                       file behind it still reaches the routes
              --rate-limit RATE        refuse a client with 429 past RATE requests, as
                                       in 100/s, 600/m or 5000/h; counted across all
                                       workers, by the forwarded address behind a
                                       trusted proxy and by /64 for IPv6
              --rate-limit-burst N     requests allowed at once before the rate
                                       applies (default: the count in RATE)
              --cache-size MIB         answer repeated GETs from a cache shared by
                                       every worker, for responses a handler marks
                                       fresh with Cache-Control s-maxage or max-age;
                                       read CONFIG.md first (nothing is stored yet)
              --cache-max-object KIB   largest body the cache keeps (default 1024)
              --cache-ttl-max SECONDS  longest a response is kept (default 300)
              --compress               compress handler responses (br, zstd or gzip,
                                       as the client accepts) when their type is
                                       text-like; read CONFIG.md about BREACH first
                                       (router responses have no type to compress yet)
              --compress-min-size N    leave bodies declared smaller than this as they
                                       are (default 1024)
              --compress-static        serve FILE.br, FILE.zst or FILE.gz beside a
                                       --static-dir file to clients that accept it
              --request-start-header   give handlers X-Request-Start: t=<usec> for
                                       when the request arrived, for APM agents that
                                       report queue time (no handler reads it yet)
              --request-id             give every request an X-Request-ID, echoed on
                                       the response and in the access log; one from a
                                       --forwarded-allow-ips proxy is kept
              --trace-context          record a request's W3C traceparent, its trace
                                       and parent span IDs, in the access log
              --health-check-path P    answer P with 200 before routing (e.g.
                                       /healthz)
              --access-log             log one line per request
              --access-log-format F    text (default) or json; implies --access-log
              --metrics-port PORT      serve Prometheus metrics on this port
              --metrics-host HOST      what the metrics port binds (default --host)
              --log-level LEVEL        debug, info, warning, error, silent
              --version                print the version and exit
              -h, --help               print this message

            examples:
              garuda --port 8080
              garuda --workers 0 --host 0.0.0.0
              garuda --unix /run/app.sock --workers 4 \\
                        --forwarded-allow-ips 10.0.0.0/8

            """
            _ = pg_write(1, usage.utf8Start, usage.utf8CodeUnitCount)
        }

        let version: StaticString = "garuda 0.1.0-dev"

        func printVersion() {
            var buf = [UInt8](repeating: 0, count: 64)
            var n = 0
            let take = min(version.utf8CodeUnitCount, buf.count - 2)
            _ = buf.withUnsafeMutableBufferPointer {
                memcpy($0.baseAddress!, version.utf8Start, take)
            }
            n = take
            buf[n] = 10
            n += 1
            buf.withUnsafeBufferPointer { _ = pg_write(1, $0.baseAddress!, n) }
        }

        var config = ServerConfig()

        // --tls-cert and --tls-key are repeatable and paired by the order they appear,
        // so that a server with several names carries several certificates. The first
        // pair is the default; the rest are chosen by SNI.
        var tlsCerts: [UnsafePointer<CChar>] = []
        var tlsKeys: [UnsafePointer<CChar>] = []

        // Collected in the order given and sorted longest-prefix-first afterwards, so
        // that --static-dir /a=... and --static-dir /a/b=... behave the way the more
        // specific one implies whichever order they were written in.
        var staticRoutes: [(prefix: UnsafePointer<CChar>, directory: UnsafePointer<CChar>)] = []
        var schemeGiven = false
        var hstsSeconds = -1
        var portSet = false

        var i = 1
        var failed = false

        while i < argc {
            guard let raw = argv[i] else { break }
            let arg = UnsafePointer<CChar>(raw)
            i += 1

            @inline(__always)
            func next(_ what: StaticString) -> UnsafePointer<CChar>? {
                guard i < argc, let v = argv[i] else {
                    Log.error(what)
                    failed = true
                    return nil
                }
                i += 1
                return UnsafePointer(v)
            }

            if matches(arg, "-h") || matches(arg, "--help") {
                printUsage()
                return 0
            } else if matches(arg, "--version") {
                printVersion()
                return 0
            } else if matches(arg, "--host") {
                guard let v = next("--host needs a value") else { break }
                config.host = v
                config.serverName = v
            } else if matches(arg, "--port") {
                guard let v = next("--port needs a value") else { break }
                let p = parseInt(v)
                if p <= 0 || p > 65535 {
                    Log.error("--port must be between 1 and 65535")
                    failed = true
                    break
                }
                config.port = UInt16(p)
                config.serverPortString = v
                portSet = true
            } else if matches(arg, "--unix") {
                guard let v = next("--unix needs a path") else { break }
                config.unixPath = v
            } else if matches(arg, "--workers") {
                guard let v = next("--workers needs a value") else { break }
                config.workers = max(0, parseInt(v))
            } else if matches(arg, "--root-path") {
                guard let v = next("--root-path needs a value") else { break }
                config.rootPath = v
            } else if matches(arg, "--scheme") {
                guard let v = next("--scheme needs a value") else { break }
                config.scheme = v
                schemeGiven = true
            } else if matches(arg, "--tls-cert") {
                guard let v = next("--tls-cert needs a path") else { break }
                tlsCerts.append(v)
            } else if matches(arg, "--tls-key") {
                guard let v = next("--tls-key needs a path") else { break }
                tlsKeys.append(v)
            } else if matches(arg, "--acme-domain") {
                guard let v = next("--acme-domain needs a name") else { break }
                config.acmeDomains.append(v)
            } else if matches(arg, "--acme-email") {
                guard let v = next("--acme-email needs an address") else { break }
                config.acmeEmail = v
            } else if matches(arg, "--acme-cache") {
                guard let v = next("--acme-cache needs a directory") else { break }
                config.acmeCacheDir = v
            } else if matches(arg, "--acme-directory") {
                guard let v = next("--acme-directory needs a URL") else { break }
                config.acmeDirectory = v
            } else if matches(arg, "--acme-staging") {
                config.acmeDirectory = staticCString("https://acme-staging-v02.api.letsencrypt.org/directory")
            } else if matches(arg, "--acme-ca-bundle") {
                guard let v = next("--acme-ca-bundle needs a path") else { break }
                config.acmeCABundle = v
            } else if matches(arg, "--tls-ciphers") {
                guard let v = next("--tls-ciphers needs an OpenSSL cipher list") else { break }
                config.tlsCiphers = v
            } else if matches(arg, "--redirect-http") {
                guard let v = next("--redirect-http needs a port") else { break }
                let p = parseInt(v)
                if p <= 0 || p > 65535 {
                    Log.error("--redirect-http must be a port between 1 and 65535")
                    failed = true
                    break
                }
                config.redirectHTTPPort = UInt16(p)
            } else if matches(arg, "--hsts") {
                guard let v = next("--hsts needs a max-age in seconds") else { break }
                var seconds = 0
                var at = 0
                while v[at] >= 48 && v[at] <= 57 && seconds < 1_000_000_000 {   // digits
                    seconds = seconds * 10 + Int(v[at] - 48)
                    at += 1
                }
                if at == 0 || v[at] != 0 {
                    Log.error("--hsts takes a number of seconds, as in 31536000 for a year")
                    failed = true
                    break
                }
                hstsSeconds = seconds
            } else if matches(arg, "--backlog") {
                guard let v = next("--backlog needs a value") else { break }
                config.backlog = Int32(max(1, parseInt(v)))
            } else if matches(arg, "--max-connections") {
                guard let v = next("--max-connections needs a value") else { break }
                config.maxConnections = max(1, parseInt(v))
            } else if matches(arg, "--max-body") {
                guard let v = next("--max-body needs a value") else { break }
                config.maxBodySize = max(0, parseInt(v))
            } else if matches(arg, "--max-header-size") {
                guard let v = next("--max-header-size needs a value") else { break }
                config.maxHeadSize = max(1024, parseInt(v))
            } else if matches(arg, "--keep-alive") {
                guard let v = next("--keep-alive needs milliseconds") else { break }
                config.keepAliveTimeoutMs = UInt64(max(0, parseInt(v)))
            } else if matches(arg, "--request-timeout") {
                guard let v = next("--request-timeout needs milliseconds") else { break }
                config.requestHeadTimeoutMs = UInt64(max(0, parseInt(v)))
            } else if matches(arg, "--graceful-timeout") {
                guard let v = next("--graceful-timeout needs milliseconds") else { break }
                config.gracefulShutdownMs = UInt64(max(0, parseInt(v)))
            } else if matches(arg, "--drain-delay") {
                guard let v = next("--drain-delay needs milliseconds") else { break }
                config.drainDelayMs = UInt64(max(0, parseInt(v)))
            } else if matches(arg, "--reload") {
                config.reload = true
            } else if matches(arg, "--reload-interval") {
                guard let v = next("--reload-interval needs milliseconds") else { break }
                config.reloadIntervalMs = UInt64(max(50, parseInt(v)))
            } else if matches(arg, "--forwarded-allow-ips") {
                guard let v = next("--forwarded-allow-ips needs a list") else { break }
                if !config.trust.parse(v) {
                    Log.error("--forwarded-allow-ips contains an address that is not valid")
                    failed = true
                    break
                }
            } else if matches(arg, "--http3") {
                config.http3Enabled = true
            } else if matches(arg, "--quic-port") {
                guard let v = next("--quic-port needs a port") else { break }
                let p = parseInt(v)
                if p <= 0 || p > 65535 {
                    Log.error("--quic-port must be between 1 and 65535")
                    return 2
                }
                config.quicPort = UInt16(p)
            } else if matches(arg, "--no-http2") {
                config.http2Enabled = false
            } else if matches(arg, "--http2-only") {
                config.http2Only = true
                config.http2Enabled = true
            } else if matches(arg, "--no-websockets") {
                config.websocketsEnabled = false
            } else if matches(arg, "--ws-max-message") {
                guard let v = next("--ws-max-message needs a byte count") else { break }
                config.maxWebsocketMessageSize = max(1024, parseInt(v))
            } else if matches(arg, "--ws-ping-interval") {
                guard let v = next("--ws-ping-interval needs milliseconds") else { break }
                config.websocketPingIntervalMs = UInt64(max(0, parseInt(v)))
            } else if matches(arg, "--ws-ping-timeout") {
                guard let v = next("--ws-ping-timeout needs milliseconds") else { break }
                config.websocketPingTimeoutMs = UInt64(max(100, parseInt(v)))
            } else if matches(arg, "--ws-max-queue") {
                guard let v = next("--ws-max-queue needs a message count") else { break }
                config.maxWebsocketQueue = max(1, parseInt(v))
            } else if matches(arg, "--ws-max-queue-bytes") {
                guard let v = next("--ws-max-queue-bytes needs a byte count") else { break }
                config.maxWebsocketQueueBytes = max(1024, parseInt(v))
            } else if matches(arg, "--ws-compress") {
                config.wsCompress = true
            } else if matches(arg, "--static-dir") {
                guard let v = next("--static-dir needs PREFIX=DIRECTORY") else { break }
                // Split on the first '=' in place: the two halves are both NUL
                // terminated afterwards, because the separator becomes the first
                // terminator. argv is ours to write to.
                var at = 0
                while v[at] != 0 && v[at] != 61 { at += 1 }   // '='
                if v[at] == 0 || at == 0 {
                    Log.error("--static-dir takes PREFIX=DIRECTORY, as in /static=/var/www/static")
                    failed = true
                    break
                }
                if v[0] != 47 {   // '/'
                    Log.error("--static-dir prefix must start with /")
                    failed = true
                    break
                }
                UnsafeMutablePointer(mutating: v)[at] = 0
                staticRoutes.append((prefix: v, directory: v + at + 1))
            } else if matches(arg, "--rate-limit") {
                guard let v = next("--rate-limit needs a rate, as in 100/s") else { break }
                var count = 0
                var at = 0
                while v[at] >= 48 && v[at] <= 57 && count < 100_000_000 {   // digits
                    count = count * 10 + Int(v[at] - 48)
                    at += 1
                }
                var period: UInt64 = 1000
                if v[at] == 47 {   // '/'
                    switch v[at + 1] {
                    case 115: period = 1000          // s
                    case 109: period = 60_000        // m
                    case 104: period = 3_600_000     // h
                    default: period = 0
                    }
                    if period != 0 && v[at + 2] != 0 { period = 0 }
                } else if v[at] != 0 {
                    period = 0
                }
                if count <= 0 || period == 0 || period * 1000 / UInt64(count) == 0 {
                    Log.error("--rate-limit takes requests per second, minute or hour, as in 100/s or 600/m")
                    failed = true
                    break
                }
                config.rateLimitCount = count
                config.rateLimitPeriodMs = period
            } else if matches(arg, "--rate-limit-burst") {
                guard let v = next("--rate-limit-burst needs a count") else { break }
                config.rateLimitBurst = max(1, parseInt(v))
            } else if matches(arg, "--cache-size") {
                guard let v = next("--cache-size needs mebibytes") else { break }
                config.cacheSizeMiB = max(0, parseInt(v))
            } else if matches(arg, "--cache-max-object") {
                guard let v = next("--cache-max-object needs kibibytes") else { break }
                config.cacheMaxObject = max(1, min(64 * 1024, parseInt(v))) * 1024
            } else if matches(arg, "--cache-ttl-max") {
                guard let v = next("--cache-ttl-max needs seconds") else { break }
                config.cacheTTLMaxSeconds = max(1, parseInt(v))
            } else if matches(arg, "--compress") {
                config.compress = true
            } else if matches(arg, "--compress-static") {
                config.compressStatic = true
            } else if matches(arg, "--compress-min-size") {
                guard let v = next("--compress-min-size needs a byte count") else { break }
                config.compressMinimumLength = max(0, parseInt(v))
            } else if matches(arg, "--request-start-header") {
                config.requestStartHeader = true
            } else if matches(arg, "--request-id") {
                config.requestID = true
            } else if matches(arg, "--trace-context") {
                config.traceContext = true
            } else if matches(arg, "--ktls") {
                config.ktls = true
            } else if matches(arg, "--health-check-path") {
                guard let v = next("--health-check-path needs a path") else { break }
                if v[0] != 47 {   // '/'
                    Log.error("--health-check-path must start with /")
                    failed = true
                    break
                }
                config.healthPath = v
            } else if matches(arg, "--access-log") {
                config.accessLog = true
            } else if matches(arg, "--metrics-port") {
                guard let v = next("--metrics-port needs a value") else { break }
                let p = parseInt(v)
                if p <= 0 || p > 65535 {
                    Log.error("--metrics-port must be between 1 and 65535")
                    failed = true
                    break
                }
                config.metricsPort = UInt16(p)
            } else if matches(arg, "--metrics-host") {
                guard let v = next("--metrics-host needs a value") else { break }
                config.metricsHost = v
            } else if matches(arg, "--access-log-format") {
                guard let v = next("--access-log-format needs a value") else { break }
                // Asking for a format is asking for the log: the alternative is a
                // flag that silently does nothing without a second one beside it.
                config.accessLog = true
                if matches(v, "text") {
                    config.accessLogJSON = false
                } else if matches(v, "json") {
                    config.accessLogJSON = true
                } else {
                    Log.error("unknown --access-log-format; use text or json")
                    failed = true
                    break
                }
            } else if matches(arg, "--log-level") {
                guard let v = next("--log-level needs a value") else { break }
                if matches(v, "debug") { config.logLevel = .debug }
                else if matches(v, "info") { config.logLevel = .info }
                else if matches(v, "warning") || matches(v, "warn") { config.logLevel = .warning }
                else if matches(v, "error") { config.logLevel = .error }
                else if matches(v, "silent") || matches(v, "none") { config.logLevel = .silent }
                else {
                    Log.error("unknown --log-level")
                    failed = true
                    break
                }
            } else if arg[0] == 45 {   // '-'
                Log.error { line in
                    line.str("unknown option: ")
                    line.cstr(arg)
                }
                failed = true
                break
            } else {
                Log.error { line in
                    line.str("unexpected argument: ")
                    line.cstr(arg)
                }
                failed = true
                break
            }
        }

        if failed {
            return 2
        }

        // Pair the certificates with their keys, in the order they were given. An
        // unequal count is a mistake worth stopping for: pairing what is there and
        // ignoring the remainder would serve the wrong certificate for a name, which
        // shows up as a browser warning rather than as an error here.
        config.staticRoutes = staticRoutes.sorted { strlen($0.prefix) > strlen($1.prefix) }

        if tlsCerts.count != tlsKeys.count {
            Log.error("--tls-cert and --tls-key go together, one key per certificate")
            return 2
        }
        if let cert = tlsCerts.first, let key = tlsKeys.first {
            config.tlsCertPath = cert
            config.tlsKeyPath = key
            config.tlsExtraCerts = Array(zip(tlsCerts.dropFirst(), tlsKeys.dropFirst()))
                .map { (cert: $0.0, key: $0.1) }
        }

        // --acme-domain: the certificate comes from the CA, into the cache directory,
        // and the TLS paths are simply where it will be.
        if config.acmeEnabled {
            if config.tlsCertPath != nil {
                Log.error("--acme-domain gets its own certificate; leave out --tls-cert and --tls-key")
                return 2
            }
            for domain in config.acmeDomains {
                // tls-alpn-01 validates one name on one connection, so there are no
                // wildcards here: a wildcard certificate needs dns-01, which needs a
                // DNS provider this server knows nothing about.
                var length = 0
                var valid = domain[0] != 0 && domain[0] != 46 && domain[0] != 45
                while domain[length] != 0 {
                    let c = UInt8(bitPattern: domain[length])
                    let allowed = (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
                        || (c >= 48 && c <= 57) || c == 45 || c == 46
                    if !allowed { valid = false }
                    length += 1
                }
                if !valid || length > 253 {
                    Log.error { line in
                        line.str("--acme-domain takes a DNS name, not ")
                        line.cstr(domain)
                    }
                    return 2
                }
            }
            let dir = config.acmeCacheDir ?? staticCString("acme")
            config.acmeCacheDir = dir
            config.tlsCertPath = joinPath(dir, "/cert.pem")
            config.tlsKeyPath = joinPath(dir, "/key.pem")
            if config.port != 443 {
                // Allowed, because a test CA validates wherever it is told to and a
                // port-forward may put 443 somewhere else -- but a public CA connects
                // to 443 and nowhere else, and saying so here beats a failed
                // validation an hour from now.
                Log.warn("--acme-domain: public CAs validate on port 443; make sure it reaches this port")
            }
        }

        // A TLS listener is https, and every URL the application builds should say so.
        // An explicit --scheme still wins: someone behind a terminating proxy may have
        // a reason.
        if config.tlsEnabled && !schemeGiven {
            config.scheme = staticCString("https")
        }
        if (config.tlsCertPath == nil) != (config.tlsKeyPath == nil) {
            Log.error("--tls-cert and --tls-key go together")
            return 2
        }
        // QUIC has no cleartext form, so HTTP/3 without a certificate is not a
        // degraded mode; it is nothing at all.
        if config.http3Enabled && config.tlsCertPath == nil {
            Log.error("--http3 needs --tls-cert and --tls-key")
            return 2
        }
        if config.http3Enabled && config.unixPath != nil {
            Log.error("--http3 cannot be served over a unix socket")
            return 2
        }
        // Both of these are about sending browsers to the TLS port, so without one
        // they are a mistake rather than a no-op.
        if config.redirectHTTPPort != 0 {
            if !config.tlsEnabled {
                Log.error("--redirect-http sends clients to https; it needs --tls-cert or --acme-domain")
                return 2
            }
            if config.unixPath != nil {
                Log.error("--redirect-http has no https port to send clients to on a unix socket")
                return 2
            }
            if config.redirectHTTPPort == config.port {
                Log.error("--redirect-http needs a port of its own, not the TLS port")
                return 2
            }
        }
        if hstsSeconds >= 0 {
            if !config.tlsEnabled {
                Log.error("--hsts is only ever sent over TLS; it needs --tls-cert or --acme-domain")
                return 2
            }
            (config.hsts, config.hstsLength) = makeHSTS(seconds: hstsSeconds)
        }
        // A client cannot discover HTTP/3 by trying: there is no upgrade and no
        // well-known port. It has to be told, on a connection it already has, which
        // is what Alt-Svc is for (RFC 7838). Purely advisory -- a client that
        // ignores it stays on TCP and everything still works.
        if config.http3Enabled {
            let udp = config.quicPort != 0 ? config.quicPort : config.port
            (config.altSvc, config.altSvcLength) = makeAltSvc(port: udp)
        }

        if !portSet {
            config.serverPortString = makeCString(Int(config.port))
        }

        return Garuda.run(config: config)
    }
}

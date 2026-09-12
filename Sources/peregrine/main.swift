//===----------------------------------------------------------------------===//
// Command line entry point.
//
// Arguments are read straight out of `argv`, which the kernel keeps alive for
// the life of the process, so configuration parsing allocates nothing and every
// configured string is a pointer into memory we did not have to manage.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CPeregrine
import PeregrineCore
import PeregrinePython
import PeregrineServer

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

func printUsage() {
    let usage: StaticString = """
    peregrine -- a Python ASGI/WSGI server written in Swift

    usage: peregrine [options] MODULE:ATTRIBUTE

      --host HOST              interface to bind (default 127.0.0.1)
      --port PORT              port to bind (default 8000)
      --unix PATH              listen on a unix socket instead
      --workers N              worker processes, 0 = one per CPU (default 1)
      --free-threaded          run the workers as threads of one process
                               instead of as processes; needs a free-threaded
                               CPython (python3.13t or newer)
      --protocol wsgi|asgi     force the application protocol (default: detect)
      --factory                the target is a factory returning the application
      --root-path PATH         SCRIPT_NAME / ASGI root_path prefix
      --scheme http|https      scheme reported to the application
      --backlog N              listen backlog (default 2048)
      --max-connections N      concurrent connections per worker (default 4096)
      --max-body BYTES         largest accepted request body (default 16 MiB)
      --max-header-size BYTES  largest accepted request head (default 32 KiB)
      --keep-alive MS          idle keep-alive timeout (default 5000)
      --request-timeout MS     how long a request may stall mid-message (30000)
      --graceful-timeout MS    time in-flight requests get on shutdown (10000)
      --wsgi-threads N         WSGI application threads per worker (default 1)
      --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted:
                               a comma-separated list of addresses or CIDR
                               blocks, "unix", or "*" for every peer
      --venv DIR               virtualenv whose packages the app should import
      --no-auto-venv           ignore VIRTUAL_ENV from the environment
      --python-path DIR        directory to prepend to sys.path (repeatable)
      --python-home DIR        PYTHONHOME for the embedded interpreter
      --reload                 restart workers when source files change
      --no-uvloop              do not use uvloop even when installed
      --no-lifespan            skip the ASGI lifespan protocol
      --lifespan-scope WHICH   with --free-threaded, whether the lifespan runs
                               per worker thread (worker, the default, so that
                               what startup opens belongs to the loop that
                               awaits it) or exactly once for the process
                               (process, for start-up that opens nothing
                               loop-bound)
      --tls-cert PATH          PEM certificate chain; enables TLS with ALPN.
                               Repeatable, with a --tls-key each: the first
                               pair is the default and the rest are picked by
                               SNI, using the names inside each certificate
      --tls-key PATH           PEM private key for the preceding --tls-cert
      --tls-ciphers LIST       OpenSSL cipher list for TLS 1.2
      --no-http2               refuse HTTP/2 and answer HTTP/1.1 only
      --http2-only             serve only HTTP/2 (h2c), with no HTTP/1 fallback
      --http3                  also serve HTTP/3 over QUIC (needs TLS)
      --quic-port PORT         UDP port for HTTP/3 (default: the TCP port)
      --no-websockets          reject WebSocket upgrades with 501
      --ws-max-message BYTES   largest accepted WebSocket message (16 MiB)
      --ws-ping-interval MS    keepalive ping period, 0 to disable (20000)
      --ws-ping-timeout MS     how long an unanswered ping may go (20000)
      --ws-max-queue N         messages buffered for a slow app (default 32)
      --ws-max-queue-bytes N   bytes buffered for a slow app (default 4 MiB)
      --health-check-path P    answer P with 200 in the server, without
                               calling the application (e.g. /healthz)
      --access-log             log one line per request
      --access-log-format F    text (default) or json; implies --access-log
      --metrics-port PORT      serve Prometheus metrics on this port
      --metrics-host HOST      what the metrics port binds (default --host)
      --log-level LEVEL        debug, info, warning, error, silent
      --version                print the version and exit
      -h, --help               print this message

    examples:
      peregrine --port 8080 myapp:application
      peregrine --workers 0 --host 0.0.0.0 myapp.asgi:app
      peregrine --unix /run/app.sock --workers 4 \\
                --forwarded-allow-ips 10.0.0.0/8 myapp:app
      peregrine --wsgi-threads 8 django_project.wsgi:application
      peregrine --workers 0 --free-threaded myapp.asgi:app

    """
    _ = pg_write(1, usage.utf8Start, usage.utf8CodeUnitCount)
}

let version: StaticString = "peregrine 1.0.0"

/// Reports the build version and the CPython actually linked.
///
/// The linked interpreter is read at runtime rather than from the headers,
/// because the two can disagree: Swift links whatever `python3-embed` resolved
/// to, which is not necessarily the interpreter that ran the build. Packaging
/// checks this output to tag the wheel for the right interpreter.
func printVersion() {
    var buf = [UInt8](repeating: 0, count: 256)
    var n = 0

    @inline(__always)
    func append(_ p: UnsafePointer<UInt8>, _ count: Int) {
        let take = min(count, buf.count - n - 1)
        if take > 0 {
            _ = buf.withUnsafeMutableBufferPointer { memcpy($0.baseAddress! + n, p, take) }
            n += take
        }
    }

    append(version.utf8Start, version.utf8CodeUnitCount)
    if let raw = pg_py_runtime_version() {
        let py = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
        var len = 0
        // Py_GetVersion returns "3.12.3 (main, ...) [GCC ...]"; only the
        // version itself is wanted, so stop at the first space.
        while py[len] != 0 && py[len] != 32 { len += 1 }
        let prefix: StaticString = " (CPython "
        append(prefix.utf8Start, prefix.utf8CodeUnitCount)
        append(py, len)
        // A free-threaded interpreter is a different ABI, not a different
        // setting, so it belongs in the same breath as the version. Packaging
        // reads this line to decide which wheel tag the binary is for.
        if pg_py_free_threaded() != 0 {
            let ft: StaticString = " free-threaded"
            append(ft.utf8Start, ft.utf8CodeUnitCount)
        }
        let suffix: StaticString = ")"
        append(suffix.utf8Start, suffix.utf8CodeUnitCount)
    }
    let newline: StaticString = "\n"
    append(newline.utf8Start, newline.utf8CodeUnitCount)
    buf.withUnsafeBufferPointer { _ = pg_write(1, $0.baseAddress!, n) }
}

var config = ServerConfig()

// --tls-cert and --tls-key are repeatable and paired by the order they appear,
// so that a server with several names carries several certificates. The first
// pair is the default; the rest are chosen by SNI.
var tlsCerts: [UnsafePointer<CChar>] = []
var tlsKeys: [UnsafePointer<CChar>] = []
var sawApp = false
var schemeGiven = false
var portSet = false

let argc = Int(CommandLine.argc)
let argv = CommandLine.unsafeArgv
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
        exit(0)
    } else if matches(arg, "--version") {
        printVersion()
        exit(0)
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
    } else if matches(arg, "--free-threaded") {
        config.freeThreaded = true
    } else if matches(arg, "--protocol") {
        guard let v = next("--protocol needs wsgi or asgi") else { break }
        if matches(v, "wsgi") {
            config.appProtocol = .wsgi
        } else if matches(v, "asgi") {
            config.appProtocol = .asgi
        } else {
            Log.error("--protocol must be wsgi or asgi")
            failed = true
            break
        }
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
    } else if matches(arg, "--tls-ciphers") {
        guard let v = next("--tls-ciphers needs an OpenSSL cipher list") else { break }
        config.tlsCiphers = v
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
    } else if matches(arg, "--wsgi-threads") {
        guard let v = next("--wsgi-threads needs a value") else { break }
        config.wsgiThreads = max(1, parseInt(v))
    } else if matches(arg, "--factory") {
        config.appIsFactory = true
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
    } else if matches(arg, "--venv") {
        guard let v = next("--venv needs a directory") else { break }
        config.venvPath = v
    } else if matches(arg, "--no-auto-venv") {
        config.noAutoVenv = true
    } else if matches(arg, "--http3") {
        config.http3Enabled = true
    } else if matches(arg, "--quic-port") {
        guard let v = next("--quic-port needs a port") else { break }
        let p = parseInt(v)
        if p <= 0 || p > 65535 {
            Log.error("--quic-port must be between 1 and 65535")
            exit(2)
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
    } else if matches(arg, "--python-path") {
        guard let v = next("--python-path needs a directory") else { break }
        config.pythonPaths.append(v)
    } else if matches(arg, "--python-home") {
        guard let v = next("--python-home needs a directory") else { break }
        config.pythonHome = v
    } else if matches(arg, "--no-uvloop") {
        config.preferUvloop = false
    } else if matches(arg, "--no-lifespan") {
        config.callLifespan = false
    } else if matches(arg, "--lifespan-scope") {
        guard let v = next("--lifespan-scope needs worker or process") else { break }
        if matches(v, "worker") { config.lifespanScope = .perWorker }
        else if matches(v, "process") || matches(v, "once") { config.lifespanScope = .once }
        else {
            Log.error("unknown --lifespan-scope; use worker or process")
            failed = true
            break
        }
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
        config.appSpec = arg
        sawApp = true
    }
}

if failed {
    exit(2)
}

// Pair the certificates with their keys, in the order they were given. An
// unequal count is a mistake worth stopping for: pairing what is there and
// ignoring the remainder would serve the wrong certificate for a name, which
// shows up as a browser warning rather than as an error here.
if tlsCerts.count != tlsKeys.count {
    Log.error("--tls-cert and --tls-key go together, one key per certificate")
    exit(2)
}
if let cert = tlsCerts.first, let key = tlsKeys.first {
    config.tlsCertPath = cert
    config.tlsKeyPath = key
    config.tlsExtraCerts = Array(zip(tlsCerts.dropFirst(), tlsKeys.dropFirst()))
        .map { (cert: $0.0, key: $0.1) }
}

// Workers as threads only mean anything on an interpreter that can run them in
// parallel. Refusing here rather than at start-up means the answer arrives
// before a listening socket exists, and names the interpreter that was linked.
if config.freeThreaded && pg_py_free_threaded() == 0 {
    Log.error("--free-threaded needs a CPython built without the GIL (PEP 703):")
    Log.error("python3.13t or newer. This binary is linked against a standard build.")
    exit(2)
}

// A TLS listener is https, and every URL the application builds should say so.
// An explicit --scheme still wins: someone behind a terminating proxy may have
// a reason.
if config.tlsEnabled && !schemeGiven {
    config.scheme = staticCString("https")
}
if (config.tlsCertPath == nil) != (config.tlsKeyPath == nil) {
    Log.error("--tls-cert and --tls-key go together")
    exit(2)
}
// QUIC has no cleartext form, so HTTP/3 without a certificate is not a
// degraded mode; it is nothing at all.
if config.http3Enabled && config.tlsCertPath == nil {
    Log.error("--http3 needs --tls-cert and --tls-key")
    exit(2)
}
if config.http3Enabled && config.unixPath != nil {
    Log.error("--http3 cannot be served over a unix socket")
    exit(2)
}
// A client cannot discover HTTP/3 by trying: there is no upgrade and no
// well-known port. It has to be told, on a connection it already has, which
// is what Alt-Svc is for (RFC 7838). Purely advisory -- a client that
// ignores it stays on TCP and everything still works.
if config.http3Enabled {
    let udp = config.quicPort != 0 ? config.quicPort : config.port
    (config.altSvc, config.altSvcLength) = makeAltSvc(port: udp)
}

if !sawApp {
    printUsage()
    Log.error("no application given")
    exit(2)
}

if !portSet {
    config.serverPortString = makeCString(Int(config.port))
}

exit(Peregrine.run(config: config))

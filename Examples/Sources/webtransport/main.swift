//===----------------------------------------------------------------------===//
// The WebTransport probe.
//
// WebTransport runs over HTTP/3, which needs TLS. For a browser to trust a
// self-signed certificate over WebTransport, the certificate must be ECDSA
// and valid for at most 14 days; the page fetches its hash from the server.
//
//   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
//       -days 14 -nodes -keyout key.pem -out cert.pem -subj /CN=localhost \
//       -addext subjectAltName=DNS:localhost,IP:127.0.0.1
//   swift run webtransport -- --port 8443 --tls-cert cert.pem --tls-key key.pem
//
// Then open https://localhost:8443, accept the certificate warning for the
// page itself, and press the button. `--http3` is added when it is not given.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import WebTransportExample

// A leading `--` is what `swift run webtransport -- --port 8443` leaves behind.
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--" { arguments.removeFirst() }

/// Writes a line to standard error.
func complain(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}

guard let flag = arguments.firstIndex(of: "--tls-cert"), flag + 1 < arguments.count else {
    complain("WebTransport needs HTTP/3, and HTTP/3 needs --tls-cert and --tls-key.\n"
             + "See the top of Sources/webtransport/main.swift for making a certificate.")
    exit(2)
}
if !arguments.contains("--http3") { arguments.append("--http3") }

/// The whole of a small file, or nil.
func contents(of path: String) -> String? {
    guard let file = fopen(path, "r") else { return nil }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = fread(&chunk, 1, chunk.count, file)
        if n == 0 { break }
        bytes += chunk[0..<n]
    }
    return String(decoding: bytes, as: UTF8.self)
}

let hash = contents(of: arguments[flag + 1]).flatMap { certificateHash(pem: $0) }
if hash == nil {
    complain("could not read a certificate from \(arguments[flag + 1]); the page will not find its hash")
}
exit(webTransportApp(certificateHash: hash).run(arguments: arguments))

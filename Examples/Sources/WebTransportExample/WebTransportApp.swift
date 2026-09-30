//===----------------------------------------------------------------------===//
// A network probe over WebTransport: round trips on datagrams, throughput on
// streams, one session per client.
//
//   GET     /                      a page that runs the probe from a browser
//   GET     /certificate-hash      the SHA-256 of the server's certificate,
//                                  which a browser needs to trust a
//                                  self-signed one for WebTransport
//   CONNECT /probe?name=ada        the session (HTTP/3 extended CONNECT)
//
// Inside a session:
//
//   - The server opens a unidirectional stream as soon as the session starts
//     and writes a greeting on it: the session's id and the largest datagram
//     the client may send.
//   - Every datagram is sent straight back, so the client can time the round
//     trip. Datagrams are unreliable: one that is lost is a lost sample, not
//     an error.
//   - Each bidirectional stream the client opens carries one command, a line
//     of text, and then its data:
//         echo\n<bytes>        the bytes come back
//         download N\n         N bytes come back (at most 256 MiB)
//         upload\n<bytes>      {"bytes": n} comes back once the client finishes
//     A command the server does not know resets the stream, and that stream
//     alone.
//   - A unidirectional stream from the client is read and thrown away.
//
// What it shows:
//
// - `app.webTransport` with an extractor. The session is a route like any
//   other until it is accepted: `Query<Hello>` runs first, and a CONNECT
//   without `name` is answered 400 and never becomes a session.
// - One task group per session: datagrams in one child, and a child per
//   stream, so a slow download does not hold up a round-trip sample. The
//   children run on the worker's thread, as a session requires; an
//   unstructured `Task { }` would not.
// - Backpressure both ways. `write` waits while too much is queued on the
//   stream, so a download to a slow client costs memory for what is in
//   flight, not for all N bytes. `read` gives the client more room only as
//   the handler reads, so an upload to a slow handler slows the client.
//
// A session lives on one worker, and everything here is per session, so any
// number of workers serves it. Sessions that must hear each other -- a game
// room, say -- need that to happen outside the worker, as the chat example
// does for WebSockets with `Topic`.
//===----------------------------------------------------------------------===//

import Garuda

/// What a client says when it opens a session.
public struct Hello: Decodable, Sendable {
    public let name: String
}

/// What the server writes on the stream it opens at the start of a session.
public struct Greeting: Codable, Equatable, Sendable {
    public let session: UInt64
    public let name: String
    public let maxDatagramSize: Int
}

/// One command on a bidirectional stream.
public enum ProbeCommand: Equatable, Sendable {
    case echo
    case download(Int)
    case upload
}

/// The most a `download` may ask for.
public let maximumDownload = 256 << 20

/// The probe. `certificateHash` is the SHA-256 of the certificate the server
/// presents, when there is one to publish.
public func webTransportApp(certificateHash: [UInt8]? = nil) -> Application {
    let app = Application()

    app.get("/") { () in HTML(probePage) }

    app.get("/certificate-hash") { () throws -> JSON<[String: String]> in
        guard let certificateHash else { throw HTTPError.notFound }
        return JSON(["sha256": hex(certificateHash)])
    }
        .summary("The SHA-256 of the server's certificate, for serverCertificateHashes")

    app.webTransport("/probe") { (session: WebTransportSession, hello: Query<Hello>) async throws in
        // A name is for the greeting only, so it is kept short rather than
        // refused: the session has been accepted by now, and any refusal
        // belongs in an extractor, before that.
        let name = String(hello.value.name.prefix(32))
        try await greet(session, name: name)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let datagram = try await session.receiveDatagram() {
                    session.sendDatagram(datagram)
                }
            }
            while let stream = try await session.acceptStream() {
                group.addTask {
                    do {
                        try await serve(stream)
                    } catch let error as WebTransportError where error == .closed {
                        // The session ended under the stream; so does the rest.
                    } catch {
                        // One stream's trouble is its own.
                        stream.reset(code: 1)
                    }
                }
            }
            // The session has ended, and with it the datagram reader.
            try await group.waitForAll()
        }
    }

    return app
}

/// Opens a unidirectional stream and says who the client is talking to.
func greet(_ session: WebTransportSession, name: String) async throws {
    let greeting = Greeting(session: session.id, name: name,
                            maxDatagramSize: session.maxDatagramSize)
    let out = try session.openStream(bidirectional: false)
    try await out.write(try JSONCoder.encode(greeting))
    out.finish()
}

/// Serves one stream the client opened.
func serve(_ stream: WebTransportStream) async throws {
    guard stream.isBidirectional else {
        // A stream to throw away, which is what an upload test with no
        // answer looks like.
        while try await stream.read() != nil {}
        return
    }
    guard let (line, rest) = try await readLine(stream), let command = ProbeCommand(line) else {
        stream.reset(code: 2)
        return
    }
    switch command {
    case .echo:
        if !rest.isEmpty { try await stream.write(rest) }
        while let bytes = try await stream.read() { try await stream.write(bytes) }

    case .download(let count):
        // Written a chunk at a time; each write waits while the stream holds
        // more than the server's high-water mark.
        let chunk = [UInt8](repeating: 0x2E, count: 64 * 1024)
        var left = count
        while left > 0 {
            let n = min(left, chunk.count)
            try await stream.write(n == chunk.count ? chunk : Array(chunk[0..<n]))
            left -= n
        }
        // Anything the client sends after the command is not wanted.
        while try await stream.read() != nil {}

    case .upload:
        var total = rest.count
        while let bytes = try await stream.read() { total += bytes.count }
        try await stream.write(try JSONCoder.encode(["bytes": total]))
    }
    stream.finish()
}

/// The first line on a stream, and whatever came after it in the same read.
/// Nil when the stream ends first, or the line runs past 64 bytes: no command
/// is that long.
func readLine(_ stream: WebTransportStream) async throws -> (String, [UInt8])? {
    var buffer: [UInt8] = []
    while true {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            return (String(decoding: buffer[..<newline], as: UTF8.self),
                    Array(buffer[(newline + 1)...]))
        }
        if buffer.count > 64 { return nil }
        guard let bytes = try await stream.read() else { return nil }
        buffer += bytes
    }
}

extension ProbeCommand {
    /// Reads a command line: `echo`, `upload`, or `download N` with N from 0
    /// to `maximumDownload`.
    public init?(_ line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        switch (words.first, words.count) {
        case ("echo", 1): self = .echo
        case ("upload", 1): self = .upload
        case ("download", 2):
            guard let count = Int(words[1]), (0...maximumDownload).contains(count) else { return nil }
            self = .download(count)
        default: return nil
        }
    }
}

// MARK: - Certificates

/// The SHA-256 of the first certificate in a PEM file: what a browser's
/// `serverCertificateHashes` names. Nil when the text holds no certificate.
public func certificateHash(pem: String) -> [UInt8]? {
    let text = Array(pem.utf8)
    let begin = Array("-----BEGIN CERTIFICATE-----".utf8)
    let end = Array("-----END CERTIFICATE-----".utf8)
    guard let start = find(begin, in: text, from: 0),
          let stop = find(end, in: text, from: start + begin.count),
          let der = decodeBase64(String(decoding: text[(start + begin.count)..<stop], as: UTF8.self)),
          !der.isEmpty else { return nil }
    return Digest.sha256(der)
}

/// Where `needle` first occurs in `haystack` at or after `from`.
private func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
    guard needle.count <= haystack.count else { return nil }
    var i = from
    while i + needle.count <= haystack.count {
        if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
        i += 1
    }
    return nil
}

/// Standard base64, ignoring whitespace. Nil for anything else.
func decodeBase64(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    var accumulator: UInt32 = 0
    var bits = 0
    var padding = 0
    for byte in text.utf8 {
        let value: UInt32
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(byte - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(byte - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(byte - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): value = 62
        case UInt8(ascii: "/"): value = 63
        case UInt8(ascii: "="): padding += 1; continue
        case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"): continue
        default: return nil
        }
        if padding > 0 { return nil }
        accumulator = accumulator << 6 | value
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
        }
    }
    return padding <= 2 ? out : nil
}

func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return out
}

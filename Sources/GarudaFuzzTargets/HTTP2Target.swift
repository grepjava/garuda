//===----------------------------------------------------------------------===//
// HTTP/2, a whole connection at a time.
//
// The frame layer has no parser of its own to call: a frame header is nine
// fixed bytes, and everything interesting -- SETTINGS, flow control, stream
// states, padding, CONTINUATION, the header blocks -- happens in the
// connection. So the input goes where a client's bytes go, after the preface
// and SETTINGS, into a connection served exactly as a shard serves one
// (GarudaTesting's in-memory duplex), and the checks are on what comes back:
//
//   * the connection ends once the client has stopped sending, whatever the
//     input left half-done: a connection that waits forever on a peer that
//     has gone is a resource anyone can pin;
//   * every frame the server sends is one a client can read -- the lengths a
//     frame of its type must have, nothing on a stream the client could not
//     have opened, and header blocks that decode, in order, through one
//     HPACK decoder, as a client's would.
//===----------------------------------------------------------------------===//

@_spi(Garuda) import VegaHTTP2Core
import Garuda
import GarudaTesting
import GarudaWire

enum HTTP2Fixture {
    /// Routes that answer at once, read a body, and send one larger than a
    /// window, so a fuzzed connection has flow control to get wrong.
    nonisolated(unsafe) static let client: TestClient = {
        let app = Application()
        app.get("/") { _, response in response.send(status: .ok) }
        app.post("/echo") { request, response in response.send(request.body) }
        app.get("/big") { _, response in response.send([UInt8](repeating: 0x61, count: 100_000)) }
        return app.test
    }()
}

extension Fuzz {

    static func h2(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let connection: HTTP2TestConnection
        do {
            connection = try HTTP2Fixture.client.http2()
        } catch {
            return "no connection to fuzz: \(error)"
        }
        connection.timeout = .seconds(5)
        do {
            if n > 0 { try connection.send(raw: Array(UnsafeBufferPointer(start: base, count: n))) }
        } catch TestClientError.timedOut {
            return "the server stopped reading before \(n) bytes were written"
        } catch {
            // It closed first: what it sent is still checked.
        }
        connection.close()
        do {
            // Reads, acknowledging and crediting as a client does, until the
            // server closes.
            while try connection.nextFrame(where: { _ in false }) != nil {}
        } catch TestClientError.timedOut {
            return "the connection was still open \(connection.timeout) after the client stopped sending"
        } catch {
            return "reading the server: \(error)"
        }
        return legible(connection.frames)
    }

    /// The frames a server sent, as a client must be able to read them.
    private static func legible(_ frames: [TestFrame]) -> String? {
        var decoder = HPACKDecoder()
        defer { decoder.destroy() }
        var block: [UInt8] = []
        var blockStream: UInt32? = nil
        for (i, f) in frames.enumerated() {
            if let stream = blockStream, f.kind != .continuation || f.stream != stream {
                return "frame \(i), a \(f.type), interrupts a header block on stream \(stream)"
            }
            // No push is enabled, so the server opens no streams: anything on
            // an even stream is on one the client cannot have opened. Except
            // RST_STREAM, the answer to a frame the client sent on whatever
            // stream it chose -- a PRIORITY that depends on its own stream is
            // a stream error on that stream (RFC 9113 section 5.3.1).
            if f.stream != 0 && f.stream & 1 == 0 && f.kind != .rstStream {
                return "frame \(i), a \(f.type), on stream \(f.stream)"
            }
            if f.payload.count > HTTP2FrameHeader.defaultMaxFrameSize {
                return "frame \(i) is \(f.payload.count) bytes, past the client's maximum"
            }
            switch f.kind {
            case .settings:
                if f.stream != 0 || (f.has(.ack) ? !f.payload.isEmpty : f.payload.count % 6 != 0) {
                    return "frame \(i): SETTINGS of \(f.payload.count) bytes on stream \(f.stream)"
                }
            case .ping:
                if f.stream != 0 || f.payload.count != 8 { return "frame \(i): PING of \(f.payload.count) bytes" }
            case .goaway:
                if f.stream != 0 || f.payload.count < 8 { return "frame \(i): GOAWAY of \(f.payload.count) bytes" }
            case .windowUpdate:
                if f.payload.count != 4 { return "frame \(i): WINDOW_UPDATE of \(f.payload.count) bytes" }
                let increment = UInt32(f.payload[0]) << 24 | UInt32(f.payload[1]) << 16
                    | UInt32(f.payload[2]) << 8 | UInt32(f.payload[3])
                if increment & 0x7FFF_FFFF == 0 { return "frame \(i): a WINDOW_UPDATE of nothing" }
            case .rstStream:
                if f.stream == 0 || f.payload.count != 4 { return "frame \(i): RST_STREAM on \(f.stream)" }
            case .data:
                if f.stream == 0 { return "frame \(i): DATA on stream 0" }
            case .headers:
                if f.stream == 0 { return "frame \(i): HEADERS on stream 0" }
                var payload = f.payload[...]
                if f.has(.padded) {
                    guard let pad = payload.first, Int(pad) < payload.count else {
                        return "frame \(i): HEADERS padded past its end"
                    }
                    payload = payload.dropFirst().dropLast(Int(pad))
                }
                if f.has(.priority) { payload = payload.dropFirst(5) }
                block = Array(payload)
                blockStream = f.stream
            case .continuation:
                guard blockStream == f.stream else { return "frame \(i): CONTINUATION with no header block" }
                block += f.payload
            case .pushPromise:
                return "frame \(i): PUSH_PROMISE, with push disabled"
            default:
                break
            }
            if blockStream != nil, f.kind == .headers || f.kind == .continuation, f.has(.endHeaders) {
                // One decoder across every block: HPACK is stateful, and a
                // block the client cannot decode leaves it unable to decode
                // any block after it.
                let count = block.count
                if block.isEmpty { block = [0] }
                let failed = block.withUnsafeBufferPointer { p -> Bool in
                    (try? decoder.decode(p.baseAddress!, count) { _ in }) == nil
                }
                if failed { return "frame \(i): a header block on stream \(f.stream) that does not decode" }
                blockStream = nil
            }
        }
        if let stream = blockStream { return "the connection ended inside a header block on stream \(stream)" }
        return nil
    }
}

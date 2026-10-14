//===----------------------------------------------------------------------===//
// Informational responses: 1xx heads ahead of the final answer.
//
//     app.get("/page") { _, response in
//         await response.sendInterim(status: HTTPStatus(103),
//                                    headers: [("link", "</app.css>; rel=preload; as=style")])
//         let page = try await render()          // the client fetches app.css meanwhile
//         response.send(html: page)
//     }
//
// Sent at once, not with the answer: 103 Early Hints is only worth anything
// while the handler is still working. Over HTTP/1.1 it goes behind whatever
// pipelined answers were still to go; over HTTP/2 it is a HEADERS frame of
// its own on the stream. HTTP/1.0 has no interim responses, and neither has
// a request once its final answer has been decided.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega
import VegaIO

extension Response {
    /// Sends an informational response ahead of the final one: 103 Early
    /// Hints, 104 Upload Resumption Supported. False, and nothing sent, once
    /// the final response has been decided, for a status outside 100-199 or
    /// 101, for a header that is not a valid field, and to an HTTP/1.0
    /// client.
    @discardableResult
    public func sendInterim(status: HTTPStatus, headers: [(String, String)] = []) async -> Bool {
        let x = exchange
        let code = status.code
        guard !x.pointee.answered, !x.pointee.committed, code >= 100, code < 200, code != 101 else { return false }
        var fields: [([UInt8], [UInt8])] = []
        for (name, value) in headers {
            let n = Array(name.utf8).map(asciiLower)
            let v = Array(value.utf8)
            guard !n.isEmpty, n.allSatisfy(isTokenChar), v.allSatisfy(isFieldValueChar) else { return false }
            fields.append((n, v))
        }
        switch x.pointee.link {
        case .http1(let held, let parts, let limits):
            if x.pointee.head.httpMinor == 0 { return false }
            HTTPResponseWriter.writeStatusLine(&parts.pointee.output, status: code)
            for (name, value) in fields {
                name.withUnsafeBufferPointer { n in
                    value.withUnsafeBufferPointer { v in
                        _ = HTTPResponseWriter.writeHeader(&parts.pointee.output,
                                                           name: ByteSpan(n.baseAddress!, n.count),
                                                           value: ByteSpan(v.baseAddress ?? n.baseAddress!, v.count))
                    }
                }
            }
            HTTPResponseWriter.endHead(&parts.pointee.output)
            let output = parts.pointee.output
            do {
                try await Runtime.withIODeadline(limits.writeTimeout) { () async throws(IOError) -> Void in
                    try await held.write(UnsafeRawBufferPointer(start: output.readPointer,
                                                                count: output.readableBytes))
                }
            } catch {
                parts.pointee.output.clear()
                return false
            }
            parts.pointee.output.clear()
            return true
        case .http2(let stream):
            let s = stream.takeUnretainedValue()
            return s.connection.sendInterim(s, status: code, fields: fields)
        case .none:
            return false
        }
    }
}

extension H2Connection {
    /// Queues an interim head for `s` with the control frames, which go out
    /// before any answer. False once the stream has been reset.
    func sendInterim(_ s: H2Stream, status: Int, fields: [([UInt8], [UInt8])]) -> Bool {
        let encoder = HPACKEncoder()
        var block = ByteBuffer()
        defer { block.destroy() }
        encoder.encodeStatus(status, into: &block)
        for (name, value) in fields {
            name.withUnsafeBufferPointer { n in
                value.withUnsafeBufferPointer { v in
                    encoder.encode(name: n.baseAddress!, nameLength: n.count,
                                   value: v.baseAddress ?? emptyBlock, valueLength: v.count, into: &block)
                }
            }
        }
        return lock.withLock { _ -> Bool in
            guard !s.reset, !stopping else { return false }
            writeHeaderBlock(&block, stream: s.id, endStream: false, frameSize: peerMaxFrameSize, into: &control)
            wake.notifyOne()
            return true
        }
    }
}

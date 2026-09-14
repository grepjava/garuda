//===----------------------------------------------------------------------===//
// Synchronous router at the dispatch seam.
//
// Routes are matched on method and path bytes. The response is written straight
// into the connection write buffer, or a continuation is parked when the
// handler must wait (GET /delay/:ms).
//
// The contract is the-benchmarker's, plus a timer spike:
//   GET  /          200, empty body
//   GET  /user/:id  200, the id as the body
//   POST /user      200, empty body
//   GET  /delay/:ms 200 after ms (clamped 1..5000), empty body
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

public enum Route {
    case hello
    case user(UnsafePointer<UInt8>, Int)
    case createUser
    case delay(UInt64)
}

public enum Router {
    @inline(__always)
    public static func match(method: HTTPMethod,
                             path: UnsafePointer<UInt8>,
                             count: Int) -> Route? {
        if method == .get {
            if count == 1 && path[0] == 0x2F { return .hello }
            if count > 6 && path[0] == 0x2F
                && path[1] == 0x75 && path[2] == 0x73 && path[3] == 0x65
                && path[4] == 0x72 && path[5] == 0x2F {
                return .user(path + 6, count - 6)
            }
            // /delay/ then one or more digits
            if count > 7 && path[0] == 0x2F
                && path[1] == 0x64 && path[2] == 0x65 && path[3] == 0x6C
                && path[4] == 0x61 && path[5] == 0x79 && path[6] == 0x2F {
                var ms: UInt64 = 0
                var i = 7
                var digits = 0
                while i < count {
                    let d = path[i]
                    if d < 0x30 || d > 0x39 { return nil }
                    ms = ms &* 10 &+ UInt64(d &- 0x30)
                    digits += 1
                    if digits > 5 { return nil }
                    i += 1
                }
                if digits == 0 { return nil }
                if ms < 1 { ms = 1 }
                if ms > 5000 { ms = 5000 }
                return .delay(ms)
            }
            return nil
        }
        if method == .post {
            if count == 5
                && path[0] == 0x2F && path[1] == 0x75 && path[2] == 0x73
                && path[3] == 0x65 && path[4] == 0x72 {
                return .createUser
            }
            return nil
        }
        return nil
    }
}

extension Worker {
    /// Answers a matched route, or 404, writing straight into the connection.
    mutating func respondRoute(_ slot: Int) {
        let c = table[slot]
        let path = c.pointee.head.path
        let base = c.pointee.headBase() + Int(path.offset)
        let route = Router.match(method: c.pointee.head.method,
                                 path: base,
                                 count: path.count)
        switch route {
        case .hello, .createUser:
            writeSwiftResponse(slot, status: 200, body: nil, bodyCount: 0)
        case .user(let id, let n):
            writeSwiftResponse(slot, status: 200, body: id, bodyCount: n)
        case .delay(let ms):
            // Streams have no body path for delay yet; answer immediately.
            if c.pointee.isStream {
                if c.pointee.isH3Stream {
                    h3FailRequest(slot, status: 200)
                } else {
                    h2FailRequest(slot, status: 200)
                }
                return
            }
            if !armDelay(slot, ms: ms) {
                failRequest(slot, status: 503)
            }
        case nil:
            failRequest(slot, status: 404)
        }
    }

    mutating func writeSwiftResponse(_ slot: Int, status: Int,
                                     body: UnsafePointer<UInt8>?, bodyCount: Int) {
        let c = table[slot]
        if c.pointee.isH3Stream {
            h3FailRequest(slot, status: status)
            return
        }
        if c.pointee.isStream {
            h2FailRequest(slot, status: status)
            return
        }
        logAccess(slot, status: status)
        dates.refresh()
        let suppress = c.pointee.head.method.hasNoResponseBody
        let n = suppress ? 0 : bodyCount
        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: status)
        HTTPResponseWriter.writeDate(&c.pointee.write, dates)
        c.pointee.write.write("Server: garuda\r\n")
        HTTPResponseWriter.writeContentLength(&c.pointee.write, n)
        HTTPResponseWriter.writeConnection(&c.pointee.write,
                                           keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&c.pointee.write)
        if n > 0, let body {
            c.pointee.write.write(body, n)
        }
        c.pointee.state = .writing
        _ = flush(slot)
    }
}

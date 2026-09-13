//===----------------------------------------------------------------------===//
// permessage-deflate: which offers are accepted, and what the server answers.
//===----------------------------------------------------------------------===//

import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

/// The response header value for these Sec-WebSocket-Extensions values, or nil.
private func answer(_ values: String...) -> String? {
    var storage = values.map { value -> [UInt8] in
        var bytes = Array(value.utf8)
        bytes.append(0)
        return bytes
    }
    let spans = storage.indices.map { i in
        storage[i].withUnsafeMutableBufferPointer { ByteSpan(UnsafePointer($0.baseAddress!), $0.count - 1) }
    }
    guard let agreement = WSDeflate.negotiate(spans) else {
        _ = storage
        return nil
    }
    var out = ByteBuffer()
    defer { out.destroy() }
    agreement.writeResponse(into: &out)
    _ = storage
    return String(decoding: UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes),
                  as: UTF8.self)
}

@Test("a plain offer is accepted as it is")
func deflatePlainOffer() {
    #expect(answer("permessage-deflate") == "permessage-deflate")
    #expect(answer("PerMessage-Deflate") == "permessage-deflate")
}

@Test("a client that may be told a window is told 12 bits, or less if it asked")
func deflateClientWindow() {
    #expect(answer("permessage-deflate; client_max_window_bits")
            == "permessage-deflate; client_max_window_bits=12")
    #expect(answer("permessage-deflate; client_max_window_bits=15")
            == "permessage-deflate; client_max_window_bits=12")
    #expect(answer("permessage-deflate; client_max_window_bits=10")
            == "permessage-deflate; client_max_window_bits=10")
    #expect(answer("permessage-deflate; client_max_window_bits=\"9\"")
            == "permessage-deflate; client_max_window_bits=9")
}

@Test("a server window limit is agreed to, but not one zlib cannot keep")
func deflateServerWindow() {
    #expect(answer("permessage-deflate; server_max_window_bits=10")
            == "permessage-deflate; server_max_window_bits=10")
    #expect(answer("permessage-deflate; server_max_window_bits=8") == nil)
    #expect(answer("permessage-deflate; server_max_window_bits") == nil)
    #expect(answer("permessage-deflate; server_max_window_bits=16") == nil)
    #expect(answer("permessage-deflate; server_max_window_bits=09") == nil)
}

@Test("no_context_takeover is echoed in both directions")
func deflateNoContextTakeover() {
    #expect(answer("permessage-deflate; client_no_context_takeover; server_no_context_takeover")
            == "permessage-deflate; server_no_context_takeover; client_no_context_takeover")
    #expect(answer("permessage-deflate; server_no_context_takeover=1") == nil)
}

@Test("an offer that cannot be honoured is passed over for the next")
func deflateFallsThrough() {
    #expect(answer("permessage-deflate; x=1, permessage-deflate") == "permessage-deflate")
    #expect(answer("x-webkit-deflate-frame", "permessage-deflate; client_max_window_bits")
            == "permessage-deflate; client_max_window_bits=12")
    #expect(answer("permessage-deflate; server_no_context_takeover; server_no_context_takeover")
            == nil)
    #expect(answer("permessage-deflate;;") == nil)
    #expect(answer("x-webkit-deflate-frame") == nil)
    #expect(answer("") == nil)
}

@Test("the agreed windows follow what was negotiated")
func deflateWindows() {
    var a = WSDeflateAgreement()
    #expect(a.deflateWindowBits == 12)
    #expect(a.inflateWindowBits == 15)
    a.serverMaxWindowBits = 9
    a.clientMaxWindowBitsOffered = true
    a.clientMaxWindowBitsValue = 8
    #expect(a.deflateWindowBits == 9)
    #expect(a.clientWindowBits == 8)
    #expect(a.inflateWindowBits == 9)
}

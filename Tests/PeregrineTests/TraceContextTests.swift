//===----------------------------------------------------------------------===//
// W3C traceparent: what is read and what is ignored.
//===----------------------------------------------------------------------===//

import Testing
@testable import PeregrineHTTP

private func valid(_ value: String) -> Bool {
    var bytes = Array(value.utf8)
    // A terminator keeps the pointer valid for an empty string.
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { TraceContext.valid($0.baseAddress!, $0.count - 1) }
}

private let trace = "4bf92f3577b34da6a3ce929d0e0e4736"
private let parent = "00f067aa0ba902b7"

@Test("the specification's own example is read")
func traceparentExample() {
    #expect(valid("00-\(trace)-\(parent)-01"))
    #expect(valid("00-\(trace)-\(parent)-00"))
}

@Test("a later version may carry more after the flags, set off by a dash")
func traceparentLaterVersion() {
    #expect(valid("01-\(trace)-\(parent)-01"))
    #expect(valid("01-\(trace)-\(parent)-01-more"))
    #expect(!valid("01-\(trace)-\(parent)-01x"))
}

@Test("version 00 is exactly 55 characters")
func traceparentVersionZeroIsExact() {
    #expect(!valid("00-\(trace)-\(parent)-01-more"))
    #expect(!valid("00-\(trace)-\(parent)-0"))
    #expect(!valid("00-\(trace)-\(parent)"))
    #expect(!valid(""))
}

@Test("version ff and all-zero IDs are invalid")
func traceparentReservedValues() {
    #expect(!valid("ff-\(trace)-\(parent)-01"))
    #expect(!valid("00-00000000000000000000000000000000-\(parent)-01"))
    #expect(!valid("00-\(trace)-0000000000000000-01"))
}

@Test("only lowercase hex, with dashes where the fields end")
func traceparentCharacters() {
    #expect(!valid("00-\(trace.uppercased())-\(parent)-01"))
    #expect(!valid("00-\(trace)-\(parent.uppercased())-01"))
    #expect(!valid("00_\(trace)-\(parent)-01"))
    #expect(!valid("00-\(trace) \(parent)-01"))
    #expect(!valid("00-4bf92f3577b34da6a3ce929d0e0e473g-\(parent)-01"))
    #expect(!valid("0x-\(trace)-\(parent)-01"))
}

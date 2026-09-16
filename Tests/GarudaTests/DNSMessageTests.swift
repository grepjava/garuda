import Testing
@testable import Garuda

/// Builds a message by hand, so a test says what is on the wire rather than
/// what some encoder thought it meant.
private struct Wire {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    /// A header with one question and `answers` answers, as a reply.
    mutating func header(id: UInt16 = 0x1234, flags: UInt16 = 0x8180,
                         questions: UInt16 = 1, answers: UInt16 = 0) {
        u16(id); u16(flags); u16(questions); u16(answers)
        u16(0); u16(0)
    }

    mutating func name(_ text: String) {
        for label in text.split(separator: ".") {
            u8(UInt8(label.utf8.count))
            bytes.append(contentsOf: Array(label.utf8))
        }
        u8(0)
    }

    /// A compression pointer to `offset`.
    mutating func pointer(to offset: Int) {
        u16(UInt16(0xc000 | offset))
    }

    mutating func question(_ text: String, type: UInt16 = 1) {
        name(text); u16(type); u16(1)
    }
}

private func parse(_ wire: Wire) throws -> DNSResponse {
    try wire.bytes.withUnsafeBytes { try DNSMessage.parse($0) }
}

private func parseError(_ wire: Wire) -> DNSError? {
    do {
        _ = try wire.bytes.withUnsafeBytes { try DNSMessage.parse($0) }
        return nil
    } catch {
        // withUnsafeBytes erases the typed throw, so the binding here is
        // `any Error` and has to be put back.
        return error as? DNSError
    }
}

@Suite("DNS messages")
struct DNSMessageTests {

    // MARK: Asking

    @Test func aQueryIsTheBytesTheRFCAsksFor() throws {
        var buffer: [UInt8] = []
        try DNSMessage.encodeQuery(id: 0xbeef, name: "alpha.example", type: .a, into: &buffer)
        #expect(buffer == [
            0xbe, 0xef,                                  // id
            0x01, 0x00,                                  // recursion desired
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            5, 97, 108, 112, 104, 97,                    // "alpha"
            7, 101, 120, 97, 109, 112, 108, 101,         // "example"
            0,                                           // root
            0x00, 0x01,                                  // A
            0x00, 0x01,                                  // IN
        ])
    }

    @Test func aTrailingDotIsTheRootAndNotAnEmptyLabel() throws {
        var withDot: [UInt8] = []
        var without: [UInt8] = []
        try DNSMessage.encodeQuery(id: 1, name: "alpha.example.", type: .a, into: &withDot)
        try DNSMessage.encodeQuery(id: 1, name: "alpha.example", type: .a, into: &without)
        #expect(withDot == without)
    }

    @Test func aQueryReusesTheBufferItIsGiven() throws {
        var buffer: [UInt8] = Array(repeating: 0xff, count: 500)
        try DNSMessage.encodeQuery(id: 1, name: "a.example", type: .aaaa, into: &buffer)
        // Replaced, not appended to: a second query in a reused buffer would
        // otherwise be sent with the first one still in front of it.
        #expect(buffer.count == 12 + 1 + 1 + 1 + 7 + 1 + 4)
        #expect(buffer[0] == 0)
        #expect(buffer[1] == 1)
    }

    @Test func anEmptyLabelIsRefused() {
        var buffer: [UInt8] = []
        #expect(throws: DNSError.badLabel) {
            try DNSMessage.encodeQuery(id: 1, name: "alpha..example", type: .a, into: &buffer)
        }
        #expect(throws: DNSError.badLabel) {
            try DNSMessage.encodeQuery(id: 1, name: ".alpha", type: .a, into: &buffer)
        }
        #expect(throws: DNSError.badLabel) {
            try DNSMessage.encodeQuery(id: 1, name: "", type: .a, into: &buffer)
        }
    }

    @Test func aLabelOverSixtyThreeBytesIsRefused() {
        var buffer: [UInt8] = []
        let label = String(repeating: "a", count: 64)
        #expect(throws: DNSError.badLabel) {
            try DNSMessage.encodeQuery(id: 1, name: "\(label).example", type: .a, into: &buffer)
        }
    }

    @Test func aNameOverTwoHundredAndFiftyFiveBytesIsRefused() {
        var buffer: [UInt8] = []
        let label = String(repeating: "a", count: 63)
        let name = [String](repeating: label, count: 5).joined(separator: ".")
        #expect(throws: DNSError.nameTooLong) {
            try DNSMessage.encodeQuery(id: 1, name: name, type: .a, into: &buffer)
        }
    }

    // MARK: Believing

    @Test func anAnswerIsRead() throws {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")
        wire.name("alpha.example")
        wire.u16(1); wire.u16(1); wire.u32(300); wire.u16(4)
        wire.bytes.append(contentsOf: [93, 184, 216, 34])

        let response = try parse(wire)
        #expect(response.id == 0x1234)
        #expect(response.isResponse)
        #expect(!response.isTruncated)
        #expect(response.responseCode == 0)
        #expect(response.questionName == "alpha.example")
        #expect(response.questionType == 1)
        #expect(response.answers == [
            DNSRecord(name: "alpha.example", ttl: 300, data: .address([93, 184, 216, 34]))
        ])
    }

    @Test func aCompressedNameIsFollowed() throws {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")
        // The owner name is a pointer back to the question at offset 12.
        wire.pointer(to: 12)
        wire.u16(1); wire.u16(1); wire.u32(60); wire.u16(4)
        wire.bytes.append(contentsOf: [10, 0, 0, 1])

        let response = try parse(wire)
        #expect(response.answers.count == 1)
        #expect(response.answers[0].name == "alpha.example")
        #expect(response.answers[0].data == .address([10, 0, 0, 1]))
    }

    @Test func anAAAARecordIsSixteenBytes() throws {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example", type: 28)
        wire.pointer(to: 12)
        wire.u16(28); wire.u16(1); wire.u32(60); wire.u16(16)
        wire.bytes.append(contentsOf: Array(repeating: 0, count: 15) + [1])

        let response = try parse(wire)
        #expect(response.answers[0].data == .address(Array(repeating: 0, count: 15) + [1]))
    }

    @Test func anAliasIsReadAsTheNameItPointsAt() throws {
        var wire = Wire()
        wire.header(answers: 2)
        wire.question("www.example")
        wire.pointer(to: 12)
        wire.u16(5); wire.u16(1); wire.u32(60)
        // The wire form is 15 bytes, not the 13 the text has: a length byte
        // before each label and a root label after them.
        wire.u16(15)
        wire.name("alpha.example")
        wire.name("alpha.example")
        wire.u16(1); wire.u16(1); wire.u32(60); wire.u16(4)
        wire.bytes.append(contentsOf: [10, 0, 0, 2])

        let response = try parse(wire)
        #expect(response.answers.count == 2)
        #expect(response.answers[0].data == .canonicalName("alpha.example"))
        #expect(response.answers[1].data == .address([10, 0, 0, 2]))
    }

    @Test func aTypeWeDoNotModelIsKeptRatherThanRefused() throws {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")
        wire.pointer(to: 12)
        wire.u16(16); wire.u16(1); wire.u32(60); wire.u16(3)   // TXT
        wire.bytes.append(contentsOf: [2, 104, 105])

        // A nameserver may send what it likes; refusing the whole reply over a
        // record nobody asked about is a resolver that breaks when somebody
        // else edits a zone.
        let response = try parse(wire)
        #expect(response.answers[0].data == .other(16))
    }

    @Test func truncationIsReported() throws {
        var wire = Wire()
        wire.header(flags: 0x8380)
        wire.question("alpha.example")
        #expect(try parse(wire).isTruncated)
    }

    @Test func aNameErrorKeepsItsCode() throws {
        var wire = Wire()
        wire.header(flags: 0x8183)
        wire.question("nope.example")
        #expect(try parse(wire).responseCode == 3)
    }

    // MARK: What a stranger can send

    /// The classic way to hang a resolver: a pointer to itself. The name never
    /// grows, so a cap on its length never fires.
    @Test func aPointerToItselfIsRefused() {
        var wire = Wire()
        wire.header()
        wire.pointer(to: 12)                            // at offset 12
        wire.u16(1); wire.u16(1)
        #expect(parseError(wire) == .badPointer)
    }

    /// Forward pointers are the other half of the same rule. A message may
    /// only refer to what has already been read.
    @Test func aForwardPointerIsRefused() {
        var wire = Wire()
        wire.header()
        wire.pointer(to: 40)
        wire.u16(1); wire.u16(1)
        wire.bytes.append(contentsOf: Array(repeating: 0, count: 24))
        #expect(parseError(wire) == .badPointer)
    }

    /// The shape a loop would have to take, refused before it can form.
    ///
    /// A pair of pointers referring to each other is the classic way to hang a
    /// resolver, but one of the two hops necessarily goes forwards, and the
    /// backwards rule refuses it there. That is why this parser needs no
    /// separate cycle detection: mutation testing showed a second condition
    /// guarding against a repeated target could never be reached, since the
    /// addresses a walk visits strictly descend.
    ///
    /// Kept as a regression test on that reasoning. If the backwards rule is
    /// ever loosened, this is the message that starts looping.
    @Test func aPairOfPointersThatWouldCycleIsRefused() {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")                  // 12...28
        let first = wire.bytes.count                    // 29
        wire.pointer(to: first + 2)                     // 29 -> 31, forwards
        wire.pointer(to: first)                         // 31 -> 29, backwards
        wire.pointer(to: first + 2)                     // owner name -> 31
        wire.u16(1); wire.u16(1); wire.u32(60); wire.u16(4)
        wire.bytes.append(contentsOf: [10, 0, 0, 1])
        // The owner name jumps back to 31, which goes back to 29 -- and 29
        // points forwards, to 31, which is where the refusal happens. A loop
        // needs that forward hop, and cannot be built without one.
        #expect(parseError(wire) == .badPointer)
    }

    /// The same rule seen from the other side: a chain that really does step
    /// further back each time is legal and must still parse, or the guard is
    /// refusing ordinary compressed messages.
    @Test func aChainThatKeepsGoingBackIsAccepted() throws {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")                  // name at 12
        wire.pointer(to: 12)                            // answer owner -> 12
        wire.u16(5); wire.u16(1); wire.u32(60)
        wire.u16(2)
        wire.pointer(to: 12)                            // its CNAME -> 12 too
        let response = try parse(wire)
        #expect(response.answers[0].name == "alpha.example")
        #expect(response.answers[0].data == .canonicalName("alpha.example"))
    }

    @Test func aLabelRunningPastTheEndIsRefused() {
        var wire = Wire()
        wire.header()
        wire.u8(40)                                     // claims forty bytes
        wire.bytes.append(contentsOf: Array("short".utf8))
        #expect(parseError(wire) == .truncated)
    }

    @Test func aReservedLabelKindIsRefused() {
        var wire = Wire()
        wire.header()
        wire.u8(0x80)                                   // neither a label nor a pointer
        wire.u8(0)
        #expect(parseError(wire) == .badLabel)
    }

    @Test func aRecordLongerThanTheDatagramIsRefused() {
        var wire = Wire()
        wire.header(answers: 1)
        wire.question("alpha.example")
        wire.pointer(to: 12)
        wire.u16(1); wire.u16(1); wire.u32(60)
        wire.u16(4000)                                  // four bytes are present
        wire.bytes.append(contentsOf: [10, 0, 0, 1])
        #expect(parseError(wire) == .truncated)
    }

    @Test func aHeaderPromisingMoreAnswersThanItSentIsRefused() {
        var wire = Wire()
        wire.header(answers: 12)
        wire.question("alpha.example")
        #expect(parseError(wire) == .truncated)
    }

    @Test func aMessageShorterThanAHeaderIsRefused() {
        var wire = Wire()
        wire.u16(0x1234); wire.u16(0x8180)
        #expect(parseError(wire) == .truncated)
    }

    /// A header claiming sixty thousand answers in a forty-byte datagram must
    /// not reserve for sixty thousand before reading the first.
    @Test func anAbsurdAnswerCountDoesNotReserveForItself() {
        var wire = Wire()
        wire.header(answers: 65535)
        wire.question("alpha.example")
        #expect(parseError(wire) == .truncated)
    }
}

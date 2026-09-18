import Testing
@testable import Garuda

// What a `Range` header asks for, against a file of a known size. RFC 9110
// section 14.1: what is a range, what is out of the file, and what is neither.

@Suite("Byte ranges")
struct ByteRangeTests {
    @Test func aRangeInsideTheFile() throws {
        #expect(parseByteRange("bytes=0-499", size: 1000) == .bytes(start: 0, length: 500))
        #expect(parseByteRange("bytes=500-999", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=0-0", size: 1000) == .bytes(start: 0, length: 1))
        #expect(parseByteRange("bytes=999-999", size: 1000) == .bytes(start: 999, length: 1))
    }

    @Test func anOpenEndIsTheRestOfTheFile() throws {
        #expect(parseByteRange("bytes=500-", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=0-", size: 1000) == .bytes(start: 0, length: 1000))
        // An end past the last byte is the last byte, not a refusal: the
        // client asked for everything from there, and there is that much.
        #expect(parseByteRange("bytes=900-5000", size: 1000) == .bytes(start: 900, length: 100))
    }

    @Test func aSuffixIsTheEndOfTheFile() throws {
        #expect(parseByteRange("bytes=-500", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=-1", size: 1000) == .bytes(start: 999, length: 1))
        // More than there is: all of it.
        #expect(parseByteRange("bytes=-5000", size: 1000) == .bytes(start: 0, length: 1000))
        // The last nothing bytes is not a range that can be served.
        #expect(parseByteRange("bytes=-0", size: 1000) == .unsatisfiable)
    }

    @Test func aRangeOutsideTheFileIs416() throws {
        #expect(parseByteRange("bytes=1000-", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=1000-1001", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=5000-6000", size: 1000) == .unsatisfiable)
        // Nothing is inside an empty file.
        #expect(parseByteRange("bytes=0-", size: 0) == .unsatisfiable)
        #expect(parseByteRange("bytes=-1", size: 0) == .unsatisfiable)
    }

    @Test func whatIsNotARangeIsIgnored() throws {
        // Section 14.2: an unsatisfiable *syntax* is not 416. The header is
        // ignored and the whole representation goes out, which is always a
        // correct answer to a GET.
        for header in ["", "bytes", "bytes=", "bytes=-", "bytes=abc", "bytes=1-2-3",
                       "items=0-10", "bytes 0-10", "bytes=0-10x", "bytes=0- 10",
                       // A range whose end is before its start.
                       "bytes=500-499"] {
            #expect(parseByteRange(header, size: 1000) == .whole, "\(header)")
        }
    }

    @Test func severalRangesAreAnsweredWhole() throws {
        // One range is served; a request for several gets the file, which
        // section 14.2 allows and this says plainly rather than half-doing
        // multipart/byteranges.
        #expect(parseByteRange("bytes=0-99,200-299", size: 1000) == .whole)
        #expect(parseByteRange("bytes=0-99, 200-299", size: 1000) == .whole)
        #expect(parseByteRange("bytes=-100,-200", size: 1000) == .whole)
    }

    @Test func whitespaceAndCaseAreWhatTheyShouldBe() throws {
        #expect(parseByteRange("BYTES=0-9", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("  bytes=0-9  ", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("bytes= 0-9", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("bytes=0-9\t", size: 100) == .bytes(start: 0, length: 10))
    }

    @Test func numbersTooBigToBeAFileAreNotTakenForOne() throws {
        // A first byte beyond any file is simply outside it.
        #expect(parseByteRange("bytes=99999999999999999999-", size: 1000) == .unsatisfiable)
        // An end beyond any file is the end of this one.
        #expect(parseByteRange("bytes=0-99999999999999999999", size: 1000) == .bytes(start: 0, length: 1000))
        #expect(parseByteRange("bytes=-99999999999999999999", size: 1000) == .bytes(start: 0, length: 1000))
    }
}

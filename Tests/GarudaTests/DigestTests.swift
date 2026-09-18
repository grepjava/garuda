import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Garuda

/// A file with these bytes in it, for the digest of a file.
private func writeFileForTest(_ path: String, _ bytes: [UInt8]) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    try #require(fd >= 0)
    defer { _ = close(fd) }
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + done, $0.count - done) }
        try #require(n > 0)
        done += n
    }
}

private func unlinkForTest(_ path: String) -> Int32 { unlink(path) }

// SHA-256, and the fields RFC 9530 carries one in.

@Suite("Digests")
struct DigestTests {
    /// The vectors everyone checks a SHA-256 against.
    @Test func knownDigests() throws {
        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }
                .joined()
        }
        #expect(hex(Digest.sha256([]))
                    == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(Digest.sha256(Array("abc".utf8)))
                    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(Digest.sha256(Array(String(repeating: "a", count: 1_000_000).utf8)))
                    == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func aStreamedDigestIsTheSameAsAWholeOne() throws {
        let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let whole = Digest.sha256(bytes)

        let streamed = SHA256Digest()
        var i = 0
        for size in [0, 1, 7, 64, 1000, 4096] {
            streamed.update(Array(bytes[i..<min(i + size, bytes.count)]))
            i = min(i + size, bytes.count)
        }
        streamed.update(Array(bytes[i...]))
        #expect(streamed.digest() == whole)

        // The digest can be taken and the hashing carried on.
        let running = SHA256Digest()
        running.update(Array("ab".utf8))
        #expect(running.digest() == Digest.sha256(Array("ab".utf8)))
        running.update(Array("c".utf8))
        #expect(running.digest() == Digest.sha256(Array("abc".utf8)))
    }

    @Test func aFieldIsWrittenAndReadBack() throws {
        let digest = Digest.sha256(Array("hello".utf8))
        let field = Digest.field(digest)
        #expect(field == "sha-256=:LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=:")
        #expect(Digest.sha256(field: field) == digest)
        // Whitespace, case, and a dictionary naming more than one.
        #expect(Digest.sha256(field: " SHA-256 = :LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=: ") == digest)
        #expect(Digest.sha256(field: "sha-512=:AAAA:, " + field) == digest)
    }

    @Test func aFieldThatNamesNothingReadableIsNil() throws {
        // An algorithm this does not know: nothing to check, rather than a
        // check that passes.
        #expect(Digest.sha256(field: "sha-512=:AAAA:") == nil)
        #expect(Digest.sha256(field: "") == nil)
        #expect(Digest.sha256(field: "sha-256") == nil)
        // Not a byte sequence.
        #expect(Digest.sha256(field: "sha-256=LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=") == nil)
        // Not base64.
        #expect(Digest.sha256(field: "sha-256=:not base64!:") == nil)
        // Base64 of the wrong length: a digest that is not SHA-256's.
        #expect(Digest.sha256(field: "sha-256=:AAAA:") == nil)
    }

    @Test func digestsCompareByValue() throws {
        let a = Digest.sha256(Array("a".utf8))
        #expect(Digest.equal(a, Digest.sha256(Array("a".utf8))))
        #expect(!Digest.equal(a, Digest.sha256(Array("b".utf8))))
        #expect(!Digest.equal(a, []), "a length that differs is not equal")
        var flipped = a
        flipped[31] ^= 1
        #expect(!Digest.equal(a, flipped), "the last byte counts as much as the first")
    }

    @Test func aFileIsHashedAPieceAtATime() throws {
        let path = "/tmp/garuda-digest-\(Timestamp.now.secondsSinceEpoch)-\(Int.random(in: 0..<1_000_000)).bin"
        let bytes = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 11) }
        try writeFileForTest(path, bytes)
        defer { _ = unlinkForTest(path) }

        #expect(Digest.sha256(contentsOfFile: path) == Digest.sha256(bytes))
        // A chunk smaller than the file, so the loop runs many times.
        #expect(Digest.sha256(contentsOfFile: path, chunkSize: 997) == Digest.sha256(bytes))
        #expect(Digest.sha256(contentsOfFile: path + ".missing") == nil)
    }
}

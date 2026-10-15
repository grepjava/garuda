//===----------------------------------------------------------------------===//
// Digests, and the HTTP fields that carry one.
//
// RFC 9530 gives two: `Content-Digest` is over the bytes of *this* message,
// and `Repr-Digest` over the whole representation however many messages it
// took. A resumable upload uses both -- one request's bytes, and the file the
// requests add up to:
//
//     let sha = Digest.sha256(bytes)
//     response.addHeader("Content-Digest", Digest.field(sha))   // sha-256=:...:
//
// Only SHA-256 is read and written. It is what the registry marks as the one
// to use, and a digest nobody checks is worse than none: a field naming an
// algorithm this does not know reads as nil, so a caller sees "nothing to
// check" rather than a false yes.
//
// `SHA256Digest` is the same hash over bytes that arrive a piece at a time,
// for a body being read. It cannot be saved and resumed in another process,
// which is why an upload spanning requests hashes its file at the end rather
// than as it goes. The hashing is VegaCrypto's.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

import VegaCrypto

public enum Digest {
    /// The SHA-256 of `bytes`.
    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Hash.sha256(bytes)
    }

    /// The SHA-256 of a file, read a piece at a time so its size does not
    /// decide how much memory this takes, on the calling thread: off the
    /// workers, on the blocking pool, unless the file is known to be small.
    /// Nil when the file cannot be read.
    public static func sha256(contentsOfFile path: String, chunkSize: Int = 256 * 1024) -> [UInt8]? {
        #if os(Windows)
        // ucrt's open is variadic, which Swift cannot call: stdio, in binary.
        guard let file = fopen(path, "rb") else { return nil }
        defer { _ = fclose(file) }
        let hash = SHA256Digest()
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, chunkSize), alignment: 1)
        defer { chunk.deallocate() }
        while true {
            let n = fread(chunk.baseAddress!, 1, chunk.count, file)
            if n == 0 {
                if ferror(file) != 0 { return nil }
                break
            }
            hash.update(UnsafeRawBufferPointer(start: chunk.baseAddress!, count: n))
        }
        return hash.digest()
        #else
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        let hash = SHA256Digest()
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, chunkSize), alignment: 1)
        defer { chunk.deallocate() }
        while true {
            let n = read(fd, chunk.baseAddress!, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hash.update(UnsafeRawBufferPointer(start: chunk.baseAddress!, count: n))
        }
        return hash.digest()
        #endif
    }

    /// A digest as `Content-Digest` and `Repr-Digest` carry it:
    /// `sha-256=:<base64>:`, the byte sequence of a structured field.
    public static func field(_ digest: [UInt8]) -> String {
        "sha-256=:" + base64(digest) + ":"
    }

    /// The SHA-256 a `Content-Digest` or `Repr-Digest` field names, or nil
    /// when it names none this understands -- an algorithm not read here, a
    /// value that is not base64, or a digest that is not 32 bytes.
    public static func sha256(field text: String) -> [UInt8]? {
        for member in text.split(separator: ",") {
            let parts = member.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            guard trimmed(parts[0]).lowercased() == "sha-256" else { continue }
            let value = trimmed(parts[1])
            // A byte sequence is wrapped in colons. Anything else is a field
            // this does not understand rather than a digest to guess at.
            guard value.utf8.count > 2, value.hasPrefix(":"), value.hasSuffix(":") else { return nil }
            guard let bytes = unbase64(value.dropFirst().dropLast()), bytes.count == 32 else { return nil }
            return bytes
        }
        return nil
    }

    /// Whether two digests are the same, in time that does not depend on
    /// where they differ: a caller comparing a digest that is also a secret
    /// gets the right thing by default.
    public static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        ConstantTime.equals(a, b)
    }

    // MARK: Base64 (RFC 4648), as the field carries it

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func base64(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i < bytes.count {
            let b0 = Int(bytes[i])
            let b1 = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0
            let b2 = i + 2 < bytes.count ? Int(bytes[i + 2]) : 0
            out.append(alphabet[b0 >> 2])
            out.append(alphabet[(b0 & 3) << 4 | b1 >> 4])
            out.append(i + 1 < bytes.count ? alphabet[(b1 & 15) << 2 | b2 >> 6] : UInt8(ascii: "="))
            out.append(i + 2 < bytes.count ? alphabet[b2 & 63] : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Padded base64, or nil for anything else.
    static func unbase64(_ text: Substring) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 4 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 4 * 3)
        var i = 0
        while i < chars.count {
            var group = 0
            var padding = 0
            for k in 0..<4 {
                let c = chars[i + k]
                let value: Int
                switch c {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = Int(c) - 65
                case UInt8(ascii: "a")...UInt8(ascii: "z"): value = Int(c) - 71
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value = Int(c) + 4
                case UInt8(ascii: "+"): value = 62
                case UInt8(ascii: "/"): value = 63
                case UInt8(ascii: "="):
                    // Only at the end, and at most two.
                    guard i + 4 == chars.count, k >= 2 else { return nil }
                    padding += 1
                    value = 0
                default: return nil
                }
                if padding > 0 && c != UInt8(ascii: "=") { return nil }
                group = group << 6 | value
            }
            out.append(UInt8(group >> 16))
            if padding < 2 { out.append(UInt8(group >> 8 & 0xFF)) }
            if padding < 1 { out.append(UInt8(group & 0xFF)) }
            i += 4
        }
        return out
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var s = text
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }
}

/// SHA-256 over bytes that arrive a piece at a time.
///
/// A class, so one hash can be updated from wherever its bytes are read;
/// one instance belongs to one request or one file being read.
public final class SHA256Digest: @unchecked Sendable {
    private var hash: Hash

    public init() {
        do {
            hash = try Hash(.sha256)
        } catch {
            fatalError("SHA-256 is unavailable")
        }
    }

    public func update(_ bytes: [UInt8]) {
        hash.update(bytes)
    }

    /// Bytes lent for the call.
    public func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        hash.update(bytes)
    }

    /// The digest of everything so far. More can be added after it.
    public func digest() -> [UInt8] {
        hash.snapshot()
    }
}

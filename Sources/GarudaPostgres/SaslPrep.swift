//===----------------------------------------------------------------------===//
// SASLprep's mapping step, which is what makes a password's bytes the same on
// both sides of SCRAM.
//
// PostgreSQL runs a password through SASLprep (RFC 4013) before it computes
// the verifier it stores. A client that does not is sending different bytes
// for the same password, and authenticating fails for a reason nobody can see
// -- most easily when a password was pasted and carries a non-breaking space
// or a soft hyphen from wherever it came.
//
// What is done here is the mapping step: the space characters SASLprep turns
// into an ordinary space, and the ones it removes. What is not done is NFKC
// normalisation, which needs Unicode's decomposition tables and is the one
// step this does not carry; a password already in normal form -- which is
// what a keyboard produces -- is unaffected by it. Nothing is prohibited
// here: a character the server would have refused could never have become a
// password there, so refusing it in the client would only turn a failure to
// authenticate into a different failure to authenticate.
//===----------------------------------------------------------------------===//

public enum SaslPrep {
    /// A password as SASLprep's mapping step leaves it.
    public static func mapped(_ password: String) -> String {
        // Nothing to do for the passwords that are only ASCII, which is most
        // of them: no scalar below 0x80 is mapped or removed.
        guard password.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return password }
        var out = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            if isMappedToSpace(scalar.value) {
                out.append(" ")
            } else if isMappedToNothing(scalar.value) {
                continue
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// RFC 3454's table C.1.2, the non-ASCII spaces, which become one space.
    static func isMappedToSpace(_ value: UInt32) -> Bool {
        switch value {
        case 0x00A0, 0x1680, 0x202F, 0x205F, 0x3000: return true
        case 0x2000...0x200B: return true
        default: return false
        }
    }

    /// RFC 3454's table B.1, the characters "commonly mapped to nothing":
    /// soft hyphens, joiners, variation selectors, a byte-order mark that
    /// came along for the ride.
    ///
    /// Checked after the spaces, as the server checks them, so a zero-width
    /// space -- which is in both tables -- becomes a space and not nothing.
    static func isMappedToNothing(_ value: UInt32) -> Bool {
        switch value {
        case 0x00AD, 0x034F, 0x1806, 0x2060, 0xFEFF: return true
        case 0x180B...0x180D: return true
        case 0x200C...0x200D: return true
        case 0xFE00...0xFE0F: return true
        default: return false
        }
    }
}

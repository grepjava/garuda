import Testing
@testable import GarudaPostgres

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

@Suite("SCRAM-SHA-256")
struct ScramTests {

    // MARK: RFC 7677, section 3

    /// The RFC's own exchange, byte for byte: user "user", password "pencil",
    /// the client nonce it uses, and the server's replies. Nothing here is
    /// derived from this implementation, which is what makes it a check on it.
    @Test func theRFC7677ExampleIsReproducedExactly() throws {
        var client = ScramSHA256Client(username: "user", password: "pencil",
                                       nonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(text(client.clientFirstMessage) == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let final = try client.respond(toServerFirst: bytes(serverFirst))
        #expect(text(final) == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                + "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verify(serverFinal: bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
    }

    // MARK: What a server does not get to do

    private func primed() throws -> ScramSHA256Client {
        var client = ScramSHA256Client(username: "user", password: "pencil",
                                       nonce: "rOprNGfwEbeRWgbNEkqO")
        _ = try client.respond(toServerFirst: bytes(
            "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        return client
    }

    @Test func aServerThatCannotProveItKnowsThePasswordIsRefused() throws {
        // One bit off. An impostor that relays everything and forges only the
        // last message would otherwise be accepted as the database.
        let client = try primed()
        #expect(throws: ScramError.serverSignatureMismatch) {
            try client.verify(serverFinal: bytes("v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        }
    }

    @Test func theRightSignatureMissingItsLastByteIsRefused() throws {
        // A true prefix of the real signature, not just any short one. A
        // comparison that looped over the shorter of the two would find every
        // byte it looked at correct and accept it -- which makes the length
        // check, not the byte comparison, the thing standing in the way.
        let client = try primed()
        let real = try #require(Base64.decode("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        let forged = "v=" + Base64.encode(Array(real.dropLast()))
        #expect(throws: ScramError.serverSignatureMismatch) {
            try client.verify(serverFinal: bytes(forged))
        }
    }

    @Test func aServerErrorIsReportedWithItsReason() throws {
        let client = try primed()
        #expect(throws: ScramError.serverError("invalid-proof")) {
            try client.verify(serverFinal: bytes("e=invalid-proof"))
        }
    }

    @Test func aNonceThatIsNotAnExtensionOfOursIsRefused() {
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.nonceMismatch) {
            _ = try client.respond(toServerFirst: bytes("r=zzzzzzXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        }
    }

    @Test func aNonceThatIsOnlyOursEchoedBackIsRefused() {
        // Starting with our nonce is not enough. A server that adds nothing of
        // its own contributes no randomness to the exchange.
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.nonceMismatch) {
            _ = try client.respond(toServerFirst: bytes("r=abcdef,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        }
    }

    @Test func tooFewIterationsAreRefused() {
        // An impostor asking for one iteration would make the client proof it
        // captures cheap to brute-force offline.
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.iterationsOutOfRange(1)) {
            _ = try client.respond(toServerFirst: bytes("r=abcdefXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1"))
        }
    }

    @Test func tooManyIterationsAreRefused() {
        // PBKDF2 runs on the worker thread. A count in the millions stalls
        // every request that worker is holding.
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.iterationsOutOfRange(10_000_000)) {
            _ = try client.respond(toServerFirst: bytes("r=abcdefXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=10000000"))
        }
    }

    @Test func aMandatoryExtensionIsRefused() {
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.unsupportedExtension) {
            _ = try client.respond(toServerFirst: bytes("m=something,r=abcdefXYZ,s=AAAA,i=4096"))
        }
    }

    @Test func attributesOutOfOrderAreRefused() {
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.malformed) {
            _ = try client.respond(toServerFirst: bytes("s=W22ZaJ0SNY7soEsUEjb6gQ==,r=abcdefXYZ,i=4096"))
        }
    }

    @Test func aSaltThatIsNotBase64IsRefused() {
        var client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.malformed) {
            _ = try client.respond(toServerFirst: bytes("r=abcdefXYZ,s=not*base64!,i=4096"))
        }
    }

    @Test func verifyingBeforeTheServerFirstMessageIsRefused() {
        // No signature has been computed to compare against. A check that
        // compared against nothing would pass nothing -- or, written the
        // other way, anything.
        let client = ScramSHA256Client(password: "pencil", nonce: "abcdef")
        #expect(throws: ScramError.malformed) {
            try client.verify(serverFinal: bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        }
    }

    // MARK: Pieces

    @Test func aUserNameIsEscaped() {
        #expect(ScramSHA256Client.escape("a=b,c") == "a=3Db=2Cc")
    }

    @Test func aRandomNonceHasNoCommaAndIsNotRepeated() {
        let a = ScramSHA256Client.randomNonce()
        let b = ScramSHA256Client.randomNonce()
        #expect(!a.contains(","))
        #expect(a.count == 24)
        #expect(a != b)
    }

    @Test func base64RoundTripsEveryRemainder() {
        for n in 0..<8 {
            let data = (0..<n).map { UInt8($0 * 37 % 256) }
            #expect(Base64.decode(Base64.encode(data)) == data)
        }
        #expect(Base64.encode(bytes("pencil")) == "cGVuY2ls")
    }

    @Test func base64IsStrictAboutWhatItAccepts() {
        #expect(Base64.decode("cGVuY2l") == nil)        // not a multiple of four
        #expect(Base64.decode("cGV*Y2ls") == nil)       // outside the alphabet
        #expect(Base64.decode("cG==Y2ls") == nil)       // padding before the end
        #expect(Base64.decode("c===") == nil)           // too much padding
    }
}

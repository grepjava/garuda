import Testing
import CAvian
@testable import Garuda

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private func writeText(_ text: String, to path: String) -> Bool {
    guard let file = fopen(path, "w") else { return false }
    defer { fclose(file) }
    return text.withCString { fputs($0, file) >= 0 }
}

@Suite("Resolver configuration")
struct ResolverConfigTests {

    // MARK: Reading the file

    @Test func nameserversAreKeptInTheOrderGiven() {
        let config = ResolverConfig.parse("""
        nameserver 10.0.0.1
        nameserver 10.0.0.2
        nameserver 10.0.0.3
        """)
        #expect(config.nameservers == ["10.0.0.1", "10.0.0.2", "10.0.0.3"])
    }

    @Test func commentsRunToTheEndOfTheLine() {
        let config = ResolverConfig.parse("""
        # nameserver 1.1.1.1
        ; nameserver 2.2.2.2
        nameserver 10.0.0.1 # the real one
        search example.internal ; and a trailing note
        """)
        #expect(config.nameservers == ["10.0.0.1"])
        #expect(config.search == ["example.internal"])
    }

    @Test func carriageReturnsAreNotPartOfAnAddress() {
        let config = ResolverConfig.parse("nameserver 10.0.0.1\r\nsearch a.internal\r\n")
        #expect(config.nameservers == ["10.0.0.1"])
        #expect(config.search == ["a.internal"])
    }

    /// The file is a sequence of settings, not a list to accumulate: a second
    /// search line replaces the first, as every system resolver does it.
    @Test func theLastSearchLineWins() {
        let config = ResolverConfig.parse("""
        search first.internal
        search second.internal third.internal
        """)
        #expect(config.search == ["second.internal", "third.internal"])
    }

    @Test func domainIsTheOlderSpellingAndSearchSupersedesIt() {
        let withBoth = ResolverConfig.parse("""
        domain old.internal
        search new.internal
        """)
        #expect(withBoth.search == ["new.internal"])

        let domainOnly = ResolverConfig.parse("domain old.internal")
        #expect(domainOnly.search == ["old.internal"])
    }

    /// systemd writes this to mean there is no search list. Appending a bare
    /// dot to every name would query for a trailing empty label.
    @Test func aLoneDotIsNotASearchDomain() {
        let config = ResolverConfig.parse("""
        nameserver 127.0.0.53
        options edns0 trust-ad
        search .
        """)
        #expect(config.search.isEmpty)
    }

    @Test func optionsThisResolverDoesNotImplementAreIgnored() {
        // The file belongs to the system. Refusing to start over an option
        // nobody here acts on would be a server broken by somebody else's
        // settings.
        let config = ResolverConfig.parse("""
        nameserver 10.0.0.1
        options edns0 trust-ad rotate single-request ndots:3
        """)
        #expect(config.nameservers == ["10.0.0.1"])
        #expect(config.ndots == 3)
    }

    @Test func numericOptionsAreBounded() {
        let config = ResolverConfig.parse("""
        options ndots:99 timeout:900 attempts:99
        """)
        // A file asking for ninety-nine dots would mean ninety-nine round
        // trips before a name is tried as it was written.
        #expect(config.ndots == 15)
        #expect(config.timeoutSeconds == 30)
        #expect(config.attempts == 5)
    }

    @Test func aMalformedOptionIsNotANumber() {
        let config = ResolverConfig.parse("options ndots: ndots:x ndots:2")
        #expect(config.ndots == 2)
    }

    // MARK: ndots, which is where resolvers go wrong

    @Test func aNameWithEnoughDotsIsTriedAsItStandsFirst() {
        var config = ResolverConfig()
        config.search = ["a.internal", "b.internal"]
        config.ndots = 1
        #expect(config.candidates(for: "example.com")
                == ["example.com", "example.com.a.internal", "example.com.b.internal"])
    }

    /// The other way round, and the reason a high ndots is a performance bug:
    /// every external lookup walks the search list before trying the name.
    @Test func aBareNameGoesThroughTheSearchListFirst() {
        var config = ResolverConfig()
        config.search = ["a.internal", "b.internal"]
        config.ndots = 1
        #expect(config.candidates(for: "db")
                == ["db.a.internal", "db.b.internal", "db"])
    }

    @Test func aHighNdotsPushesEvenADottedNameThroughTheList() {
        var config = ResolverConfig()
        config.search = ["svc.cluster.local"]
        config.ndots = 5
        #expect(config.candidates(for: "example.com")
                == ["example.com.svc.cluster.local", "example.com"])
    }

    /// A trailing dot means absolute, whatever ndots says, and the dot is not
    /// part of the name that goes on the wire.
    @Test func aTrailingDotIsAbsoluteAndIsDropped() {
        var config = ResolverConfig()
        config.search = ["a.internal"]
        config.ndots = 5
        #expect(config.candidates(for: "example.com.") == ["example.com"])
        #expect(config.isAbsolute("example.com."))
    }

    @Test func withNoSearchListThereIsOnlyTheNameItself() {
        var config = ResolverConfig()
        config.ndots = 1
        #expect(config.candidates(for: "db") == ["db"])
        #expect(config.candidates(for: "example.com") == ["example.com"])
    }

    // MARK: The file on disk

    @Test func aFileIsReadThroughTheShim() {
        let path = "/tmp/garuda-resolv-test.conf"
        #expect(writeText("""
        # written by a test
        nameserver 10.1.2.3
        search one.internal two.internal
        options ndots:2
        """, to: path))
        defer { _ = path.withCString { av_unlink($0) } }

        let config = ResolverConfig.read(path: path)
        #expect(config.nameservers == ["10.1.2.3"])
        #expect(config.search == ["one.internal", "two.internal"])
        #expect(config.ndots == 2)
    }

    /// A machine with no resolv.conf has no DNS configured. It gets localhost
    /// rather than a public resolver: sending its lookups to a third party is
    /// not a default anyone consented to.
    @Test func aMissingFileFallsBackToLocalhost() {
        let config = ResolverConfig.read(path: "/tmp/garuda-resolv-does-not-exist.conf")
        #expect(config.nameservers == ["127.0.0.1"])
        #expect(config.search.isEmpty)
        #expect(config.ndots == 1)
    }

    @Test func aFileNamingNoNameserverStillGetsOne() {
        let path = "/tmp/garuda-resolv-empty.conf"
        #expect(writeText("search only.internal\n", to: path))
        defer { _ = path.withCString { av_unlink($0) } }

        let config = ResolverConfig.read(path: path)
        #expect(config.nameservers == ["127.0.0.1"])
        #expect(config.search == ["only.internal"])
    }

    /// A system file swapped for a fifo must be refused outright.
    ///
    /// Asserted against `av_open_read` rather than through `read(path:)`,
    /// because every way of failing comes back from there as the same
    /// fallback: mutation testing showed this test passing with the
    /// regular-file check deleted, since a fifo opened non-blocking simply
    /// reads as empty and an empty config falls back too. Only the open itself
    /// can say whether the file was refused or merely found to have nothing
    /// in it.
    @Test func aFifoIsRefusedRatherThanRead() {
        let path = "/tmp/garuda-resolv-fifo"
        _ = path.withCString { av_unlink($0) }
        #expect(path.withCString { mkfifo($0, 0o644) } == 0)
        defer { _ = path.withCString { av_unlink($0) } }

        #expect(path.withCString { av_open_read($0) } == -1)
        // And a regular file at the same path does open, so the refusal above
        // is about what the file is and not about the path or the test.
        _ = path.withCString { av_unlink($0) }
        #expect(writeText("nameserver 10.9.9.9\n", to: path))
        let fd = path.withCString { av_open_read($0) }
        #expect(fd >= 0)
        if fd >= 0 { _ = av_close(fd) }
        #expect(ResolverConfig.read(path: path).nameservers == ["10.9.9.9"])
    }

    /// A directory is the other thing a path can turn into, and read(2) on one
    /// fails with EISDIR rather than returning bytes.
    @Test func aDirectoryIsRefused() {
        #expect("/tmp".withCString { av_open_read($0) } == -1)
    }
}

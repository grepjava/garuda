//===----------------------------------------------------------------------===//
// pgfuzz -- a mutation fuzzer for the parsers that read untrusted bytes.
//
//   swift run -c release pgfuzz                    # every target, 5s each
//   swift run -c release pgfuzz http-head --seconds 300
//   swift run -c release pgfuzz --corpus-only      # replay what is on disk
//
// Under a sanitizer, which is where it earns its keep -- a release build traps
// on an out-of-bounds Array access or a signed overflow, but the parsers here
// walk raw pointers, and only ASan sees a read one byte past a buffer:
//
//   swift build -c release -Xswiftc -sanitize=address
//   .build/release/pgfuzz --seconds 60
//
// The design is deliberately small. Every run is reproducible from its seed,
// which is printed at the start and repeatable with --seed, so a failure found
// in CI can be reproduced exactly. There is no coverage feedback: that is what
// libFuzzer is for, and pointing it at `Fuzz.run` is a two-line target when it
// is wanted. What this buys instead is that it builds and runs anywhere the
// server does, with no extra toolchain, which is what makes it something CI
// can run on every commit.
//
// An input that breaks an invariant is written to the working directory and
// named, so it can be added to `fuzz/corpus/<target>/` -- where the test suite
// replays it on every `swift test`, and a fixed crash stays fixed.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineFuzzTargets

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Reproducible randomness

/// SplitMix64. Small, seedable, and good enough to pick mutations with.
struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<n, or 0 when n is not positive.
    mutating func below(_ n: Int) -> Int {
        n <= 0 ? 0 : Int(next() % UInt64(n))
    }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

// MARK: - Writing a failing input out (reading is FuzzCorpus's job)

func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { return false }
    defer { close(fd) }
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress! + written, raw.count - written)
        }
        if n <= 0 { return false }
        written += n
    }
    return true
}

// MARK: - Mutation

/// Byte sequences that mean something to at least one of these parsers, so a
/// mutation has a chance of producing a different valid shape rather than
/// only a rejected one.
let tokens: [[UInt8]] = [
    Array("\r\n".utf8), Array("\r\n\r\n".utf8), Array("\n".utf8),
    Array(": ".utf8), Array(";".utf8), Array(",".utf8), Array(" ".utf8),
    Array("chunked".utf8), Array("Transfer-Encoding: chunked\r\n".utf8),
    Array("Content-Length: ".utf8), Array("0\r\n\r\n".utf8),
    Array("HTTP/1.1".utf8), Array("HTTP/1.0".utf8), Array("Host: x\r\n".utf8),
    Array("18446744073709551616".utf8), Array("-1".utf8), Array("FFFFFFFFFFFFFFFF".utf8),
    [0x00], [0xFF], [0x80], [0x7F],
]

func mutate(_ input: [UInt8], _ rng: inout Rng, corpus: [[UInt8]], maxLength: Int) -> [UInt8] {
    var out = input
    // A few mutations at once: one bit flip rarely moves a parser from one
    // branch to another, and a stack of them is how a seed drifts into a
    // shape nobody wrote down.
    let rounds = 1 + rng.below(4)
    for _ in 0..<rounds {
        switch rng.below(9) {
        case 0 where !out.isEmpty:                       // flip one bit
            let i = rng.below(out.count)
            out[i] ^= UInt8(1) << rng.below(8)
        case 1 where !out.isEmpty:                       // set one byte
            let i = rng.below(out.count)
            out[i] = rng.byte()
        case 2:                                          // insert a token
            let token = tokens[rng.below(tokens.count)]
            let at = rng.below(out.count + 1)
            out.insert(contentsOf: token, at: at)
        case 3 where !out.isEmpty:                       // delete a run
            let at = rng.below(out.count)
            let n = 1 + rng.below(min(32, out.count - at))
            out.removeSubrange(at..<(at + n))
        case 4 where !out.isEmpty:                       // duplicate a run
            let at = rng.below(out.count)
            let n = 1 + rng.below(min(64, out.count - at))
            let run = Array(out[at..<(at + n)])
            out.insert(contentsOf: run, at: rng.below(out.count + 1))
        case 5 where !corpus.isEmpty:                    // splice with another input
            let other = corpus[rng.below(corpus.count)]
            if !other.isEmpty {
                let cut = rng.below(out.count + 1)
                let take = rng.below(other.count)
                out = Array(out[0..<cut]) + Array(other[take...])
            }
        case 6 where !out.isEmpty:                       // truncate
            out.removeSubrange(rng.below(out.count)...)
        case 7:                                          // append random bytes
            let n = 1 + rng.below(16)
            for _ in 0..<n { out.append(rng.byte()) }
        default:                                         // repeat a byte, a lot
            if !out.isEmpty {
                let at = rng.below(out.count)
                let n = 1 + rng.below(256)
                out.insert(contentsOf: [UInt8](repeating: out[at], count: n), at: at)
            }
        }
        if out.count > maxLength { out.removeSubrange(maxLength...) }
    }
    return out
}

// MARK: - Reporting

func hexDump(_ bytes: [UInt8], limit: Int = 256) -> String {
    var s = ""
    for b in bytes.prefix(limit) {
        let hi = b >> 4, lo = b & 0xF
        s.append(Character(UnicodeScalar(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)))
        s.append(Character(UnicodeScalar(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)))
    }
    if bytes.count > limit { s += "... (\(bytes.count) bytes)" }
    return s
}

func fail(_ target: FuzzTarget, _ reason: String, _ input: [UInt8], seed: UInt64) -> Never {
    let path = "pgfuzz-\(target.rawValue)-\(seed).bin"
    let saved = writeFile(path, input)
    print("")
    print("FAIL \(target.rawValue): \(reason)")
    print("  input: \(hexDump(input))")
    if saved {
        print("  saved: \(path)")
        print("  add it to fuzz/corpus/\(target.rawValue)/ so the suite keeps checking it")
    }
    print("  reproduce: pgfuzz \(target.rawValue) --seed \(seed)")
    exit(1)
}

// MARK: - Arguments

var targets: [FuzzTarget] = []
var seconds = 5.0
var seed = UInt64(pg_monotonic_ms())
var corpusRoot = "fuzz/corpus"
var maxLength = 4096
var corpusOnly = false

var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let arg = argv[i]
    i += 1
    func value(_ what: String) -> String {
        if i >= argv.count {
            print("pgfuzz: \(what) needs a value")
            exit(2)
        }
        let v = argv[i]
        i += 1
        return v
    }
    switch arg {
    case "--seconds": seconds = Double(value("--seconds")) ?? 5.0
    case "--seed": seed = UInt64(value("--seed")) ?? 0
    case "--corpus": corpusRoot = value("--corpus")
    case "--max-len": maxLength = Int(value("--max-len")) ?? 4096
    case "--corpus-only": corpusOnly = true
    case "--help", "-h":
        print("""
        usage: pgfuzz [target ...] [--seconds N] [--seed N] [--corpus DIR]
                      [--max-len N] [--corpus-only]

        targets: \(FuzzTarget.allCases.map(\.rawValue).joined(separator: ", "))
        """)
        exit(0)
    default:
        guard let t = FuzzTarget(rawValue: arg) else {
            print("pgfuzz: no such target: \(arg)")
            exit(2)
        }
        targets.append(t)
    }
}
if targets.isEmpty { targets = FuzzTarget.allCases }
if maxLength < 1 { maxLength = 1 }

// MARK: - The loop

print("pgfuzz: seed \(seed), \(corpusOnly ? "corpus only" : "\(seconds)s per target")")
var totalRuns = 0

for target in targets {
    var corpus = Fuzz.seeds(for: target)
    var fromDisk = 0
    for (_, bytes) in FuzzCorpus.inputs(for: target, root: corpusRoot) {
        corpus.append(bytes)
        fromDisk += 1
    }

    // The corpus first, unmutated: whatever is on disk is there because it
    // mattered once, and a run that never reaches it is not a regression test.
    for input in corpus {
        if let reason = Fuzz.run(target, input) {
            fail(target, reason, input, seed: seed)
        }
    }
    var runs = corpus.count

    if !corpusOnly {
        var rng = Rng(seed: seed &+ UInt64(target.rawValue.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) }))
        let deadline = pg_monotonic_ms() &+ UInt64(seconds * 1000)
        while pg_monotonic_ms() < deadline {
            // Time is checked every so often rather than every run: the check
            // is a syscall on some platforms and the parses are microseconds.
            for _ in 0..<512 {
                let base = corpus[rng.below(corpus.count)]
                let input = mutate(base, &rng, corpus: corpus, maxLength: maxLength)
                if let reason = Fuzz.run(target, input) {
                    fail(target, reason, input, seed: seed)
                }
                runs += 1
            }
        }
    }

    totalRuns += runs
    print("  ok   \(target.rawValue): \(runs) inputs "
          + "(\(corpus.count) seeds, \(fromDisk) from \(corpusRoot))")
}

print("pgfuzz: \(totalRuns) inputs, no invariant broken")

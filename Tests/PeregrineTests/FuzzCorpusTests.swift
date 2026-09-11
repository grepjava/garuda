//===----------------------------------------------------------------------===//
// The fuzz corpus, replayed.
//
// `pgfuzz` finds things; this is what stops them coming back. Every input in
// `fuzz/corpus/` goes through its target's invariants on every `swift test`,
// which costs milliseconds and means a fixed parser bug has a test that names
// the byte string that broke it.
//
// The seeds compiled into the fuzz targets are replayed too, so a bare
// checkout with no corpus still exercises one valid example of every shape
// these parsers have a branch for.
//===----------------------------------------------------------------------===//

import Testing

@testable import PeregrineFuzzTargets

/// The repository root, derived from this file rather than from the working
/// directory: `swift test` does not promise where it runs from.
private let repositoryRoot: String = {
    var path = Substring(#filePath)
    // .../Tests/PeregrineTests/FuzzCorpusTests.swift -> ...
    for _ in 0..<3 {
        guard let slash = path.lastIndex(of: "/") else { break }
        path = path[..<slash]
    }
    return String(path)
}()

@Suite("Fuzz corpus")
struct FuzzCorpusTests {

    @Test("every compiled-in seed satisfies its target's invariants",
          arguments: FuzzTarget.allCases)
    func seedsHold(target: FuzzTarget) {
        let seeds = Fuzz.seeds(for: target)
        #expect(!seeds.isEmpty, "\(target.rawValue) has no seeds")
        for (i, seed) in seeds.enumerated() {
            if let reason = Fuzz.run(target, seed) {
                Issue.record("\(target.rawValue) seed \(i): \(reason)")
            }
        }
    }

    @Test("every checked-in corpus input satisfies them too",
          arguments: FuzzTarget.allCases)
    func corpusHolds(target: FuzzTarget) {
        for (path, bytes) in FuzzCorpus.inputs(for: target,
                                               root: repositoryRoot + "/fuzz/corpus") {
            if let reason = Fuzz.run(target, bytes) {
                Issue.record("\(path): \(reason)")
            }
        }
    }

    @Test("an empty input is not a special case for any parser",
          arguments: FuzzTarget.allCases)
    func emptyInput(target: FuzzTarget) {
        #expect(Fuzz.run(target, []) == nil)
    }
}

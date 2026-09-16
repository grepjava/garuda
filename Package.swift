// swift-tools-version: 6.1
import PackageDescription

// Garuda — a pure-Swift web framework. No Foundation.
//
// No target sets unsafe flags: SwiftPM refuses them in a package that is
// depended on by version. Benchmarks build the way the-benchmarker builds
// every Swift entry, with the flag on the command line:
//   swift build -c release -Xswiftc -enforce-exclusivity=unchecked

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .define("GARUDA_RELEASE", .when(configuration: .release)),
]

let package = Package(
    name: "garuda",
    // macOS 15: async handlers run on a `TaskExecutor`.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "garuda", targets: ["garuda-server"]),
        .executable(name: "garuda-conformance", targets: ["garuda-conformance"]),
        .library(name: "Garuda", targets: ["Garuda"]),
    ],
    targets: [
        .target(
            name: "CGaruda",
            path: "Sources/CGaruda",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
                .linkedLibrary("z"),
            ]
        ),

        .target(name: "GarudaCore", dependencies: ["CGaruda"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "GarudaHTTP", dependencies: ["GarudaCore"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "GarudaQUIC", dependencies: ["GarudaCore", "GarudaHTTP"],
                swiftSettings: sharedSwiftSettings),

        // Database protocols as byte-level state machines: no sockets, no
        // poller, so each is tested against recorded exchanges and fuzzed.
        .target(name: "GarudaPostgres", dependencies: ["GarudaCore", "CGaruda"],
                swiftSettings: sharedSwiftSettings),

        // The engine and the handler API: `import Garuda`.
        .target(name: "Garuda",
                dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC", "GarudaPostgres"],
                swiftSettings: sharedSwiftSettings),

        // The `garuda` executable. Its module is not named `garuda`, which a
        // case-insensitive file system would take for the `Garuda` module.
        .executableTarget(name: "garuda-server", dependencies: ["Garuda"],
                          path: "Sources/garuda-server",
                          swiftSettings: sharedSwiftSettings),

        // The routes the end-to-end suites need a handler for.
        .executableTarget(name: "garuda-conformance",
                          dependencies: ["GarudaCore", "GarudaHTTP", "Garuda"],
                          path: "Sources/GarudaConformance",
                          swiftSettings: sharedSwiftSettings),

        .target(name: "GarudaFuzzTargets",
                dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC", "Garuda"],
                swiftSettings: sharedSwiftSettings),

        .executableTarget(name: "pgfuzz",
                          dependencies: ["CGaruda", "GarudaFuzzTargets"],
                          swiftSettings: sharedSwiftSettings),

        // Counts heap allocations in the test process, on glibc.
        .target(name: "CAllocationCounter", path: "Tests/CAllocationCounter"),

        .testTarget(name: "GarudaTests",
                    dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC", "GarudaPostgres",
                                   "Garuda", "GarudaFuzzTargets", "CAllocationCounter"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cLanguageStandard: .gnu11
)

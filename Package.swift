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
]

/// A module of aviancore, the protocol and systems layers Garuda is built on.
func avian(_ name: String) -> Target.Dependency {
    .product(name: name, package: "aviancore")
}

let package = Package(
    name: "garuda",
    // macOS 15: async handlers run on a `TaskExecutor`.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "garuda", targets: ["garuda-server"]),
        .executable(name: "garuda-conformance", targets: ["garuda-conformance"]),
        .library(name: "Garuda", targets: ["Garuda"]),
        .library(name: "GarudaUploads", targets: ["GarudaUploads"]),
    ],
    dependencies: [
        // The protocol and systems layers: syscalls, TLS, buffers, the poller,
        // HTTP/1.1, HTTP/2, HTTP/3 and QUIC.
        .package(url: "https://github.com/grepjava/aviancore", from: "0.2.0"),
    ],
    targets: [
        // Database protocols as byte-level state machines: no sockets, no
        // poller, so each is tested against recorded exchanges.
        .target(name: "GarudaPostgres", dependencies: [avian("CAvian"), avian("AvianCore")],
                swiftSettings: sharedSwiftSettings),

        // The engine and the handler API: `import Garuda`.
        .target(name: "Garuda",
                dependencies: [avian("CAvian"), avian("AvianCore"), avian("AvianHTTP"), avian("AvianQUIC"),
                               "GarudaPostgres"],
                swiftSettings: sharedSwiftSettings),

        // Resumable uploads (draft-ietf-httpbis-resumable-upload), built on the
        // public handler API alone: `import GarudaUploads`.
        .target(name: "GarudaUploads", dependencies: [avian("AvianHTTP"), "Garuda"],
                swiftSettings: sharedSwiftSettings),

        // The `garuda` executable. Its module is not named `garuda`, which a
        // case-insensitive file system would take for the `Garuda` module.
        .executableTarget(name: "garuda-server", dependencies: ["Garuda"],
                          path: "Sources/garuda-server",
                          swiftSettings: sharedSwiftSettings),

        // The routes the end-to-end suites need a handler for.
        .executableTarget(name: "garuda-conformance",
                          dependencies: [avian("AvianCore"), avian("AvianHTTP"), "Garuda", "GarudaUploads"],
                          path: "Sources/GarudaConformance",
                          swiftSettings: sharedSwiftSettings),

        .target(name: "GarudaFuzzTargets",
                dependencies: [avian("AvianCore"), avian("AvianHTTP"), avian("AvianQUIC"), "Garuda"],
                swiftSettings: sharedSwiftSettings),

        .executableTarget(name: "pgfuzz",
                          dependencies: [avian("CAvian"), "GarudaFuzzTargets"],
                          swiftSettings: sharedSwiftSettings),

        // Counts heap allocations in the test process, on glibc.
        .target(name: "CAllocationCounter", path: "Tests/CAllocationCounter"),

        .testTarget(name: "GarudaTests",
                    dependencies: [avian("CAvian"), avian("AvianCore"), avian("AvianHTTP"), avian("AvianQUIC"),
                                   "GarudaPostgres", "Garuda", "GarudaFuzzTargets", "CAllocationCounter"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GarudaUploadsTests",
                    dependencies: [avian("CAvian"), avian("AvianHTTP"), "Garuda", "GarudaUploads"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cLanguageStandard: .gnu11
)

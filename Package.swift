// swift-tools-version: 6.2
import CompilerPluginSupport
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
        // `@JSON`. A separate product because it is the only thing in Garuda
        // that needs swift-syntax: an application that does not import it
        // never builds the macro plugin.
        .library(name: "GarudaJSON", targets: ["GarudaJSON"]),
        // `@PostgresRow`, from the same plugin.
        .library(name: "GarudaSQL", targets: ["GarudaSQL"]),
    ],
    dependencies: [
        // The protocol and systems layers: syscalls, TLS, buffers, the poller,
        // HTTP/1.1, HTTP/2, HTTP/3 and QUIC.
        .package(url: "https://github.com/grepjava/aviancore", from: "0.6.7"),
        // The tracing API the Swift server ecosystem shares: Garuda starts
        // spans, and whichever tracer the application bootstraps records
        // them. No Foundation, no threads of its own.
        .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.3.0"),
        // Only the `GarudaJSON` plugin builds against this. It is still
        // resolved by everyone who depends on Garuda, because SwiftPM resolves
        // a package's dependencies whether or not a product uses them.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
    ],
    targets: [
        // Database protocols as byte-level state machines: no sockets, no
        // poller, so each is tested against recorded exchanges.
        .target(name: "GarudaPostgres", dependencies: [avian("CAvian"), avian("AvianCore")],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaRedis", dependencies: [avian("AvianCore")],
                swiftSettings: sharedSwiftSettings),
        // The system's libsqlite3, opened with dlopen: no headers to build.
        .target(name: "CGarudaSQLite"),
        // JSON Web Token signatures over the system's libcrypto, which the TLS
        // layer already links: RSA, ECDSA, EdDSA and HMAC-SHA-512.
        .target(name: "CGarudaJWT", linkerSettings: [.linkedLibrary("crypto")]),

        // The engine and the handler API: `import Garuda`.
        .target(name: "Garuda",
                dependencies: [avian("CAvian"), avian("AvianCore"), avian("AvianHTTP"), avian("AvianQUIC"),
                               "GarudaPostgres", "GarudaRedis", "CGarudaSQLite", "CGarudaJWT",
                               .product(name: "Tracing", package: "swift-distributed-tracing")],
                swiftSettings: sharedSwiftSettings),

        // Resumable uploads (draft-ietf-httpbis-resumable-upload), built on the
        // public handler API alone: `import GarudaUploads`.
        .target(name: "GarudaUploads", dependencies: [avian("AvianHTTP"), "Garuda"],
                swiftSettings: sharedSwiftSettings),

        // `@JSON` reads the members off a declaration and writes the
        // `JSONReadable` and `JSONWritable` conformances a hand is otherwise
        // asked to write. It runs in the compiler, so it is its own plugin.
        .macro(name: "GarudaMacros",
               dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"),
                              .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                              .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                              .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                              .product(name: "SwiftCompilerPlugin", package: "swift-syntax")],
               swiftSettings: sharedSwiftSettings),

        // The declaration of `@JSON`: `import GarudaJSON`.
        .target(name: "GarudaJSON", dependencies: ["Garuda", "GarudaMacros"],
                swiftSettings: sharedSwiftSettings),

        // The declaration of `@PostgresRow`: `import GarudaSQL`.
        .target(name: "GarudaSQL", dependencies: ["Garuda", "GarudaMacros"],
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
                                   "GarudaPostgres", "GarudaRedis", "CGarudaSQLite", "CGarudaJWT", "Garuda", "GarudaSQL",
                                   "GarudaFuzzTargets",
                                   "CAllocationCounter",
                                   .product(name: "Tracing", package: "swift-distributed-tracing"),
                                   .product(name: "InMemoryTracing", package: "swift-distributed-tracing")],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GarudaJSONTests",
                    dependencies: ["Garuda", "GarudaJSON"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GarudaUploadsTests",
                    dependencies: [avian("CAvian"), avian("AvianHTTP"), "Garuda", "GarudaUploads"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cLanguageStandard: .gnu11
)

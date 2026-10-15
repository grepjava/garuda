// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// Garuda 2 -- a pure-Swift web framework on Vega's work-stealing runtime. No
// Foundation.
//
// No target sets unsafe flags: SwiftPM refuses them in a package that is
// depended on by version. Benchmarks build the way the-benchmarker builds
// every Swift entry, with the flag on the command line:
//   swift build -c release -Xswiftc -enforce-exclusivity=unchecked

// Nonsending by default, as Vega is: an async function runs on its caller's
// executor, so returning from one is no hop, which on Vega costs a lock.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// A module of Vega.
func vega(_ name: String) -> Target.Dependency {
    .product(name: name, package: "vega")
}

/// Garuda's TLS library traits pass straight through to Vega's.
let vegaTraits: Set<Package.Dependency.Trait> = [
    .init(name: "OpenSSL", condition: .when(traits: ["OpenSSL"])),
    .init(name: "BoringSSL", condition: .when(traits: ["BoringSSL"])),
]

/// Vega, by version; or, with GARUDA_VEGA_PATH set, a local checkout -- for
/// working on Garuda and Vega together before a Vega release has what
/// Garuda needs.
let vegaPackage: Package.Dependency = Context.environment["GARUDA_VEGA_PATH"].map {
    .package(path: $0, traits: vegaTraits)
} ?? .package(url: "https://github.com/grepjava/vega.git", .upToNextMinor(from: "0.4.2"), traits: vegaTraits)

/// vega-db, by version; or, with GARUDA_VEGA_DB_PATH set, a local checkout.
/// A local Vega under it as well takes VEGA_PATH, which vega-db reads, set
/// to the same checkout as GARUDA_VEGA_PATH.
let vegaDBPackage: Package.Dependency = Context.environment["GARUDA_VEGA_DB_PATH"].map {
    .package(path: $0, traits: vegaTraits)
} ?? .package(url: "https://github.com/grepjava/vega-db.git", .upToNextMinor(from: "0.2.3"), traits: vegaTraits)

/// A module of vega-db.
func vegaDB(_ name: String) -> Target.Dependency {
    .product(name: name, package: "vega-db")
}

let package = Package(
    name: "garuda",
    // Vega's floor: its executor needs macOS 26.4's custom-executor hooks.
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "garuda", targets: ["garuda-server"]),
        // The routes the end-to-end suites under scripts/ drive.
        .executable(name: "garuda-conformance", targets: ["garuda-conformance"]),
        .library(name: "Garuda", targets: ["Garuda"]),
        // `app.test`: requests through the real HTTP/1 connection over an
        // in-memory stream.
        .library(name: "GarudaTesting", targets: ["GarudaTesting"]),
        // `@JSON`. A separate product because it is the only thing in Garuda
        // that needs swift-syntax: an application that does not import it
        // never builds the macro plugin.
        .library(name: "GarudaJSON", targets: ["GarudaJSON"]),
        // The databases, each vega-db's driver re-exported with what joins it
        // to Garuda: its UUID and Timestamp as columns, JSON through its
        // coder. Separate products, so an application builds only the
        // drivers it imports.
        .library(name: "GarudaPostgres", targets: ["GarudaPostgres"]),
        .library(name: "GarudaRedis", targets: ["GarudaRedis"]),
        .library(name: "GarudaSQLite", targets: ["GarudaSQLite"]),
        // `@PostgresRow`, apart from GarudaPostgres for the same reason
        // GarudaJSON is apart: only it needs swift-syntax.
        .library(name: "GarudaSQL", targets: ["GarudaSQL"]),
    ],
    // The TLS library under Vega's TLS. BoringSSL, vendored in Vega, is the
    // default: Garuda 1's library, cheaper a request than OpenSSL 3, and no
    // system OpenSSL needed. `swift build --traits OpenSSL` (or a dependent's
    // `traits: ["OpenSSL"]`) builds on the system's OpenSSL 3 instead.
    traits: [
        .trait(name: "BoringSSL", description: "TLS on Vega's vendored BoringSSL (the default)."),
        .trait(name: "OpenSSL", description: "TLS on the system's OpenSSL 3. BoringSSL wins if both are on."),
        .default(enabledTraits: ["BoringSSL"]),
    ],
    dependencies: [
        // The runtime: work-stealing scheduler, sharded processes, sockets,
        // TLS. upToNextMinor, not `from:`: Vega is below 1.0, so a minor
        // release may change its API.
        vegaPackage,
        // PostgreSQL, Redis and SQLite. Resolved by everyone, built only for
        // an application that imports one of the database products.
        vegaDBPackage,
        // Traces: a request's span, and its outbound calls' under it
        // (Tracing.swift). The API alone; the application picks a tracer.
        .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.3.0"),
        // Only the `GarudaJSON` plugin builds against this. It is still
        // resolved by everyone who depends on Garuda, because SwiftPM resolves
        // a package's dependencies whether or not a product uses them.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
    ],
    targets: [
        // HTTP on the wire as byte-level state machines: the HTTP/1.1 parser,
        // HPACK, QPACK, frames. No sockets, no allocation on the hot path.
        // Vendored from aviancore's AvianHTTP; see Sources/GarudaWire/VENDORED.md.
        .target(name: "GarudaWire", exclude: ["VENDORED.md"], swiftSettings: sharedSwiftSettings),
        // VegaTLS serves HTTPS (TLS.swift). VegaCrypto: Garuda has no
        // cryptography of its own. Signed and
        // encrypted cookies (HMAC, HKDF, AES-GCM), JWT signing and verifying,
        // password hashes and tokens all use it.
        // What the shards share that needs C's atomics over raw memory: the
        // response cache's table (garuda_cache.c).
        .target(name: "CGarudaShared"),
        .target(name: "Garuda",
                dependencies: ["GarudaWire", "CGarudaShared", vega("Vega"), vega("VegaIO"), vega("VegaCrypto"), vega("VegaTLS"),
                               vega("VegaFS"), vega("VegaExtras"), vegaDB("VegaDBTracing"),
                               .product(name: "Tracing", package: "swift-distributed-tracing")],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaTesting",
                dependencies: ["Garuda", "GarudaWire", vega("Vega"), vega("VegaIO"), vega("VegaTest")],
                swiftSettings: sharedSwiftSettings),
        .macro(name: "GarudaMacros",
               dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"),
                              .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                              .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                              .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                              .product(name: "SwiftCompilerPlugin", package: "swift-syntax")],
               swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaJSON", dependencies: ["Garuda", "GarudaMacros"],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaPostgres", dependencies: ["Garuda", vegaDB("VegaPostgres")],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaRedis", dependencies: ["Garuda", vegaDB("VegaRedis")],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaSQLite", dependencies: ["Garuda", "GarudaWire", vegaDB("VegaSQLite")],
                swiftSettings: sharedSwiftSettings),
        .target(name: "GarudaSQL", dependencies: ["GarudaPostgres", "GarudaMacros"],
                swiftSettings: sharedSwiftSettings),
        // The benchmark server: the-benchmarker's routes plus the workloads.
        .executableTarget(name: "garuda-server",
                          dependencies: ["Garuda", "GarudaJSON", "GarudaPostgres", "GarudaSQL", vega("Vega")],
                          path: "Sources/garuda-server",
                          swiftSettings: sharedSwiftSettings),
        .executableTarget(name: "garuda-conformance", dependencies: ["Garuda", vega("Vega"), vega("VegaExtras")],
                          path: "Sources/garuda-conformance",
                          swiftSettings: sharedSwiftSettings),

        .target(name: "CAllocationCounter", path: "Tests/CAllocationCounter"),
        .testTarget(name: "GarudaWireTests", dependencies: ["GarudaWire"],
                    swiftSettings: sharedSwiftSettings),
        .testTarget(name: "GarudaTests",
                    dependencies: ["Garuda", "GarudaWire", "GarudaTesting", "CAllocationCounter",
                                   vega("Vega"),
                                   .product(name: "Tracing", package: "swift-distributed-tracing"),
                                   .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
                                   vegaDB("VegaDBTracing")],
                    swiftSettings: sharedSwiftSettings),
        .testTarget(name: "GarudaJSONTests", dependencies: ["Garuda", "GarudaJSON"],
                    swiftSettings: sharedSwiftSettings),
        .testTarget(name: "GarudaDatabaseTests",
                    dependencies: ["Garuda", "GarudaPostgres", "GarudaRedis", "GarudaSQLite", "GarudaSQL",
                                   "GarudaWire", "GarudaTesting", vega("Vega"),
                                   .product(name: "InMemoryTracing", package: "swift-distributed-tracing")],
                    swiftSettings: sharedSwiftSettings),
    ]
)

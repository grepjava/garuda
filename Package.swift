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

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

/// A module of Vega.
func vega(_ name: String) -> Target.Dependency {
    .product(name: name, package: "vega")
}

/// Vega, by version; or, with GARUDA_VEGA_PATH set, a local checkout -- for
/// working on Garuda and Vega together before a Vega release has what
/// Garuda needs.
let vegaPackage: Package.Dependency = Context.environment["GARUDA_VEGA_PATH"].map {
    .package(path: $0)
} ?? .package(url: "https://github.com/grepjava/vega.git", .upToNextMinor(from: "0.3.0"))

let package = Package(
    name: "garuda",
    // Vega's floor: its executor needs macOS 26.4's custom-executor hooks.
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "garuda", targets: ["garuda-server"]),
        .library(name: "Garuda", targets: ["Garuda"]),
        // `app.test`: requests through the real HTTP/1 connection over an
        // in-memory stream.
        .library(name: "GarudaTesting", targets: ["GarudaTesting"]),
        // `@JSON`. A separate product because it is the only thing in Garuda
        // that needs swift-syntax: an application that does not import it
        // never builds the macro plugin.
        .library(name: "GarudaJSON", targets: ["GarudaJSON"]),
    ],
    dependencies: [
        // The runtime: work-stealing scheduler, sharded processes, sockets,
        // TLS. upToNextMinor, not `from:`: Vega is below 1.0, so a minor
        // release may change its API.
        vegaPackage,
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
        .target(name: "Garuda",
                dependencies: ["GarudaWire", vega("Vega"), vega("VegaIO")],
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
        // The benchmark server: the-benchmarker's routes plus the workloads.
        .executableTarget(name: "garuda-server", dependencies: ["Garuda", "GarudaJSON", vega("Vega")],
                          path: "Sources/garuda-server",
                          swiftSettings: sharedSwiftSettings),

        .target(name: "CAllocationCounter", path: "Tests/CAllocationCounter"),
        .testTarget(name: "GarudaWireTests", dependencies: ["GarudaWire"],
                    swiftSettings: sharedSwiftSettings),
        .testTarget(name: "GarudaTests",
                    dependencies: ["Garuda", "GarudaWire", "GarudaTesting", "CAllocationCounter",
                                   vega("Vega")],
                    swiftSettings: sharedSwiftSettings),
        .testTarget(name: "GarudaJSONTests", dependencies: ["Garuda", "GarudaJSON"],
                    swiftSettings: sharedSwiftSettings),
    ]
)

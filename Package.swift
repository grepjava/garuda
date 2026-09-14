// swift-tools-version: 6.1
import PackageDescription

// Garuda — a pure-Swift web framework. No Foundation, no CPython.

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
    .define("GARUDA_RELEASE", .when(configuration: .release)),
]

let package = Package(
    name: "garuda",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "garuda", targets: ["garuda"]),
        .library(name: "Garuda", targets: ["GarudaServer"]),
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

        .target(name: "GarudaServer",
                dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC"],
                swiftSettings: sharedSwiftSettings),

        .executableTarget(name: "garuda", dependencies: ["GarudaServer"],
                          swiftSettings: sharedSwiftSettings),

        .target(name: "GarudaFuzzTargets",
                dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC"],
                swiftSettings: sharedSwiftSettings),

        .executableTarget(name: "pgfuzz",
                          dependencies: ["CGaruda", "GarudaFuzzTargets"],
                          swiftSettings: sharedSwiftSettings),

        .testTarget(name: "GarudaTests",
                    dependencies: ["GarudaCore", "GarudaHTTP", "GarudaQUIC",
                                   "GarudaServer", "GarudaFuzzTargets"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cLanguageStandard: .gnu11
)

// swift-tools-version: 6.2
import PackageDescription

// Runnable examples, each an application built on the public API alone.
//
//   swift run todo       a JSON CRUD API backed by SQLite
//   swift run auth       sign-up, login and sessions with hashed passwords
//   swift run streaming  server-sent events, a streamed export and uploads
//   swift run chat       rooms over WebSockets and server-sent events,
//                        across every shard
//   swift run starter    accounts and notes on PostgreSQL: configuration,
//                        migrations, JWT access and refresh tokens, OpenAPI
//   swift run webtransport
//                        a network probe over WebTransport: datagram round
//                        trips, and throughput on streams
//   swift run files      a file service: resumable uploads, and downloads
//                        with byte ranges from the static route
//   swift run uploads    photo uploads per user: resumable, behind bearer
//                        tokens, checked for what the bytes are
//
// Each application is a library target with a function that builds it, so
// `swift test` drives it through `app.test`, and a small executable that runs
// it with the server's command-line flags.

// Garuda's own settings: Swift 6, and async functions that run on their
// caller's executor unless they say otherwise.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

// Vega, the runtime Garuda is built on, for what an example needs that Garuda
// does not export: VegaCrypto's SHA-256 in the webtransport example, a
// runtime for work outside the server in the starter's `withServices`, and
// VegaFS's file system calls, which run on the blocking pool, in the
// streaming, files and uploads examples. The same checkout Garuda builds on
// (GARUDA_VEGA_PATH), or the same release, and BoringSSL under its TLS as
// Garuda's default has it.
let vega: Package.Dependency = Context.environment["GARUDA_VEGA_PATH"].map {
    .package(path: $0, traits: ["BoringSSL"])
} ?? .package(url: "https://github.com/grepjava/vega.git", from: "1.0.0", traits: ["BoringSSL"])

func garuda(_ product: String) -> Target.Dependency {
    .product(name: product, package: "garuda")
}

let package = Package(
    name: "garuda-examples",
    platforms: [.macOS("26.4")],
    dependencies: [
        .package(name: "garuda", path: ".."),
        vega,
    ],
    targets: [
        .target(name: "TodoExample", dependencies: [garuda("Garuda"), garuda("GarudaSQLite")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "todo", dependencies: ["TodoExample"], swiftSettings: swiftSettings),

        .target(name: "AuthExample", dependencies: [garuda("Garuda"), garuda("GarudaSQLite")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "auth", dependencies: ["AuthExample"], swiftSettings: swiftSettings),

        .target(name: "StreamingExample",
                dependencies: [garuda("Garuda"), .product(name: "Vega", package: "vega"),
                               .product(name: "VegaFS", package: "vega")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "streaming", dependencies: ["StreamingExample"], swiftSettings: swiftSettings),

        .target(name: "ChatExample", dependencies: [garuda("Garuda")], swiftSettings: swiftSettings),
        .executableTarget(name: "chat", dependencies: ["ChatExample"], swiftSettings: swiftSettings),

        .target(name: "WebTransportExample",
                dependencies: [garuda("Garuda"), .product(name: "VegaCrypto", package: "vega")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "webtransport", dependencies: ["WebTransportExample", garuda("Garuda")],
                          swiftSettings: swiftSettings),

        .target(name: "StarterExample",
                dependencies: [garuda("Garuda"), garuda("GarudaPostgres"),
                               .product(name: "Vega", package: "vega")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "starter", dependencies: ["StarterExample", garuda("Garuda")],
                          swiftSettings: swiftSettings),

        .target(name: "FilesExample",
                dependencies: [garuda("Garuda"), garuda("GarudaUploads"),
                               .product(name: "VegaFS", package: "vega")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "files", dependencies: ["FilesExample", garuda("Garuda")],
                          swiftSettings: swiftSettings),

        .target(name: "UploadsExample",
                dependencies: [garuda("Garuda"), garuda("GarudaUploads"),
                               .product(name: "Vega", package: "vega"),
                               .product(name: "VegaFS", package: "vega")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "uploads", dependencies: ["UploadsExample", garuda("Garuda")],
                          swiftSettings: swiftSettings),

        .testTarget(name: "ExampleTests",
                    dependencies: ["TodoExample", "AuthExample", "StreamingExample", "ChatExample",
                                   "WebTransportExample", "StarterExample", "FilesExample",
                                   "UploadsExample",
                                   garuda("Garuda"), garuda("GarudaSQLite"), garuda("GarudaPostgres"),
                                   garuda("GarudaUploads"), garuda("GarudaTesting"),
                                   .product(name: "VegaCrypto", package: "vega")],
                    swiftSettings: swiftSettings),
    ]
)

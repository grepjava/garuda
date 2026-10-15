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
//
// Each application is a library target with a function that builds it, so
// `swift test` drives it through `app.test`, and a small executable that runs
// it with the server's command-line flags.
//
// Sources/FilesExample, Sources/UploadsExample and their executables are not
// built yet: they need GarudaUploads, which Garuda 2 does not have yet.

// Garuda's own settings: Swift 6, and async functions that run on their
// caller's executor unless they say otherwise.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

func garuda(_ product: String) -> Target.Dependency {
    .product(name: product, package: "garuda")
}

let package = Package(
    name: "garuda-examples",
    platforms: [.macOS("26.4")],
    dependencies: [
        .package(name: "garuda", path: ".."),
    ],
    targets: [
        .target(name: "TodoExample", dependencies: [garuda("Garuda"), garuda("GarudaSQLite")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "todo", dependencies: ["TodoExample"], swiftSettings: swiftSettings),

        .testTarget(name: "ExampleTests",
                    dependencies: ["TodoExample", garuda("Garuda"), garuda("GarudaSQLite"), garuda("GarudaTesting")],
                    // Waiting for GarudaUploads.
                    exclude: ["FilesTests.swift", "UploadsTests.swift",
                              "AuthTests.swift", "StreamingTests.swift", "ChatTests.swift", "StarterTests.swift", "WebTransportTests.swift"],
                    swiftSettings: swiftSettings),
    ]
)

// swift-tools-version: 6.1
import PackageDescription

// Runnable examples, each an application built on the public API alone.
//
//   swift run todo       a JSON CRUD API backed by SQLite
//   swift run auth       sign-up, login and sessions with hashed passwords
//   swift run streaming  server-sent events, a streamed export and uploads
//   swift run chat       rooms over WebSockets and server-sent events,
//                        across every worker
//   swift run starter    accounts and notes on PostgreSQL: configuration,
//                        migrations, JWT access and refresh tokens, OpenAPI
//
// Each application is a library target with a function that builds it, so
// `swift test` drives it through `app.test`, and a small executable that runs
// it with the server's command-line flags.

let package = Package(
    name: "garuda-examples",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "garuda", path: ".."),
    ],
    targets: [
        .target(name: "TodoExample", dependencies: [.product(name: "Garuda", package: "garuda")]),
        .executableTarget(name: "todo", dependencies: ["TodoExample"]),

        .target(name: "AuthExample", dependencies: [.product(name: "Garuda", package: "garuda")]),
        .executableTarget(name: "auth", dependencies: ["AuthExample"]),

        .target(name: "StreamingExample", dependencies: [.product(name: "Garuda", package: "garuda")]),
        .executableTarget(name: "streaming", dependencies: ["StreamingExample"]),

        .target(name: "ChatExample", dependencies: [.product(name: "Garuda", package: "garuda")]),
        .executableTarget(name: "chat", dependencies: ["ChatExample"]),

        .target(name: "StarterExample", dependencies: [.product(name: "Garuda", package: "garuda")]),
        .executableTarget(name: "starter", dependencies: ["StarterExample",
                                                          .product(name: "Garuda", package: "garuda")]),

        .testTarget(name: "ExampleTests",
                    dependencies: ["TodoExample", "AuthExample", "StreamingExample", "ChatExample",
                                   "StarterExample", .product(name: "Garuda", package: "garuda")]),
    ]
)

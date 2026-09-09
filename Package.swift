// swift-tools-version: 6.1
import PackageDescription

// Peregrine — a Python ASGI/WSGI server written in Swift.
//
// Design constraints baked into this manifest:
//  * No Foundation anywhere. Foundation drags in ARC-heavy bridging types
//    (NSString, NSData, DispatchQueue) that we cannot afford on the hot path.
//  * All platform syscalls and every CPython macro live in the C target so the
//    Swift side never has to import packed structs, unions or varargs.
//  * Whole-module optimisation + cross-module optimisation so the many tiny
//    `@inlinable` byte-pushing helpers actually collapse.

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    // Exclusivity checking on a struct-of-pointers connection table costs real
    // time and buys nothing: none of these structs are ever shared.
    .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
    .define("PEREGRINE_RELEASE", .when(configuration: .release)),
]

let package = Package(
    name: "peregrine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "peregrine", targets: ["peregrine"]),
        .library(name: "Peregrine", targets: ["PeregrineServer"]),
    ],
    targets: [
        // libpython, located through `python3-embed.pc`.
        .systemLibrary(
            name: "CPython",
            path: "Sources/CPython",
            pkgConfig: "python3-embed",
            providers: [
                .apt(["python3-dev"]),
                .yum(["python3-devel"]),
                .brew(["python@3.13"]),
            ]
        ),

        // Syscall wrappers (epoll/kqueue, sockets, sendfile, clock) plus every
        // CPython construct that is a macro, a union, or variadic.
        .target(
            name: "CPeregrine",
            dependencies: ["CPython"],
            path: "Sources/CPeregrine",
            cSettings: [
                // Feature-test macros are set inside the .c files, never here:
                // a define that reaches the module build would change glibc
                // struct layouts relative to SwiftGlibc.
                .headerSearchPath("include"),
            ],
            // TLS. OpenSSL supplies the primitives and the handshake; the
            // protocol state above it is ours. Headers are reached only from
            // peregrine_tls.c, never from anything Swift imports.
            linkerSettings: [
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
            ]
        ),

        .target(name: "PeregrineCore", dependencies: ["CPeregrine"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "PeregrineHTTP", dependencies: ["PeregrineCore"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "PeregrinePython", dependencies: ["CPython", "CPeregrine", "PeregrineCore"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "PeregrineWSGI",
                dependencies: ["PeregrineCore", "PeregrineHTTP", "PeregrinePython"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "PeregrineASGI",
                dependencies: ["PeregrineCore", "PeregrineHTTP", "PeregrinePython"],
                swiftSettings: sharedSwiftSettings),

        .target(name: "PeregrineServer",
                dependencies: ["PeregrineCore", "PeregrineHTTP", "PeregrinePython",
                               "PeregrineWSGI", "PeregrineASGI"],
                swiftSettings: sharedSwiftSettings),

        .executableTarget(name: "peregrine", dependencies: ["PeregrineServer"],
                          swiftSettings: sharedSwiftSettings),

        .testTarget(name: "PeregrineTests",
                    dependencies: ["PeregrineCore", "PeregrineHTTP"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cLanguageStandard: .gnu11
)

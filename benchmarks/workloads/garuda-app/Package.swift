// swift-tools-version: 6.1
import PackageDescription

// The Garuda half of benchmarks/workloads.sh: the four requests that do work,
// written as an application would write them. benchmarks/workloads/axum is
// the same four in axum.
let package = Package(
    name: "garuda-workloads",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "garuda", path: "../../.."),
    ],
    targets: [
        .executableTarget(name: "workloads",
                          dependencies: [.product(name: "Garuda", package: "garuda"),
                                         .product(name: "GarudaJSON", package: "garuda"),
                                         .product(name: "GarudaSQL", package: "garuda")]),
    ]
)

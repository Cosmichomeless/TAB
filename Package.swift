// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TABCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TABCore", targets: ["TABCore"]),
        // Synchronization with a backend. The shipped app does not link it (see docs/architecture/local-only.md).
        .library(name: "TABSync", targets: ["TABSync"]),
    ],
    targets: [
        .target(name: "TABCore"),
        .target(name: "TABSync", dependencies: ["TABCore"]),
        .testTarget(name: "TABCoreTests", dependencies: ["TABCore"]),
        .testTarget(name: "TABSyncTests", dependencies: ["TABSync", "TABCore"]),
    ]
)

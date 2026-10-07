// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TABCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TABCore", targets: ["TABCore"]),
    ],
    targets: [
        .target(name: "TABCore"),
        .testTarget(name: "TABCoreTests", dependencies: ["TABCore"]),
    ]
)

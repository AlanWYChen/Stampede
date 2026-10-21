// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stampede",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StampedeCore", targets: ["StampedeCore"]),
        .executable(name: "Stampede", targets: ["Stampede"]),
    ],
    targets: [
        .target(name: "StampedeCore", path: "src/StampedeCore"),
        .executableTarget(name: "Stampede", dependencies: ["StampedeCore"], path: "src/Stampede"),
        .testTarget(name: "StampedeCoreTests", dependencies: ["StampedeCore"]),
    ]
)

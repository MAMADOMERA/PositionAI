// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PositionAI",
    platforms: [.iOS(.v16)],
    targets: [
        .executableTarget(name: "PositionAI", path: "Sources")
    ]
)

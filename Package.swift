// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TokenBallCore", targets: ["TokenBallCore"]),
        .executable(name: "TokenUsage", targets: ["TokenBall"])
    ],
    targets: [
        .target(
            name: "TokenBallCore",
            dependencies: []
        ),
        .executableTarget(
            name: "TokenBall",
            dependencies: ["TokenBallCore"],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "TokenBallCoreTests",
            dependencies: ["TokenBallCore"]
        )
    ]
)

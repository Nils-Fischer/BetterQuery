// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BetterQuery",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "BetterQuery",
            targets: ["BetterQuery"]
        ),
    ],
    targets: [
        .target(
            name: "BetterQuery",
            path: "BetterQuery"
        ),
        .testTarget(
            name: "BetterQueryTests",
            dependencies: ["BetterQuery"],
            path: "BetterQueryTests"
        ),
    ]
)

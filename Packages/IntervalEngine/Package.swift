// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "IntervalEngine",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v13),
    ],
    products: [
        .library(name: "IntervalEngine", targets: ["IntervalEngine"]),
        .library(name: "IntervalUI", targets: ["IntervalUI"]),
    ],
    targets: [
        .target(name: "IntervalEngine"),
        .target(
            name: "IntervalUI",
            dependencies: ["IntervalEngine"]
        ),
        .testTarget(
            name: "IntervalEngineTests",
            dependencies: ["IntervalEngine"]
        ),
    ]
)

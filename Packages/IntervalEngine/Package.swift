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
    ],
    targets: [
        .target(name: "IntervalEngine"),
        .testTarget(
            name: "IntervalEngineTests",
            dependencies: ["IntervalEngine"]
        ),
    ]
)

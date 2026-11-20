// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DigestionInsights",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DigestionInsightsEngine", targets: ["DigestionInsightsEngine"]),
    ],
    targets: [
        .target(
            name: "DigestionInsightsEngine",
            swiftSettings: [
                // The sampler and model are numerical hot loops. Unoptimised
                // Debug builds (the app's development configuration) run them
                // about 30x slower than Release, so the engine is always
                // optimised. Allowed for local path packages in Xcode and
                // SwiftPM; a remote dependency would reject unsafeFlags.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                // Current (non-deprecated) CBLAS interface of Accelerate.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"]),
            ]
        ),
        .testTarget(
            name: "DigestionInsightsEngineTests",
            dependencies: ["DigestionInsightsEngine"]
        ),
    ]
)

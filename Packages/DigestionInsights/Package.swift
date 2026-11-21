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
        // Simulation study (synthetic users, SBC, recovery, calibration).
        // Not part of the library product; the app never links it.
        .target(
            name: "DigestionSimulation",
            dependencies: ["DigestionInsightsEngine"],
            path: "Simulation/Sources/DigestionSimulation"
        ),
        .executableTarget(
            name: "digestion-sim",
            dependencies: ["DigestionSimulation"],
            path: "Simulation/Sources/digestion-sim"
        ),
        .testTarget(
            name: "DigestionInsightsEngineTests",
            dependencies: ["DigestionInsightsEngine"]
        ),
        .testTarget(
            name: "DigestionSimulationTests",
            dependencies: ["DigestionSimulation"],
            path: "Simulation/Tests/DigestionSimulationTests"
        ),
    ]
)

import Foundation

/// Watch-side mirror of the app's `MockMode`. Separate module ⇒ its own copy.
/// Under `-mockData` (or `MOCK_DATA=1`) the watch synthesizes HR instead of
/// opening a real `HKWorkoutSession`, so the session flow is demoable in the
/// watch Simulator where sensors don't exist (spec §9).
enum MockMode {
    static let isActive: Bool =
        ProcessInfo.processInfo.arguments.contains("-mockData")
        || ProcessInfo.processInfo.environment["MOCK_DATA"] == "1"
}

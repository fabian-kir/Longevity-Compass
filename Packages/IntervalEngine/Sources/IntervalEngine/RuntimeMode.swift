import Foundation

/// Shared gate for the screenshot and simulator-only mock experience.
///
/// Keeping this in the cross-platform package ensures the phone and watch use
/// exactly the same launch contract. Release builds still ignore it because the
/// app layers only consult it inside `#if DEBUG` blocks.
public enum MockMode {
    public static let isActive =
        ProcessInfo.processInfo.arguments.contains("-mockData")
        || ProcessInfo.processInfo.environment["MOCK_DATA"] == "1"
}

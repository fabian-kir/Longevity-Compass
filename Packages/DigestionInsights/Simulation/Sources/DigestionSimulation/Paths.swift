import Foundation

/// File locations of the simulation study, from the package root.
public struct SimulationPaths: Sendable {
    public var packageRoot: URL

    public init(packageRoot: URL) {
        self.packageRoot = packageRoot
    }

    /// Raw runs and logs: `build/digestion-sim/` at the repository root (git-ignored).
    public var rawDirectory: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/digestion-sim", isDirectory: true)
    }
    public var recoveryRecords: URL { rawDirectory.appendingPathComponent("recovery.jsonl") }
    public var sbcRecords: URL { rawDirectory.appendingPathComponent("sbc.json") }
    public var resultsJSON: URL { packageRoot.appendingPathComponent("Simulation/results.json") }
    public var resultsMarkdown: URL { packageRoot.appendingPathComponent("Simulation/results.md") }
}

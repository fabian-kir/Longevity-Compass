import Foundation

/// Per-parameter diagnostics.
public struct ParameterDiagnostics: Sendable, Codable, Equatable {
    public var rhat: Double
    public var bulkESS: Double
    public var tailESS: Double
}

/// Run-level diagnostics of one sampler output.
public struct SamplerDiagnostics: Sendable, Codable, Equatable {
    /// Maximum rank-normalised split-R̂ over parameters (NaN if any is NaN).
    public var maxRhat: Double
    public var minBulkESS: Double
    public var minTailESS: Double
    /// Post-warmup divergent transitions, all chains.
    public var divergences: Int
    /// Post-warmup transitions that hit the maximum tree depth.
    public var treeDepthHits: Int
    /// Adapted step size per chain, chain order.
    public var stepSizes: [Double]
    public var leapfrogSteps: Int
    public var parameters: [ParameterDiagnostics]

    /// Diagnostics over all sampled parameters (or the given subset).
    public init(_ output: SamplerOutput, parameters indices: [Int]? = nil) {
        let selected = indices ?? Array(0..<output.dimension)
        var perParameter = [ParameterDiagnostics](
            repeating: ParameterDiagnostics(rhat: .nan, bulkESS: .nan, tailESS: .nan),
            count: selected.count
        )
        // Parameters are independent; slots are written by index, so the
        // result does not depend on scheduling.
        perParameter.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: selected.count) { k in
                let traces = output.traces(of: selected[k])
                slots[k] = ParameterDiagnostics(
                    rhat: Diagnostics.splitRhat(traces),
                    bulkESS: Diagnostics.bulkESS(traces),
                    tailESS: Diagnostics.tailESS(traces)
                )
            }
        }
        parameters = perParameter
        maxRhat = Self.nanAwareMax(perParameter.map(\.rhat))
        minBulkESS = Self.nanAwareMin(perParameter.map(\.bulkESS))
        minTailESS = Self.nanAwareMin(perParameter.map(\.tailESS))
        divergences = output.divergences
        treeDepthHits = output.treeDepthHits
        stepSizes = output.chains.map(\.stepSize)
        leapfrogSteps = output.totalLeapfrogSteps
    }

    static func nanAwareMax(_ values: [Double]) -> Double {
        if values.isEmpty || values.contains(where: \.isNaN) { return .nan }
        return values.max()!
    }

    static func nanAwareMin(_ values: [Double]) -> Double {
        if values.isEmpty || values.contains(where: \.isNaN) { return .nan }
        return values.min()!
    }
}

/// Convergence pass (B9): max split-R̂ < 1.01, min bulk ESS ≥ 400, no
/// divergences. NaN diagnostics fail.
public struct ConvergenceCriteria: Sendable, Codable, Equatable {
    public var maxRhat: Double
    public var minBulkESS: Double
    public var maxDivergences: Int

    public init(maxRhat: Double = 1.01, minBulkESS: Double = 400, maxDivergences: Int = 0) {
        self.maxRhat = maxRhat
        self.minBulkESS = minBulkESS
        self.maxDivergences = maxDivergences
    }

    public static let `default` = ConvergenceCriteria()

    public func isConverged(maxRhat rhat: Double, minBulkESS ess: Double, divergences: Int) -> Bool {
        rhat < maxRhat && ess >= minBulkESS && divergences <= maxDivergences
    }

    public func isConverged(_ diagnostics: SamplerDiagnostics) -> Bool {
        isConverged(maxRhat: diagnostics.maxRhat, minBulkESS: diagnostics.minBulkESS, divergences: diagnostics.divergences)
    }
}

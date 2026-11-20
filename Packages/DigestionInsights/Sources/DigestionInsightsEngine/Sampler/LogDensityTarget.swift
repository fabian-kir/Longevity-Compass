import Foundation

/// A differentiable log density on unconstrained ℝ^dimension.
///
/// The sampler calls `logDensity` once per leapfrog step. Implementations write
/// the gradient into `gradient` in place and return the log density up to an
/// additive constant. A non-finite return value marks the point as outside the
/// support; the sampler treats the trajectory as divergent there.
///
/// Targets are shared by all chains, so they must be immutable. Mutable scratch
/// memory belongs in `Workspace`: every chain makes its own through
/// `makeWorkspace()`.
public protocol LogDensityTarget: Sendable {
    associatedtype Workspace = Void

    var dimension: Int { get }

    func makeWorkspace() -> Workspace

    func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace: inout Workspace
    ) -> Double

    /// Optional starting point. `nil` means uniform on [−radius, radius]^d
    /// (`NUTSConfiguration.initRadius`), the usual default.
    func initialPosition(rng: inout Xoshiro256StarStar) -> [Double]?
}

public extension LogDensityTarget where Workspace == Void {
    func makeWorkspace() {}
}

public extension LogDensityTarget {
    func initialPosition(rng: inout Xoshiro256StarStar) -> [Double]? { nil }

    /// Convenience for tests and finite-difference checks (allocates).
    func logDensityAndGradient(at position: [Double]) -> (value: Double, gradient: [Double]) {
        precondition(position.count == dimension, "position has wrong dimension")
        var workspace = makeWorkspace()
        var gradient = [Double](repeating: 0, count: dimension)
        let value = position.withUnsafeBufferPointer { q in
            gradient.withUnsafeMutableBufferPointer { g in
                logDensity(q, gradient: g, workspace: &workspace)
            }
        }
        return (value, gradient)
    }

    /// Central finite-difference gradient, for verifying analytic gradients.
    func finiteDifferenceGradient(at position: [Double], step: Double = 1e-6) -> [Double] {
        var result = [Double](repeating: 0, count: dimension)
        var shifted = position
        for i in 0..<dimension {
            let h = step * max(1, abs(position[i]))
            shifted[i] = position[i] + h
            let up = logDensityAndGradient(at: shifted).value
            shifted[i] = position[i] - h
            let down = logDensityAndGradient(at: shifted).value
            shifted[i] = position[i]
            result[i] = (up - down) / (2 * h)
        }
        return result
    }
}

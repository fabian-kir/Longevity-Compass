import Accelerate

/// Targets with known exact moments, used to validate the sampler (B12: no
/// external reference implementation; exact answers instead).

/// Independent standard normal in `dimension` dimensions.
public struct StandardNormalTarget: LogDensityTarget {
    public let dimension: Int

    public init(dimension: Int) {
        self.dimension = dimension
    }

    public func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace: inout Void
    ) -> Double {
        let n = vDSP_Length(dimension)
        var sumSquares = 0.0
        vDSP_svesqD(position.baseAddress!, 1, &sumSquares, n)
        vDSP_vnegD(position.baseAddress!, 1, gradient.baseAddress!, 1, n)
        return -0.5 * sumSquares
    }
}

/// Bivariate normal with zero mean, unit variances and correlation `rho`.
public struct CorrelatedNormal2DTarget: LogDensityTarget {
    public let rho: Double
    public var dimension: Int { 2 }

    public init(rho: Double) {
        precondition(abs(rho) < 1, "correlation must lie in (−1, 1)")
        self.rho = rho
    }

    public func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace: inout Void
    ) -> Double {
        let x = position[0], y = position[1]
        let scale = 1 / (1 - rho * rho)
        gradient[0] = -scale * (x - rho * y)
        gradient[1] = -scale * (y - rho * x)
        return -0.5 * scale * (x * x - 2 * rho * x * y + y * y)
    }
}

/// Neal's funnel in non-centred form: v ~ N(0, 3²), z_i ~ N(0, 1), sampled
/// directly; x_i = exp(v / 2) · z_i is the funnel variable. Exact moments:
/// E[v] = 0, Var[v] = 9, E[z_i] = 0, Var[z_i] = 1.
public struct NonCentredFunnelTarget: LogDensityTarget {
    public let dimension: Int

    /// `dimension` = 1 (v) + number of z_i.
    public init(dimension: Int) {
        precondition(dimension >= 2, "funnel needs v and at least one z")
        self.dimension = dimension
    }

    public func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace: inout Void
    ) -> Double {
        let v = position[0]
        var logp = -v * v / 18
        gradient[0] = -v / 9
        for i in 1..<dimension {
            logp -= 0.5 * position[i] * position[i]
            gradient[i] = -position[i]
        }
        return logp
    }
}

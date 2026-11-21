import Accelerate
import Foundation

/// Bayesian distributed-lag Poisson model (B9).
///
///     y[h, s] ~ Poisson(exp η[h, s])
///     η[h, s] = α_s + tod(h) + drift(h) + Σ_f Σ_k X[h, f, k] (b[f, k] + d[f, s, k])
///
/// Non-centred priors, all scales sampled on the log scale with Jacobian:
///
///     b_f = τ_g λ_f C z_f,       z_f ~ N(0, I),  τ_g ~ HN(0.5), λ_f ~ HN(1)
///     d_fs = λ_f σ_d C z_fs,     z_fs ~ N(0, I), σ_d ~ HN(kindDeviationScale)
///     C = chol((ωP + diag κ_k)⁻¹), P = second-difference penalty, κ_k growing with lag
///     λ_f ~ HalfCauchy(1) (default; B9 draft: HalfNormal)
///
/// Defaults deviate from the B9 draft where the draft failed planted-trigger
/// recovery; the switches in `ModelPriors` restore the draft for comparison.
///     α_s ~ N(log observed base rate, 2)
///     tod(h) = Σ_j γ_j T_j(h),   2 Fourier harmonics, γ_j ~ N(0, 1)
///     drift(h) = Σ_j D_j(h) δ_j, cubic B-spline over days, ~1 knot / 30 days,
///                columns centred; δ = σ_drift C_D u, u ~ N(0, I), σ_drift ~ HN(0.3)
///
/// Cross-basis and drift columns are centred over the fit's rows, which only
/// reparametrises α_s (see `init`). Everything enters η through one augmented
/// design Xa = [X̃ | T | D̃ | 1], so
/// η = Xa · W and ∇ = Xaᵀ (y − μ) are two dense matrix products per gradient.
public struct LagModel: LogDensityTarget {
    /// Parameter vector layout (offsets into the position).
    public struct Layout: Sendable {
        public let kinds: Int
        public let features: Int
        public let basis: Int
        public let todTerms: Int
        public let driftTerms: Int

        public var alpha: Int { 0 }
        public var tod: Int { alpha + kinds }
        public var driftU: Int { tod + todTerms }
        public var logSigmaDrift: Int { driftU + driftTerms }
        public var logTauGlobal: Int { logSigmaDrift + 1 }
        public var logLambda: Int { logTauGlobal + 1 }
        public var zShared: Int { logLambda + features }
        public var logSigmaKind: Int { zShared + features * basis }
        public var zKind: Int { logSigmaKind + 1 }
        public var dimension: Int { zKind + features * kinds * basis }

        /// Design columns: features · basis, then tod, drift, intercept.
        public var designColumns: Int { features * basis + todTerms + driftTerms + 1 }
    }

    public final class Workspace {
        let weights: Vector     // P × S
        let eta: Vector         // H × S
        let mu: Vector          // H × S
        let residual: Vector    // H × S
        let gradW: Vector       // P × S
        let shared: Vector      // F × K (b)
        let kind: Vector        // F·S × K (d)
        let gradShared: Vector  // F × K
        let gradKind: Vector    // F·S × K
        let temp: Vector        // max(F·S, F) × K
        let drift: Vector       // J
        let gradDrift: Vector   // J

        init(layout: Layout, rows: Int) {
            let p = layout.designColumns, s = layout.kinds, f = layout.features, k = layout.basis
            weights = Vector(p * s)
            eta = Vector(rows * s)
            mu = Vector(rows * s)
            residual = Vector(rows * s)
            gradW = Vector(p * s)
            shared = Vector(f * k)
            kind = Vector(f * s * k)
            gradShared = Vector(f * k)
            gradKind = Vector(f * s * k)
            temp = Vector(max(f * s, f, 1) * k)
            drift = Vector(layout.driftTerms)
            gradDrift = Vector(layout.driftTerms)
        }
    }

    public let layout: Layout
    public let rows: Int
    public let priors: ModelPriors
    /// Augmented design, row-major rows × designColumns.
    public let design: [Double]
    public let counts: [Double]
    /// Prior means of α_s: log((count_s + 0.5) / rows).
    public let interceptMeans: [Double]
    /// Lag prior factor C (K × K, lower) and its transpose.
    public let lagFactor: [Double]
    public let lagFactorT: [Double]
    public let driftFactor: [Double]
    public let driftFactorT: [Double]
    /// Means of the uncentred cross-basis columns over the fit's rows (F·K).
    public let featureMeans: [Double]

    public var dimension: Int { layout.dimension }

    static let todTerms = 4

    /// Model on the given rows (indices into `data.hours`).
    public init(data: LagData, rows rowIndices: [Int], priors: ModelPriors, driftKnotSpacingDays: Double) {
        let s = data.kindCount, f = data.featureCount, k = data.basisCount
        let firstHour = data.hours[rowIndices.first!]
        let lastHour = data.hours[rowIndices.last!]
        let spanDays = Double(lastHour + 1 - firstHour) / 24
        let interiorCount = max(0, Int((spanDays / driftKnotSpacingDays).rounded()) - 1)
        let driftBasis = BSplineBasis(
            lower: 0,
            upper: spanDays,
            interiorKnots: (0..<interiorCount).map { spanDays * Double($0 + 1) / Double(interiorCount + 1) }
        )
        let j = driftBasis.count
        layout = Layout(kinds: s, features: f, basis: k, todTerms: Self.todTerms, driftTerms: j)
        rows = rowIndices.count
        self.priors = priors

        let p = layout.designColumns
        let fk = f * k
        var design = [Double](repeating: 0, count: rows * p)
        var counts = [Double](repeating: 0, count: rows * s)
        var driftValues = [Double](repeating: 0, count: j)
        for (r, row) in rowIndices.enumerated() {
            let hour = data.hours[row]
            for c in 0..<fk { design[r * p + c] = data.crossBasis[row * fk + c] }
            // Time of day from the absolute hour (UTC); a constant time-zone
            // offset only shifts the Fourier phase.
            let hourOfDay = Double(((hour % 24) + 24) % 24) + 0.5
            let angle = 2 * Double.pi * hourOfDay / 24
            design[r * p + fk] = sin(angle)
            design[r * p + fk + 1] = cos(angle)
            design[r * p + fk + 2] = sin(2 * angle)
            design[r * p + fk + 3] = cos(2 * angle)
            driftValues.withUnsafeMutableBufferPointer {
                driftBasis.evaluate(at: (Double(hour - firstHour) + 0.5) / 24, into: $0.baseAddress!)
            }
            for c in 0..<j { design[r * p + fk + 4 + c] = driftValues[c] }
            design[r * p + p - 1] = 1
            for kind in 0..<s { counts[r * s + kind] = data.counts[row * s + kind] }
        }
        // Centre cross-basis and drift columns over the fit's rows. Drift: its
        // constant part belongs to α_s. Cross-basis: the columns of a feature
        // sum to its rolling exposure count, nearly constant for frequent
        // foods, so uncentred columns tie α_s to every flat lag curve along a
        // curved ridge (divergences). Centring only moves the intercept:
        // α_s(uncentred) = α_s − Σ_fk X̄[f, k] W[fk, s]; b and d are unchanged.
        var columnMeans = [Double](repeating: 0, count: fk + j)
        for c in 0..<(fk + j) {
            let column = c < fk ? c : fk + Self.todTerms + (c - fk)
            var mean = 0.0
            for r in 0..<rows { mean += design[r * p + column] }
            mean /= Double(rows)
            for r in 0..<rows { design[r * p + column] -= mean }
            columnMeans[c] = mean
        }
        featureMeans = Array(columnMeans[0..<fk])
        self.design = design
        self.counts = counts
        let rowCount = rowIndices.count
        interceptMeans = (0..<s).map { kind in
            var total = 0.0
            for r in 0..<rowCount { total += counts[r * s + kind] }
            return log((total + 0.5) / Double(rowIndices.count))
        }
        lagFactor = Self.lagPriorFactor(basis: data.lagBasis, priors: priors)
        lagFactorT = DenseMatrix.transpose(lagFactor, rows: k, columns: k)
        driftFactor = BSplineBasis.priorFactor(size: j, ridge: 1)
        driftFactorT = DenseMatrix.transpose(driftFactor, rows: j, columns: j)
    }

    /// C = chol((ωP + diag κ_k)⁻¹) with κ_k = κ (1 + (g_k / lagDecayHours)²),
    /// g_k the Greville abscissa (lag "centre") of basis function k. The
    /// lag-dependent ridge shrinks long-lag coefficients towards zero, as in
    /// Bayesian distributed-lag models (Welty et al. 2009) and the varying
    /// ridge of penalised DLNMs (Gasparrini et al. 2017).
    static func lagPriorFactor(basis: BSplineBasis, priors: ModelPriors) -> [Double] {
        let k = basis.count
        let ridge = (0..<k).map { index -> Double in
            guard priors.lagDecayHours > 0 else { return priors.lagRidge }
            let greville = (1...basis.degree).reduce(0) { $0 + basis.knots[index + $1] } / Double(basis.degree)
            let ratio = greville / priors.lagDecayHours
            return priors.lagRidge * (1 + ratio * ratio)
        }
        return BSplineBasis.priorFactor(size: k, ridge: ridge, smoothing: priors.lagSmoothing)
    }

    public func makeWorkspace() -> Workspace {
        Workspace(layout: layout, rows: rows)
    }

    /// α near its prior mean, everything else in a modest box so the first
    /// evaluation does not overflow; still dispersed across chains.
    public func initialPosition(rng: inout Xoshiro256StarStar) -> [Double]? {
        var q = (0..<dimension).map { _ in rng.uniform(in: -1, 1) }
        for s in 0..<layout.kinds { q[layout.alpha + s] = interceptMeans[s] + rng.uniform(in: -1, 1) }
        q[layout.logSigmaDrift] = log(priors.driftScale) + rng.uniform(in: -1, 1)
        q[layout.logTauGlobal] = log(priors.globalScale) + rng.uniform(in: -1, 1)
        for f in 0..<layout.features { q[layout.logLambda + f] = log(priors.localScale) + rng.uniform(in: -1, 1) }
        q[layout.logSigmaKind] = log(priors.kindDeviationScale) + rng.uniform(in: -1, 1)
        return q
    }

    // MARK: - Effects from parameters

    /// Scale of d_fs = scale · C z_fs (`ModelPriors.kindDeviationScaling`),
    /// after the slab (`ModelPriors.slab`), with ρ = ∂ log scale / ∂ log raw scale.
    @inline(__always)
    func kindSlab(_ q: UnsafePointer<Double>, feature: Int, tauGlobal: Double, sigmaKind: Double) -> (scale: Double, rho: Double) {
        switch priors.kindDeviationScaling {
        case .absolute: return priors.slab(sigmaKind)
        case .local: return priors.slab(exp(q[layout.logLambda + feature]) * sigmaKind)
        case .feature: return priors.slab(tauGlobal * exp(q[layout.logLambda + feature]) * sigmaKind)
        }
    }

    @inline(__always)
    func kindScale(_ q: UnsafePointer<Double>, feature: Int, tauGlobal: Double, sigmaKind: Double) -> Double {
        kindSlab(q, feature: feature, tauGlobal: tauGlobal, sigmaKind: sigmaKind).scale
    }

    /// Scale of b_f = scale · C z_f: τ_g λ_f after the slab, with
    /// ρ = ∂ log scale / ∂ log(τ_g λ_f).
    @inline(__always)
    func sharedSlab(_ q: UnsafePointer<Double>, feature: Int) -> (scale: Double, rho: Double) {
        priors.slab(exp(q[layout.logTauGlobal] + q[layout.logLambda + feature]))
    }

    /// Fills `ws.shared` (b, F × K), `ws.kind` (d, F·S × K), `ws.drift` (δ)
    /// and the weight matrix W (P × S) from position q.
    func fillWeights(_ q: UnsafePointer<Double>, _ ws: Workspace) {
        let s = layout.kinds, f = layout.features, k = layout.basis, j = layout.driftTerms
        let p = layout.designColumns
        let tauGlobal = exp(q[layout.logTauGlobal])
        let sigmaKind = exp(q[layout.logSigmaKind])
        let sigmaDrift = exp(q[layout.logSigmaDrift])

        lagFactorT.withUnsafeBufferPointer { ct in
            if f > 0 {
                // b[f, ·] = τ_f · C z_f, as rows: Z (F × K) · Cᵀ.
                vDSP_mmulD(q + layout.zShared, 1, ct.baseAddress!, 1, ws.shared.p, 1, vDSP_Length(f), vDSP_Length(k), vDSP_Length(k))
                for feature in 0..<f {
                    var tau = sharedSlab(q, feature: feature).scale
                    vDSP_vsmulD(ws.shared.p + feature * k, 1, &tau, ws.shared.p + feature * k, 1, vDSP_Length(k))
                }
                vDSP_mmulD(q + layout.zKind, 1, ct.baseAddress!, 1, ws.kind.p, 1, vDSP_Length(f * s), vDSP_Length(k), vDSP_Length(k))
                for feature in 0..<f {
                    var scale = kindScale(q, feature: feature, tauGlobal: tauGlobal, sigmaKind: sigmaKind)
                    vDSP_vsmulD(ws.kind.p + feature * s * k, 1, &scale, ws.kind.p + feature * s * k, 1, vDSP_Length(s * k))
                }
            }
        }
        driftFactor.withUnsafeBufferPointer { cd in
            vDSP_mmulD(cd.baseAddress!, 1, q + layout.driftU, 1, ws.drift.p, 1, vDSP_Length(j), 1, vDSP_Length(j))
        }
        var scale = sigmaDrift
        vDSP_vsmulD(ws.drift.p, 1, &scale, ws.drift.p, 1, vDSP_Length(j))

        let w = ws.weights.p
        for feature in 0..<f {
            for basis in 0..<k {
                let row = (feature * k + basis) * s
                let b = ws.shared.p[feature * k + basis]
                for kind in 0..<s {
                    w[row + kind] = b + ws.kind.p[(feature * s + kind) * k + basis]
                }
            }
        }
        let fk = f * k
        for term in 0..<layout.todTerms {
            for kind in 0..<s { w[(fk + term) * s + kind] = q[layout.tod + term] }
        }
        for term in 0..<j {
            for kind in 0..<s { w[(fk + layout.todTerms + term) * s + kind] = ws.drift.p[term] }
        }
        for kind in 0..<s { w[(p - 1) * s + kind] = q[layout.alpha + kind] }
    }

    /// η (rows × kinds, row-major) at `position`: for simulating outcomes
    /// from parameter draws (SBC).
    public func linearPredictor(_ position: [Double]) -> [Double] {
        precondition(position.count == dimension, "position has wrong dimension")
        let ws = makeWorkspace()
        position.withUnsafeBufferPointer { fillWeights($0.baseAddress!, ws) }
        var eta = [Double](repeating: 0, count: rows * layout.kinds)
        vDSP_mmulD(design, 1, ws.weights.p, 1, &eta, 1, vDSP_Length(rows), vDSP_Length(layout.kinds), vDSP_Length(layout.designColumns))
        return eta
    }

    // MARK: - Log density

    public func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace ws: inout Workspace
    ) -> Double {
        let q = position.baseAddress!
        let g = gradient.baseAddress!
        let s = layout.kinds, f = layout.features, k = layout.basis, j = layout.driftTerms
        let p = layout.designColumns
        let n = rows * s

        fillWeights(q, ws)

        // η = Xa · W, μ = exp η.
        design.withUnsafeBufferPointer { x in
            vDSP_mmulD(x.baseAddress!, 1, ws.weights.p, 1, ws.eta.p, 1, vDSP_Length(rows), vDSP_Length(s), vDSP_Length(p))
        }
        var count32 = Int32(n)
        vvexp(ws.mu.p, ws.eta.p, &count32)

        var logLikelihood = 0.0
        var sumMu = 0.0
        counts.withUnsafeBufferPointer { y in
            vDSP_dotprD(y.baseAddress!, 1, ws.eta.p, 1, &logLikelihood, vDSP_Length(n))
            vDSP_vsubD(ws.mu.p, 1, y.baseAddress!, 1, ws.residual.p, 1, vDSP_Length(n))  // y − μ
        }
        vDSP_sveD(ws.mu.p, 1, &sumMu, vDSP_Length(n))
        logLikelihood -= sumMu
        guard logLikelihood.isFinite else {
            gradient.update(repeating: 0)
            return -.infinity
        }

        // ∂ℓ/∂W = Xaᵀ (y − μ). The transposed product reads Xa row-major
        // directly (3x faster than vDSP_mmulD on a stored transpose).
        design.withUnsafeBufferPointer { x in
            cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans, __LAPACK_int(p), __LAPACK_int(s), __LAPACK_int(rows),
                        1, x.baseAddress!, __LAPACK_int(p), ws.residual.p, __LAPACK_int(s), 0, ws.gradW.p, __LAPACK_int(s))
        }
        let gw = ws.gradW.p
        var logPrior = 0.0

        // Intercepts.
        let interceptPrecision = 1 / (priors.interceptSD * priors.interceptSD)
        for kind in 0..<s {
            let a = q[layout.alpha + kind]
            let deviation = a - interceptMeans[kind]
            logPrior -= 0.5 * deviation * deviation * interceptPrecision
            g[layout.alpha + kind] = gw[(p - 1) * s + kind] - deviation * interceptPrecision
        }

        // Time of day.
        let fk = f * k
        let todPrecision = 1 / (priors.timeOfDaySD * priors.timeOfDaySD)
        for term in 0..<layout.todTerms {
            var sum = 0.0
            for kind in 0..<s { sum += gw[(fk + term) * s + kind] }
            let gamma = q[layout.tod + term]
            logPrior -= 0.5 * gamma * gamma * todPrecision
            g[layout.tod + term] = sum - gamma * todPrecision
        }

        // Drift: δ = σ_drift C_D u.
        let sigmaDrift = exp(q[layout.logSigmaDrift])
        var driftChain = 0.0
        for term in 0..<j {
            var sum = 0.0
            for kind in 0..<s { sum += gw[(fk + layout.todTerms + term) * s + kind] }
            ws.gradDrift.p[term] = sum
            driftChain += sum * ws.drift.p[term]
        }
        // ∂/∂u = σ_drift C_Dᵀ ∂δ (row vector ∂δ · C_D) − u.
        driftFactor.withUnsafeBufferPointer { cd in
            vDSP_mmulD(ws.gradDrift.p, 1, cd.baseAddress!, 1, g + layout.driftU, 1, 1, vDSP_Length(j), vDSP_Length(j))
        }
        for term in 0..<j {
            let u = q[layout.driftU + term]
            logPrior -= 0.5 * u * u
            g[layout.driftU + term] = sigmaDrift * g[layout.driftU + term] - u
        }
        logPrior += halfNormalLogScale(q[layout.logSigmaDrift], scale: priors.driftScale)
        g[layout.logSigmaDrift] = driftChain + halfNormalLogScaleGradient(q[layout.logSigmaDrift], scale: priors.driftScale)

        // Feature effects.
        let tauGlobal = exp(q[layout.logTauGlobal])
        let sigmaKind = exp(q[layout.logSigmaKind])
        var tauGlobalChain = 0.0
        var sigmaKindChain = 0.0
        if f > 0 {
            for feature in 0..<f {
                var lambdaChain = 0.0
                var kindChain = 0.0
                for basis in 0..<k {
                    let row = (feature * k + basis) * s
                    var shared = 0.0
                    for kind in 0..<s {
                        let gKind = gw[row + kind]
                        shared += gKind
                        ws.gradKind.p[(feature * s + kind) * k + basis] = gKind
                        kindChain += gKind * ws.kind.p[(feature * s + kind) * k + basis]
                    }
                    ws.gradShared.p[feature * k + basis] = shared
                    lambdaChain += shared * ws.shared.p[feature * k + basis]
                }
                // With a slab, ∂ scale / ∂ log raw scale = ρ · scale.
                lambdaChain *= sharedSlab(q, feature: feature).rho
                kindChain *= kindSlab(q, feature: feature, tauGlobal: tauGlobal, sigmaKind: sigmaKind).rho
                sigmaKindChain += kindChain
                // Deviations scaled by λ_f (and τ_g) feed those gradients too.
                switch priors.kindDeviationScaling {
                case .absolute:
                    tauGlobalChain += lambdaChain
                case .local:
                    tauGlobalChain += lambdaChain
                    lambdaChain += kindChain
                case .feature:
                    lambdaChain += kindChain
                    tauGlobalChain += lambdaChain
                }
                let logLambda = q[layout.logLambda + feature]
                logPrior += scaleLogDensity(logLambda, scale: priors.localScale, distribution: priors.localDistribution)
                g[layout.logLambda + feature] = lambdaChain
                    + scaleLogDensityGradient(logLambda, scale: priors.localScale, distribution: priors.localDistribution)
            }
            lagFactor.withUnsafeBufferPointer { c in
                // ∂/∂z_f = τ_f Cᵀ ∂b_f − z_f; as rows: ∂B (F × K) · C.
                vDSP_mmulD(ws.gradShared.p, 1, c.baseAddress!, 1, ws.temp.p, 1, vDSP_Length(f), vDSP_Length(k), vDSP_Length(k))
                for feature in 0..<f {
                    let tau = sharedSlab(q, feature: feature).scale
                    for basis in 0..<k {
                        let index = layout.zShared + feature * k + basis
                        g[index] = tau * ws.temp.p[feature * k + basis] - q[index]
                    }
                }
                vDSP_mmulD(ws.gradKind.p, 1, c.baseAddress!, 1, ws.temp.p, 1, vDSP_Length(f * s), vDSP_Length(k), vDSP_Length(k))
            }
            let zKindCount = f * s * k
            var sumSquares = 0.0
            vDSP_svesqD(q + layout.zShared, 1, &sumSquares, vDSP_Length(f * k))
            logPrior -= 0.5 * sumSquares
            vDSP_svesqD(q + layout.zKind, 1, &sumSquares, vDSP_Length(zKindCount))
            logPrior -= 0.5 * sumSquares
            // ∂/∂z_fs = scale_f (∂d_fs · C) − z_fs
            for feature in 0..<f {
                var scale = kindScale(q, feature: feature, tauGlobal: tauGlobal, sigmaKind: sigmaKind)
                vDSP_vsmulD(ws.temp.p + feature * s * k, 1, &scale, g + layout.zKind + feature * s * k, 1, vDSP_Length(s * k))
            }
            vDSP_vsubD(q + layout.zKind, 1, g + layout.zKind, 1, g + layout.zKind, 1, vDSP_Length(zKindCount))
        }
        logPrior += halfNormalLogScale(q[layout.logTauGlobal], scale: priors.globalScale)
        g[layout.logTauGlobal] = tauGlobalChain + halfNormalLogScaleGradient(q[layout.logTauGlobal], scale: priors.globalScale)
        logPrior += halfNormalLogScale(q[layout.logSigmaKind], scale: priors.kindDeviationScale)
        g[layout.logSigmaKind] = sigmaKindChain + halfNormalLogScaleGradient(q[layout.logSigmaKind], scale: priors.kindDeviationScale)

        return logLikelihood + logPrior
    }
}

/// log HalfNormal(e^θ | scale) + θ (Jacobian), constants dropped.
@inline(__always)
func halfNormalLogScale(_ theta: Double, scale: Double) -> Double {
    let x = exp(theta)
    return -0.5 * x * x / (scale * scale) + theta
}

@inline(__always)
func halfNormalLogScaleGradient(_ theta: Double, scale: Double) -> Double {
    let x = exp(theta)
    return 1 - x * x / (scale * scale)
}

/// log p(e^θ) + θ for a half-normal or half-Cauchy scale, constants dropped.
@inline(__always)
func scaleLogDensity(_ theta: Double, scale: Double, distribution: ScaleDistribution) -> Double {
    switch distribution {
    case .halfNormal:
        return halfNormalLogScale(theta, scale: scale)
    case .halfCauchy:
        let ratio = exp(theta) / scale
        return -log1p(ratio * ratio) + theta
    }
}

@inline(__always)
func scaleLogDensityGradient(_ theta: Double, scale: Double, distribution: ScaleDistribution) -> Double {
    switch distribution {
    case .halfNormal:
        return halfNormalLogScaleGradient(theta, scale: scale)
    case .halfCauchy:
        let r2 = exp(2 * theta) / (scale * scale)
        return 1 - 2 * r2 / (1 + r2)
    }
}

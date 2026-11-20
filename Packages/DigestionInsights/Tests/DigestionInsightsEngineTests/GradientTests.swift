import XCTest
@testable import DigestionInsightsEngine

/// The sampler trusts the analytic gradient completely, so it is checked
/// against central finite differences in every parameter block, and the log
/// density itself against a direct evaluation of the B9 formulas.
final class GradientTests: XCTestCase {

    private func smallModel(rows: ((LagData) -> [Int])? = nil, priors: ModelPriors = .default) -> (LagModel, LagData) {
        let scenario = SyntheticScenario(
            days: 40,
            features: [("a", 0.4), ("b", 0.3), ("c", 0.2)],
            kinds: ["k1", "k2", "k3"],
            baselinePerDay: [0.6, 0.4, 0.3],
            trigger: .init(feature: "a", kind: "k1", lagRange: 4..<8, multiplier: 3),
            seed: 3
        )
        let data = LagData(input: scenario.makeInput(config: fastConfig()))
        let rowIndices = rows?(data) ?? Array(data.hours.indices)
        return (LagModel(data: data, rows: rowIndices, priors: priors, driftKnotSpacingDays: 10), data)
    }

    private func randomPosition(_ model: LagModel, seed: UInt64) -> [Double] {
        var rng = Xoshiro256StarStar(seed: seed)
        var q = model.initialPosition(rng: &rng)!
        // Move away from the initialisation box a little more.
        for i in q.indices { q[i] += 0.3 * rng.standardNormal() }
        return q
    }

    private func assertGradientMatches(_ model: LagModel, _ q: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let analytic = model.logDensityAndGradient(at: q).gradient
        let numeric = model.finiteDifferenceGradient(at: q, step: 1e-5)
        var worst = 0.0
        for i in analytic.indices {
            let error = abs(analytic[i] - numeric[i]) / max(1, abs(numeric[i]))
            worst = max(worst, error)
            if error > 1e-5 {
                XCTFail("parameter \(i): analytic \(analytic[i]) vs numeric \(numeric[i])", file: file, line: line)
                return
            }
        }
        XCTAssertLessThan(worst, 1e-5, file: file, line: line)
    }

    func testGradientMatchesFiniteDifferencesFeatureScaledDeviations() {
        let (model, _) = smallModel(priors: ModelPriors(kindDeviationScaling: .feature))
        assertGradientMatches(model, randomPosition(model, seed: 4))
    }

    func testGradientMatchesFiniteDifferencesFullFit() {
        let (model, _) = smallModel()
        XCTAssertEqual(model.layout.features, 3)
        XCTAssertEqual(model.layout.basis, 8)
        for seed in [1, 2, 3] as [UInt64] {
            assertGradientMatches(model, randomPosition(model, seed: seed))
        }
    }

    func testGradientMatchesFiniteDifferencesHalfFitAndDraftPriors() {
        // Ridge 1e-3 (the B9 draft) makes C entries ~30, so generic test points
        // give log densities near −1e12 where finite differences are noise.
        // Also the B9-draft switches: half-normal λ, absolute d, no lag decay.
        let priors = ModelPriors(
            lagRidge: 0.05, lagSmoothing: 0.5, lagDecayHours: 0, globalScale: 1.2, localScale: 0.7,
            localDistribution: .halfNormal, kindDeviationScale: 0.5, kindDeviationScaling: .absolute,
            interceptSD: 1.5, timeOfDaySD: 0.8, driftScale: 0.6
        )
        let (model, _) = smallModel(rows: { data in Array(data.hours.indices.prefix(data.hours.count / 2)) }, priors: priors)
        assertGradientMatches(model, randomPosition(model, seed: 7))
    }

    func testLogDensityMatchesDirectFormula() {
        let (model, data) = smallModel()
        let q = randomPosition(model, seed: 11)
        let layout = model.layout
        let s = layout.kinds, f = layout.features, k = layout.basis, j = layout.driftTerms
        let priors = model.priors
        let c = model.lagFactor
        let cd = model.driftFactor

        func lowerTimes(_ matrix: [Double], _ v: [Double], _ n: Int) -> [Double] {
            (0..<n).map { row in (0...row).reduce(0) { $0 + matrix[row * n + $1] * v[$1] } }
        }
        let tauG = exp(q[layout.logTauGlobal])
        let sigmaD = exp(q[layout.logSigmaKind])
        let sigmaDrift = exp(q[layout.logSigmaDrift])
        let b: [[Double]] = (0..<f).map { fi in
            let tau = tauG * exp(q[layout.logLambda + fi])
            return lowerTimes(c, Array(q[(layout.zShared + fi * k)..<(layout.zShared + (fi + 1) * k)]), k).map { tau * $0 }
        }
        // Kind deviations scaled by the local scale: d_fs = λ_f σ_d C z_fs.
        let d: [[[Double]]] = (0..<f).map { fi in
            let tau = exp(q[layout.logLambda + fi])
            return (0..<s).map { si in
                let start = layout.zKind + (fi * s + si) * k
                return lowerTimes(c, Array(q[start..<(start + k)]), k).map { tau * sigmaD * $0 }
            }
        }
        // Cross-basis columns centred over the rows.
        let width = f * k
        let crossMeans = (0..<width).map { col in
            (0..<data.hours.count).reduce(0.0) { $0 + data.crossBasis[$1 * width + col] } / Double(data.hours.count)
        }
        let delta = lowerTimes(cd, Array(q[layout.driftU..<(layout.driftU + j)]), j).map { sigmaDrift * $0 }

        // Rebuild the drift basis independently of the model's design.
        let firstHour = data.hours.first!
        let spanDays = Double(data.hours.last! + 1 - firstHour) / 24
        let interior = max(0, Int((spanDays / 10).rounded()) - 1)
        let driftBasis = BSplineBasis(lower: 0, upper: spanDays, interiorKnots: (0..<interior).map { spanDays * Double($0 + 1) / Double(interior + 1) })
        let driftRows = data.hours.map { driftBasis.evaluate(at: (Double($0 - firstHour) + 0.5) / 24) }
        let driftMeans = (0..<j).map { col in driftRows.reduce(0) { $0 + $1[col] } / Double(driftRows.count) }

        var logLik = 0.0
        for (row, hour) in data.hours.enumerated() {
            let angle = 2 * Double.pi * (Double(hour % 24) + 0.5) / 24
            let tod = q[layout.tod] * sin(angle) + q[layout.tod + 1] * cos(angle)
                + q[layout.tod + 2] * sin(2 * angle) + q[layout.tod + 3] * cos(2 * angle)
            let drift = (0..<j).reduce(0) { $0 + (driftRows[row][$1] - driftMeans[$1]) * delta[$1] }
            for si in 0..<s {
                var eta = q[layout.alpha + si] + tod + drift
                for fi in 0..<f {
                    for ki in 0..<k {
                        eta += (data.crossBasis[row * width + fi * k + ki] - crossMeans[fi * k + ki]) * (b[fi][ki] + d[fi][si][ki])
                    }
                }
                let y = data.counts[row * s + si]
                logLik += y * eta - exp(eta)
            }
        }
        func halfNormal(_ theta: Double, _ scale: Double) -> Double { -0.5 * exp(2 * theta) / (scale * scale) + theta }
        var logPrior = 0.0
        for si in 0..<s {
            let z = (q[layout.alpha + si] - model.interceptMeans[si]) / priors.interceptSD
            logPrior -= 0.5 * z * z
        }
        for t in 0..<4 { logPrior -= 0.5 * pow(q[layout.tod + t] / priors.timeOfDaySD, 2) }
        for i in 0..<j { logPrior -= 0.5 * q[layout.driftU + i] * q[layout.driftU + i] }
        for i in 0..<(f * k) { logPrior -= 0.5 * q[layout.zShared + i] * q[layout.zShared + i] }
        for i in 0..<(f * s * k) { logPrior -= 0.5 * q[layout.zKind + i] * q[layout.zKind + i] }
        logPrior += halfNormal(q[layout.logSigmaDrift], priors.driftScale)
        logPrior += halfNormal(q[layout.logTauGlobal], priors.globalScale)
        logPrior += halfNormal(q[layout.logSigmaKind], priors.kindDeviationScale)
        // λ_f ~ HalfCauchy(localScale): log p(λ) + log λ = −log(1 + (λ/s)²) + θ.
        for fi in 0..<f {
            let theta = q[layout.logLambda + fi]
            logPrior += -log(1 + pow(exp(theta) / priors.localScale, 2)) + theta
        }

        let modelValue = model.logDensityAndGradient(at: q).value
        XCTAssertEqual(modelValue, logLik + logPrior, accuracy: 1e-8 * abs(modelValue))
    }

    func testOverflowGivesNegativeInfinity() {
        let (model, _) = smallModel()
        var q = randomPosition(model, seed: 5)
        q[model.layout.alpha] = 800
        XCTAssertEqual(model.logDensityAndGradient(at: q).value, -.infinity)
    }
}

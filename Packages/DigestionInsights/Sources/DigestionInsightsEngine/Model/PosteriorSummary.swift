import Accelerate
import Foundation

/// Per-feature posterior summaries of one fit (B9), computed draw by draw
/// and then reduced to median and 90 % interval.
struct FeatureSummaries {
    var overall: [EffectSummary]
    var perKind: [[String: EffectSummary]]
    var mainKind: [String?]
    /// Overall lag curve quantiles per feature: 0..<maxLag, total-rate RR at l + 0.5.
    var curves: [[Interval]]

    var probRaises: [Double] { overall.map(\.probRaises) }
}

enum PosteriorSummary {
    /// β evaluated at lag-hour midpoints: L × K row-major.
    static func lagMatrix(_ basis: BSplineBasis, maxLagHours: Int) -> [Double] {
        var matrix = [Double](repeating: 0, count: maxLagHours * basis.count)
        for l in 0..<maxLagHours {
            let values = basis.evaluate(at: Double(l) + 0.5)
            for k in 0..<basis.count { matrix[l * basis.count + k] = values[k] }
        }
        return matrix
    }

    static func interval(_ values: [Double]) -> Interval {
        let sorted = values.sorted()
        return Interval(
            median: Diagnostics.quantileOfSorted(sorted, 0.5),
            lower: Diagnostics.quantileOfSorted(sorted, 0.05),
            upper: Diagnostics.quantileOfSorted(sorted, 0.95)
        )
    }

    /// Draws in chain order as one array of positions (no copy of the rows).
    static func drawPointers(_ output: SamplerOutput) -> [(chain: Int, index: Int)] {
        var result: [(Int, Int)] = []
        for (c, chain) in output.chains.enumerated() {
            for i in 0..<chain.sampleCount { result.append((c, i)) }
        }
        return result
    }

    /// Mean baseline hourly rate per kind and draw, i.e. without any feature
    /// exposure: mean_h exp(α_s + tod(h) + drift(h)).
    /// Returns draws × kinds row-major.
    static func baselineRates(model: LagModel, output: SamplerOutput) -> [Double] {
        let layout = model.layout
        let s = layout.kinds, j = layout.driftTerms, t = layout.todTerms
        let p = layout.designColumns
        let fk = layout.features * layout.basis
        let rows = model.rows
        let columns = t + j
        // Contiguous copy of the tod and drift columns.
        var baselineDesign = [Double](repeating: 0, count: rows * columns)
        for r in 0..<rows {
            for c in 0..<columns { baselineDesign[r * columns + c] = model.design[r * p + fk + c] }
        }
        let pointers = drawPointers(output)
        var rates = [Double](repeating: 0, count: pointers.count * s)
        let workspace = model.makeWorkspace()
        var theta = [Double](repeating: 0, count: columns)
        var base = [Double](repeating: 0, count: rows)
        var expBase = [Double](repeating: 0, count: rows)
        for (d, pointer) in pointers.enumerated() {
            let chain = output.chains[pointer.chain]
            chain.draws.withUnsafeBufferPointer { draws in
                let q = draws.baseAddress! + pointer.index * layout.dimension
                model.fillWeights(q, workspace)
                for c in 0..<t { theta[c] = q[layout.tod + c] }
                for c in 0..<j { theta[t + c] = workspace.drift.p[c] }
                vDSP_mmulD(baselineDesign, 1, theta, 1, &base, 1, vDSP_Length(rows), 1, vDSP_Length(columns))
                var n = Int32(rows)
                vvexp(&expBase, base, &n)
                var mean = 0.0
                vDSP_meanvD(expBase, 1, &mean, vDSP_Length(rows))
                for kind in 0..<s {
                    // Uncentred intercept: α_s − Σ_fk X̄[fk] W[fk, s] (zero exposure).
                    var alpha = q[layout.alpha + kind]
                    for c in 0..<fk { alpha -= model.featureMeans[c] * workspace.weights.p[c * s + kind] }
                    rates[d * s + kind] = exp(alpha) * mean
                }
            }
        }
        return rates
    }

    /// Per-draw quantities of one lag curve β (log RR per lag hour).
    struct CurveStats {
        var sum: Double
        var peakRR: Double
        var averageRR: Double
        var excess: Double
        var medianLag: Double?
    }

    static func curveStats(logRR beta: UnsafePointer<Double>, rr: UnsafePointer<Double>, count: Int, baselineRate: Double) -> CurveStats {
        var sum = 0.0, maximum = -Double.infinity, positiveTotal = 0.0, excessSum = 0.0
        for l in 0..<count {
            sum += beta[l]
            maximum = max(maximum, beta[l])
            excessSum += rr[l] - 1
            positiveTotal += max(0, rr[l] - 1)
        }
        var medianLag: Double?
        if positiveTotal > 0 {
            let half = positiveTotal / 2
            var cumulative = 0.0
            for l in 0..<count {
                let positive = max(0, rr[l] - 1)
                if cumulative + positive >= half, positive > 0 {
                    medianLag = Double(l) + (half - cumulative) / positive
                    break
                }
                cumulative += positive
            }
        }
        return CurveStats(
            sum: sum,
            peakRR: exp(min(maximum, 700)),
            averageRR: exp(min(sum / Double(count), 700)),
            excess: baselineRate * excessSum,
            medianLag: medianLag
        )
    }

    static func effectSummary(_ stats: [CurveStats], peakThreshold: Double) -> EffectSummary {
        let lags = stats.compactMap(\.medianLag)
        let n = Double(stats.count)
        return EffectSummary(
            peakRR: interval(stats.map(\.peakRR)),
            averageRR: interval(stats.map(\.averageRR)),
            excessPerExposure: interval(stats.map(\.excess)),
            medianLagHours: lags.isEmpty ? nil : interval(lags),
            probRaises: Double(stats.filter { $0.sum > 0 }.count) / n,
            probPeakAbove: Double(stats.filter { $0.peakRR > peakThreshold }.count) / n
        )
    }

    /// Full summaries for every model feature.
    ///
    /// Per kind s the lag curve is β_s(l) = Σ_k B_k(l) (b[f, k] + d[f, s, k]).
    /// Overall is the effect on the total symptom rate (all kinds):
    /// β(l) = log Σ_s w_s exp(β_s(l)), w_s = μ̄₀_s / Σ μ̄₀ per draw. B9 wrote
    /// overall as the shared part b alone; b is separated from the mean of
    /// the d only by their priors, so a trigger of one kind left b near zero
    /// (unit 3 note). The two agree when kind deviations vanish, and overall
    /// excess is exactly the sum of per-kind excess.
    static func summarize(
        model: LagModel,
        output: SamplerOutput,
        kinds: [String],
        lagBasis: BSplineBasis,
        maxLagHours: Int,
        peakThreshold: Double,
        includeCurves: Bool = true
    ) throws -> FeatureSummaries {
        let layout = model.layout
        let f = layout.features, s = layout.kinds, k = layout.basis
        let lagCount = maxLagHours
        let lagMatrixT = DenseMatrix.transpose(lagMatrix(lagBasis, maxLagHours: maxLagHours), rows: lagCount, columns: k)
        let rates = baselineRates(model: model, output: output)
        let pointers = drawPointers(output)
        let drawCount = pointers.count
        let totalRates = (0..<drawCount).map { d in (0..<s).reduce(0) { $0 + rates[d * s + $1] } }
        let factorT = model.lagFactorT

        var result = FeatureSummaries(overall: [], perKind: [], mainKind: [], curves: [])
        var coefficients = [Double](repeating: 0, count: drawCount * k)   // D × K
        var beta = [Double](repeating: 0, count: drawCount * lagCount)    // D × L
        var rr = [Double](repeating: 0, count: drawCount * lagCount)
        var rrTotal = [Double](repeating: 0, count: drawCount * lagCount)
        var betaTotal = [Double](repeating: 0, count: drawCount * lagCount)
        var zRow = [Double](repeating: 0, count: k)
        var cz = [Double](repeating: 0, count: k)

        func stats(_ logRR: [Double], _ ratio: [Double], baseline: (Int) -> Double) -> [CurveStats] {
            var result: [CurveStats] = []
            result.reserveCapacity(drawCount)
            logRR.withUnsafeBufferPointer { b in
                ratio.withUnsafeBufferPointer { r in
                    for d in 0..<drawCount {
                        result.append(curveStats(
                            logRR: b.baseAddress! + d * lagCount,
                            rr: r.baseAddress! + d * lagCount,
                            count: lagCount,
                            baselineRate: baseline(d)
                        ))
                    }
                }
            }
            return result
        }

        for feature in 0..<f {
            try Task.checkCancellation()
            var kindSummaries: [String: EffectSummary] = [:]
            for i in rrTotal.indices { rrTotal[i] = 0 }
            for kind in 0..<s {
                for (d, pointer) in pointers.enumerated() {
                    output.chains[pointer.chain].draws.withUnsafeBufferPointer { draws in
                        let q = draws.baseAddress! + pointer.index * layout.dimension
                        let tau = model.sharedSlab(q, feature: feature).scale
                        let sigma = model.kindScale(q, feature: feature, tauGlobal: exp(q[layout.logTauGlobal]), sigmaKind: exp(q[layout.logSigmaKind]))
                        for j in 0..<k { zRow[j] = q[layout.zShared + feature * k + j] }
                        vDSP_mmulD(zRow, 1, factorT, 1, &cz, 1, 1, vDSP_Length(k), vDSP_Length(k))
                        for j in 0..<k { coefficients[d * k + j] = tau * cz[j] }
                        for j in 0..<k { zRow[j] = q[layout.zKind + (feature * s + kind) * k + j] }
                        vDSP_mmulD(zRow, 1, factorT, 1, &cz, 1, 1, vDSP_Length(k), vDSP_Length(k))
                        for j in 0..<k { coefficients[d * k + j] += sigma * cz[j] }
                    }
                }
                // β_s (D × L) = coefficients (D × K) · Bᵀ (K × L)
                vDSP_mmulD(coefficients, 1, lagMatrixT, 1, &beta, 1, vDSP_Length(drawCount), vDSP_Length(lagCount), vDSP_Length(k))
                var clampHigh = 700.0, clampLow = -700.0
                vDSP_vclipD(beta, 1, &clampLow, &clampHigh, &rr, 1, vDSP_Length(beta.count))
                exponentiateInPlace(&rr)
                kindSummaries[kinds[kind]] = effectSummary(stats(beta, rr) { rates[$0 * s + kind] }, peakThreshold: peakThreshold)
                for d in 0..<drawCount {
                    let weight = totalRates[d] > 0 ? rates[d * s + kind] / totalRates[d] : 1 / Double(s)
                    for l in 0..<lagCount { rrTotal[d * lagCount + l] += weight * rr[d * lagCount + l] }
                }
            }
            for i in rrTotal.indices { betaTotal[i] = log(rrTotal[i]) }
            let overall = effectSummary(stats(betaTotal, rrTotal) { totalRates[$0] }, peakThreshold: peakThreshold)
            result.overall.append(overall)
            result.perKind.append(kindSummaries)
            result.curves.append(includeCurves
                ? (0..<lagCount).map { l in interval((0..<drawCount).map { rrTotal[$0 * lagCount + l] }) }
                : [])
            // Kind with the largest share of the excess.
            let main = kinds.max { (kindSummaries[$0]?.excessPerExposure.median ?? -.infinity) < (kindSummaries[$1]?.excessPerExposure.median ?? -.infinity) }
            result.mainKind.append(main)
        }
        return result
    }

    /// Posterior median of expected exposure–symptom pairs per lag hour with
    /// feature f's effect removed (B9 chart data), over `chartDraws` evenly
    /// thinned draws. Expected symptoms in lag hour l after exposure e are
    /// approximated by the null rate of the observed hour containing
    /// t_e + l + 0.5 h. Requires the full fit (rows = all data rows).
    static func expectedPairsNull(
        model: LagModel,
        data: LagData,
        output: SamplerOutput,
        chartDraws: Int
    ) throws -> [[Double]] {
        let layout = model.layout
        let f = layout.features, s = layout.kinds, k = layout.basis
        let p = layout.designColumns
        let rows = model.rows
        let lagCount = data.maxLagHours
        let pointers = drawPointers(output)
        let thinned = Swift.max(1, Swift.min(chartDraws, pointers.count))
        let selected = (0..<thinned).map { pointers[($0 * pointers.count) / thinned] }

        // Rows hit by exposure e at lag l, grouped per feature and lag.
        var lagRows: [[[Int]]] = []
        for feature in data.modelFeatures {
            var perLag = [[Int]](repeating: [], count: lagCount)
            for event in data.exposures[feature]! {
                for l in 0..<lagCount {
                    if let row = data.rowOfHour[absoluteHour(event.time + (Double(l) + 0.5) * 3600)] {
                        perLag[l].append(row)
                    }
                }
            }
            lagRows.append(perLag)
        }
        // Contiguous per-feature cross-basis blocks (rows × K).
        var blocks = [[Double]](repeating: [], count: f)
        for feature in 0..<f {
            var block = [Double](repeating: 0, count: rows * k)
            for r in 0..<rows {
                // Uncentred X_f: η − X_f W_f is the linear predictor without f.
                for j in 0..<k { block[r * k + j] = model.design[r * p + feature * k + j] + model.featureMeans[feature * k + j] }
            }
            blocks[feature] = block
        }

        var expected = [[[Double]]](repeating: [[Double]](repeating: [], count: lagCount), count: f)
        let workspace = model.makeWorkspace()
        var eta = [Double](repeating: 0, count: rows * s)
        var contribution = [Double](repeating: 0, count: rows * s)
        var nullRate = [Double](repeating: 0, count: rows)
        for pointer in selected {
            try Task.checkCancellation()
            output.chains[pointer.chain].draws.withUnsafeBufferPointer { draws in
                model.fillWeights(draws.baseAddress! + pointer.index * layout.dimension, workspace)
            }
            vDSP_mmulD(model.design, 1, workspace.weights.p, 1, &eta, 1, vDSP_Length(rows), vDSP_Length(s), vDSP_Length(p))
            for feature in 0..<f {
                vDSP_mmulD(blocks[feature], 1, workspace.weights.p + feature * k * s, 1, &contribution, 1,
                           vDSP_Length(rows), vDSP_Length(s), vDSP_Length(k))
                contribution.withUnsafeMutableBufferPointer { c in
                    // η − c_f, then exp.
                    vDSP_vsubD(c.baseAddress!, 1, eta, 1, c.baseAddress!, 1, vDSP_Length(rows * s))
                }
                exponentiateInPlace(&contribution)
                for r in 0..<rows {
                    var total = 0.0
                    for kind in 0..<s { total += contribution[r * s + kind] }
                    nullRate[r] = total
                }
                for l in 0..<lagCount {
                    var total = 0.0
                    for row in lagRows[feature][l] { total += nullRate[row] }
                    expected[feature][l].append(total)
                }
            }
        }
        return expected.map { perLag in perLag.map { interval($0).median } }
    }
}

func exponentiateInPlace(_ values: inout [Double]) {
    values.withUnsafeMutableBufferPointer { buffer in
        var n = Int32(buffer.count)
        vvexp(buffer.baseAddress!, buffer.baseAddress!, &n)
    }
}

import Foundation

/// Convergence diagnostics after Vehtari, Gelman, Simpson, Carpenter & Bürkner
/// (2021), "Rank-normalization, folding, and localization: an improved R̂ for
/// assessing convergence of MCMC", Bayesian Analysis 16(2).
///
/// Inputs are one trace per chain, all of equal length.
public enum Diagnostics {
    // MARK: - R̂

    /// Classic potential scale reduction on the given chains (no splitting,
    /// no rank normalisation): √(((n − 1)/n · W + B/n) / W).
    public static func basicRhat(_ chains: [[Double]]) -> Double {
        let m = chains.count
        guard m >= 2, let n = chains.first?.count, n >= 2 else { return .nan }
        let means = chains.map(mean)
        let variances = chains.map(sampleVariance)
        let between = Double(n) * sampleVariance(means)
        let within = mean(variances)
        guard within > 0 else { return .nan }
        return ((between / within + Double(n) - 1) / Double(n)).squareRoot()
    }

    /// Rank-normalised split-R̂: maximum of bulk R̂ (rank-normalised split
    /// chains) and tail R̂ (same on |x − median|).
    public static func splitRhat(_ chains: [[Double]]) -> Double {
        let split = splitChains(chains)
        let bulk = basicRhat(rankNormalize(split))
        let folded = basicRhat(rankNormalize(fold(split)))
        if bulk.isNaN || folded.isNaN { return .nan }
        return max(bulk, folded)
    }

    // MARK: - ESS

    /// Bulk ESS: ESS of rank-normalised split chains.
    public static func bulkESS(_ chains: [[Double]]) -> Double {
        essMean(rankNormalize(splitChains(chains)))
    }

    /// Tail ESS: minimum ESS of the 5 % and 95 % quantile indicators.
    public static func tailESS(_ chains: [[Double]]) -> Double {
        let split = splitChains(chains)
        let pooled = split.flatMap { $0 }
        let q05 = quantile(pooled, 0.05)
        let q95 = quantile(pooled, 0.95)
        let lower = essMean(split.map { $0.map { $0 <= q05 ? 1 : 0 } })
        let upper = essMean(split.map { $0.map { $0 <= q95 ? 1 : 0 } })
        if lower.isNaN || upper.isNaN { return .nan }
        return min(lower, upper)
    }

    /// ESS of the mean by Geyer's initial monotone sequence on the multi-chain
    /// autocorrelation estimate (Vehtari et al. 2021, eqs. 10–11), as given
    /// in their reference implementation. Chains are used as given (callers
    /// split beforehand).
    public static func essMean(_ chains: [[Double]]) -> Double {
        let m = chains.count
        guard m >= 1, let n = chains.first?.count, n >= 4 else { return .nan }
        let means = chains.map(mean)
        let centred = zip(chains, means).map { chain, mu in chain.map { $0 - mu } }

        // Biased autocovariance at lag t, averaged over chains, computed lazily:
        // the Geyer sequence usually stops after a few lags.
        func meanAutocovariance(_ t: Int) -> Double {
            var total = 0.0
            for chain in centred {
                var sum = 0.0
                chain.withUnsafeBufferPointer { x in
                    for i in 0..<(n - t) { sum += x[i] * x[i + t] }
                }
                total += sum / Double(n)
            }
            return total / Double(m)
        }

        let acov0 = meanAutocovariance(0)
        let meanVar = acov0 * Double(n) / Double(n - 1)
        var varPlus = meanVar * Double(n - 1) / Double(n)
        if m > 1 { varPlus += sampleVariance(means) }
        guard varPlus > 0 else { return .nan }

        var rho = [Double](repeating: 0, count: n)
        var t = 0
        var rhoEven = 1.0
        rho[0] = rhoEven
        var rhoOdd = 1 - (meanVar - meanAutocovariance(1)) / varPlus
        rho[1] = rhoOdd
        while t < n - 5, !(rhoEven + rhoOdd).isNaN, rhoEven + rhoOdd > 0 {
            t += 2
            rhoEven = 1 - (meanVar - meanAutocovariance(t)) / varPlus
            rhoOdd = 1 - (meanVar - meanAutocovariance(t + 1)) / varPlus
            if rhoEven + rhoOdd >= 0 {
                rho[t] = rhoEven
                rho[t + 1] = rhoOdd
            }
        }
        let maxT = t
        // Improved truncation (reference implementation): keep a positive
        // final even term.
        if rhoEven > 0 { rho[maxT] = rhoEven }

        // Initial monotone sequence.
        t = 0
        while t <= maxT - 4 {
            t += 2
            if rho[t] + rho[t + 1] > rho[t - 2] + rho[t - 1] {
                rho[t] = (rho[t - 2] + rho[t - 1]) / 2
                rho[t + 1] = rho[t]
            }
        }

        let total = Double(m * n)
        var tau = -1.0 + rho[maxT]
        for k in 0..<maxT { tau += 2 * rho[k] }
        tau = max(tau, 1 / log10(total))
        return total / tau
    }

    // MARK: - Building blocks

    /// Each chain split into first and second half (middle draw dropped for
    /// odd lengths).
    public static func splitChains(_ chains: [[Double]]) -> [[Double]] {
        var result: [[Double]] = []
        result.reserveCapacity(chains.count * 2)
        for chain in chains {
            let half = chain.count / 2
            result.append(Array(chain[0..<half]))
            result.append(Array(chain[(chain.count - half)...]))
        }
        return result
    }

    /// Normal scores of pooled average ranks: Φ⁻¹((r − 3/8) / (S + 1/4)).
    public static func rankNormalize(_ chains: [[Double]]) -> [[Double]] {
        let pooled = chains.flatMap { $0 }
        let ranks = averageRanks(pooled)
        let s = Double(pooled.count)
        var result: [[Double]] = []
        var offset = 0
        for chain in chains {
            result.append((0..<chain.count).map {
                normalQuantile((ranks[offset + $0] - 0.375) / (s + 0.25))
            })
            offset += chain.count
        }
        return result
    }

    /// |x − median| over the pooled draws.
    public static func fold(_ chains: [[Double]]) -> [[Double]] {
        let med = quantile(chains.flatMap { $0 }, 0.5)
        return chains.map { $0.map { abs($0 - med) } }
    }

    /// 1-based ranks, ties get their average rank.
    public static func averageRanks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] || (values[$0] == values[$1] && $0 < $1) }
        var ranks = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let rank = Double(i + j) / 2 + 1
            for k in i...j { ranks[order[k]] = rank }
            i = j + 1
        }
        return ranks
    }

    /// Sample quantile, linear interpolation between order statistics
    /// (Hyndman & Fan type 7).
    public static func quantile(_ values: [Double], _ probability: Double) -> Double {
        quantileOfSorted(values.sorted(), probability)
    }

    public static func quantileOfSorted(_ sorted: [Double], _ probability: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let h = Double(sorted.count - 1) * probability
        let lower = Int(h.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (h - Double(lower)) * (sorted[upper] - sorted[lower])
    }

    static func mean(_ x: [Double]) -> Double {
        x.reduce(0, +) / Double(x.count)
    }

    static func sampleVariance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let mu = mean(x)
        return x.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Double(x.count - 1)
    }

    /// Φ⁻¹(p), Wichura (1988) algorithm AS 241 (PPND16), relative accuracy
    /// about 1e-16.
    public static func normalQuantile(_ p: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        let q = p - 0.5
        if abs(q) <= 0.425 {
            let r = 0.180625 - q * q
            let num = (((((((2509.0809287301226727 * r + 33430.575583588128105) * r + 67265.770927008700853) * r
                + 45921.953931549871457) * r + 13731.693765509461125) * r + 1971.5909503065514427) * r
                + 133.14166789178437745) * r + 3.387132872796366608)
            let den = (((((((5226.495278852545925 * r + 28729.085735721942674) * r + 39307.89580009271061) * r
                + 21213.794301586595867) * r + 5394.1960214247511077) * r + 687.1870074920579083) * r
                + 42.313330701600911252) * r + 1)
            return q * num / den
        }
        var r = q < 0 ? p : 1 - p
        r = (-log(r)).squareRoot()
        var value: Double
        if r <= 5 {
            r -= 1.6
            let num = (((((((7.7454501427834140764e-4 * r + 0.0227238449892691845833) * r + 0.24178072517745061177) * r
                + 1.27045825245236838258) * r + 3.64784832476320460504) * r + 5.7694972214606914055) * r
                + 4.6303378461565452959) * r + 1.42343711074968357734)
            let den = (((((((1.05075007164441684324e-9 * r + 5.475938084995344946e-4) * r + 0.0151986665636164571966) * r
                + 0.14810397642748007459) * r + 0.68976733498510000455) * r + 1.6763848301838038494) * r
                + 2.05319162663775882187) * r + 1)
            value = num / den
        } else {
            r -= 5
            let num = (((((((2.01033439929228813265e-7 * r + 2.71155556874348757815e-5) * r + 0.0012426609473880784386) * r
                + 0.026532189526576123093) * r + 0.29656057182850489123) * r + 1.7848265399172913358) * r
                + 5.4637849111641143699) * r + 6.6579046435011037772)
            let den = (((((((2.04426310338993978564e-15 * r + 1.4215117583164458887e-7) * r + 1.8463183175100546818e-5) * r
                + 7.868691311456132591e-4) * r + 0.0148753612908506148525) * r + 0.13692988092273580531) * r
                + 0.59983220655588793769) * r + 1)
            value = num / den
        }
        return q < 0 ? -value : value
    }
}

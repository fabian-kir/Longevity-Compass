import Foundation

/// Share with 95 % Wilson score interval (Monte-Carlo uncertainty of a
/// simulated proportion).
public struct Proportion: Codable, Sendable, Equatable {
    public var successes: Int
    public var trials: Int
    public var rate: Double
    public var lower: Double
    public var upper: Double

    public init(_ successes: Int, of trials: Int) {
        self.successes = successes
        self.trials = trials
        guard trials > 0 else {
            rate = .nan; lower = .nan; upper = .nan
            return
        }
        let n = Double(trials), p = Double(successes) / n, z = 1.959964
        let denominator = 1 + z * z / n
        let centre = (p + z * z / (2 * n)) / denominator
        let half = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot() / denominator
        rate = p
        lower = max(0, centre - half)
        upper = min(1, centre + half)
    }

    enum CodingKeys: String, CodingKey { case successes, trials, rate, lower, upper }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Int.self, forKey: .successes), of: try c.decode(Int.self, forKey: .trials))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(successes, forKey: .successes)
        try c.encode(trials, forKey: .trials)
        try c.encode(rate.isFinite ? rate : 0, forKey: .rate)
        try c.encode(lower.isFinite ? lower : 0, forKey: .lower)
        try c.encode(upper.isFinite ? upper : 1, forKey: .upper)
    }
}

enum SpecialFunctions {
    /// Upper tail P(X ≥ x) of a chi-square distribution with `df` degrees of freedom.
    static func chiSquareUpperTail(_ x: Double, df: Int) -> Double {
        regularizedGammaQ(Double(df) / 2, x / 2)
    }

    /// Q(a, x) = Γ(a, x) / Γ(a): series for x < a + 1, continued fraction otherwise.
    static func regularizedGammaQ(_ a: Double, _ x: Double) -> Double {
        guard x > 0 else { return 1 }
        let logPrefix = -x + a * log(x) - lgamma(a)
        if x < a + 1 {
            var sum = 1 / a, term = 1 / a, n = a
            for _ in 0..<500 {
                n += 1
                term *= x / n
                sum += term
                if abs(term) < abs(sum) * 1e-15 { break }
            }
            return max(0, 1 - sum * exp(logPrefix))
        }
        // Lentz's continued fraction.
        let tiny = 1e-300
        var b = x + 1 - a, c = 1 / tiny, d = 1 / b, h = d
        for i in 1..<500 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 1e-15 { break }
        }
        return min(1, exp(logPrefix) * h)
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

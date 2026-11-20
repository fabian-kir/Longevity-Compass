import Foundation

/// Clamped B-spline basis on [lower, upper] (Cox–de Boor recursion as in
/// Piegl & Tiller, "The NURBS Book", algorithm A2.2).
///
/// With the B9 lag settings (cubic, interior knots 3, 8, 24, 48 h on
/// [0, 96] h) there are K = 8 basis functions. On [lower, upper] they are
/// non-negative and sum to 1.
public struct BSplineBasis: Sendable, Equatable {
    public let degree: Int
    public let lower: Double
    public let upper: Double
    public let interiorKnots: [Double]
    /// Full knot vector with `degree + 1` copies of each boundary.
    public let knots: [Double]

    public init(lower: Double, upper: Double, interiorKnots: [Double], degree: Int = 3) {
        precondition(upper > lower, "empty spline domain")
        precondition(degree >= 0, "negative degree")
        precondition(zip(interiorKnots, interiorKnots.dropFirst()).allSatisfy { $0 < $1 }, "knots must increase")
        precondition(interiorKnots.allSatisfy { $0 > lower && $0 < upper }, "interior knots must lie inside the domain")
        self.degree = degree
        self.lower = lower
        self.upper = upper
        self.interiorKnots = interiorKnots
        knots = Array(repeating: lower, count: degree + 1) + interiorKnots + Array(repeating: upper, count: degree + 1)
    }

    public var count: Int { knots.count - degree - 1 }

    /// All `count` basis values at x; zeros outside [lower, upper].
    public func evaluate(at x: Double) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { evaluate(at: x, into: $0.baseAddress!) }
        return out
    }

    /// Writes `count` values into `out` (zeros outside the support).
    public func evaluate(at x: Double, into out: UnsafeMutablePointer<Double>) {
        out.update(repeating: 0, count: count)
        guard x >= lower, x <= upper else { return }
        let n = count
        let p = degree
        // Span: largest i in [p, n − 1] with knots[i] ≤ x (last span at x = upper).
        var span = n - 1
        if x < upper {
            var lo = p, hi = n
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if knots[mid] <= x { lo = mid } else { hi = mid }
            }
            span = lo
        }
        var values = [Double](repeating: 0, count: p + 1)
        var left = [Double](repeating: 0, count: p + 1)
        var right = [Double](repeating: 0, count: p + 1)
        values[0] = 1
        if p > 0 {
            for j in 1...p {
                left[j] = x - knots[span + 1 - j]
                right[j] = knots[span + j] - x
                var saved = 0.0
                for r in 0..<j {
                    let temp = values[r] / (right[r + 1] + left[j - r])
                    values[r] = saved + right[r + 1] * temp
                    saved = left[j - r] * temp
                }
                values[j] = saved
            }
        }
        for r in 0...p {
            out[span - p + r] = values[r]
        }
    }

    /// Second-difference penalty P = DᵀD (D is (K − 2) × K with rows 1, −2, 1),
    /// row-major K × K.
    public static func secondDifferencePenalty(size k: Int) -> [Double] {
        var penalty = [Double](repeating: 0, count: k * k)
        guard k >= 3 else { return penalty }
        for row in 0..<(k - 2) {
            let coefficients: [(Int, Double)] = [(row, 1), (row + 1, -2), (row + 2, 1)]
            for (i, a) in coefficients {
                for (j, b) in coefficients {
                    penalty[i * k + j] += a * b
                }
            }
        }
        return penalty
    }

    /// Lower Cholesky factor C of (smoothing · P + ridge · I)⁻¹, row-major
    /// K × K. With z ~ N(0, I), C z ~ N(0, (ωP + κI)⁻¹): a smoothing prior on
    /// spline coefficients.
    public static func priorFactor(size k: Int, ridge: Double, smoothing: Double = 1) -> [Double] {
        priorFactor(size: k, ridge: [Double](repeating: ridge, count: k), smoothing: smoothing)
    }

    /// As above with a separate ridge κ_k per coefficient.
    public static func priorFactor(size k: Int, ridge: [Double], smoothing: Double) -> [Double] {
        var precision = secondDifferencePenalty(size: k).map { $0 * smoothing }
        for i in 0..<k { precision[i * k + i] += ridge[i] }
        let covariance = DenseMatrix.inverseSPD(precision, size: k)
        return DenseMatrix.cholesky(covariance, size: k)
    }
}

/// Small dense helpers (row-major), sizes up to a few dozen.
enum DenseMatrix {
    /// Lower-triangular L with A = L Lᵀ. A must be symmetric positive definite.
    static func cholesky(_ a: [Double], size n: Int) -> [Double] {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    precondition(sum > 0, "matrix not positive definite")
                    l[i * n + i] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        return l
    }

    static func inverseSPD(_ a: [Double], size n: Int) -> [Double] {
        let l = cholesky(a, size: n)
        // Solve L Lᵀ X = I column by column.
        var inverse = [Double](repeating: 0, count: n * n)
        for column in 0..<n {
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var sum = i == column ? 1.0 : 0.0
                for k in 0..<i { sum -= l[i * n + k] * y[k] }
                y[i] = sum / l[i * n + i]
            }
            var x = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = y[i]
                for k in (i + 1)..<n { sum -= l[k * n + i] * x[k] }
                x[i] = sum / l[i * n + i]
            }
            for i in 0..<n { inverse[i * n + column] = x[i] }
        }
        return inverse
    }

    static func transpose(_ a: [Double], rows: Int, columns: Int) -> [Double] {
        var t = [Double](repeating: 0, count: rows * columns)
        for i in 0..<rows {
            for j in 0..<columns { t[j * rows + i] = a[i * columns + j] }
        }
        return t
    }
}

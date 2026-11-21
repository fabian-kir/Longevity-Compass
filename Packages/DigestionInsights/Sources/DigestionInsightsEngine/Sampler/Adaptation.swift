import Foundation

/// Nesterov dual averaging of log step size (Hoffman & Gelman 2014, §3.2),
/// with Stan's defaults γ = 0.05, t0 = 10, κ = 0.75.
struct DualAveraging {
    let delta: Double
    let gamma = 0.05
    let t0 = 10.0
    let kappa = 0.75
    var mu: Double
    private var counter = 0.0
    private var sBar = 0.0
    private var xBar = 0.0

    init(targetAcceptance: Double, initialStepSize: Double) {
        delta = targetAcceptance
        mu = log(10 * initialStepSize)
    }

    mutating func restart(stepSize: Double) {
        mu = log(10 * stepSize)
        counter = 0
        sBar = 0
        xBar = 0
    }

    /// Returns the step size for the next iteration.
    mutating func learn(acceptStat: Double) -> Double {
        counter += 1
        let adaptStat = min(1, acceptStat)
        let eta = 1 / (counter + t0)
        sBar = (1 - eta) * sBar + eta * (delta - adaptStat)
        let x = mu - sBar * counter.squareRoot() / gamma
        let xEta = pow(counter, -kappa)
        xBar = (1 - xEta) * xBar + xEta * x
        return exp(x)
    }

    /// Final step size after warmup: the averaged iterate.
    var finalStepSize: Double { exp(xBar) }
}

/// Stan's windowed diagonal metric adaptation: fast initial buffer (step size
/// only), doubling slow windows that estimate the posterior variance, fast
/// terminal buffer. Window sizes follow Stan's `windowed_adaptation`.
struct WindowedVarianceAdaptation {
    let warmup: Int
    private(set) var initBuffer: Int
    private(set) var termBuffer: Int
    private(set) var baseWindow: Int
    private var counter = 0
    private var windowSize: Int
    private var nextWindowEnd: Int
    private var welford: WelfordVariance
    let enabled: Bool

    init(warmup: Int, dimension: Int, initBuffer: Int = 75, termBuffer: Int = 50, baseWindow: Int = 25) {
        self.warmup = warmup
        var initBuffer = initBuffer
        var termBuffer = termBuffer
        var baseWindow = baseWindow
        enabled = warmup >= 20
        if enabled, initBuffer + baseWindow + termBuffer > warmup {
            initBuffer = Int(0.15 * Double(warmup))
            termBuffer = Int(0.1 * Double(warmup))
            baseWindow = warmup - (initBuffer + termBuffer)
        }
        self.initBuffer = initBuffer
        self.termBuffer = termBuffer
        self.baseWindow = baseWindow
        windowSize = baseWindow
        nextWindowEnd = initBuffer + baseWindow - 1
        welford = WelfordVariance(dimension: dimension)
    }

    private var inWindow: Bool {
        counter >= initBuffer && counter < warmup - termBuffer && counter != warmup
    }

    private var atWindowEnd: Bool {
        counter == nextWindowEnd && counter != warmup
    }

    private mutating func computeNextWindow() {
        if nextWindowEnd == warmup - termBuffer - 1 { return }
        windowSize *= 2
        nextWindowEnd = counter + windowSize
        if nextWindowEnd != warmup - termBuffer - 1 {
            let nextBoundary = nextWindowEnd + 2 * windowSize
            if nextBoundary >= warmup - termBuffer {
                nextWindowEnd = warmup - termBuffer - 1
            }
        }
    }

    /// Feed one warmup draw. Returns true when a window closed and
    /// `inverseMetric` was updated (caller then re-initialises step size).
    mutating func learn(position: UnsafePointer<Double>, inverseMetric: UnsafeMutablePointer<Double>) -> Bool {
        guard enabled else { return false }
        if inWindow { welford.add(position) }
        if atWindowEnd {
            computeNextWindow()
            // Regularise towards 1e-3 · I as Stan does (weight 5 / (n + 5)).
            let n = Double(welford.count)
            welford.writeVariance(into: inverseMetric)
            for i in 0..<welford.dimension {
                inverseMetric[i] = (n / (n + 5)) * inverseMetric[i] + 1e-3 * (5 / (n + 5))
            }
            welford.restart()
            counter += 1
            return true
        }
        counter += 1
        return false
    }
}

struct WelfordVariance {
    let dimension: Int
    private(set) var count = 0
    private var mean: [Double]
    private var m2: [Double]

    init(dimension: Int) {
        self.dimension = dimension
        mean = [Double](repeating: 0, count: dimension)
        m2 = [Double](repeating: 0, count: dimension)
    }

    mutating func restart() {
        count = 0
        for i in 0..<dimension {
            mean[i] = 0
            m2[i] = 0
        }
    }

    mutating func add(_ x: UnsafePointer<Double>) {
        count += 1
        let n = Double(count)
        mean.withUnsafeMutableBufferPointer { mean in
            m2.withUnsafeMutableBufferPointer { m2 in
                for i in 0..<dimension {
                    let delta = x[i] - mean[i]
                    mean[i] += delta / n
                    m2[i] += delta * (x[i] - mean[i])
                }
            }
        }
    }

    func writeVariance(into output: UnsafeMutablePointer<Double>) {
        let denominator = Double(max(count - 1, 1))
        for i in 0..<dimension { output[i] = m2[i] / denominator }
    }
}

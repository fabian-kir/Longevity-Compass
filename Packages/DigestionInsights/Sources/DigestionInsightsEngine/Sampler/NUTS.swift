import Foundation

public struct NUTSConfiguration: Sendable, Codable, Equatable {
    public var chains: Int
    public var warmup: Int
    public var samples: Int
    public var targetAcceptance: Double
    public var maxTreeDepth: Int
    public var initialStepSize: Double
    /// Default initialisation: uniform on [−initRadius, initRadius]^d.
    public var initRadius: Double
    public var seed: UInt64

    public init(
        chains: Int = 4,
        warmup: Int = 1000,
        samples: Int = 1000,
        targetAcceptance: Double = 0.8,
        maxTreeDepth: Int = 10,
        initialStepSize: Double = 1,
        initRadius: Double = 2,
        seed: UInt64
    ) {
        self.chains = chains
        self.warmup = warmup
        self.samples = samples
        self.targetAcceptance = targetAcceptance
        self.maxTreeDepth = maxTreeDepth
        self.initialStepSize = initialStepSize
        self.initRadius = initRadius
        self.seed = seed
    }
}

public enum SamplerError: Error, Equatable {
    case initializationFailed
    case stepSizeSearchFailed
    case invalidConfiguration(String)
}

/// Output of one chain. Draws are post-warmup, row-major
/// (`draws[i * dimension + j]` = parameter j of draw i).
public struct ChainOutput: Sendable, Equatable {
    public let dimension: Int
    public let draws: [Double]
    public let logDensity: [Double]
    public let acceptStat: [Double]
    public let treeDepth: [Int]
    public let leapfrogSteps: [Int]
    public let divergent: [Bool]
    public let warmupDivergences: Int
    public let stepSize: Double
    public let inverseMetric: [Double]

    public var sampleCount: Int { logDensity.count }

    public func draw(_ i: Int) -> ArraySlice<Double> {
        draws[(i * dimension)..<((i + 1) * dimension)]
    }

    public func trace(of parameter: Int) -> [Double] {
        (0..<sampleCount).map { draws[$0 * dimension + parameter] }
    }
}

public struct SamplerOutput: Sendable, Equatable {
    public let dimension: Int
    public let chains: [ChainOutput]
    public let configuration: NUTSConfiguration

    /// One trace per chain for `parameter`, chain order.
    public func traces(of parameter: Int) -> [[Double]] {
        chains.map { $0.trace(of: parameter) }
    }

    public var divergences: Int { chains.reduce(0) { $0 + $1.divergent.filter { $0 }.count } }

    public var treeDepthHits: Int {
        chains.reduce(0) { total, chain in
            total + chain.treeDepth.filter { $0 >= configuration.maxTreeDepth }.count
        }
    }

    public var totalLeapfrogSteps: Int { chains.reduce(0) { $0 + $1.leapfrogSteps.reduce(0, +) } }
}

/// No-U-Turn sampler with multinomial trajectory sampling, as in Stan's
/// `base_nuts` (Hoffman & Gelman 2014; Betancourt 2017, appendix A), with the
/// generalised U-turn criterion and the extra checks across merged subtrees.
public enum NUTSSampler {
    /// Runs `configuration.chains` chains in parallel. Chain `c` uses stream
    /// `c` of `Xoshiro256StarStar(seed:)`; results are returned in chain order,
    /// so the output is bitwise identical for the same target, seed and
    /// configuration. Throws `CancellationError` when the task is cancelled
    /// (checked once per iteration in every chain).
    ///
    /// `onIteration` is called once per finished iteration (warmup or
    /// sampling) from whichever chain finished it.
    public static func sample<Target: LogDensityTarget>(
        _ target: Target,
        configuration: NUTSConfiguration,
        onIteration: (@Sendable () -> Void)? = nil
    ) async throws -> SamplerOutput {
        try validate(configuration, dimension: target.dimension)
        let chains = try await withThrowingTaskGroup(of: (Int, ChainOutput).self) { group in
            for chainIndex in 0..<configuration.chains {
                group.addTask {
                    let chain = NUTSChain(
                        target: target,
                        configuration: configuration,
                        rng: Xoshiro256StarStar(seed: configuration.seed, stream: chainIndex)
                    )
                    return (chainIndex, try chain.run(onIteration: onIteration))
                }
            }
            var results = [ChainOutput?](repeating: nil, count: configuration.chains)
            for try await (index, output) in group {
                results[index] = output
            }
            return results.map { $0! }
        }
        return SamplerOutput(dimension: target.dimension, chains: chains, configuration: configuration)
    }

    /// Single chain on the calling task, for callers that manage concurrency.
    public static func sampleChain<Target: LogDensityTarget>(
        _ target: Target,
        configuration: NUTSConfiguration,
        chainIndex: Int,
        onIteration: (@Sendable () -> Void)? = nil
    ) throws -> ChainOutput {
        try validate(configuration, dimension: target.dimension)
        let chain = NUTSChain(
            target: target,
            configuration: configuration,
            rng: Xoshiro256StarStar(seed: configuration.seed, stream: chainIndex)
        )
        return try chain.run(onIteration: onIteration)
    }

    private static func validate(_ c: NUTSConfiguration, dimension: Int) throws {
        guard dimension > 0 else { throw SamplerError.invalidConfiguration("dimension must be positive") }
        guard c.chains > 0 else { throw SamplerError.invalidConfiguration("chains must be positive") }
        guard c.samples > 0, c.warmup >= 0 else { throw SamplerError.invalidConfiguration("bad iteration counts") }
        guard c.targetAcceptance > 0, c.targetAcceptance < 1 else {
            throw SamplerError.invalidConfiguration("targetAcceptance must lie in (0, 1)")
        }
        guard c.maxTreeDepth > 0 else { throw SamplerError.invalidConfiguration("maxTreeDepth must be positive") }
    }
}

/// Position, momentum, gradient and log density of one phase-space point.
private final class PhasePoint {
    let q: Vector
    let p: Vector
    let g: Vector
    var logp = 0.0

    init(_ n: Int) {
        q = Vector(n)
        p = Vector(n)
        g = Vector(n)
    }

    func copyAll(from other: PhasePoint) {
        q.copy(from: other.q)
        p.copy(from: other.p)
        g.copy(from: other.g)
        logp = other.logp
    }

    /// Copy only what a proposal needs (momentum is resampled anyway).
    func copyState(from other: PhasePoint) {
        q.copy(from: other.q)
        g.copy(from: other.g)
        logp = other.logp
    }
}

/// Scratch buffers owned by one recursion level of `buildTree`. Calls at the
/// same depth never overlap, so one set per depth suffices.
private final class TreeLevel {
    let pInitEnd: Vector
    let pSharpInitEnd: Vector
    let rhoInit: Vector
    let zProposeFinal: PhasePoint
    let rhoFinal: Vector
    let pFinalBeg: Vector
    let pSharpFinalBeg: Vector
    let rhoSubtree: Vector
    let rhoExtended: Vector

    init(_ n: Int) {
        pInitEnd = Vector(n)
        pSharpInitEnd = Vector(n)
        rhoInit = Vector(n)
        zProposeFinal = PhasePoint(n)
        rhoFinal = Vector(n)
        pFinalBeg = Vector(n)
        pSharpFinalBeg = Vector(n)
        rhoSubtree = Vector(n)
        rhoExtended = Vector(n)
    }
}

private final class NUTSChain<Target: LogDensityTarget> {
    let target: Target
    var workspace: Target.Workspace
    let config: NUTSConfiguration
    let n: Int
    var rng: Xoshiro256StarStar

    var stepSize: Double
    let inverseMetric: Vector

    // Integrator point and trajectory state.
    let z: PhasePoint
    let zFwd: PhasePoint
    let zBck: PhasePoint
    let zSample: PhasePoint
    let zPropose: PhasePoint
    let pFwdFwd: Vector, pSharpFwdFwd: Vector
    let pFwdBck: Vector, pSharpFwdBck: Vector
    let pBckFwd: Vector, pSharpBckFwd: Vector
    let pBckBck: Vector, pSharpBckBck: Vector
    let rho: Vector, rhoFwd: Vector, rhoBck: Vector, rhoExtended: Vector
    let scratch: Vector
    let levels: [TreeLevel]

    // Per-transition counters.
    var leapfrogs = 0
    var sumMetroProb = 0.0
    var divergent = false

    static var maxDeltaH: Double { 1000 }

    init(target: Target, configuration: NUTSConfiguration, rng: Xoshiro256StarStar) {
        self.target = target
        workspace = target.makeWorkspace()
        config = configuration
        n = target.dimension
        self.rng = rng
        stepSize = configuration.initialStepSize
        inverseMetric = Vector(n)
        for i in 0..<n { inverseMetric.p[i] = 1 }
        z = PhasePoint(n)
        zFwd = PhasePoint(n)
        zBck = PhasePoint(n)
        zSample = PhasePoint(n)
        zPropose = PhasePoint(n)
        pFwdFwd = Vector(n); pSharpFwdFwd = Vector(n)
        pFwdBck = Vector(n); pSharpFwdBck = Vector(n)
        pBckFwd = Vector(n); pSharpBckFwd = Vector(n)
        pBckBck = Vector(n); pSharpBckBck = Vector(n)
        rho = Vector(n); rhoFwd = Vector(n); rhoBck = Vector(n); rhoExtended = Vector(n)
        scratch = Vector(n)
        let dimension = target.dimension
        levels = (0...configuration.maxTreeDepth).map { _ in TreeLevel(dimension) }
    }

    // MARK: - Run

    func run(onIteration: (@Sendable () -> Void)?) throws -> ChainOutput {
        try initialise()

        var stepAdaptation = DualAveraging(targetAcceptance: config.targetAcceptance, initialStepSize: stepSize)
        var metricAdaptation = WindowedVarianceAdaptation(warmup: config.warmup, dimension: n)
        if config.warmup > 0 {
            try findReasonableStepSize()
            stepAdaptation.restart(stepSize: stepSize)
        }

        var warmupDivergences = 0
        for _ in 0..<config.warmup {
            try Task.checkCancellation()
            let stat = transition()
            if stat.divergent { warmupDivergences += 1 }
            stepSize = stepAdaptation.learn(acceptStat: stat.acceptStat)
            if metricAdaptation.learn(position: z.q.p, inverseMetric: inverseMetric.p) {
                try findReasonableStepSize()
                stepAdaptation.restart(stepSize: stepSize)
            }
            onIteration?()
        }
        if config.warmup > 0 { stepSize = stepAdaptation.finalStepSize }

        let samples = config.samples
        var draws = [Double]()
        draws.reserveCapacity(samples * n)
        var logDensity = [Double](), acceptStat = [Double](), treeDepth = [Int](), leapfrogSteps = [Int](), divergentFlags = [Bool]()
        logDensity.reserveCapacity(samples)
        acceptStat.reserveCapacity(samples)
        treeDepth.reserveCapacity(samples)
        leapfrogSteps.reserveCapacity(samples)
        divergentFlags.reserveCapacity(samples)
        for _ in 0..<samples {
            try Task.checkCancellation()
            let stat = transition()
            draws.append(contentsOf: UnsafeBufferPointer(start: z.q.p, count: n))
            logDensity.append(z.logp)
            acceptStat.append(stat.acceptStat)
            treeDepth.append(stat.depth)
            leapfrogSteps.append(stat.leapfrogs)
            divergentFlags.append(stat.divergent)
            onIteration?()
        }
        return ChainOutput(
            dimension: n,
            draws: draws,
            logDensity: logDensity,
            acceptStat: acceptStat,
            treeDepth: treeDepth,
            leapfrogSteps: leapfrogSteps,
            divergent: divergentFlags,
            warmupDivergences: warmupDivergences,
            stepSize: stepSize,
            inverseMetric: inverseMetric.array
        )
    }

    private func initialise() throws {
        for _ in 0..<100 {
            if let start = target.initialPosition(rng: &rng) {
                precondition(start.count == n, "initialPosition has wrong dimension")
                start.withUnsafeBufferPointer { z.q.copy(from: $0.baseAddress!) }
            } else {
                for i in 0..<n { z.q.p[i] = rng.uniform(in: -config.initRadius, config.initRadius) }
            }
            z.logp = evaluate(z)
            if z.logp.isFinite, VectorOps.allFinite(z.g.p, n) { return }
        }
        throw SamplerError.initializationFailed
    }

    // MARK: - Hamiltonian dynamics

    @inline(__always)
    private func evaluate(_ point: PhasePoint) -> Double {
        target.logDensity(
            UnsafeBufferPointer(start: point.q.p, count: n),
            gradient: UnsafeMutableBufferPointer(start: point.g.p, count: n),
            workspace: &workspace
        )
    }

    private func sampleMomentum(_ point: PhasePoint) {
        for i in 0..<n {
            point.p.p[i] = rng.standardNormal() / inverseMetric.p[i].squareRoot()
        }
    }

    /// p♯ = M⁻¹ p
    @inline(__always)
    private func sharp(_ p: Vector, into out: Vector) {
        VectorOps.multiply(inverseMetric.p, p.p, out.p, n)
    }

    /// H = −log π(q) + ½ pᵀ M⁻¹ p; writes p♯ into `pSharp`.
    @inline(__always)
    private func hamiltonian(_ point: PhasePoint, pSharp: Vector) -> Double {
        sharp(point.p, into: pSharp)
        return -point.logp + 0.5 * VectorOps.dot(point.p.p, pSharp.p, n)
    }

    private func leapfrog(_ point: PhasePoint, epsilon: Double) {
        VectorOps.axpy(0.5 * epsilon, point.g.p, point.p.p, n)
        sharp(point.p, into: scratch)
        VectorOps.axpy(epsilon, scratch.p, point.q.p, n)
        point.logp = evaluate(point)
        VectorOps.axpy(0.5 * epsilon, point.g.p, point.p.p, n)
    }

    /// Stan's `init_stepsize`: double or halve until the one-step acceptance
    /// probability crosses 0.8.
    private func findReasonableStepSize() throws {
        guard stepSize > 0, stepSize < 1e7, stepSize.isFinite else { return }
        let start = PhasePoint(n)
        start.copyAll(from: z)
        defer { z.copyAll(from: start) }

        func oneStepDelta() -> Double {
            z.copyAll(from: start)
            sampleMomentum(z)
            let h0 = hamiltonian(z, pSharp: scratch)
            leapfrog(z, epsilon: stepSize)
            var h = hamiltonian(z, pSharp: scratch)
            if h.isNaN { h = .infinity }
            return h0 - h
        }

        let logTarget = log(0.8)
        let direction: Double = oneStepDelta() > logTarget ? 1 : -1
        for _ in 0..<200 {
            let delta = oneStepDelta()
            if direction == 1, !(delta > logTarget) { return }
            if direction == -1, !(delta < logTarget) { return }
            stepSize = direction == 1 ? 2 * stepSize : 0.5 * stepSize
            if stepSize > 1e7 || stepSize == 0 { throw SamplerError.stepSizeSearchFailed }
        }
    }

    // MARK: - Transition

    private struct TransitionStats {
        var acceptStat: Double
        var depth: Int
        var leapfrogs: Int
        var divergent: Bool
    }

    @inline(__always)
    private func criterion(_ pSharpMinus: Vector, _ pSharpPlus: Vector, _ rho: Vector) -> Bool {
        VectorOps.dot(pSharpPlus.p, rho.p, n) > 0 && VectorOps.dot(pSharpMinus.p, rho.p, n) > 0
    }

    private func transition() -> TransitionStats {
        sampleMomentum(z)
        zFwd.copyAll(from: z)
        zBck.copyAll(from: z)
        zSample.copyState(from: z)
        zPropose.copyState(from: z)

        let h0 = hamiltonian(z, pSharp: pSharpFwdFwd)
        pSharpFwdBck.copy(from: pSharpFwdFwd)
        pSharpBckFwd.copy(from: pSharpFwdFwd)
        pSharpBckBck.copy(from: pSharpFwdFwd)
        pFwdFwd.copy(from: z.p)
        pFwdBck.copy(from: z.p)
        pBckFwd.copy(from: z.p)
        pBckBck.copy(from: z.p)
        rho.copy(from: z.p)

        var logSumWeight = 0.0
        leapfrogs = 0
        sumMetroProb = 0
        divergent = false
        var depth = 0

        while depth < config.maxTreeDepth {
            rhoFwd.zero()
            rhoBck.zero()
            var logSumWeightSubtree = -Double.infinity
            let valid: Bool
            if rng.uniform() > 0.5 {
                z.copyAll(from: zFwd)
                rhoBck.copy(from: rho)
                pBckFwd.copy(from: pFwdBck)
                pSharpBckFwd.copy(from: pSharpFwdBck)
                valid = buildTree(
                    depth: depth, zPropose: zPropose,
                    pSharpBeg: pSharpFwdBck, pSharpEnd: pSharpFwdFwd, rho: rhoFwd,
                    pBeg: pFwdBck, pEnd: pFwdFwd, h0: h0, sign: 1,
                    logSumWeight: &logSumWeightSubtree
                )
                zFwd.copyAll(from: z)
            } else {
                z.copyAll(from: zBck)
                rhoFwd.copy(from: rho)
                pFwdBck.copy(from: pBckFwd)
                pSharpFwdBck.copy(from: pSharpBckFwd)
                valid = buildTree(
                    depth: depth, zPropose: zPropose,
                    pSharpBeg: pSharpBckFwd, pSharpEnd: pSharpBckBck, rho: rhoBck,
                    pBeg: pBckFwd, pEnd: pBckBck, h0: h0, sign: -1,
                    logSumWeight: &logSumWeightSubtree
                )
                zBck.copyAll(from: z)
            }
            if !valid { break }
            depth += 1

            // Biased progressive sampling between old trajectory and new subtree.
            if logSumWeightSubtree > logSumWeight {
                zSample.copyState(from: zPropose)
            } else if rng.uniform() < exp(logSumWeightSubtree - logSumWeight) {
                zSample.copyState(from: zPropose)
            }
            logSumWeight = logSumExp(logSumWeight, logSumWeightSubtree)

            VectorOps.add(rhoBck.p, rhoFwd.p, rho.p, n)
            var persist = criterion(pSharpBckBck, pSharpFwdFwd, rho)
            VectorOps.add(rhoBck.p, pFwdBck.p, rhoExtended.p, n)
            persist = criterion(pSharpBckBck, pSharpFwdBck, rhoExtended) && persist
            VectorOps.add(rhoFwd.p, pBckFwd.p, rhoExtended.p, n)
            persist = criterion(pSharpBckFwd, pSharpFwdFwd, rhoExtended) && persist
            if !persist { break }
        }

        z.copyState(from: zSample)
        return TransitionStats(
            acceptStat: leapfrogs > 0 ? sumMetroProb / Double(leapfrogs) : 0,
            depth: depth,
            leapfrogs: leapfrogs,
            divergent: divergent
        )
    }

    /// Builds a subtree of 2^depth leapfrog steps from the current point `z`
    /// in direction `sign`. Returns false on divergence or internal U-turn.
    private func buildTree(
        depth: Int,
        zPropose: PhasePoint,
        pSharpBeg: Vector,
        pSharpEnd: Vector,
        rho: Vector,
        pBeg: Vector,
        pEnd: Vector,
        h0: Double,
        sign: Double,
        logSumWeight: inout Double
    ) -> Bool {
        if depth == 0 {
            leapfrog(z, epsilon: sign * stepSize)
            leapfrogs += 1
            var h = hamiltonian(z, pSharp: pSharpBeg)
            if h.isNaN { h = .infinity }
            if h - h0 > Self.maxDeltaH { divergent = true }
            logSumWeight = logSumExp(logSumWeight, h0 - h)
            sumMetroProb += h0 - h > 0 ? 1 : exp(h0 - h)
            zPropose.copyState(from: z)
            pSharpEnd.copy(from: pSharpBeg)
            VectorOps.add(rho.p, z.p.p, rho.p, n)
            pBeg.copy(from: z.p)
            pEnd.copy(from: z.p)
            return !divergent
        }

        let level = levels[depth]

        level.rhoInit.zero()
        var logSumWeightInit = -Double.infinity
        let validInit = buildTree(
            depth: depth - 1, zPropose: zPropose,
            pSharpBeg: pSharpBeg, pSharpEnd: level.pSharpInitEnd, rho: level.rhoInit,
            pBeg: pBeg, pEnd: level.pInitEnd, h0: h0, sign: sign,
            logSumWeight: &logSumWeightInit
        )
        if !validInit { return false }

        level.rhoFinal.zero()
        var logSumWeightFinal = -Double.infinity
        let validFinal = buildTree(
            depth: depth - 1, zPropose: level.zProposeFinal,
            pSharpBeg: level.pSharpFinalBeg, pSharpEnd: pSharpEnd, rho: level.rhoFinal,
            pBeg: level.pFinalBeg, pEnd: pEnd, h0: h0, sign: sign,
            logSumWeight: &logSumWeightFinal
        )
        if !validFinal { return false }

        // Multinomial sample between the two halves of this subtree.
        let logSumWeightSubtree = logSumExp(logSumWeightInit, logSumWeightFinal)
        logSumWeight = logSumExp(logSumWeight, logSumWeightSubtree)
        if logSumWeightFinal > logSumWeightSubtree {
            zPropose.copyState(from: level.zProposeFinal)
        } else if rng.uniform() < exp(logSumWeightFinal - logSumWeightSubtree) {
            zPropose.copyState(from: level.zProposeFinal)
        }

        VectorOps.add(level.rhoInit.p, level.rhoFinal.p, level.rhoSubtree.p, n)
        VectorOps.add(rho.p, level.rhoSubtree.p, rho.p, n)

        var persist = criterion(pSharpBeg, pSharpEnd, level.rhoSubtree)
        VectorOps.add(level.rhoInit.p, level.pFinalBeg.p, level.rhoExtended.p, n)
        persist = criterion(pSharpBeg, level.pSharpFinalBeg, level.rhoExtended) && persist
        VectorOps.add(level.rhoFinal.p, level.pInitEnd.p, level.rhoExtended.p, n)
        persist = criterion(level.pSharpInitEnd, pSharpEnd, level.rhoExtended) && persist
        return persist
    }
}

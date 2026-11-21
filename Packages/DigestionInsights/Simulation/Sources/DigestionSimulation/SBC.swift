import DigestionInsightsEngine
import Foundation

/// Simulation-based calibration (Talts et al. 2018) of `LagModel` on a
/// reduced problem: 3 features, 2 kinds, 30 logged days of a synthetic user's
/// meal log. Each replication draws parameters from the prior, simulates
/// hourly symptom counts from the model, refits with the engine's NUTS
/// sampler and records the rank of the true value among thinned posterior
/// draws. A correct sampler and model give uniform ranks.
public struct SBCPlan: Codable, Sendable, Equatable {
    public var replications: Int = 200
    public var warmup: Int = 500
    public var samples: Int = 500
    public var targetAcceptance: Double = 0.8
    /// Thinned draws per replication; ranks lie in 0...thinnedDraws.
    public var thinnedDraws: Int = 99
    public var loggedDays: Int = 30
    public var features: [String] = [FoodWorld.coffee, FoodWorld.garlic, "ingredient:en:tomato"]
    public var kinds: [String] = ["abdominalPain", "bloating"]
    /// Replications whose simulated hourly rate exceeds this are redrawn
    /// (heavy half-Cauchy tails can give absurd rates); the count is reported.
    public var maxHourlyRate: Double = 50
    public var baseSeed: UInt64 = 7_201_826
    public var concurrency: Int = 2

    public init() {}
}

public struct SBCReplication: Codable, Sendable, Equatable {
    public var index: Int
    /// Rank per tracked quantity, in `SBC.quantityNames` order.
    public var ranks: [Int]
    public var redraws: Int
    public var symptoms: Int
    public var divergences: Int
    @FiniteOrNull public var maxRhat: Double
    @FiniteOrNull public var minBulkESS: Double
}

public enum SBC {
    public static let quantityNames = [
        "alpha[abdominalPain]", "alpha[bloating]", "tod[sin 1]", "log sigma_drift",
        "log tau_global", "log lambda[coffee]", "log lambda[garlic]", "log sigma_kind",
        "beta_shared[coffee](6 h)", "beta_shared[garlic](6 h)", "sum_l beta_shared[garlic](l)",
    ]

    public static func run(plan: SBCPlan, output: URL, log: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var results: [SBCReplication] = []
        let started = Date()
        try await withThrowingTaskGroup(of: SBCReplication.self) { group in
            var next = 0
            func addNext() {
                guard next < plan.replications else { return }
                let index = next
                next += 1
                group.addTask { try await replicate(index: index, plan: plan) }
            }
            for _ in 0..<max(plan.concurrency, 1) { addNext() }
            while let replication = try await group.next() {
                results.append(replication)
                log(String(format: "[sbc %d/%d %.0fs] symptoms=%d div=%d rhat=%.3f ess=%.0f redraws=%d",
                           results.count, plan.replications, Date().timeIntervalSince(started),
                           replication.symptoms, replication.divergences, replication.maxRhat,
                           replication.minBulkESS, replication.redraws))
                addNext()
            }
        }
        results.sort { $0.index < $1.index }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(SBCRaw(plan: plan, replications: results)).write(to: output)
    }

    struct SBCRaw: Codable {
        var plan: SBCPlan
        var replications: [SBCReplication]
    }

    static func readRaw(_ url: URL) throws -> (SBCPlan, [SBCReplication]) {
        let raw = try JSONDecoder().decode(SBCRaw.self, from: Data(contentsOf: url))
        return (raw.plan, raw.replications)
    }

    /// Meal log of a fixed synthetic user, reduced to the plan's features.
    static func design(plan: SBCPlan) -> AnalysisInput {
        let user = SyntheticUser(spec: UserSpec(
            seed: plan.baseSeed, diligence: .typical, trigger: nil,
            calendarDays: Int(Double(plan.loggedDays) * 1.25) + 7
        ))
        var input = user.input(loggedDayCount: plan.loggedDays, config: AnalysisConfig(seed: 0))!
        let keep = Set(plan.features)
        input.exposures = input.exposures.filter { keep.contains($0.featureID) }
        input.symptoms = []
        input.symptomKinds = plan.kinds
        return input
    }

    static func replicate(index: Int, plan: SBCPlan) async throws -> SBCReplication {
        var rng = Xoshiro256StarStar(seed: plan.baseSeed, stream: index + 1)
        let base = design(plan: plan)
        let priors = ModelPriors.default
        let emptyData = LagData(input: base)
        let rows = Array(emptyData.hours.indices)
        let generator = LagModel(data: emptyData, rows: rows, priors: priors, driftKnotSpacingDays: 30)
        let layout = generator.layout

        // Draw from the prior until the simulated rates are sane.
        var redraws = 0
        var truth: [Double] = []
        var counts: [Int] = []
        while true {
            truth = drawPrior(layout: layout, priors: priors, rng: &rng)
            let eta = generator.linearPredictor(truth)
            if let maxEta = eta.max(), exp(maxEta) <= plan.maxHourlyRate {
                counts = eta.map { poisson(exp($0), &rng) }
                if counts.reduce(0, +) > 0 { break }
            }
            redraws += 1
        }

        // Simulated counts become symptom events at the hour centre.
        var input = base
        for (row, hour) in emptyData.hours.enumerated() {
            for (s, kind) in plan.kinds.enumerated() {
                for _ in 0..<counts[row * plan.kinds.count + s] {
                    input.symptoms.append(SymptomEvent(
                        kind: kind,
                        onset: Date(timeIntervalSince1970: (Double(hour) + 0.5) * 3600),
                        levelRank: 0, isTopLevel: false
                    ))
                }
            }
        }
        let data = LagData(input: input)
        let model = LagModel(data: data, rows: Array(data.hours.indices), priors: priors, driftKnotSpacingDays: 30)
        let output = try await NUTSSampler.sample(model, configuration: NUTSConfiguration(
            warmup: plan.warmup, samples: plan.samples, targetAcceptance: plan.targetAcceptance, seed: plan.baseSeed &+ UInt64(index) &* 0x2545_F491_4F6C_DD1D
        ))
        let diagnostics = SamplerDiagnostics(output)

        precondition(data.modelFeatures == plan.features.sorted(), "SBC design lost a feature: \(data.modelFeatures)")
        let trueValues = quantities(truth, model: model, data: data)
        let total = output.chains.reduce(0) { $0 + $1.sampleCount }
        var below = [Int](repeating: 0, count: trueValues.count)
        for t in 0..<plan.thinnedDraws {
            // Equally spaced thinning over all chains' draws.
            let flat = Int((Double(t) + 0.5) * Double(total) / Double(plan.thinnedDraws))
            let chain = output.chains[flat / output.chains[0].sampleCount]
            let draw = Array(chain.draw(flat % chain.sampleCount))
            let values = quantities(draw, model: model, data: data)
            for i in values.indices where values[i] < trueValues[i] { below[i] += 1 }
        }
        return SBCReplication(
            index: index, ranks: below, redraws: redraws, symptoms: counts.reduce(0, +),
            divergences: diagnostics.divergences, maxRhat: diagnostics.maxRhat, minBulkESS: diagnostics.minBulkESS
        )
    }

    /// One draw from the model's prior (`ModelPriors`), in the sampler's
    /// parametrisation (log scales, non-centred z).
    static func drawPrior(layout: LagModel.Layout, priors: ModelPriors, rng: inout Xoshiro256StarStar) -> [Double] {
        var q = [Double](repeating: 0, count: layout.dimension)
        func halfNormal(_ scale: Double) -> Double { abs(rng.standardNormal()) * scale }
        for s in 0..<layout.kinds { q[layout.alpha + s] = log(0.3 / 24) + priors.interceptSD * rng.standardNormal() }
        for t in 0..<layout.todTerms { q[layout.tod + t] = priors.timeOfDaySD * rng.standardNormal() }
        for j in 0..<layout.driftTerms { q[layout.driftU + j] = rng.standardNormal() }
        q[layout.logSigmaDrift] = log(halfNormal(priors.driftScale))
        q[layout.logTauGlobal] = log(halfNormal(priors.globalScale))
        for f in 0..<layout.features {
            let lambda: Double
            switch priors.localDistribution {
            case .halfNormal: lambda = halfNormal(priors.localScale)
            case .halfCauchy: lambda = priors.localScale * abs(tan(Double.pi * (rng.uniform() - 0.5)))
            }
            q[layout.logLambda + f] = log(lambda)
        }
        for i in 0..<(layout.features * layout.basis) { q[layout.zShared + i] = rng.standardNormal() }
        q[layout.logSigmaKind] = log(halfNormal(priors.kindDeviationScale))
        for i in 0..<(layout.features * layout.kinds * layout.basis) { q[layout.zKind + i] = rng.standardNormal() }
        return q
    }

    /// Tracked scalar quantities of a position (see `quantityNames`).
    static func quantities(_ q: [Double], model: LagModel, data: LagData) -> [Double] {
        let layout = model.layout
        let basis = data.lagBasis
        let coffeeIndex = data.modelFeatures.firstIndex(of: FoodWorld.coffee)!
        let garlicIndex = data.modelFeatures.firstIndex(of: FoodWorld.garlic)!
        let k = layout.basis
        func shared(_ feature: Int) -> [Double] {
            // b_f = slab(τ_g λ_f) C z_f
            let tau = model.priors.slab(exp(q[layout.logTauGlobal] + q[layout.logLambda + feature])).scale
            return (0..<k).map { row in
                var sum = 0.0
                for column in 0..<k { sum += model.lagFactor[row * k + column] * q[layout.zShared + feature * k + column] }
                return tau * sum
            }
        }
        func beta(_ b: [Double], at lag: Double) -> Double {
            zip(basis.evaluate(at: lag), b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let coffee = shared(coffeeIndex), garlic = shared(garlicIndex)
        let garlicSum = (0..<96).reduce(0.0) { $0 + beta(garlic, at: Double($1) + 0.5) }
        return [
            q[layout.alpha], q[layout.alpha + 1], q[layout.tod], q[layout.logSigmaDrift],
            q[layout.logTauGlobal], q[layout.logLambda + coffeeIndex], q[layout.logLambda + garlicIndex], q[layout.logSigmaKind],
            beta(coffee, at: 6.5), beta(garlic, at: 6.5), garlicSum,
        ]
    }
}

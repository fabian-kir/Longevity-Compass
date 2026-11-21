import Foundation

public enum DigestionAnalysis {
    /// Full analysis (B9): design, three NUTS fits (full data, first half,
    /// second half of observed hours), convergence check, summaries, chart
    /// data, confounding and levels. Throws `CancellationError` on cancel.
    public static func run(_ input: AnalysisInput) async throws -> AnalysisResult {
        try await run(input, progress: nil)
    }

    /// As `run(_:)`, reporting progress in [0, 1] (sampler iterations
    /// weighted by fit size). The callback runs on sampler threads, at most
    /// about once per 0.1 %.
    public static func run(
        _ input: AnalysisInput,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AnalysisResult {
        let clock = ContinuousClock()
        let started = clock.now
        try Task.checkCancellation()
        let config = input.config
        let fingerprint = Self.fingerprint(input)
        let data = LagData(input: input)
        let confounded = data.confounding(threshold: config.confoundingCorrelation, windows: input.windows)

        func elapsed() -> Double {
            let duration = clock.now - started
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        }

        guard !data.kinds.isEmpty, !data.hours.isEmpty, !data.observedSymptoms.isEmpty, !data.modelFeatures.isEmpty else {
            let features = data.allFeatures.map { feature in
                FeatureResult(
                    featureID: feature,
                    exposureCount: data.exposureCount[feature]!,
                    symptomsAfterCount: data.symptomsAfterCount[feature]!,
                    level: .notEnoughData,
                    overall: nil, perKind: [:], mainKind: nil,
                    firstHalfProbRaises: nil, secondHalfProbRaises: nil,
                    lagCurve: [], confoundedWith: confounded[feature] ?? []
                )
            }
            progress?(1)
            return AnalysisResult(
                status: .insufficientData,
                diagnostics: RunDiagnostics(maxRhat: .nan, minBulkESS: .nan, divergences: 0, durationSeconds: elapsed(), fits: 0),
                features: features,
                inputFingerprint: fingerprint
            )
        }

        // Fits: full, then halves split at the median observed hour.
        let allRows = Array(data.hours.indices)
        let medianHour = data.hours[(data.hours.count - 1) / 2]
        var plans: [(name: String, rows: [Int])] = [("full", allRows)]
        if config.fitHalves {
            let first = allRows.filter { data.hours[$0] <= medianHour }
            let second = allRows.filter { data.hours[$0] > medianHour }
            for (name, rows) in [("firstHalf", first), ("secondHalf", second)]
            where rows.count >= 2 && data.symptomCount(rows: rows) > 0 {
                plans.append((name, rows))
            }
        }
        let iterationsPerFit = config.chains * (config.warmup + config.samples)
        let tracker = ProgressTracker(
            weights: plans.map { Double($0.rows.count) },
            iterationsPerFit: iterationsPerFit,
            callback: progress
        )

        var fitDiagnostics: [FitDiagnostics] = []
        var fullSummaries: FeatureSummaries?
        var expectedNull: [[Double]] = []
        var halfProbRaises: [String: [Double]] = [:]

        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            let fitStart = clock.now
            let model = LagModel(
                data: data,
                rows: plan.rows,
                priors: config.priors,
                driftKnotSpacingDays: config.driftKnotSpacingDays
            )
            let samplerConfig = NUTSConfiguration(
                chains: config.chains,
                warmup: config.warmup,
                samples: config.samples,
                targetAcceptance: config.targetAcceptance,
                maxTreeDepth: config.maxTreeDepth,
                seed: config.seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            )
            let output = try await NUTSSampler.sample(model, configuration: samplerConfig) {
                tracker.tick(fit: index)
            }
            try Task.checkCancellation()
            let diagnostics = SamplerDiagnostics(output)
            if plan.name == "full" {
                fullSummaries = try PosteriorSummary.summarize(
                    model: model, output: output, kinds: data.kinds,
                    lagBasis: data.lagBasis, maxLagHours: data.maxLagHours,
                    peakThreshold: config.thresholds.noLinkUpper
                )
                expectedNull = try PosteriorSummary.expectedPairsNull(
                    model: model, data: data, output: output, chartDraws: config.chartDraws
                )
            } else {
                halfProbRaises[plan.name] = try PosteriorSummary.summarize(
                    model: model, output: output, kinds: data.kinds,
                    lagBasis: data.lagBasis, maxLagHours: data.maxLagHours,
                    peakThreshold: config.thresholds.noLinkUpper, includeCurves: false
                ).probRaises
            }
            let fitDuration = clock.now - fitStart
            fitDiagnostics.append(FitDiagnostics(
                name: plan.name,
                observedHours: plan.rows.count,
                symptoms: data.symptomCount(rows: plan.rows),
                parameters: model.dimension,
                maxRhat: diagnostics.maxRhat,
                minBulkESS: diagnostics.minBulkESS,
                minTailESS: diagnostics.minTailESS,
                divergences: diagnostics.divergences,
                treeDepthHits: diagnostics.treeDepthHits,
                stepSizes: diagnostics.stepSizes,
                leapfrogSteps: diagnostics.leapfrogSteps,
                durationSeconds: Double(fitDuration.components.seconds) + Double(fitDuration.components.attoseconds) * 1e-18,
                converged: ConvergenceCriteria.default.isConverged(diagnostics)
            ))
        }
        progress?(1)

        let summaries = fullSummaries!
        let modelIndex = Dictionary(uniqueKeysWithValues: data.modelFeatures.enumerated().map { ($1, $0) })
        let features: [FeatureResult] = data.allFeatures.map { feature in
            let exposures = data.exposureCount[feature]!
            let symptomsAfter = data.symptomsAfterCount[feature]!
            guard let m = modelIndex[feature] else {
                return FeatureResult(
                    featureID: feature, exposureCount: exposures, symptomsAfterCount: symptomsAfter,
                    level: .notEnoughData, overall: nil, perKind: [:], mainKind: nil,
                    firstHalfProbRaises: nil, secondHalfProbRaises: nil,
                    lagCurve: [], confoundedWith: confounded[feature] ?? []
                )
            }
            let pairs = data.observedPairs(feature: feature)
            let curve = (0..<data.maxLagHours).map { l in
                LagPoint(hour: l, rr: summaries.curves[m][l], observedPairs: pairs[l], expectedPairsNull: expectedNull[m][l])
            }
            let first = halfProbRaises["firstHalf"]?[m]
            let second = halfProbRaises["secondHalf"]?[m]
            let overall = summaries.overall[m]
            return FeatureResult(
                featureID: feature,
                exposureCount: exposures,
                symptomsAfterCount: symptomsAfter,
                level: PatternLevel.classify(
                    exposureCount: exposures,
                    symptomsAfterCount: symptomsAfter,
                    overall: overall,
                    firstHalfProbRaises: first,
                    secondHalfProbRaises: second,
                    config: config
                ),
                overall: overall,
                perKind: summaries.perKind[m],
                mainKind: summaries.mainKind[m],
                firstHalfProbRaises: first,
                secondHalfProbRaises: second,
                lagCurve: curve,
                confoundedWith: confounded[feature] ?? []
            )
        }

        let converged = fitDiagnostics.allSatisfy(\.converged)
        let diagnostics = RunDiagnostics(
            maxRhat: SamplerDiagnostics.nanAwareMax(fitDiagnostics.map(\.maxRhat)),
            minBulkESS: SamplerDiagnostics.nanAwareMin(fitDiagnostics.map(\.minBulkESS)),
            divergences: fitDiagnostics.reduce(0) { $0 + $1.divergences },
            durationSeconds: elapsed(),
            fits: fitDiagnostics.count,
            fitDiagnostics: fitDiagnostics
        )
        return AnalysisResult(
            status: converged ? .ok : .notConverged,
            diagnostics: diagnostics,
            features: features,
            inputFingerprint: fingerprint
        )
    }

    /// FNV-1a 64-bit over the canonical JSON of `input` (sorted keys, dates
    /// as seconds since 1970) with `config.seed` set to 0 — the B11 hash, so
    /// the app derives its seed as `fingerprint(input) ^ attempt`.
    public static func fingerprint(_ input: AnalysisInput) -> UInt64 {
        var canonical = input
        canonical.config.seed = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(canonical) else { return 0 }
        return fnv1a64(data)
    }

    public static func fnv1a64(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

public extension PatternLevel {
    /// Level rules (B9), in order: notEnoughData, clearPattern, earlySignal,
    /// noLinkFound, inconclusive. No time gates.
    ///
    /// Addition to B9: noLinkFound also needs median peakRR < noLinkUpper.
    /// averageRR spreads an acute effect over 96 h (a ×4 effect for 4 h
    /// averages to about ×1.1), so without this guard a clear short-lag peak
    /// could be reported as "No link found" (B2).
    static func classify(
        exposureCount: Int,
        symptomsAfterCount: Int,
        overall: EffectSummary?,
        firstHalfProbRaises: Double?,
        secondHalfProbRaises: Double?,
        config: AnalysisConfig
    ) -> PatternLevel {
        let t = config.thresholds
        guard exposureCount >= config.minExposures,
              symptomsAfterCount >= config.minSymptomsAfter,
              let overall else { return .notEnoughData }
        if overall.probRaises >= t.clearProb,
           let first = firstHalfProbRaises, first >= t.halfProb,
           let second = secondHalfProbRaises, second >= t.halfProb {
            return .clearPattern
        }
        if overall.probRaises >= t.earlyProb { return .earlySignal }
        if exposureCount >= t.noLinkMinExposures,
           overall.averageRR.lower >= t.noLinkLower,
           overall.averageRR.upper <= t.noLinkUpper,
           overall.peakRR.median < t.noLinkUpper {
            return .noLinkFound
        }
        return .inconclusive
    }
}

/// Aggregates per-iteration ticks from all chains of all fits.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let shares: [Double]
    private let iterationsPerFit: Int
    private let callback: (@Sendable (Double) -> Void)?
    private var done: [Int]
    private var lastReported = -1.0

    init(weights: [Double], iterationsPerFit: Int, callback: (@Sendable (Double) -> Void)?) {
        let total = weights.reduce(0, +)
        shares = weights.map { total > 0 ? $0 / total : 0 }
        self.iterationsPerFit = max(iterationsPerFit, 1)
        self.callback = callback
        done = [Int](repeating: 0, count: weights.count)
    }

    func tick(fit: Int) {
        guard let callback else { return }
        lock.lock()
        done[fit] += 1
        var fraction = 0.0
        for i in shares.indices { fraction += shares[i] * Double(done[i]) / Double(iterationsPerFit) }
        // Summaries after sampling take the last few percent.
        fraction = min(fraction * 0.98, 0.98)
        let report = fraction - lastReported >= 0.001
        if report { lastReported = fraction }
        lock.unlock()
        if report { callback(fraction) }
    }
}

import DigestionInsightsEngine
import Foundation

/// Threshold calibration and result tables from the raw recovery and SBC
/// runs. Rules (B12):
/// - false-earlySignal: share of null-user analyses where at least one food
///   reaches earlySignal or clearPattern; target ≤ 5 %.
/// - false-clearPattern: same for clearPattern; target ≤ 1 %.
/// - earlyProb = smallest grid value meeting the early target in the pooled
///   null analyses (all horizons); halfProb = earlyProb (each half must show
///   at least an early signal on its own); clearProb = smallest grid value
///   ≥ earlyProb meeting the clear target. Run convergence is ignored for
///   calibration (more data; shown rates are reported separately).
public enum Calibration {
    public static let grid: [Double] = stride(from: 80, through: 99, by: 1).map { Double($0) / 100 } + [0.995, 0.999]
    public static let falseEarlyTarget = 0.05
    public static let falseClearTarget = 0.01

    public static func run(paths: SimulationPaths, log: @escaping @Sendable (String) -> Void) throws {
        let records = try RecoveryStudy.readRecords(paths.recoveryRecords)
        log("calibrate: \(records.count) recovery records")
        let sbc = try? SBC.readRaw(paths.sbcRecords)
        if sbc == nil { log("calibrate: no SBC file at \(paths.sbcRecords.path); SBC section left empty") }
        let results = analyse(records: records, sbc: sbc, compute: computeUsed(paths: paths))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: paths.resultsJSON)
        log("calibrate: wrote \(paths.resultsJSON.path)")
        log("calibrate: earlyProb \(results.calibration.earlyProb) clearProb \(results.calibration.clearProb) halfProb \(results.calibration.halfProb)")
        log("headline: \(results.headline.sentence)")
    }

    // MARK: - Analysis

    static func thresholds(early: Double, clear: Double, half: Double) -> Thresholds {
        Thresholds(earlyProb: early, clearProb: clear, halfProb: half)
    }

    /// Levels of null-user analyses: any food at early-or-clear / clear.
    static func nullHits(_ records: [RunRecord], _ t: Thresholds, excluding: (RunRecord) -> Set<String> = { _ in [] })
        -> (early: [Bool], clear: [Bool]) {
        var early: [Bool] = [], clear: [Bool] = []
        for record in records {
            let skip = excluding(record)
            let levels = record.levels(t).filter { !skip.contains($0.key) }.values
            early.append(levels.contains { $0 == .earlySignal || $0 == .clearPattern })
            clear.append(levels.contains(.clearPattern))
        }
        return (early, clear)
    }

    static func proportion(_ flags: [Bool]) -> Proportion {
        Proportion(flags.filter { $0 }.count, of: flags.count)
    }

    public static func analyse(records: [RunRecord], sbc: (SBCPlan, [SBCReplication])?, compute: ComputeUsed) -> SimulationResults {
        let nulls = records.filter(\.isNull)
        let planted = records.filter { !$0.isNull }
        let horizons = Array(Set(records.map(\.horizon))).sorted()

        // Threshold curve on null users.
        var curve: [ThresholdPoint] = []
        for value in grid {
            let early = nullHits(nulls, thresholds(early: value, clear: 2, half: value)).early
            let clear = nullHits(nulls, thresholds(early: value, clear: value, half: value)).clear
            curve.append(ThresholdPoint(threshold: value, falseEarly: proportion(early), falseClearWithEqualHalf: proportion(clear)))
        }
        let earlyProb = grid.first { value in
            proportion(nullHits(nulls, thresholds(early: value, clear: 2, half: value)).early).rate <= falseEarlyTarget
        } ?? grid.last!
        let halfProb = earlyProb
        let clearProb = grid.filter { $0 >= earlyProb }.first { value in
            proportion(nullHits(nulls, thresholds(early: earlyProb, clear: value, half: halfProb)).clear).rate <= falseClearTarget
        } ?? grid.last!
        let chosen = thresholds(early: earlyProb, clear: clearProb, half: halfProb)

        func nullRates(_ subset: [RunRecord]) -> (Proportion, Proportion) {
            let hits = nullHits(subset, chosen)
            return (proportion(hits.early), proportion(hits.clear))
        }
        let pooled = nullRates(nulls)
        let shownHits = nullHits(nulls, chosen)
        let shownEarly = zip(nulls, shownHits.early).map { $0.status == .ok && $1 }
        let shownClear = zip(nulls, shownHits.clear).map { $0.status == .ok && $1 }
        var perHorizon: [NullRate] = []
        for h in horizons {
            let subset = nulls.filter { $0.horizon == h }
            let rates = nullRates(subset)
            perHorizon.append(NullRate(horizon: h, falseEarly: rates.0, falseClear: rates.1))
        }
        // Ever flagged across the analysed horizons, per null user.
        let byUser = Dictionary(grouping: nulls, by: \.userSeed)
        let everEarly = byUser.values.map { runs in nullHits(runs, chosen).early.contains(true) }
        let everClear = byUser.values.map { runs in nullHits(runs, chosen).clear.contains(true) }
        // Background: foods other than the trigger and its partner in planted users.
        let background = nullHits(planted, chosen) { record in
            var skip: Set<String> = []
            if let t = record.trigger {
                skip.insert(t.featureID)
                if let p = FoodWorld.partner(of: t.featureID) { skip.insert(p) }
            }
            return skip
        }
        let calibration = CalibrationResult(
            grid: grid,
            falseEarlyTarget: falseEarlyTarget,
            falseClearTarget: falseClearTarget,
            earlyProb: earlyProb,
            clearProb: clearProb,
            halfProb: halfProb,
            nullUsers: byUser.count,
            nullAnalyses: nulls.count,
            falseEarlyPooled: pooled.0,
            falseClearPooled: pooled.1,
            falseEarlyShown: proportion(shownEarly),
            falseClearShown: proportion(shownClear),
            perHorizon: perHorizon,
            falseEarlyEver: proportion(everEarly),
            falseClearEver: proportion(everClear),
            backgroundFalseEarly: proportion(background.early),
            backgroundFalseClear: proportion(background.clear),
            curve: curve,
            targetsMet: pooled.0.rate <= falseEarlyTarget && pooled.1.rate <= falseClearTarget
        )

        // Convergence.
        var convergence: [ConvergenceRow] = []
        for d in LoggingDiligence.allCases {
            for h in horizons {
                let subset = records.filter { $0.diligence == d && $0.horizon == h }
                guard !subset.isEmpty else { continue }
                convergence.append(ConvergenceRow(
                    diligence: d, horizon: h,
                    converged: Proportion(subset.filter { $0.status == .ok }.count, of: subset.count),
                    withDivergences: Proportion(subset.filter { $0.divergences > 0 }.count, of: subset.count),
                    medianMaxRhat: median(subset.map(\.maxRhat).filter(\.isFinite)) ?? .nan,
                    medianSeconds: median(subset.map(\.durationSeconds)) ?? .nan,
                    medianSymptoms: median(subset.map { Double($0.symptoms) }) ?? .nan
                ))
            }
        }

        // Recovery of planted triggers.
        func trigger(_ record: RunRecord) -> (PatternLevel, FeatureRecord?) {
            let id = record.trigger!.featureID
            return (record.levels(chosen)[id] ?? .notEnoughData, record.features.first { $0.featureID == id })
        }
        func partnerLevel(_ record: RunRecord) -> PatternLevel? {
            guard let p = FoodWorld.partner(of: record.trigger!.featureID) else { return nil }
            return record.levels(chosen)[p] ?? .notEnoughData
        }
        func isEarly(_ level: PatternLevel) -> Bool { level == .earlySignal || level == .clearPattern }
        func row(_ subset: [RunRecord]) -> RecoveryCounts {
            let levels = subset.map { trigger($0).0 }
            let shown = zip(subset, levels).map { $0.status == .ok ? $1 : .notEnoughData }
            return RecoveryCounts(
                users: subset.count,
                early: levels.filter(isEarly).count,
                clear: levels.filter { $0 == .clearPattern }.count,
                earlyShown: shown.filter(isEarly).count,
                clearShown: shown.filter { $0 == .clearPattern }.count,
                noLinkFound: levels.filter { $0 == .noLinkFound }.count
            )
        }
        var recovery: [RecoveryRow] = []
        let effects = Array(Set(planted.map { $0.trigger!.multiplier })).sorted()
        for d in LoggingDiligence.allCases {
            for e in effects {
                for k in LagKernel.allCases {
                    for h in horizons {
                        let subset = planted.filter {
                            $0.diligence == d && $0.trigger!.multiplier == e && $0.trigger!.kernel == k && $0.horizon == h
                        }
                        guard !subset.isEmpty else { continue }
                        recovery.append(RecoveryRow(diligence: d, effect: e, kernel: k, food: nil, horizon: h, counts: row(subset)))
                    }
                }
            }
        }
        var byFood: [RecoveryRow] = []
        for food in FoodWorld.triggerFoods {
            for e in effects {
                for h in horizons {
                    let subset = planted.filter { $0.trigger!.featureID == food && $0.trigger!.multiplier == e && $0.horizon == h }
                    guard !subset.isEmpty else { continue }
                    byFood.append(RecoveryRow(diligence: nil, effect: e, kernel: nil, food: food, horizon: h, counts: row(subset)))
                }
            }
        }
        var lagErrors: [LagErrorRow] = []
        for k in LagKernel.allCases {
            for e in effects {
                for h in horizons {
                    let subset = planted.filter { $0.trigger!.kernel == k && $0.trigger!.multiplier == e && $0.horizon == h }
                    let found = subset.filter { isEarly(trigger($0).0) }
                    let errors = found.compactMap { trigger($0).1?.overall?.medianLagHours?.median }.map { $0 - k.medianLagHours }
                    guard !subset.isEmpty else { continue }
                    lagErrors.append(LagErrorRow(
                        kernel: k, effect: e, horizon: h, trueMedianLag: k.medianLagHours,
                        found: errors.count,
                        medianError: median(errors),
                        medianAbsoluteError: median(errors.map(abs))
                    ))
                }
            }
        }
        var partner: [PartnerRow] = []
        for h in horizons {
            let subset = planted.filter { $0.horizon == h && FoodWorld.partner(of: $0.trigger!.featureID) != nil }
            guard !subset.isEmpty else { continue }
            let levels = subset.compactMap(partnerLevel)
            let triggerFound = subset.filter { isEarly(trigger($0).0) }
            partner.append(PartnerRow(
                horizon: h,
                partnerEarly: Proportion(levels.filter(isEarly).count, of: levels.count),
                partnerClear: Proportion(levels.filter { $0 == .clearPattern }.count, of: levels.count),
                partnerEarlyWhenTriggerFound: Proportion(triggerFound.compactMap(partnerLevel).filter(isEarly).count, of: triggerFound.count),
                flaggedAsConfounded: Proportion(
                    subset.filter { r in trigger(r).1?.confoundedWith.contains(FoodWorld.partner(of: r.trigger!.featureID)!) ?? false }.count,
                    of: subset.count
                )
            ))
        }

        // Alternative statistic (comparison only): P(peak RR > noLinkUpper).
        let peakThreshold = grid.first { value in
            proportion(nulls.map { r in r.features.contains { f in eligible(f) && (f.overall?.probPeakAbove ?? 0) >= value } }).rate <= falseEarlyTarget
        } ?? grid.last!
        var peakRows: [PeakRow] = []
        for k in LagKernel.allCases {
            for e in effects {
                for h in horizons {
                    let subset = planted.filter { $0.trigger!.kernel == k && $0.trigger!.multiplier == e && $0.horizon == h }
                    guard !subset.isEmpty else { continue }
                    let viaPeak = subset.filter { r in
                        guard let f = trigger(r).1, eligible(f) else { return false }
                        return (f.overall?.probPeakAbove ?? 0) >= peakThreshold
                    }.count
                    let viaRaises = subset.filter { isEarly(trigger($0).0) }.count
                    peakRows.append(PeakRow(kernel: k, effect: e, horizon: h, users: subset.count, earlyViaProbRaises: viaRaises, earlyViaPeak: viaPeak))
                }
            }
        }
        let peak = PeakAlternative(
            threshold: peakThreshold,
            nullFalseEarly: proportion(nulls.map { r in r.features.contains { f in eligible(f) && (f.overall?.probPeakAbove ?? 0) >= peakThreshold } }),
            rows: peakRows
        )

        let headline = makeHeadline(planted: planted, horizons: horizons, chosen: chosen, calibration: calibration, convergence: records)
        return SimulationResults(
            schemaVersion: 1,
            settings: SimulationSettings.current(records: records, sbc: sbc?.0),
            compute: compute,
            sbc: sbc.map(summarizeSBC),
            calibration: calibration,
            convergence: convergence,
            recovery: recovery,
            recoveryByFood: byFood,
            lagErrors: lagErrors,
            partner: partner,
            peakAlternative: peak,
            headline: headline
        )
    }

    static func eligible(_ f: FeatureRecord) -> Bool {
        f.exposureCount >= 5 && f.symptomsAfterCount >= 3 && f.overall != nil
    }

    /// Smallest horizon at which at least half of typical-logging ×2 users
    /// (all lag kernels) reach the level, counting only converged runs.
    static func makeHeadline(planted: [RunRecord], horizons: [Int], chosen: Thresholds,
                             calibration: CalibrationResult, convergence records: [RunRecord]) -> Headline {
        func share(_ h: Int, clear: Bool) -> Proportion {
            let subset = planted.filter { $0.diligence == .typical && $0.trigger!.multiplier == 2 && $0.horizon == h }
            let hits = subset.filter { r in
                guard r.status == .ok else { return false }
                let level = r.levels(chosen)[r.trigger!.featureID] ?? .notEnoughData
                return clear ? level == .clearPattern : (level == .earlySignal || level == .clearPattern)
            }
            return Proportion(hits.count, of: subset.count)
        }
        let earlyShares = horizons.map { HorizonShare(horizon: $0, share: share($0, clear: false)) }
        let clearShares = horizons.map { HorizonShare(horizon: $0, share: share($0, clear: true)) }
        let earlyDay = earlyShares.first { $0.share.trials > 0 && $0.share.rate >= 0.5 }?.horizon
        let clearDay = clearShares.first { $0.share.trials > 0 && $0.share.rate >= 0.5 }?.horizon
        let maxH = horizons.max() ?? 0
        func phrase(_ day: Int?) -> String { day.map { "about \($0)" } ?? "more than \(maxH) (not reached in the study)" }
        let fc = calibration.falseClearPooled
        let sentence = String(
            format: "With typical logging, a ×2 trigger reaches an early signal after %@ logged days and a clear pattern after %@ logged days (median user, converged runs only); null false-clear %.1f %% (95 %% interval %.1f–%.1f %%).",
            phrase(earlyDay), phrase(clearDay), 100 * fc.rate, 100 * fc.lower, 100 * fc.upper
        )
        func verdict(_ day: Int?, expected: Int) -> String {
            guard let day else { return "refuted: not reached within \(maxH) logged days" }
            if day <= Int(Double(expected) * 1.5) { return "confirmed: reached at \(day) logged days (expected about \(expected))" }
            return "refuted: reached only at \(day) logged days (expected about \(expected))"
        }
        return Headline(
            sentence: sentence,
            earlyLoggedDays: earlyDay,
            clearLoggedDays: clearDay,
            earlyShares: earlyShares,
            clearShares: clearShares,
            expectationEarly: verdict(earlyDay, expected: 14),
            expectationClear: verdict(clearDay, expected: 90)
        )
    }

    static func summarizeSBC(_ raw: (SBCPlan, [SBCReplication])) -> SBCSummary {
        let (plan, replications) = raw
        let bins = 10
        let maxRank = plan.thinnedDraws
        var quantities: [SBCQuantity] = []
        for (q, name) in SBC.quantityNames.enumerated() {
            var histogram = [Int](repeating: 0, count: bins)
            for r in replications {
                let bin = min(bins - 1, r.ranks[q] * bins / (maxRank + 1))
                histogram[bin] += 1
            }
            let expected = Double(replications.count) / Double(bins)
            let chi = histogram.reduce(0.0) { $0 + (Double($1) - expected) * (Double($1) - expected) / expected }
            quantities.append(SBCQuantity(
                name: name, histogram: histogram, chiSquare: chi,
                pValue: SpecialFunctions.chiSquareUpperTail(chi, df: bins - 1)
            ))
        }
        return SBCSummary(
            replications: replications.count,
            thinnedDraws: plan.thinnedDraws,
            bins: bins,
            redraws: replications.reduce(0) { $0 + $1.redraws },
            replicationsWithDivergences: replications.filter { $0.divergences > 0 }.count,
            medianSymptoms: median(replications.map { Double($0.symptoms) }) ?? .nan,
            quantities: quantities
        )
    }

    /// Facts about this study's compute that the logs do not show.
    static let computeNotes = [
        "Before the final runs: about 25 min of pilots and divergence probes (target acceptance 0.8 and 0.95 without the slab, prior variants); their runs are not in the results.",
        "Phase logs were restarted when concurrency changed; the run file resumes, so no analysis was counted twice. The simulation was paused for about 8 min in total during builds; those pauses are inside the logged wall times.",
    ]

    /// Wall time per phase, from the elapsed seconds in the run logs.
    static func computeUsed(paths: SimulationPaths) -> ComputeUsed {
        var phases: [ComputePhase] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.rawDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var last = 0.0, runs = 0
            for line in text.split(separator: "\n") where line.hasPrefix("[") {
                // "[12/660 336s] ..." or "[sbc 3/200 41s] ..."
                guard let close = line.firstIndex(of: "]") else { continue }
                let head = line[line.index(after: line.startIndex)..<close]
                if let token = head.split(separator: " ").last, token.hasSuffix("s"), let seconds = Double(token.dropLast()) {
                    last = max(last, seconds)
                    runs += 1
                }
            }
            if runs > 0 { phases.append(ComputePhase(log: file.lastPathComponent, runs: runs, wallSeconds: last)) }
        }
        var size = 0
        var length = MemoryLayout<Int>.size
        sysctlbyname("hw.ncpu", &size, &length, nil, 0)
        var model = [CChar](repeating: 0, count: 256)
        var modelLength = model.count
        sysctlbyname("machdep.cpu.brand_string", &model, &modelLength, nil, 0)
        return ComputeUsed(
            machine: String(cString: model),
            logicalCores: size,
            build: "swift build -c release",
            phases: phases,
            totalWallSeconds: phases.reduce(0) { $0 + $1.wallSeconds },
            notes: computeNotes
        )
    }
}

import DigestionInsightsEngine
import Foundation

// Schema of Simulation/results.json. `report` renders results.md from it,
// so every number in the markdown comes from this file.

public struct SimulationResults: Codable, Sendable {
    public var schemaVersion: Int
    public var settings: SimulationSettings
    public var compute: ComputeUsed
    public var sbc: SBCSummary?
    public var calibration: CalibrationResult
    public var convergence: [ConvergenceRow]
    public var recovery: [RecoveryRow]
    public var recoveryByFood: [RecoveryRow]
    public var lagErrors: [LagErrorRow]
    public var partner: [PartnerRow]
    public var peakAlternative: PeakAlternative
    public var headline: Headline
}

public struct SimulationSettings: Codable, Sendable {
    public var analysisConfig: AnalysisConfig
    public var horizons: [Int]
    public var kinds: [String]
    public var foods: [String]
    public var triggerFoods: [String]
    public var plantedUsers: Int
    public var nullUsers: Int
    public var analyses: Int
    public var diligence: [String: DiligenceProfile]
    public var evidence: [String: Double]
    public var generatorNotes: [String]
    /// Expected extra symptoms (of the trigger kind) per true exposure for
    /// the average user: (effect − 1) × window hours × mean baseline hourly
    /// rate of one kind (0.5 / day total, a third per kind). Key "×2 fast".
    public var expectedExcessPerExposure: [String: Double]
    public var designCaveats: [String]
    public var sbcPlan: SBCPlan?

    static func current(records: [RunRecord], sbc: SBCPlan?) -> SimulationSettings {
        var config = AnalysisConfig(seed: 0, chartDraws: 10)
        config.seed = 0
        return SimulationSettings(
            analysisConfig: config,
            horizons: Array(Set(records.map(\.horizon))).sorted(),
            kinds: FoodWorld.kinds,
            foods: FoodWorld.featureIDs,
            triggerFoods: FoodWorld.triggerFoods,
            plantedUsers: Set(records.filter { !$0.isNull }.map(\.userSeed)).count,
            nullUsers: Set(records.filter(\.isNull).map(\.userSeed)).count,
            analyses: records.count,
            diligence: Dictionary(uniqueKeysWithValues: LoggingDiligence.allCases.map { ($0.rawValue, $0.profile) }),
            evidence: [
                "barcodeCompleteShare": EvidenceModel.barcodeCompleteShare,
                "barcodeIncompleteShare": EvidenceModel.barcodeIncompleteShare,
                "photoShare": EvidenceModel.photoShare,
                "noProfileShare": 1 - EvidenceModel.barcodeCompleteShare - EvidenceModel.barcodeIncompleteShare - EvidenceModel.photoShare,
                "incompleteMissRate": EvidenceModel.incompleteMissRate,
                "photoMissRate": EvidenceModel.photoMissRate,
                "photoFalseRatePerAbsentFood": EvidenceModel.photoFalseRate,
                "level1": EvidenceModel.level1,
                "level2": EvidenceModel.level2,
                "level3": EvidenceModel.level3,
            ],
            generatorNotes: [
                "2-4 meals a day (20 % two, 55 % three, 25 % four), weekend meals 1 h later, meal time SD 0.6 h around slot centre",
                "15 foods; per-user taste factor exp(N(0, 0.3^2)) on every food's frequency",
                "staples: bread (gluten) at most meals, coffee most breakfasts, milk with 70 % of coffees and in all cheese",
                "co-eaten pair: onion with 85 % of garlic meals; weekly rhythm: alcohol on Friday and Saturday dinners, fish on Friday",
                "baseline symptoms 0.2-0.8 a day (uniform per user), split 40/35/25 % over 3 kinds, ±30 % time-of-day wave",
                "planted trigger: one food, one kind, rate x effect for every true exposure (logged or not) inside the lag window; overlapping windows multiply",
                "trigger food cycles over garlic (co-eaten), legume (occasional), milk (staple); trigger kind cycles over the 3 kinds",
                "4 days of meal history before tracking starts (B3); observed days = days with at least one logged meal",
            ],
            expectedExcessPerExposure: Dictionary(uniqueKeysWithValues:
                Array(Set(records.compactMap { $0.trigger?.multiplier })).sorted().flatMap { e in
                    LagKernel.allCases.map { k in
                        let width = k.hours.upperBound - k.hours.lowerBound
                        return ("×\(e == e.rounded() ? String(Int(e)) : String(e)) \(k.rawValue)", (e - 1) * width * 0.5 / 24 / 3)
                    }
                }),
            designCaveats: [
                "In the main grid (×1.5, ×2, ×4) trigger food and lag window share one index: garlic triggers are always fast, legume medium, milk slow. Food and window effects cannot be separated there. The ×10 extension rotates foods across windows.",
                "Effects are rate ratios on a low hourly baseline, so a short window adds few symptoms in absolute terms (see expected extra symptoms per exposure). Detection depends on that excess, not on the ratio alone.",
                "Only typical logging was run at 180 logged days, and only for ×2 and ×4 triggers and typical null users. The ×10 extension covers typical logging at 30 and 90 logged days.",
                "The threshold grid starts at 0.80, a stated floor: a posterior probability below 0.8 is not called a signal. If the false-positive targets are already met at the floor, the floor decides.",
                "15 foods and 3 symptom kinds per user; the app has more of both (unit 3's reference workload: 40 foods, 6 kinds). More foods mean more chances for a false hit per analysis.",
            ],
            sbcPlan: sbc
        )
    }
}

public struct ComputePhase: Codable, Sendable {
    public var log: String
    public var runs: Int
    public var wallSeconds: Double
}

public struct ComputeUsed: Codable, Sendable {
    public var machine: String
    public var logicalCores: Int
    public var build: String
    public var phases: [ComputePhase]
    public var totalWallSeconds: Double
    /// Compute not covered by the phase logs (pilots, pauses).
    public var notes: [String]
}

public struct SBCQuantity: Codable, Sendable {
    public var name: String
    public var histogram: [Int]
    public var chiSquare: Double
    public var pValue: Double
}

public struct SBCSummary: Codable, Sendable {
    public var replications: Int
    public var thinnedDraws: Int
    public var bins: Int
    public var redraws: Int
    public var replicationsWithDivergences: Int
    public var medianSymptoms: Double
    public var quantities: [SBCQuantity]
}

public struct ThresholdPoint: Codable, Sendable {
    public var threshold: Double
    public var falseEarly: Proportion
    public var falseClearWithEqualHalf: Proportion
}

public struct NullRate: Codable, Sendable {
    public var horizon: Int
    public var falseEarly: Proportion
    public var falseClear: Proportion
}

public struct CalibrationResult: Codable, Sendable {
    public var grid: [Double]
    public var falseEarlyTarget: Double
    public var falseClearTarget: Double
    public var earlyProb: Double
    public var clearProb: Double
    public var halfProb: Double
    public var nullUsers: Int
    public var nullAnalyses: Int
    public var falseEarlyPooled: Proportion
    public var falseClearPooled: Proportion
    /// Only analyses that passed the convergence gate (what a user would see).
    public var falseEarlyShown: Proportion
    public var falseClearShown: Proportion
    public var perHorizon: [NullRate]
    /// Null users flagged in at least one of their analysed horizons.
    public var falseEarlyEver: Proportion
    public var falseClearEver: Proportion
    /// Foods other than the trigger and its partner, in planted users.
    public var backgroundFalseEarly: Proportion
    public var backgroundFalseClear: Proportion
    public var curve: [ThresholdPoint]
    public var targetsMet: Bool
}

public struct ConvergenceRow: Codable, Sendable {
    public var diligence: LoggingDiligence
    public var horizon: Int
    public var converged: Proportion
    public var withDivergences: Proportion
    @FiniteOrNull public var medianMaxRhat: Double
    @FiniteOrNull public var medianSeconds: Double
    @FiniteOrNull public var medianSymptoms: Double
}

public struct RecoveryCounts: Codable, Sendable {
    public var users: Int
    /// Trigger at earlySignal or clearPattern, ignoring the convergence gate.
    public var early: Int
    public var clear: Int
    /// Same, counting only runs that passed the gate (shown in the app).
    public var earlyShown: Int
    public var clearShown: Int
    /// Trigger reported as "No link found" (B2 risk).
    public var noLinkFound: Int
}

public struct RecoveryRow: Codable, Sendable {
    public var diligence: LoggingDiligence?
    public var effect: Double
    public var kernel: LagKernel?
    public var food: String?
    public var horizon: Int
    public var counts: RecoveryCounts
}

public struct LagErrorRow: Codable, Sendable {
    public var kernel: LagKernel
    public var effect: Double
    public var horizon: Int
    public var trueMedianLag: Double
    /// Triggers found (early or clear) with an estimated median lag.
    public var found: Int
    public var medianError: Double?
    public var medianAbsoluteError: Double?
}

public struct PartnerRow: Codable, Sendable {
    public var horizon: Int
    public var partnerEarly: Proportion
    public var partnerClear: Proportion
    public var partnerEarlyWhenTriggerFound: Proportion
    public var flaggedAsConfounded: Proportion
}

public struct PeakRow: Codable, Sendable {
    public var kernel: LagKernel
    public var effect: Double
    public var horizon: Int
    public var users: Int
    public var earlyViaProbRaises: Int
    public var earlyViaPeak: Int
}

public struct PeakAlternative: Codable, Sendable {
    /// probPeakAbove threshold calibrated like earlyProb (null false-early ≤ 5 %).
    public var threshold: Double
    public var nullFalseEarly: Proportion
    public var rows: [PeakRow]
}

public struct HorizonShare: Codable, Sendable {
    public var horizon: Int
    public var share: Proportion
}

public struct Headline: Codable, Sendable {
    public var sentence: String
    public var earlyLoggedDays: Int?
    public var clearLoggedDays: Int?
    public var earlyShares: [HorizonShare]
    public var clearShares: [HorizonShare]
    public var expectationEarly: String
    public var expectationClear: String
}

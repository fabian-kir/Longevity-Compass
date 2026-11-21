import Foundation

// Public engine API (B10). Field names are a contract with the app (unit 5)
// and the simulation (unit 4): additions only, never renames.

/// One meal's exposure to one feature. `value` is the evidence weight
/// (B7: 1.0, 0.85 or 0.5), read by the model as exposure intensity.
public struct ExposureEvent: Codable, Sendable, Equatable, Hashable {
    public var featureID: String
    public var time: Date
    public var value: Double

    public init(featureID: String, time: Date, value: Double) {
        self.featureID = featureID
        self.time = time
        self.value = value
    }
}

public struct SymptomEvent: Codable, Sendable, Equatable, Hashable {
    public var kind: String
    public var onset: Date
    public var levelRank: Int
    public var isTopLevel: Bool

    public init(kind: String, onset: Date, levelRank: Int, isTopLevel: Bool) {
        self.kind = kind
        self.onset = onset
        self.levelRank = levelRank
        self.isTopLevel = isTopLevel
    }
}

/// Half-open interval [start, end) during which absence of symptom entries
/// means "no symptom" (B3 observation rule).
public struct ObservationWindow: Codable, Sendable, Equatable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Decision thresholds for pattern levels (B9).
public struct Thresholds: Codable, Sendable, Equatable {
    public var earlyProb: Double
    public var clearProb: Double
    public var halfProb: Double
    public var noLinkMinExposures: Int
    public var noLinkLower: Double
    public var noLinkUpper: Double

    public init(
        earlyProb: Double = 0.80,
        clearProb: Double = 0.80,
        halfProb: Double = 0.80,
        noLinkMinExposures: Int = 15,
        noLinkLower: Double = 0.8,
        noLinkUpper: Double = 1.25
    ) {
        self.earlyProb = earlyProb
        self.clearProb = clearProb
        self.halfProb = halfProb
        self.noLinkMinExposures = noLinkMinExposures
        self.noLinkLower = noLinkLower
        self.noLinkUpper = noLinkUpper
    }

    /// Calibrated by simulation (unit 4): see
    /// Packages/DigestionInsights/Simulation/results.md (§ Calibrated
    /// thresholds) and results.json. earlyProb is the smallest value on the
    /// grid 0.80…0.999 with at most 5 % of null analyses showing a false
    /// early signal; halfProb = earlyProb; clearProb the smallest value
    /// ≥ earlyProb with at most 1 % false clear patterns. Both targets were
    /// already met at the grid floor 0.80, so the floor decides all three.
    /// `digestion-sim report` fails if these differ from results.json.
    public static let `default` = Thresholds()
}

/// Prior hyperparameters of the distributed-lag model (see `LagModel`).
/// Defaults differ from the B9 draft where the draft failed in testing:
/// `lagRidge` 1 (draft 1e-3), `lagDecayHours` 24 (draft: none),
/// `localDistribution` half-Cauchy (draft half-normal), `kindDeviationScaling`
/// `.local` with `kindDeviationScale` 1 (draft `.absolute`, 0.3), and (unit 4)
/// `slabScale` 1 (draft: none). Setting those five back restores the draft,
/// for simulation-based comparison.
public struct ModelPriors: Codable, Sendable, Equatable {
    /// κ in C = chol((ωP + κI)⁻¹), P = second-difference penalty on the lag
    /// spline coefficients. κ = 1 gives flat lag curves prior SD τ_f.
    public var lagRidge: Double
    /// ω in C = chol((ωP + κI)⁻¹): weight of the smoothness penalty.
    public var lagSmoothing: Double
    /// Ridge grows with lag: κ_k = κ (1 + (lag centre_k / lagDecayHours)²).
    /// 0 switches the decay off (B9 draft: constant ridge).
    public var lagDecayHours: Double
    /// τ_g ~ HalfNormal(globalScale)
    public var globalScale: Double
    /// λ_f ~ localDistribution(localScale)
    public var localScale: Double
    public var localDistribution: ScaleDistribution
    /// σ_d ~ HalfNormal(kindDeviationScale)
    public var kindDeviationScale: Double
    /// How kind deviations d_fs scale (see `KindDeviationScaling`).
    public var kindDeviationScaling: KindDeviationScaling
    /// α_s ~ N(log observed base rate, interceptSD)
    public var interceptSD: Double
    /// Fourier time-of-day coefficients ~ N(0, timeOfDaySD)
    public var timeOfDaySD: Double
    /// Drift spline: δ = σ_drift · C_drift · u, σ_drift ~ HalfNormal(driftScale)
    public var driftScale: Double
    /// Slab c of a regularised horseshoe with fixed slab (Piironen & Vehtari
    /// 2017): every effect scale s = τ_g λ_f (and the kind-deviation scale)
    /// becomes c s / √(c² + s²), so it can never exceed c. 0 switches the slab
    /// off (unit 3 behaviour). Default 1: lag-curve coefficients on the
    /// log rate-ratio scale stay within about ±2 (×0.14 … ×7.4) a priori.
    /// Added by unit 4: without it, heavy half-Cauchy
    /// tails let lag curves become steep where few symptoms constrain them,
    /// and NUTS diverged in nearly every simulated run (results.md).
    public var slabScale: Double

    public init(
        lagRidge: Double = 1.0,
        lagSmoothing: Double = 1.0,
        lagDecayHours: Double = 24,
        globalScale: Double = 0.5,
        localScale: Double = 1.0,
        localDistribution: ScaleDistribution = .halfCauchy,
        kindDeviationScale: Double = 1.0,
        kindDeviationScaling: KindDeviationScaling = .local,
        interceptSD: Double = 2.0,
        timeOfDaySD: Double = 1.0,
        driftScale: Double = 0.3,
        slabScale: Double = 1
    ) {
        self.lagRidge = lagRidge
        self.lagSmoothing = lagSmoothing
        self.lagDecayHours = lagDecayHours
        self.globalScale = globalScale
        self.localScale = localScale
        self.localDistribution = localDistribution
        self.kindDeviationScale = kindDeviationScale
        self.kindDeviationScaling = kindDeviationScaling
        self.interceptSD = interceptSD
        self.timeOfDaySD = timeOfDaySD
        self.driftScale = driftScale
        self.slabScale = slabScale
    }

    public static let `default` = ModelPriors()

    /// Effect scale after the slab and ρ = ∂ log(result) / ∂ log(raw).
    @inline(__always)
    public func slab(_ raw: Double) -> (scale: Double, rho: Double) {
        guard slabScale > 0 else { return (raw, 1) }
        let c2 = slabScale * slabScale
        let denominator = c2 + raw * raw
        return (slabScale * raw / denominator.squareRoot(), c2 / denominator)
    }
}

/// Distribution of a positive scale parameter.
public enum ScaleDistribution: String, Codable, Sendable {
    case halfNormal, halfCauchy
}

/// Scale of the per-kind deviations d_fs = scale · C z_fs.
public enum KindDeviationScaling: String, Codable, Sendable {
    /// σ_d (B9 draft): one absolute scale for every feature.
    case absolute
    /// σ_d λ_f: deviations share the feature's local scale; σ_d is a second
    /// global scale next to τ_g.
    case local
    /// σ_d τ_g λ_f: deviations relative to the feature's whole scale.
    case feature
}

public struct AnalysisConfig: Codable, Sendable, Equatable {
    public var maxLagHours: Int
    public var interiorKnots: [Double]
    public var minExposures: Int
    public var chains: Int
    public var warmup: Int
    public var samples: Int
    public var targetAcceptance: Double
    public var seed: UInt64
    public var thresholds: Thresholds
    // Additions to B10 (unit 3):
    public var maxTreeDepth: Int
    /// `notEnoughData` below this many symptoms within maxLagHours after exposures (B9: 3).
    public var minSymptomsAfter: Int
    /// `confoundedWith` lists features whose hourly exposure series correlate at least this much (B9: 0.9).
    public var confoundingCorrelation: Double
    /// About one drift knot per this many days (B9: 30).
    public var driftKnotSpacingDays: Double
    /// Run first-half and second-half fits (B9: yes). Simulation may switch off.
    public var fitHalves: Bool
    /// Thinned draws used for `expectedPairsNull` in chart data.
    public var chartDraws: Int
    public var priors: ModelPriors

    public init(
        maxLagHours: Int = 96,
        interiorKnots: [Double] = [3, 8, 24, 48],
        minExposures: Int = 5,
        chains: Int = 4,
        warmup: Int = 1000,
        samples: Int = 1000,
        targetAcceptance: Double = 0.8,
        seed: UInt64,
        thresholds: Thresholds = .default,
        maxTreeDepth: Int = 10,
        minSymptomsAfter: Int = 3,
        confoundingCorrelation: Double = 0.9,
        driftKnotSpacingDays: Double = 30,
        fitHalves: Bool = true,
        chartDraws: Int = 200,
        priors: ModelPriors = .default
    ) {
        self.maxLagHours = maxLagHours
        self.interiorKnots = interiorKnots
        self.minExposures = minExposures
        self.chains = chains
        self.warmup = warmup
        self.samples = samples
        self.targetAcceptance = targetAcceptance
        self.seed = seed
        self.thresholds = thresholds
        self.maxTreeDepth = maxTreeDepth
        self.minSymptomsAfter = minSymptomsAfter
        self.confoundingCorrelation = confoundingCorrelation
        self.driftKnotSpacingDays = driftKnotSpacingDays
        self.fitHalves = fitHalves
        self.chartDraws = chartDraws
        self.priors = priors
    }
}

public struct AnalysisInput: Codable, Sendable, Equatable {
    public var exposures: [ExposureEvent]
    public var symptoms: [SymptomEvent]
    public var windows: [ObservationWindow]
    /// Model kinds in this order (e.g. all `SymptomKind` raw values).
    public var symptomKinds: [String]
    public var config: AnalysisConfig

    public init(
        exposures: [ExposureEvent],
        symptoms: [SymptomEvent],
        windows: [ObservationWindow],
        symptomKinds: [String],
        config: AnalysisConfig
    ) {
        self.exposures = exposures
        self.symptoms = symptoms
        self.windows = windows
        self.symptomKinds = symptomKinds
        self.config = config
    }
}

public enum AnalysisStatus: String, Codable, Sendable {
    case ok, notConverged, insufficientData, cancelled
}

/// Diagnostics of one model fit (addition to B10).
public struct FitDiagnostics: Codable, Sendable, Equatable {
    /// "full", "firstHalf" or "secondHalf".
    public var name: String
    public var observedHours: Int
    public var symptoms: Int
    public var parameters: Int
    @FiniteOrNull public var maxRhat: Double
    @FiniteOrNull public var minBulkESS: Double
    @FiniteOrNull public var minTailESS: Double
    public var divergences: Int
    public var treeDepthHits: Int
    public var stepSizes: [Double]
    public var leapfrogSteps: Int
    public var durationSeconds: Double
    public var converged: Bool

    public init(
        name: String, observedHours: Int, symptoms: Int, parameters: Int,
        maxRhat: Double, minBulkESS: Double, minTailESS: Double,
        divergences: Int, treeDepthHits: Int, stepSizes: [Double],
        leapfrogSteps: Int, durationSeconds: Double, converged: Bool
    ) {
        self.name = name
        self.observedHours = observedHours
        self.symptoms = symptoms
        self.parameters = parameters
        self.maxRhat = maxRhat
        self.minBulkESS = minBulkESS
        self.minTailESS = minTailESS
        self.divergences = divergences
        self.treeDepthHits = treeDepthHits
        self.stepSizes = stepSizes
        self.leapfrogSteps = leapfrogSteps
        self.durationSeconds = durationSeconds
        self.converged = converged
    }
}

public struct RunDiagnostics: Codable, Sendable, Equatable {
    /// Maximum over fits; NaN (JSON null) when not computed.
    @FiniteOrNull public var maxRhat: Double
    @FiniteOrNull public var minBulkESS: Double
    public var divergences: Int
    public var durationSeconds: Double
    public var fits: Int
    /// Addition to B10: one entry per fit, in order full, firstHalf, secondHalf.
    public var fitDiagnostics: [FitDiagnostics]

    public init(
        maxRhat: Double, minBulkESS: Double, divergences: Int,
        durationSeconds: Double, fits: Int, fitDiagnostics: [FitDiagnostics] = []
    ) {
        self.maxRhat = maxRhat
        self.minBulkESS = minBulkESS
        self.divergences = divergences
        self.durationSeconds = durationSeconds
        self.fits = fits
        self.fitDiagnostics = fitDiagnostics
    }
}

public enum PatternLevel: String, Codable, Sendable, CaseIterable {
    case notEnoughData, inconclusive, earlySignal, clearPattern, noLinkFound
}

/// Posterior median with 90 % equal-tailed interval (5 %, 95 % quantiles).
public struct Interval: Codable, Sendable, Equatable {
    public var median: Double
    public var lower: Double
    public var upper: Double

    public init(median: Double, lower: Double, upper: Double) {
        self.median = median
        self.lower = lower
        self.upper = upper
    }
}

public struct EffectSummary: Codable, Sendable, Equatable {
    /// max over lag of exp(β(l)).
    public var peakRR: Interval
    /// exp(mean over lag hours of β(l)).
    public var averageRR: Interval
    /// Extra symptom onsets per exposure: Σ_l μ̄₀ (exp(β(l)) − 1).
    public var excessPerExposure: Interval
    /// Lag (hours) where cumulative positive excess reaches half its total;
    /// nil when no draw has positive excess.
    public var medianLagHours: Interval?
    /// P(Σ_l β(l) > 0).
    public var probRaises: Double
    /// Addition to B10: P(max_l RR(l) > thresholds.noLinkUpper). Lag-free
    /// alternative to `probRaises` for acute effects of frequently eaten
    /// foods (unit 3 note); not used by the level rules.
    public var probPeakAbove: Double

    public init(
        peakRR: Interval, averageRR: Interval, excessPerExposure: Interval,
        medianLagHours: Interval?, probRaises: Double, probPeakAbove: Double
    ) {
        self.peakRR = peakRR
        self.averageRR = averageRR
        self.excessPerExposure = excessPerExposure
        self.medianLagHours = medianLagHours
        self.probRaises = probRaises
        self.probPeakAbove = probPeakAbove
    }
}

/// Chart data for lag hour [hour, hour + 1).
public struct LagPoint: Codable, Sendable, Equatable {
    public var hour: Int
    /// exp(β) at the hour midpoint: median and 90 % interval.
    public var rr: Interval
    /// Exposure–symptom pairs (any kind) with onset − exposure in this hour.
    public var observedPairs: Int
    /// Posterior median of expected pairs with this feature's effect set to zero.
    public var expectedPairsNull: Double

    public init(hour: Int, rr: Interval, observedPairs: Int, expectedPairsNull: Double) {
        self.hour = hour
        self.rr = rr
        self.observedPairs = observedPairs
        self.expectedPairsNull = expectedPairsNull
    }
}

public struct FeatureResult: Codable, Sendable, Equatable {
    public var featureID: String
    /// Exposures inside observation windows (history exposures excluded).
    public var exposureCount: Int
    /// Observed symptom onsets within maxLagHours after at least one exposure.
    public var symptomsAfterCount: Int
    public var level: PatternLevel
    public var overall: EffectSummary?
    public var perKind: [String: EffectSummary]
    public var mainKind: String?
    public var firstHalfProbRaises: Double?
    public var secondHalfProbRaises: Double?
    /// Empty for features not in the model (fewer than minExposures).
    public var lagCurve: [LagPoint]
    public var confoundedWith: [String]

    public init(
        featureID: String, exposureCount: Int, symptomsAfterCount: Int, level: PatternLevel,
        overall: EffectSummary?, perKind: [String: EffectSummary], mainKind: String?,
        firstHalfProbRaises: Double?, secondHalfProbRaises: Double?,
        lagCurve: [LagPoint], confoundedWith: [String]
    ) {
        self.featureID = featureID
        self.exposureCount = exposureCount
        self.symptomsAfterCount = symptomsAfterCount
        self.level = level
        self.overall = overall
        self.perKind = perKind
        self.mainKind = mainKind
        self.firstHalfProbRaises = firstHalfProbRaises
        self.secondHalfProbRaises = secondHalfProbRaises
        self.lagCurve = lagCurve
        self.confoundedWith = confoundedWith
    }
}

public struct AnalysisResult: Codable, Sendable, Equatable {
    public var status: AnalysisStatus
    public var diagnostics: RunDiagnostics
    /// Sorted by featureID. Present for every status; when status is
    /// `notConverged` the summaries exist but must not be shown (B9).
    public var features: [FeatureResult]
    /// `DigestionAnalysis.fingerprint(input)`.
    public var inputFingerprint: UInt64

    public init(status: AnalysisStatus, diagnostics: RunDiagnostics, features: [FeatureResult], inputFingerprint: UInt64) {
        self.status = status
        self.diagnostics = diagnostics
        self.features = features
        self.inputFingerprint = inputFingerprint
    }
}

/// Encodes non-finite doubles as JSON null and decodes null as NaN, so
/// diagnostics such as an undefined R̂ never make `JSONEncoder` throw.
@propertyWrapper
public struct FiniteOrNull: Codable, Sendable, Equatable {
    public var wrappedValue: Double

    public init(wrappedValue: Double) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? .nan : try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if wrappedValue.isFinite {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }

    public static func == (lhs: FiniteOrNull, rhs: FiniteOrNull) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue || (lhs.wrappedValue.isNaN && rhs.wrappedValue.isNaN)
    }
}

import DigestionInsightsEngine
import Foundation

/// Planted-trigger and null users analysed at several logged-day horizons.
/// One engine run per (user, horizon), production defaults unless the plan
/// overrides sampler settings. Raw records go to a JSON-lines file, one line
/// per run, so long runs can resume.
public struct RecoveryPlan: Codable, Sendable, Equatable {
    public var horizons: [Int] = [14, 30, 60, 90, 180]
    public var diligences: [LoggingDiligence] = LoggingDiligence.allCases
    public var effects: [Double] = [1.5, 2, 4]
    public var kernels: [LagKernel] = LagKernel.allCases
    /// Planted users per diligence × effect × kernel cell.
    public var usersPerCell: Int = 4
    public var nullUsers: Int = 60
    public var baseSeed: UInt64 = 20_261_120
    public var warmup: Int = 1000
    public var samples: Int = 1000
    /// B11 attempt 1.
    public var targetAcceptance: Double = 0.8
    /// Engine runs in flight (each uses 4 chains).
    public var concurrency: Int = 3

    public init() {}

    /// Calendar days generated per user, fixed so that a user's data never
    /// depend on the horizons of a run: 180 logged days fit even for sloppy
    /// loggers (12 % missed days).
    public var calendarDays: Int { 240 }

    /// Users in a stable order: replicate-major, so a partial run covers
    /// every cell evenly. Seeds, trigger foods and kinds depend only on the
    /// cell and replicate (not on which cells a run selects), so a later run
    /// with `--diligences typical --horizons 180` extends the same users.
    public func users() -> [UserSpec] {
        var specs: [UserSpec] = []
        let allCells = LoggingDiligence.allCases.flatMap { d in
            [1.5, 2.0, 4.0].flatMap { e in LagKernel.allCases.map { (d, e, $0) } }
        }
        let nullsPerRound = usersPerCell > 0 ? Int((Double(nullUsers) / Double(usersPerCell)).rounded(.up)) : nullUsers
        var nullIndex = 0
        for replicate in 0..<max(usersPerCell, 1) {
            if usersPerCell > 0 {
                for (c, cell) in allCells.enumerated()
                where diligences.contains(cell.0) && effects.contains(cell.1) && kernels.contains(cell.2) {
                    let n = replicate * allCells.count + c
                    let trigger = PlantedTrigger(
                        featureID: FoodWorld.triggerFoods[n % FoodWorld.triggerFoods.count],
                        kind: FoodWorld.kinds[(n / FoodWorld.triggerFoods.count) % FoodWorld.kinds.count],
                        kernel: cell.2,
                        multiplier: cell.1
                    )
                    specs.append(UserSpec(seed: userSeed(UInt64(n)), diligence: cell.0, trigger: trigger, calendarDays: calendarDays))
                }
            }
            // Strong-effect extension (×10, added after the main grid): the
            // trigger food rotates independently of the lag window. In the
            // main grid food and window share one index, so garlic is always
            // fast, legume medium and milk slow (results.md says so).
            if effects.contains(10) {
                for (c, cell) in LoggingDiligence.allCases.flatMap({ d in LagKernel.allCases.map { (d, $0) } }).enumerated()
                where diligences.contains(cell.0) && kernels.contains(cell.1) {
                    let n = replicate * 9 + c
                    let trigger = PlantedTrigger(
                        featureID: FoodWorld.triggerFoods[(replicate + c) % FoodWorld.triggerFoods.count],
                        kind: FoodWorld.kinds[n % FoodWorld.kinds.count],
                        kernel: cell.1,
                        multiplier: 10
                    )
                    specs.append(UserSpec(seed: userSeed(2_000_000 + UInt64(n)), diligence: cell.0, trigger: trigger, calendarDays: calendarDays))
                }
            }
            // Null users cycle through all diligences; a filter keeps the matching ones.
            for _ in 0..<nullsPerRound where nullIndex < nullUsers {
                let diligence = LoggingDiligence.allCases[nullIndex % LoggingDiligence.allCases.count]
                if diligences.contains(diligence) {
                    specs.append(UserSpec(seed: userSeed(1_000_000 + UInt64(nullIndex)), diligence: diligence, trigger: nil, calendarDays: calendarDays))
                }
                nullIndex += 1
            }
        }
        return specs
    }

    func userSeed(_ index: UInt64) -> UInt64 {
        var mixer = SplitMix64(seed: baseSeed ^ (index &* 0x9E37_79B9_7F4A_7C15))
        return mixer.next()
    }
}

public struct FeatureRecord: Codable, Sendable, Equatable {
    public var featureID: String
    public var exposureCount: Int
    public var symptomsAfterCount: Int
    public var overall: EffectSummary?
    public var firstHalfProbRaises: Double?
    public var secondHalfProbRaises: Double?
    public var mainKind: String?
    public var confoundedWith: [String]
}

public struct RunRecord: Codable, Sendable, Equatable {
    public var userSeed: UInt64
    public var diligence: LoggingDiligence
    public var trigger: PlantedTrigger?
    public var horizon: Int
    public var symptoms: Int
    public var status: AnalysisStatus
    @FiniteOrNull public var maxRhat: Double
    @FiniteOrNull public var minBulkESS: Double
    public var divergences: Int
    public var fitDivergences: [Int]
    public var fitConverged: [Bool]
    public var parameters: Int
    public var durationSeconds: Double
    public var features: [FeatureRecord]

    public var key: String { "\(userSeed)-\(horizon)" }
    public var isNull: Bool { trigger == nil }

    /// Classify every feature with `thresholds` (B9 rules via the engine).
    public func levels(_ thresholds: Thresholds) -> [String: PatternLevel] {
        var config = AnalysisConfig(seed: 0)
        config.thresholds = thresholds
        var result: [String: PatternLevel] = [:]
        for feature in features {
            result[feature.featureID] = PatternLevel.classify(
                exposureCount: feature.exposureCount,
                symptomsAfterCount: feature.symptomsAfterCount,
                overall: feature.overall,
                firstHalfProbRaises: feature.firstHalfProbRaises,
                secondHalfProbRaises: feature.secondHalfProbRaises,
                config: config
            )
        }
        return result
    }
}

public enum RecoveryStudy {
    /// Runs every (user, horizon) of `plan` not yet in `output`, appending
    /// records. `log` receives one line per finished run.
    public static func run(plan: RecoveryPlan, output: URL, limit: Int? = nil, log: @escaping @Sendable (String) -> Void) async throws {
        let done = Set((try? readRecords(output))?.map(\.key) ?? [])
        var jobs: [(UserSpec, Int)] = []
        for spec in plan.users() {
            for horizon in plan.horizons where !done.contains("\(spec.seed)-\(horizon)") {
                jobs.append((spec, horizon))
            }
        }
        if let limit { jobs = Array(jobs.prefix(limit)) }
        log("recovery: \(jobs.count) runs to do, \(done.count) already in \(output.path)")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let started = Date()
        var finished = 0
        try await withThrowingTaskGroup(of: RunRecord?.self) { group in
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let (spec, horizon) = jobs[next]
                next += 1
                group.addTask { try await runOne(spec: spec, horizon: horizon, plan: plan) }
            }
            for _ in 0..<max(plan.concurrency, 1) { addNext() }
            while let record = try await group.next() {
                if let record {
                    var line = try encoder.encode(record)
                    line.append(0x0A)
                    try handle.write(contentsOf: line)
                    finished += 1
                    let elapsed = Date().timeIntervalSince(started)
                    log(String(format: "[%d/%d %.0fs] %@ %@ h=%d status=%@ div=%@ rhat=%.3f ess=%.0f %.1fs",
                               finished, jobs.count, elapsed,
                               record.diligence.rawValue,
                               record.trigger.map { "\($0.featureID) x\($0.multiplier) \($0.kernel.rawValue)" } ?? "null",
                               record.horizon, record.status.rawValue,
                               record.fitDivergences.map(String.init).joined(separator: "/"),
                               record.maxRhat, record.minBulkESS, record.durationSeconds))
                }
                addNext()
            }
        }
    }

    public static func runOne(spec: UserSpec, horizon: Int, plan: RecoveryPlan) async throws -> RunRecord? {
        let user = SyntheticUser(spec: spec)
        let config = AnalysisConfig(
            warmup: plan.warmup,
            samples: plan.samples,
            targetAcceptance: plan.targetAcceptance,
            seed: spec.seed ^ UInt64(horizon),
            chartDraws: 10
        )
        guard let input = user.input(loggedDayCount: horizon, config: config) else { return nil }
        let result = try await DigestionAnalysis.run(input)
        return RunRecord(
            userSeed: spec.seed,
            diligence: spec.diligence,
            trigger: spec.trigger,
            horizon: horizon,
            symptoms: input.symptoms.count,
            status: result.status,
            maxRhat: result.diagnostics.maxRhat,
            minBulkESS: result.diagnostics.minBulkESS,
            divergences: result.diagnostics.divergences,
            fitDivergences: result.diagnostics.fitDiagnostics.map(\.divergences),
            fitConverged: result.diagnostics.fitDiagnostics.map(\.converged),
            parameters: result.diagnostics.fitDiagnostics.first?.parameters ?? 0,
            durationSeconds: result.diagnostics.durationSeconds,
            features: result.features.map {
                FeatureRecord(
                    featureID: $0.featureID, exposureCount: $0.exposureCount,
                    symptomsAfterCount: $0.symptomsAfterCount, overall: $0.overall,
                    firstHalfProbRaises: $0.firstHalfProbRaises, secondHalfProbRaises: $0.secondHalfProbRaises,
                    mainKind: $0.mainKind, confoundedWith: $0.confoundedWith
                )
            }
        )
    }

    public static func readRecords(_ url: URL) throws -> [RunRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(RunRecord.self, from: Data($0.utf8)) }
    }
}

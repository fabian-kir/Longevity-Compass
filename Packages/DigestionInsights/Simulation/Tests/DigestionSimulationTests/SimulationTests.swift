import DigestionInsightsEngine
import XCTest
@testable import DigestionSimulation

final class GeneratorTests: XCTestCase {
    private func spec(seed: UInt64 = 5, diligence: LoggingDiligence = .typical, trigger: PlantedTrigger? = nil, days: Int = 60) -> UserSpec {
        UserSpec(seed: seed, diligence: diligence, trigger: trigger, calendarDays: days)
    }

    func testSameSpecGivesIdenticalInput() {
        let config = AnalysisConfig(seed: 1)
        let a = SyntheticUser(spec: spec()).input(loggedDayCount: 30, config: config)
        let b = SyntheticUser(spec: spec()).input(loggedDayCount: 30, config: config)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        let other = SyntheticUser(spec: spec(seed: 6)).input(loggedDayCount: 30, config: config)
        XCTAssertNotEqual(a, other)
    }

    func testInputCoversExactlyTheLoggedDays() throws {
        let user = SyntheticUser(spec: spec(diligence: .sloppy))
        let input = try XCTUnwrap(user.input(loggedDayCount: 20, config: AnalysisConfig(seed: 1)))
        let hours = input.windows.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 3600 }
        XCTAssertEqual(hours, 20 * 24, accuracy: 1e-9)
        let end = try XCTUnwrap(input.windows.last?.end)
        XCTAssertTrue(input.exposures.allSatisfy { $0.time < end })
        XCTAssertTrue(input.symptoms.allSatisfy { $0.onset < end })
        // History before day 0 is included as exposures only (B3).
        XCTAssertTrue(input.exposures.contains { $0.time < simulationDay0 })
        XCTAssertTrue(input.exposures.allSatisfy { [0.5, 0.85, 1.0].contains($0.value) })
        XCTAssertNil(user.input(loggedDayCount: user.loggedDays.count + 1, config: AnalysisConfig(seed: 1)))
    }

    func testSloppyLoggersMissMoreThanCarefulOnes() {
        let careful = SyntheticUser(spec: spec(diligence: .careful, days: 120))
        let sloppy = SyntheticUser(spec: spec(diligence: .sloppy, days: 120))
        func loggedShare(_ user: SyntheticUser) -> Double {
            Double(user.symptoms.filter(\.logged).count) / Double(max(user.symptoms.count, 1))
        }
        XCTAssertGreaterThan(careful.loggedDays.count, sloppy.loggedDays.count)
        XCTAssertGreaterThan(loggedShare(careful), loggedShare(sloppy))
        XCTAssertGreaterThan(careful.meals.filter(\.logged).count, sloppy.meals.filter(\.logged).count)
    }

    func testCoEatenPartnerFollowsGarlic() {
        let user = SyntheticUser(spec: spec(days: 120))
        let garlic = user.meals.filter { $0.foods.contains(FoodWorld.garlic) }
        let withOnion = garlic.filter { $0.foods.contains(FoodWorld.onion) }
        XCTAssertGreaterThan(garlic.count, 30)
        XCTAssertGreaterThan(Double(withOnion.count) / Double(garlic.count), 0.75)
    }

    /// The planted trigger raises the true symptom rate inside its lag window.
    func testPlantedEffectIsPresentInGeneratedData() {
        let trigger = PlantedTrigger(featureID: FoodWorld.garlic, kind: "diarrhoea", kernel: .medium, multiplier: 4)
        let user = SyntheticUser(spec: spec(seed: 9, diligence: .careful, trigger: trigger, days: 200))
        let exposures = user.meals.filter { $0.foods.contains(trigger.featureID) }.map(\.trueTime)
        let onsets = user.symptoms.filter { $0.kind == trigger.kind }.map(\.trueTime)
        let totalHours = Double(user.spec.calendarDays * 24)
        // Hours covered by at least one window, and onsets inside them.
        var covered = Set<Int>()
        for t in exposures {
            for h in Int(t + trigger.kernel.hours.lowerBound)..<Int(t + trigger.kernel.hours.upperBound) where h >= 0 { covered.insert(h) }
        }
        let inside = onsets.filter { covered.contains(Int($0)) }.count
        let rateInside = Double(inside) / Double(covered.count)
        let rateOutside = Double(onsets.count - inside) / (totalHours - Double(covered.count))
        XCTAssertGreaterThan(rateInside / rateOutside, 2.5)

        // A null user with the same seed has no such contrast.
        let null = SyntheticUser(spec: spec(seed: 9, diligence: .careful, trigger: nil, days: 200))
        let nullOnsets = null.symptoms.filter { $0.kind == trigger.kind }.map(\.trueTime)
        let nullInside = nullOnsets.filter { covered.contains(Int($0)) }.count
        let nullRatio = (Double(nullInside) / Double(covered.count)) / (Double(nullOnsets.count - nullInside) / (totalHours - Double(covered.count)))
        XCTAssertLessThan(nullRatio, 1.6)
    }

    func testPlanUsersAreStableUnderCellFilters() {
        var plan = RecoveryPlan()
        plan.usersPerCell = 2
        plan.nullUsers = 6
        let all = plan.users()
        XCTAssertEqual(all.filter { $0.trigger != nil }.count, 54)
        XCTAssertEqual(all.filter { $0.trigger == nil }.count, 6)
        XCTAssertEqual(Set(all.map(\.seed)).count, all.count)
        plan.diligences = [.typical]
        let typical = plan.users()
        XCTAssertEqual(typical.map(\.seed), all.filter { $0.diligence == .typical }.map(\.seed))
    }
}

final class CommandTests: XCTestCase {
    func testParsesRecoveryOptions() throws {
        let command = try SimulationCommand.parse(["recovery", "--users-per-cell", "2", "--nulls", "9", "--horizons", "14,90", "--diligences", "typical,sloppy", "--limit", "3"])
        guard case .recovery(let plan, let limit) = command else { return XCTFail("wrong command \(command)") }
        XCTAssertEqual(plan.usersPerCell, 2)
        XCTAssertEqual(plan.nullUsers, 9)
        XCTAssertEqual(plan.horizons, [14, 90])
        XCTAssertEqual(plan.diligences, [.typical, .sloppy])
        XCTAssertEqual(limit, 3)
    }

    func testParsesOtherCommands() throws {
        XCTAssertEqual(try SimulationCommand.parse(["report"]), .report(checkOnly: false))
        XCTAssertEqual(try SimulationCommand.parse(["report", "--check"]), .report(checkOnly: true))
        XCTAssertEqual(try SimulationCommand.parse(["calibrate"]), .calibrate)
        guard case .sbc(let plan) = try SimulationCommand.parse(["sbc", "--replications", "10"]) else { return XCTFail() }
        XCTAssertEqual(plan.replications, 10)
    }

    func testRejectsBadArguments() {
        XCTAssertThrowsError(try SimulationCommand.parse([]))
        XCTAssertThrowsError(try SimulationCommand.parse(["fly"]))
        XCTAssertThrowsError(try SimulationCommand.parse(["recovery", "--nulls"]))
        XCTAssertThrowsError(try SimulationCommand.parse(["recovery", "--nulls", "-1"]))
        XCTAssertThrowsError(try SimulationCommand.parse(["recovery", "--horizons", "14,x"]))
        XCTAssertThrowsError(try SimulationCommand.parse(["recovery", "--diligences", "lazy"]))
        XCTAssertThrowsError(try SimulationCommand.parse(["calibrate", "--warmup", "5"]))
    }
}

final class CalibrationTests: XCTestCase {
    func testWilsonIntervalAndChiSquareTail() {
        let p = Proportion(0, of: 100)
        XCTAssertEqual(p.lower, 0)
        XCTAssertEqual(p.upper, 0.037, accuracy: 0.001)
        let q = Proportion(10, of: 100)
        XCTAssertEqual(q.lower, 0.0552, accuracy: 0.0005)
        XCTAssertEqual(q.upper, 0.1744, accuracy: 0.0005)
        XCTAssertEqual(SpecialFunctions.chiSquareUpperTail(16.919, df: 9), 0.05, accuracy: 0.0005)
        XCTAssertEqual(SpecialFunctions.chiSquareUpperTail(2.0, df: 2), exp(-1), accuracy: 1e-9)
    }

    private func record(seed: UInt64, probRaises: Double, half: Double, trigger: PlantedTrigger? = nil) -> RunRecord {
        let interval = Interval(median: 1, lower: 0.5, upper: 2)
        let summary = EffectSummary(peakRR: interval, averageRR: interval, excessPerExposure: interval,
                                    medianLagHours: nil, probRaises: probRaises, probPeakAbove: 0)
        let feature = FeatureRecord(featureID: trigger?.featureID ?? "ingredient:en:rice", exposureCount: 30, symptomsAfterCount: 10,
                                    overall: summary, firstHalfProbRaises: half, secondHalfProbRaises: half,
                                    mainKind: nil, confoundedWith: [])
        return RunRecord(userSeed: seed, diligence: .typical, trigger: trigger, horizon: 30, symptoms: 20, status: .ok,
                         maxRhat: 1.001, minBulkESS: 900, divergences: 0, fitDivergences: [0, 0, 0],
                         fitConverged: [true, true, true], parameters: 100, durationSeconds: 1, features: [feature])
    }

    /// 100 null analyses with probRaises 0.00, 0.01, …, 0.99: the smallest
    /// grid value with at most 5 % at or above it is 0.95 (5 analyses: 0.95…0.99).
    func testThresholdSelectionFollowsTheRule() {
        let nulls = (0..<100).map { record(seed: UInt64($0), probRaises: Double($0) / 100, half: Double($0) / 100) }
        let trigger = PlantedTrigger(featureID: FoodWorld.garlic, kind: "bloating", kernel: .fast, multiplier: 2)
        let planted = [record(seed: 500, probRaises: 0.999, half: 0.999, trigger: trigger)]
        let results = Calibration.analyse(records: nulls + planted, sbc: nil,
                                          compute: ComputeUsed(machine: "test", logicalCores: 1, build: "", phases: [], totalWallSeconds: 0, notes: []))
        XCTAssertEqual(results.calibration.earlyProb, 0.95)
        XCTAssertEqual(results.calibration.halfProb, 0.95)
        // Clear: at most 1 % → only 0.99 itself may pass; grid value 0.99 leaves 1/100.
        XCTAssertEqual(results.calibration.clearProb, 0.99)
        XCTAssertEqual(results.calibration.falseEarlyPooled.successes, 5)
        XCTAssertEqual(results.calibration.falseClearPooled.successes, 1)
        XCTAssertEqual(results.recovery.first?.counts.clear, 1)
        // The report renders without the SBC section.
        XCTAssertTrue(Report.render(results).contains("earlyProb 0.950"))
    }
}

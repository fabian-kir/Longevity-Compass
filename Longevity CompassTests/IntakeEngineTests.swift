import XCTest
@testable import Longevity_Compass

final class IntakeEngineTests: XCTestCase {
    /// 2027-01-15 09:00 in Berlin, so "today" has room on both sides.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    // MARK: - Daily window

    func testDailyWindowCountsOnlyToday() {
        let entries = [
            entry(daysAgo: 0, kcal: 600, protein: 30, fiber: 8),
            entry(daysAgo: 0, kcal: 900, protein: 45, fiber: 12),
            entry(daysAgo: 1, kcal: 2_500, protein: 100, fiber: 20),
        ]

        let summary = summary(entries, targets: IntakeTargets(energyKcal: 2_000, fiberGrams: 30), window: IntakeWindow())

        XCTAssertEqual(summary.budgetDays, 1)
        XCTAssertEqual(summary.totals.energyKcal, 1_500, accuracy: 0.001)
        XCTAssertEqual(summary.totals.protein, 75, accuracy: 0.001)
        XCTAssertEqual(summary.progress(for: .energy), .remaining(500))
        XCTAssertEqual(summary.progress(for: .fiber), .remaining(10))
        XCTAssertNil(summary.progress(for: .protein), "No protein target was set")
        XCTAssertNil(summary.remainingPerDay(for: .energy), "Only today is left")
    }

    func testMealsWithoutCaloriesAreCountedSeparately() {
        let entries = [
            entry(daysAgo: 0, kcal: 500),
            entry(daysAgo: 0, kcal: nil),
        ]

        let summary = summary(entries, targets: IntakeTargets(), window: IntakeWindow())

        XCTAssertEqual(summary.mealCount, 2)
        XCTAssertEqual(summary.mealsWithoutEnergy, 1)
        XCTAssertEqual(summary.totals.energyKcal, 500, accuracy: 0.001)
    }

    // MARK: - Target kinds

    func testDeficitTargetIsALimit() {
        let entries = [entry(daysAgo: 0, kcal: 2_300)]
        let targets = IntakeTargets(energyKcal: 2_000, energyGoal: .deficit)

        let summary = summary(entries, targets: targets, window: IntakeWindow())

        XCTAssertEqual(summary.progress(for: .energy), .over(300))
    }

    func testSurplusTargetIsAMinimum() {
        let entries = [entry(daysAgo: 0, kcal: 3_100)]
        let targets = IntakeTargets(energyKcal: 3_000, energyGoal: .surplus)

        let summary = summary(entries, targets: targets, window: IntakeWindow())

        XCTAssertEqual(summary.progress(for: .energy), .reached)
    }

    func testZeroTargetMeansNoTarget() {
        let targets = IntakeTargets(energyKcal: 0, proteinGrams: 0)

        XCTAssertNil(targets.daily(.energy))
        XCTAssertNil(targets.daily(.protein))
    }

    // MARK: - Rolling window

    func testRollingWindowMultipliesBudgetAndKeepsTodaySeparate() {
        let entries = [
            entry(daysAgo: 3, kcal: 2_000),   // Outside a 3-day window; also marks tracking as older.
            entry(daysAgo: 2, kcal: 500),     // Fasting-style day.
            entry(daysAgo: 1, kcal: 2_600),
            entry(daysAgo: 0, kcal: 700),
        ]
        let window = IntakeWindow(mode: .rolling, length: 3)

        let summary = summary(entries, targets: IntakeTargets(energyKcal: 2_000), window: window)

        XCTAssertEqual(summary.budgetDays, 3)
        XCTAssertFalse(summary.startsAtFirstLog)
        XCTAssertEqual(summary.budget(for: .energy), 6_000)
        XCTAssertEqual(summary.totals.energyKcal, 3_800, accuracy: 0.001)
        XCTAssertEqual(summary.today.energyKcal, 700, accuracy: 0.001)
        XCTAssertEqual(summary.progress(for: .energy), .remaining(2_200))
        XCTAssertEqual(summary.days.map(\.energyKcal), [500, 2_600, 700])
        XCTAssertEqual(summary.days.last?.isToday, true)
    }

    func testEmptyDaysAfterFirstLogCountAsZero() {
        let entries = [
            entry(daysAgo: 2, kcal: 1_800),
            entry(daysAgo: 0, kcal: 400),
        ]
        let window = IntakeWindow(mode: .rolling, length: 3)

        let summary = summary(entries, targets: IntakeTargets(energyKcal: 2_000), window: window)

        XCTAssertEqual(summary.budgetDays, 3)
        XCTAssertEqual(summary.loggedDays, 2)
        XCTAssertEqual(summary.days[1].energyKcal, 0)
    }

    func testWindowStartsAtFirstLoggedMeal() {
        let entries = [
            entry(daysAgo: 1, kcal: 1_500),
            entry(daysAgo: 0, kcal: 500),
        ]
        let window = IntakeWindow(mode: .rolling, length: 5)

        let summary = summary(entries, targets: IntakeTargets(energyKcal: 2_000), window: window)

        XCTAssertEqual(summary.budgetDays, 2, "Days before the first log are not fasting days")
        XCTAssertTrue(summary.startsAtFirstLog)
        XCTAssertEqual(summary.budget(for: .energy), 4_000)
    }

    // MARK: - Fixed blocks

    func testFixedBlockIncludesUpcomingDaysAndSpreadsWhatIsLeft() {
        // Anchor 10 days ago with 3-day blocks: blocks start 10, 7, 4 and 1 days ago,
        // so the current block is yesterday, today and tomorrow.
        let anchor = day(-10)
        let entries = [
            entry(daysAgo: 12, kcal: 2_000),
            entry(daysAgo: 2, kcal: 2_000),   // Previous block.
            entry(daysAgo: 1, kcal: 400),
            entry(daysAgo: 0, kcal: 1_200),
        ]
        let window = IntakeWindow(mode: .fixed, length: 3, anchor: anchor)

        let summary = summary(entries, targets: IntakeTargets(energyKcal: 2_000), window: window)

        XCTAssertEqual(summary.days.map(\.date), [day(-1), day(0), day(1)])
        XCTAssertEqual(summary.days.map(\.isUpcoming), [false, false, true])
        XCTAssertEqual(summary.totals.energyKcal, 1_600, accuracy: 0.001)
        XCTAssertEqual(summary.daysLeft, 2)
        XCTAssertEqual(summary.progress(for: .energy), .remaining(4_400))
        XCTAssertEqual(try XCTUnwrap(summary.remainingPerDay(for: .energy)), 2_200, accuracy: 0.001)
    }

    func testFixedBlockAnchorInTheFutureStillAlignsBlocks() {
        // Anchor 2 days ahead with 3-day blocks: the block before it starts yesterday.
        let window = IntakeWindow(mode: .fixed, length: 3, anchor: day(2))

        let bounds = IntakeEngine.bounds(for: window, now: now, firstLog: nil, calendar: calendar)

        XCTAssertEqual(bounds.start, day(-1))
        XCTAssertEqual(bounds.end, day(2))
    }

    func testFixedBlockStartingTodayRunsForward() {
        let window = IntakeWindow(mode: .fixed, length: 7, anchor: now)

        let bounds = IntakeEngine.bounds(for: window, now: now, firstLog: nil, calendar: calendar)

        XCTAssertEqual(bounds.start, day(0))
        XCTAssertEqual(bounds.end, day(7))
    }

    // MARK: - Portion and fingerprint scaling

    func testFingerprintScalesFibreWithPortion() throws {
        let scaled = try XCTUnwrap(fingerprint(fiberPer100g: 4).scaledMacros(toGrams: 250))

        XCTAssertEqual(scaled.kcal, 375, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(scaled.fiber), 10, accuracy: 0.001)
    }

    func testRescalingPhotoEntryRecomputesFromPer100gEstimates() throws {
        let json = try JSONEncoder().encode(fingerprint(fiberPer100g: 4))
        let photo = NutritionEntry(
            source: .photo,
            rawInput: "",
            caloriesKcal: 300,
            portionGrams: 200,
            fingerprintJSON: String(data: json, encoding: .utf8)
        )

        photo.rescale(toPortionGrams: 400)

        XCTAssertEqual(photo.portionGrams, 400)
        XCTAssertEqual(try XCTUnwrap(photo.caloriesKcal), 600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(photo.fiberGrams), 16, accuracy: 0.001)
    }

    func testRescalingBarcodeEntryScalesByPortionRatio() throws {
        let barcode = NutritionEntry(
            source: .barcode,
            rawInput: "4000000000000",
            caloriesKcal: 200,
            portionGrams: 50,
            proteinGrams: 4,
            sodiumMilligrams: 100
        )

        barcode.rescale(toPortionGrams: 75)

        XCTAssertEqual(barcode.portionGrams, 75)
        XCTAssertEqual(try XCTUnwrap(barcode.caloriesKcal), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(barcode.proteinGrams), 6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(barcode.sodiumMilligrams), 150, accuracy: 0.001)
        XCTAssertNil(barcode.fiberGrams, "Unknown values stay unknown")
    }

    func testOlderFingerprintWithoutFibreStillDecodes() throws {
        let legacy = #"{"items":[],"plantIngredients":[],"estimatedKcalPer100g":120,"proteinPer100g":5,"carbsPer100g":15,"fatPer100g":4}"#
        let decoded = try JSONDecoder().decode(MealFingerprint.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.fiberPer100g)
        XCTAssertNil(try XCTUnwrap(decoded.scaledMacros(toGrams: 100)).fiber)
    }

    // MARK: - Helpers

    private func summary(
        _ entries: [NutritionEntry],
        targets: IntakeTargets,
        window: IntakeWindow
    ) -> IntakeSummary {
        IntakeEngine.summary(entries: entries, targets: targets, window: window, now: now, calendar: calendar)
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func entry(
        daysAgo: Int,
        kcal: Double?,
        protein: Double? = nil,
        fiber: Double? = nil
    ) -> NutritionEntry {
        NutritionEntry(
            date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
            source: .barcode,
            rawInput: "",
            caloriesKcal: kcal,
            proteinGrams: protein,
            fiberGrams: fiber
        )
    }

    private func fingerprint(fiberPer100g: Double?) -> MealFingerprint {
        MealFingerprint(
            items: [],
            plantIngredients: [],
            aiNotes: nil,
            confidence: "medium",
            title: "Test meal",
            estimatedKcalPer100g: 150,
            proteinPer100g: 8,
            carbsPer100g: 18,
            fatPer100g: 5,
            fiberPer100g: fiberPer100g,
            typicalServingGrams: 300
        )
    }
}

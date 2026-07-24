import XCTest
@testable import Longevity_Compass

final class NutritionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDigestCapturesDietBreadthAndApproximateEnergyByLoggedDay() throws {
        let first = entry(
            daysAgo: 0,
            categories: [.leafyGreens, .fruit, .wholeGrains],
            plants: ["spinach", "apple", "oats"],
            calories: 500
        )
        let second = entry(
            daysAgo: 1,
            categories: [.legumes, .otherVeg, .fried],
            plants: ["lentils", "tomato"],
            calories: 700
        )

        let digest = NutritionEngine.digest([first, second], now: now)

        XCTAssertEqual(digest.pattern.beneficialGroupsSeen, 5)
        XCTAssertEqual(digest.pattern.beneficialGroupTarget, 9)
        XCTAssertEqual(digest.pattern.mealsWithoutLimitFlags, 1)
        XCTAssertEqual(digest.pattern.assessedMeals, 2)
        XCTAssertEqual(digest.energyEstimateDays, 2)
        XCTAssertEqual(try XCTUnwrap(digest.estimatedCaloriesPerLoggedDay), 600, accuracy: 0.001)
    }

    func testLimitConcernTakesPriorityOverAdditionGap() {
        let entries = (0..<4).map { day in
            entry(
                daysAgo: day,
                categories: [.fried, .refinedCarbs],
                plants: [],
                calories: 650
            )
        }

        let digest = NutritionEngine.digest(entries, now: now)

        XCTAssertEqual(digest.priorityGuidance?.tone, .rebalance)
        XCTAssertEqual(digest.priorityGuidance?.bucket, .friedMeals)
        XCTAssertEqual(digest.priorityGuidance?.title, "Choose roasted, grilled or steamed next")
    }

    func testPackagedFoodNovaScoreFeedsProcessingPattern() {
        let entries = (0..<4).map { day in
            NutritionEntry(
                date: Calendar.current.date(byAdding: .day, value: -day, to: now) ?? now,
                source: .barcode,
                rawInput: "123456789",
                productName: "Packaged snack",
                caloriesKcal: 250,
                ultraProcessedScore: 1
            )
        }

        let digest = NutritionEngine.digest(entries, now: now)

        XCTAssertEqual(digest.rollup(for: .ultraProcessedMeals)?.weeklyValue, 4)
        XCTAssertEqual(digest.pattern.assessedMeals, 4)
        XCTAssertEqual(digest.pattern.mealsWithoutLimitFlags, 0)
        XCTAssertEqual(digest.priorityGuidance?.bucket, .ultraProcessedMeals)
    }

    func testLargestBeneficialGapBecomesNextMealAction() {
        let digest = NutritionDigest(
            rollups: [
                rollup(.plantVariety, status: .ok, value: 30, target: 30),
                rollup(.leafyGreenDays, status: .veryLow, value: 1, target: 5),
                rollup(.omega3Days, status: .low, value: 2, target: 3),
                rollup(.fermentedDays, status: .ok, value: 3, target: 3),
                rollup(.legumeDays, status: .ok, value: 4, target: 4),
                rollup(.ultraProcessedMeals, status: .ok, value: 0, target: 3),
                rollup(.processedMeatMeals, status: .ok, value: 0, target: 2),
                rollup(.friedMeals, status: .ok, value: 0, target: 2),
            ],
            coverageDays: 7,
            lookbackDays: 7,
            totalEntries: 12,
            costThisMonthUSD: 0,
            costAllTimeUSD: 0
        )

        XCTAssertEqual(digest.priorityGuidance?.tone, .add)
        XCTAssertEqual(digest.priorityGuidance?.bucket, .leafyGreenDays)
        XCTAssertEqual(digest.priorityGuidance?.title, "Put something dark green on the plate")
    }

    private func entry(
        daysAgo: Int,
        categories: [MealCategory],
        plants: [String],
        calories: Double
    ) -> NutritionEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let fingerprint = MealFingerprint(
            items: categories.map {
                MealFingerprint.Item(category: $0, plateFraction: 0.25)
            },
            plantIngredients: plants,
            aiNotes: nil,
            confidence: "high",
            title: "Test meal",
            estimatedKcalPer100g: nil,
            proteinPer100g: nil,
            carbsPer100g: nil,
            fatPer100g: nil,
            typicalServingGrams: nil
        )
        let json = try? JSONEncoder().encode(fingerprint)
        return NutritionEntry(
            date: date,
            source: .photo,
            rawInput: "",
            caloriesKcal: calories,
            fingerprintJSON: json.flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    private func rollup(
        _ bucket: NutrientBucket,
        status: BucketStatus,
        value: Double,
        target: Double
    ) -> NutritionBucketRollup {
        NutritionBucketRollup(
            bucket: bucket,
            status: status,
            weeklyValue: value,
            target: target,
            percentOfTarget: value / target,
            daysWithData: 7,
            lookbackDays: 7,
            summary: ""
        )
    }
}

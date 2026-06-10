import Foundation
import HealthKit

struct BloodPressureReading: Hashable, Identifiable {
    let id = UUID()
    let systolic: Double
    let diastolic: Double
    let date: Date
}

struct HealthKitSnapshot {
    var dailyStepsAverage7d: Double?
    var dailyStepsAverage28d: Double?
    var exerciseMinutesPerWeek: Double?
    var exerciseMinutesPriorWeek: Double?
    var workoutsLast7Days: Int?
    var workoutsLast28Days: Int?
    var strengthWorkoutsLast7Days: Int?
    var strengthWorkoutsLast28Days: Int?
    var restingHeartRateAverage28d: Double?
    var restingHeartRateAverage90d: Double?
    var hrvAverage28d: Double?
    var sleepHoursAverage7d: Double?
    var sleepHoursAverage28d: Double?
    var latestBodyMass: (value: Double, date: Date)?
    var bodyMassSeries: [(date: Date, value: Double)] = []
    var latestVO2Max: (value: Double, date: Date)?
    var bloodPressureReadings: [BloodPressureReading] = []
    var sampledAt: Date = .now
}

@Observable
final class HealthKitManager {

    enum HealthKitError: LocalizedError {
        case notAvailableOnDevice

        var errorDescription: String? {
            switch self {
            case .notAvailableOnDevice:
                return "HealthKit is not available on this device."
            }
        }
    }

    private let healthStore = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var authorizationRequested: Bool = false
    var lastSyncDate: Date?
    var lastError: String?

    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        let q: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .activeEnergyBurned,
            .appleExerciseTime,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .bodyMass,
            .waistCircumference,
            .vo2Max,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
        ]
        for id in q {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }
        set.insert(HKObjectType.workoutType())
        return set
    }

    private var writeTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = []
        if let sys = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) { set.insert(sys) }
        if let dia = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) { set.insert(dia) }
        return set
    }

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = HealthKitError.notAvailableOnDevice.localizedDescription
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            authorizationRequested = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Write

    func saveBloodPressure(systolic: Double, diastolic: Double, date: Date) async throws {
        guard
            let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
            let bpType  = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)
        else { return }

        let mmHg = HKUnit.millimeterOfMercury()
        let sysSample = HKQuantitySample(type: sysType, quantity: HKQuantity(unit: mmHg, doubleValue: systolic), start: date, end: date)
        let diaSample = HKQuantitySample(type: diaType, quantity: HKQuantity(unit: mmHg, doubleValue: diastolic), start: date, end: date)
        let correlation = HKCorrelation(type: bpType, start: date, end: date, objects: [sysSample, diaSample])
        try await healthStore.save(correlation)
    }

    // MARK: - Public read

    func refreshSnapshot() async -> HealthKitSnapshot {
        guard isAvailable else { return HealthKitSnapshot() }

        var snapshot = HealthKitSnapshot()
        snapshot.dailyStepsAverage7d         = try? await averageDailySum(.stepCount, days: 7, unit: .count())
        snapshot.dailyStepsAverage28d        = try? await averageDailySum(.stepCount, days: 28, unit: .count())
        snapshot.exerciseMinutesPerWeek      = try? await totalSum(.appleExerciseTime, days: 7, unit: .minute())
        snapshot.exerciseMinutesPriorWeek    = try? await totalSumBetween(.appleExerciseTime, startDaysAgo: 14, endDaysAgo: 7, unit: .minute())
        snapshot.workoutsLast7Days           = try? await workoutCount(days: 7)
        snapshot.workoutsLast28Days          = try? await workoutCount(days: 28)
        snapshot.strengthWorkoutsLast7Days   = try? await workoutCount(days: 7, activityTypes: HealthKitManager.strengthActivityTypes)
        snapshot.strengthWorkoutsLast28Days  = try? await workoutCount(days: 28, activityTypes: HealthKitManager.strengthActivityTypes)
        snapshot.restingHeartRateAverage28d  = try? await averageDiscrete(.restingHeartRate, days: 28, unit: HKUnit.count().unitDivided(by: .minute()))
        snapshot.restingHeartRateAverage90d  = try? await averageDiscrete(.restingHeartRate, days: 90, unit: HKUnit.count().unitDivided(by: .minute()))
        snapshot.hrvAverage28d               = try? await averageDiscrete(.heartRateVariabilitySDNN, days: 28, unit: .secondUnit(with: .milli))
        let (s7, s28) = await sleepAverages()
        snapshot.sleepHoursAverage7d         = s7
        snapshot.sleepHoursAverage28d        = s28
        snapshot.latestBodyMass              = try? await latestSample(.bodyMass, unit: .gramUnit(with: .kilo))
        snapshot.bodyMassSeries              = (try? await bodyMassSeries(days: 180)) ?? []
        snapshot.latestVO2Max                = try? await latestSample(.vo2Max, unit: HKUnit(from: "ml/(kg*min)"))
        snapshot.bloodPressureReadings       = (try? await bloodPressureSamples(days: 365)) ?? []
        snapshot.sampledAt                   = .now

        lastSyncDate = snapshot.sampledAt
        return snapshot
    }

    static let strengthActivityTypes: Set<HKWorkoutActivityType> = [
        .traditionalStrengthTraining,
        .functionalStrengthTraining,
        .coreTraining,
    ]

    // MARK: - Internal helpers

    private func dateRange(days: Int) -> (start: Date, end: Date) {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        return (start, end)
    }

    private func averageDailySum(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore),
              let sum = result.sumQuantity()?.doubleValue(for: unit) else { return nil }
        return sum / Double(days)
    }

    private func totalSum(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore) else { return nil }
        return result.sumQuantity()?.doubleValue(for: unit)
    }

    private func averageDiscrete(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .discreteAverage
        )
        guard let result = try await descriptor.result(for: healthStore),
              let avg = result.averageQuantity()?.doubleValue(for: unit) else { return nil }
        return avg
    }

    private func latestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> (Double, Date)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: type, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: healthStore)
        guard let s = samples.first else { return nil }
        return (s.quantity.doubleValue(for: unit), s.endDate)
    }

    private func workoutCount(days: Int, activityTypes: Set<HKWorkoutActivityType>? = nil) async throws -> Int {
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        let workouts = try await descriptor.result(for: healthStore)
        if let filter = activityTypes {
            return workouts.filter { filter.contains($0.workoutActivityType) }.count
        }
        return workouts.count
    }

    private func totalSumBetween(
        _ identifier: HKQuantityTypeIdentifier,
        startDaysAgo: Int,
        endDaysAgo: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let now = Date()
        guard
            let start = Calendar.current.date(byAdding: .day, value: -startDaysAgo, to: now),
            let end   = Calendar.current.date(byAdding: .day, value: -endDaysAgo, to: now)
        else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore) else { return nil }
        return result.sumQuantity()?.doubleValue(for: unit)
    }

    private func sleepAverages() async -> (Double?, Double?) {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return (nil, nil)
        }
        let (start28, end28) = dateRange(days: 28)
        let predicate = HKQuery.predicateForSamples(withStart: start28, end: end28, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        guard let samples = try? await descriptor.result(for: healthStore), !samples.isEmpty else {
            return (nil, nil)
        }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let cal = Calendar.current
        var perNight: [Date: TimeInterval] = [:]
        for s in samples where asleepValues.contains(s.value) {
            let bucket = cal.startOfDay(for: s.startDate)
            perNight[bucket, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        let cutoff7 = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let last7 = perNight.filter { $0.key >= cutoff7 }.values
        let last28 = perNight.values

        func hours(_ vals: some Collection<TimeInterval>) -> Double? {
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count) / 3600.0
        }
        return (hours(last7), hours(last28))
    }

    // MARK: - Historical series (for Trends view)

    func dailyStepsSeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        try await dailyBucketSeries(.stepCount, days: days, unit: .count(), options: .cumulativeSum)
    }

    func dailyExerciseMinutesSeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        try await dailyBucketSeries(.appleExerciseTime, days: days, unit: .minute(), options: .cumulativeSum)
    }

    func restingHeartRateSeries(days: Int = 60) async throws -> [(date: Date, value: Double)] {
        try await dailyBucketSeries(
            .restingHeartRate,
            days: days,
            unit: HKUnit.count().unitDivided(by: .minute()),
            options: .discreteAverage,
            sumOrAverage: .average
        )
    }

    func bodyMassSeries(days: Int = 180) async throws -> [(date: Date, value: Double)] {
        try await sampleSeries(.bodyMass, days: days, unit: .gramUnit(with: .kilo))
    }

    func vo2MaxSeries(days: Int = 365) async throws -> [(date: Date, value: Double)] {
        try await sampleSeries(.vo2Max, days: days, unit: HKUnit(from: "ml/(kg*min)"))
    }

    func sleepNightlySeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: healthStore)
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let cal = Calendar.current
        var perNight: [Date: TimeInterval] = [:]
        for s in samples where asleepValues.contains(s.value) {
            let bucket = cal.startOfDay(for: s.startDate)
            perNight[bucket, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        return perNight
            .map { (date: $0.key, value: $0.value / 3600.0) }
            .sorted { $0.date < $1.date }
    }

    func bloodPressureSeries(days: Int = 90) async throws -> [BloodPressureReading] {
        try await bloodPressureSamples(days: days)
    }

    // MARK: - Series helpers

    private enum DailyAggregation { case sum, average }

    private func dailyBucketSeries(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit,
        options: HKStatisticsOptions,
        sumOrAverage: DailyAggregation = .sum
    ) async throws -> [(date: Date, value: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let anchor = Calendar.current.startOfDay(for: start)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: healthStore)
        var series: [(date: Date, value: Double)] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let value: Double? = switch sumOrAverage {
            case .sum:     stat.sumQuantity()?.doubleValue(for: unit)
            case .average: stat.averageQuantity()?.doubleValue(for: unit)
            }
            if let v = value, v > 0 {
                series.append((stat.startDate, v))
            }
        }
        return series
    }

    private func sampleSeries(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> [(date: Date, value: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: healthStore)
        return samples.map { (date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    private func bloodPressureSamples(days: Int) async throws -> [BloodPressureReading] {
        guard
            let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)
        else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let sysDesc = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: sysType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let diaDesc = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: diaType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        async let sysSamples = sysDesc.result(for: healthStore)
        async let diaSamples = diaDesc.result(for: healthStore)
        let (sys, dia) = try await (sysSamples, diaSamples)

        let diaByDate = Dictionary(uniqueKeysWithValues: dia.map { ($0.startDate, $0) })
        let unit = HKUnit.millimeterOfMercury()
        return sys.compactMap { s in
            guard let d = diaByDate[s.startDate] else { return nil }
            return BloodPressureReading(
                systolic: s.quantity.doubleValue(for: unit),
                diastolic: d.quantity.doubleValue(for: unit),
                date: s.startDate
            )
        }
    }
}

import Foundation
import HealthKit
import IntervalEngine

/// Owns the watch's `HKWorkoutSession` + `HKLiveWorkoutBuilder` — the real
/// beat-to-beat HR source that makes the watch a valid session *primary*
/// (spec §5.2). Live HR samples are pushed to `onHR`; HRmax is estimated from
/// HealthKit DOB + observed 90-day max via the shared `HRMaxEstimator`.
///
/// Sensors don't run in the Simulator (spec §9), so the caller bypasses this
/// entirely under `MockMode`; everything here is exercised only on device.
@MainActor
final class WatchWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var onHR: ((Double, Date) -> Void)?

    // `nonisolated`: pure computed HealthKit lookups with no stored state, so the
    // nonisolated builder delegate (below) can read them off the main actor.
    private nonisolated static var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }
    private nonisolated static var heartRateType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .heartRate)
    }

    /// Request read access to HR (and DOB) plus workout share. Returns `false`
    /// when HealthKit is unavailable or the user declines.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let hr = Self.heartRateType else { return false }
        var read: Set<HKObjectType> = [hr]
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { read.insert(dob) }
        let share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
            return true
        } catch {
            return false
        }
    }

    /// HRmax = higher of Tanaka(age) and observed 90-day max (spec §3), or `nil`
    /// when neither DOB nor any observed max is available (→ timer-only).
    func estimatedHRMax() async -> Double? {
        let dob = (try? healthStore.dateOfBirthComponents())?.date
        let observed = try? await observedMaxHeartRate(days: 90)
        return HRMaxEstimator.estimate(dateOfBirth: dob, observedMaxLast90d: observed)
    }

    private func observedMaxHeartRate(days: Int) async throws -> Double? {
        guard let hr = Self.heartRateType else { return nil }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: hr, predicate: predicate),
            options: .discreteMax
        )
        let result = try await descriptor.result(for: healthStore)
        return result?.maximumQuantity()?.doubleValue(for: Self.bpmUnit)
    }

    /// Start a HIIT workout session and begin streaming HR. Returns `false` if a
    /// session can't be created (no HealthKit) so the caller can degrade.
    @discardableResult
    func start(onHR: @escaping (Double, Date) -> Void) -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        self.onHR = onHR

        let config = HKWorkoutConfiguration()
        config.activityType = .highIntensityIntervalTraining
        config.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            return true
        } catch {
            self.onHR = nil
            return false
        }
    }

    func stop() {
        onHR = nil
        session?.end()
        let builder = self.builder
        builder?.endCollection(withEnd: Date()) { _, _ in
            builder?.finishWorkout { _, _ in }
        }
        session = nil
        self.builder = nil
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hr = WatchWorkoutManager.heartRateType, collectedTypes.contains(hr) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let stats = workoutBuilder.statistics(for: hr),
              let bpm = stats.mostRecentQuantity()?.doubleValue(for: unit) else { return }
        let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor [weak self] in self?.onHR?(bpm, date) }
    }
}

import Foundation
import HealthKit

/// The phone's standalone HR source (spec §5.2 / §5.3): an iOS `HKWorkoutSession`
/// + `HKLiveWorkoutBuilder`, available on iOS 17+, that reads beat-to-beat HR
/// from whatever sensor is locally paired — e.g. AirPods Pro 2 or another
/// Bluetooth HR strap — when no Watch is acting as primary.
///
/// This is the "phone alone + external HR source" mode: the phone opens its own
/// workout session and owns sensing/haptics. Live samples are pushed to `onHR`.
/// Sensors don't run in the Simulator (spec §9), so `MockMode` bypasses this
/// entirely; everything here is exercised only on a physical device.
@MainActor
final class PhoneWorkoutManager: NSObject {
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

    /// Start a HIIT workout session and begin streaming HR. Returns `false` if a
    /// session can't be created (no HealthKit / no sensor) so the caller can
    /// degrade to timer-only.
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
        // N4x4 currently uses the workout session only for live sensing. Saving
        // an HKWorkout is a separate product decision, so discard collected data
        // instead of silently writing every session into HealthKit.
        builder?.discardWorkout()
        session = nil
        builder = nil
    }
}

extension PhoneWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

extension PhoneWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hr = PhoneWorkoutManager.heartRateType, collectedTypes.contains(hr) else { return }
        guard let stats = workoutBuilder.statistics(for: hr),
              let bpm = stats.mostRecentQuantity()?.doubleValue(for: PhoneWorkoutManager.bpmUnit) else { return }
        let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor [weak self] in self?.onHR?(bpm, date) }
    }
}

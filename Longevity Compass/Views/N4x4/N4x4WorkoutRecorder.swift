import Foundation
import IntervalEngine
import Observation
import SwiftData

@Observable
@MainActor
final class N4x4WorkoutRecorder {
    private let context: ModelContext
    private var currentLog: N4x4WorkoutLog?
    private var framesSinceSave = 0

    private(set) var liveFrames: [N4x4WorkoutFrame] = []
    private(set) var lastCompletedLogID: UUID?

    init(context: ModelContext) {
        self.context = context
    }

    func begin(
        sessionID: UUID,
        startedAt: Date,
        hrMax: Double?,
        details: N4x4WorkoutDetails
    ) {
        if currentLog?.sessionID == sessionID { return }

        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let existing = try? context.fetch(descriptor).first
        let log = existing ?? N4x4WorkoutLog(
            sessionID: sessionID,
            startedAt: startedAt,
            estimatedHRMax: hrMax,
            equipment: details.equipment
        )
        if existing == nil { context.insert(log) }

        currentLog = log
        liveFrames = log.frames
        framesSinceSave = 0
        try? context.save()
    }

    func record(
        output: EngineOutput,
        sessionID: UUID,
        startedAt: Date,
        hrMax: Double?,
        details: N4x4WorkoutDetails,
        capturedAt: Date = .now
    ) {
        begin(sessionID: sessionID, startedAt: startedAt, hrMax: hrMax, details: details)
        guard let currentLog else { return }

        let frame = N4x4WorkoutFrame(capturedAt: capturedAt, output: output)
        if let last = liveFrames.last,
           abs(last.elapsed - frame.elapsed) < 0.5,
           last.bpm == frame.bpm,
           last.targetLower == frame.targetLower,
           last.targetUpper == frame.targetUpper {
            return
        }

        liveFrames.append(frame)
        currentLog.duration = max(currentLog.duration, output.elapsed)
        framesSinceSave += 1
        if framesSinceSave >= 10 || output.isFinished {
            flush()
        }
    }

    func finish(output: EngineOutput?, completed: Bool, healthKitRequested: Bool) {
        guard let currentLog else { return }
        if let output {
            record(
                output: output,
                sessionID: currentLog.sessionID,
                startedAt: currentLog.startedAt,
                hrMax: currentLog.estimatedHRMax,
                details: N4x4WorkoutDetails(equipment: currentLog.equipment)
            )
            currentLog.duration = output.elapsed
        }
        currentLog.endedAt = .now
        currentLog.isCompleted = completed
        currentLog.healthKitSaveState = healthKitRequested ? .requested : .notRequested
        updateSummary(on: currentLog)
        flush()
        if completed { lastCompletedLogID = currentLog.sessionID }
        self.currentLog = nil
    }

    func updateHealthKitResult(sessionID: UUID, error: Error?) {
        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        guard let log = try? context.fetch(descriptor).first else { return }
        log.healthKitSaveState = error == nil ? .saved : .failed
        log.healthKitError = error?.localizedDescription
        try? context.save()
    }

    func resetLiveFrames() {
        liveFrames = []
        lastCompletedLogID = nil
    }

    private func flush() {
        guard let currentLog else { return }
        currentLog.frames = liveFrames
        framesSinceSave = 0
        try? context.save()
    }

    private func updateSummary(on log: N4x4WorkoutLog) {
        let heartRates = liveFrames.compactMap(\.bpm)
        if !heartRates.isEmpty {
            log.averageHeartRate = heartRates.reduce(0, +) / Double(heartRates.count)
            log.peakHeartRate = heartRates.max()
        }

        let targeted = liveFrames.compactMap { frame -> Bool? in
            guard let bpm = frame.bpm,
                  let low = frame.targetLower,
                  let high = frame.targetUpper else { return nil }
            return bpm >= low - IntervalEngine.deadBandBPM
                && bpm <= high + IntervalEngine.deadBandBPM
        }
        if !targeted.isEmpty {
            log.targetAdherence = Double(targeted.filter { $0 }.count) / Double(targeted.count)
        }

        log.averageOneMinuteRise = averageOneMinuteChange(for: .highIntensity, descending: false)
        log.averageOneMinuteRecovery = averageOneMinuteChange(for: .activeRecovery, descending: true)
    }

    private enum PhaseFamily { case highIntensity, activeRecovery }

    private func averageOneMinuteChange(for family: PhaseFamily, descending: Bool) -> Double? {
        let grouped = Dictionary(grouping: liveFrames) { frame -> String in
            switch frame.phase {
            case .highIntensity(let round): return "high-\(round)"
            case .activeRecovery(let round): return "recovery-\(round)"
            case .warmUp: return "warmup"
            case .cooldown: return "cooldown"
            }
        }

        let values = grouped.values.compactMap { phaseFrames -> Double? in
            guard let phase = phaseFrames.first?.phase else { return nil }
            let matches = switch (family, phase) {
            case (.highIntensity, .highIntensity): true
            case (.activeRecovery, .activeRecovery): true
            default: false
            }
            guard matches,
                  let startFrame = phaseFrames.first(where: { $0.bpm != nil }),
                  let startBPM = startFrame.bpm else { return nil }
            let targetElapsed = startFrame.elapsed + 60
            guard let oneMinuteFrame = phaseFrames
                .filter({ $0.bpm != nil && $0.elapsed >= targetElapsed })
                .min(by: { $0.elapsed < $1.elapsed }),
                  let oneMinuteBPM = oneMinuteFrame.bpm else { return nil }
            return descending ? startBPM - oneMinuteBPM : oneMinuteBPM - startBPM
        }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

import Foundation

#if canImport(ActivityKit)
import ActivityKit

#if os(iOS)
/// Shared Live Activity contract used by the host app and its widget extension.
public struct N4x4ActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public let phaseLabel: String
        public let ringColor: RingColor
        public let phaseProgress: Double
        /// Non-nil while running so system timer views can count down without
        /// receiving a new state every second.
        public let phaseEndDate: Date?
        /// Static fallback used while paused or finished.
        public let phaseRemaining: TimeInterval
        public let totalEndDate: Date?
        public let totalRemaining: TimeInterval
        public let heartRate: Double?
        public let targetLower: Double?
        public let targetUpper: Double?
        public let adjustmentHint: AdjustmentHint
        public let isPaused: Bool
        public let isFinished: Bool

        public init(
            phaseLabel: String,
            ringColor: RingColor,
            phaseProgress: Double,
            phaseEndDate: Date?,
            phaseRemaining: TimeInterval,
            totalEndDate: Date?,
            totalRemaining: TimeInterval,
            heartRate: Double?,
            targetLower: Double?,
            targetUpper: Double?,
            adjustmentHint: AdjustmentHint,
            isPaused: Bool,
            isFinished: Bool
        ) {
            self.phaseLabel = phaseLabel
            self.ringColor = ringColor
            self.phaseProgress = phaseProgress
            self.phaseEndDate = phaseEndDate
            self.phaseRemaining = phaseRemaining
            self.totalEndDate = totalEndDate
            self.totalRemaining = totalRemaining
            self.heartRate = heartRate
            self.targetLower = targetLower
            self.targetUpper = targetUpper
            self.adjustmentHint = adjustmentHint
            self.isPaused = isPaused
            self.isFinished = isFinished
        }

        public init(snapshot: SessionSnapshot, capturedAt: Date) {
            let output = snapshot.output
            let isRunning = !output.isPaused && !output.isFinished

            self.init(
                phaseLabel: output.phaseLabel,
                ringColor: output.ringColor,
                phaseProgress: output.phaseProgress,
                phaseEndDate: isRunning
                    ? capturedAt.addingTimeInterval(output.timeRemainingInPhase)
                    : nil,
                phaseRemaining: output.timeRemainingInPhase,
                totalEndDate: isRunning
                    ? capturedAt.addingTimeInterval(output.totalRemaining)
                    : nil,
                totalRemaining: output.totalRemaining,
                heartRate: output.trailingHR,
                targetLower: output.target?.lowerBound,
                targetUpper: output.target?.upperBound,
                adjustmentHint: output.adjustmentHint,
                isPaused: output.isPaused,
                isFinished: output.isFinished
            )
        }
    }

    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    public init(snapshot: SessionSnapshot) {
        self.init(sessionID: snapshot.sessionID)
    }
}
#endif
#endif

import ActivityKit
import Foundation
import IntervalEngine

/// Keeps the system Live Activity aligned with the canonical N4x4 session.
///
/// Connectivity is intentionally not part of this object's lifecycle. A missing
/// phone/Watch link merely means there is no new snapshot to publish; it never
/// ends a running Live Activity. Only an explicit stop or an engine snapshot
/// marked as finished is terminal.
@MainActor
final class N4x4LiveActivityManager {
    static let shared = N4x4LiveActivityManager()

    private var latestSequenceBySession: [UUID: UInt64] = [:]
    private var terminalSessions: Set<UUID> = []

    private init() {}

    /// Creates the Live Activity for the first snapshot of a session, restores
    /// an existing activity after an app relaunch, or updates the matching one.
    /// Old/duplicate snapshots cannot move the system presentation backwards.
    func reconcile(_ snapshot: SessionSnapshot, capturedAt: Date = .now) async {
        let sessionID = snapshot.sessionID
        guard !terminalSessions.contains(sessionID) else { return }
        guard latestSequenceBySession[sessionID].map({ snapshot.sequence > $0 }) ?? true else { return }

        let state = N4x4ActivityAttributes.ContentState(
            snapshot: snapshot,
            capturedAt: capturedAt
        )
        let content = activityContent(for: state)

        if state.isFinished {
            terminalSessions.insert(sessionID)
            latestSequenceBySession[sessionID] = snapshot.sequence
            await endActivities(
                matching: sessionID,
                content: content,
                dismissalPolicy: .default
            )
            return
        }

        let matchingActivities = activities(matching: sessionID)
        if !matchingActivities.isEmpty {
            latestSequenceBySession[sessionID] = snapshot.sequence
            for activity in matchingActivities {
                await activity.update(content)
            }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            _ = try Activity<N4x4ActivityAttributes>.request(
                attributes: N4x4ActivityAttributes(sessionID: sessionID),
                content: content,
                pushType: nil
            )
            latestSequenceBySession[sessionID] = snapshot.sequence
        } catch {
            // A Live Activity is supplementary UI. Permission, quota, or system
            // failures must never affect the workout session itself.
        }
    }

    /// Ends a session only because the user explicitly stopped it. Passing the
    /// most recent snapshot lets the system show one final coherent frame while
    /// it dismisses; an immediate dismissal is used either way.
    func endExplicitly(
        sessionID: UUID,
        finalSnapshot: SessionSnapshot? = nil,
        capturedAt: Date = .now
    ) async {
        terminalSessions.insert(sessionID)

        let content = finalSnapshot.map {
            activityContent(
                for: N4x4ActivityAttributes.ContentState(
                    snapshot: $0,
                    capturedAt: capturedAt
                )
            )
        }
        await endActivities(
            matching: sessionID,
            content: content,
            dismissalPolicy: .immediate
        )
    }

    private func activities(matching sessionID: UUID) -> [Activity<N4x4ActivityAttributes>] {
        Activity<N4x4ActivityAttributes>.activities.filter {
            $0.attributes.sessionID == sessionID
        }
    }

    private func activityContent(
        for state: N4x4ActivityAttributes.ContentState
    ) -> ActivityContent<N4x4ActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: state.isPaused || state.isFinished ? nil : state.phaseEndDate,
            relevanceScore: 1
        )
    }

    private func endActivities(
        matching sessionID: UUID,
        content: ActivityContent<N4x4ActivityAttributes.ContentState>?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        for activity in activities(matching: sessionID) {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }
}

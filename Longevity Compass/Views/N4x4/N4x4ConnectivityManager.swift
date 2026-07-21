import Foundation
import IntervalEngine
import WatchConnectivity

/// Phone side of the primary/mirror link (spec §5.2). While the phone runs the
/// session as primary it streams each `EngineOutput` tick to a reachable watch so
/// the watch can mirror — and, if the phone's link drops, the watch's
/// `FailoverController` promotes itself and takes over sensing/haptics.
///
/// Transport only. `EngineOutput` crosses as JSON (`Codable`). Receiving the
/// watch's output (phone-as-mirror) is surfaced via `onRemoteOutput` for a future
/// pass; today the phone uses this only to stream out.
@MainActor
final class N4x4ConnectivityManager: NSObject {
    var onRemoteOutput: ((EngineOutput) -> Void)?

    /// Called (on the main actor) when the remote primary broadcasts an explicit
    /// session stop. Lets an intentional End propagate instead of looking like a
    /// dropped link — which would otherwise trip the mirror's failover promotion.
    var onRemoteStop: (() -> Void)?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    var isWatchReachable: Bool { session?.isReachable ?? false }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ output: EngineOutput) {
        guard let session, session.isReachable,
              let data = try? JSONEncoder().encode(output) else { return }
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    /// Broadcast an explicit "session ended" control message so the counterpart
    /// tears down too, rather than promoting itself on the ensuing silence.
    func sendStop() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["control": "stop"], replyHandler: nil, errorHandler: nil)
    }
}

extension N4x4ConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    // iOS-only lifecycle: the session deactivates when switching watches; reactivate.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let output = try? JSONDecoder().decode(EngineOutput.self, from: messageData) else { return }
        Task { @MainActor [weak self] in self?.onRemoteOutput?(output) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["control"] as? String == "stop" else { return }
        Task { @MainActor [weak self] in self?.onRemoteStop?() }
    }
}

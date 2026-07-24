import Foundation
import IntervalEngine
import WatchConnectivity

/// Phone side of the primary/mirror link (spec §5.2). While the phone runs the
/// session as primary it streams each `EngineOutput` tick to a reachable watch so
/// the watch can mirror — and, if the phone's link drops, the watch's
/// `FailoverController` promotes itself and takes over sensing/haptics.
///
/// Transport only. A shared `SessionMessage` crosses as JSON; role decisions
/// remain in the session model.
@MainActor
final class N4x4ConnectivityManager: NSObject {
    var onRemoteOutput: ((EngineOutput) -> Void)?

    /// Called (on the main actor) when the remote primary broadcasts an explicit
    /// session stop. Lets an intentional End propagate instead of looking like a
    /// dropped link — which would otherwise trip the mirror's failover promotion.
    var onRemoteStop: (() -> Void)?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ output: EngineOutput) {
        send(.output(output))
    }

    /// Broadcast an explicit "session ended" control message so the counterpart
    /// tears down too, rather than promoting itself on the ensuing silence.
    func sendStop() {
        send(.stop)
    }

    private func send(_ message: SessionMessage) {
        guard let session, session.isReachable,
              let data = try? JSONEncoder().encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
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
        guard let message = try? JSONDecoder().decode(SessionMessage.self, from: messageData) else { return }
        Task { @MainActor [weak self] in
            switch message {
            case .output(let output): self?.onRemoteOutput?(output)
            case .stop:               self?.onRemoteStop?()
            }
        }
    }
}

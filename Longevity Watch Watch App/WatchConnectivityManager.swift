import Foundation
import IntervalEngine
import WatchConnectivity

/// Watch side of the primary/mirror link (spec §5.2). Streams the local engine's
/// `EngineOutput` to the phone while this device is primary, and surfaces the
/// phone's output (when the phone is primary) so the watch can mirror it.
///
/// Transport only — the *decision* of who is primary lives in `FailoverController`
/// and the session model. `EngineOutput` crosses the wire as JSON (it is `Codable`).
@MainActor
final class WatchConnectivityManager: NSObject {
    /// Called (on the main actor) with each decoded tick received from a remote
    /// primary. The session model uses this to render mirror state and to feed
    /// its `FailoverController` watchdog.
    var onRemoteOutput: ((EngineOutput) -> Void)?

    /// Called (on the main actor) when the remote primary broadcasts an explicit
    /// session stop. Lets an intentional End propagate instead of looking like a
    /// dropped link — which would otherwise trip the mirror's failover promotion.
    var onRemoteStop: (() -> Void)?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    var isReachable: Bool { session?.isReachable ?? false }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Fire-and-forget stream of the local primary's output. Dropped silently when
    /// the counterpart isn't reachable — the mirror's watchdog handles a real drop.
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

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let output = try? JSONDecoder().decode(EngineOutput.self, from: messageData) else { return }
        Task { @MainActor [weak self] in self?.onRemoteOutput?(output) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["control"] as? String == "stop" else { return }
        Task { @MainActor [weak self] in self?.onRemoteStop?() }
    }
}

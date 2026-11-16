import Foundation

/// Deterministic conflict rules for simultaneous phone/watch session state.
///
/// The result intentionally does not depend on which device evaluates it: both
/// peers must pick the same winner to converge after reconnecting.
public enum SessionReconciliation {
    /// Returns whether `remote` is the deterministic winner over `local`.
    ///
    /// - Different sessions: the earlier creation date wins, with ascending UUID
    ///   text as a stable tie-breaker.
    /// - Same session: Watch authority wins; snapshots from the same authority
    ///   are ordered by sequence number.
    /// - No local snapshot: adopt the remote snapshot.
    public static func shouldAdopt(
        remote: SessionSnapshot,
        over local: SessionSnapshot?,
        localDevice: SessionDevice
    ) -> Bool {
        guard let local else { return true }

        // Keep the caller's identity explicit at integration sites while making
        // the actual winner device-independent.
        _ = localDevice

        guard remote.sessionID == local.sessionID else {
            if remote.createdAt != local.createdAt {
                return remote.createdAt < local.createdAt
            }
            return remote.sessionID.uuidString < local.sessionID.uuidString
        }

        if remote.authority != local.authority {
            return remote.authority == .watch
        }
        return remote.sequence > local.sequence
    }
}

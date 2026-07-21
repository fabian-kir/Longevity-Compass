import Foundation

public enum SyncRole: Equatable, Sendable {
    case primary
    case mirror
}

/// Transport-agnostic primary/mirror failover logic (spec §5.2).
///
/// The actual `WCSession` plumbing lives in the app layer; this type owns only
/// the *decision*: a mirror that stops hearing from the primary for longer than
/// `promotionTimeout` promotes itself to primary. There is no auto-reclaim — once
/// promoted, the device stays primary to avoid ping-ponging authority.
///
/// Kept in the pure package so the watchdog timing is unit-testable without two
/// physical devices.
public final class FailoverController {
    public private(set) var role: SyncRole
    /// Long enough to survive a normal Bluetooth hiccup, short enough not to
    /// leave the user without coaching for a meaningful stretch (spec §5.2).
    public let promotionTimeout: TimeInterval

    private var lastTickFromPrimary: Date?

    public init(role: SyncRole, referenceStart: Date, promotionTimeout: TimeInterval = 4.5) {
        self.role = role
        self.promotionTimeout = promotionTimeout
        self.lastTickFromPrimary = (role == .mirror) ? referenceStart : nil
    }

    /// Record that a live tick arrived from the primary. Ignored once this device
    /// has itself become primary (no auto-reclaim). `now` is the mirror's local
    /// receive time, so a clock-skewed primary timestamp can't stall the watchdog.
    public func receivedPrimaryTick(at now: Date) {
        guard role == .mirror else { return }
        lastTickFromPrimary = now
    }

    /// Evaluate the watchdog on the local timer. Returns `true` exactly once, on
    /// the tick where a mirror promotes itself to primary.
    @discardableResult
    public func evaluate(at now: Date) -> Bool {
        guard role == .mirror, let last = lastTickFromPrimary else { return false }
        guard now.timeIntervalSince(last) > promotionTimeout else { return false }
        role = .primary
        return true
    }
}

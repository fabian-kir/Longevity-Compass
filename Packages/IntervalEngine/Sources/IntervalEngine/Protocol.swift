import Foundation

/// The kind of block within a Norwegian 4x4 session.
///
/// `round` is 1-based. High-intensity blocks run rounds 1...4; a recovery block
/// carries the round of the high block it *follows* (recovery 1...3). There is no
/// recovery after round 4 — the protocol goes straight to cooldown (spec §2).
public enum PhaseKind: Equatable, Hashable, Sendable, Codable {
    case warmUp
    case highIntensity(round: Int)
    case activeRecovery(round: Int)
    case cooldown
}

extension PhaseKind {
    /// Ring colour for this phase (spec §6): blue for warm-up/cooldown, red for
    /// high intensity, green for active recovery.
    public var ringColor: RingColor {
        switch self {
        case .warmUp, .cooldown:   return .blue
        case .highIntensity:       return .red
        case .activeRecovery:      return .green
        }
    }

    /// Short label shown alongside the timer, e.g. `"3/4 (high intensity)"` (spec §6.1).
    public var label: String {
        switch self {
        case .warmUp:                 return "Warm-up"
        case .highIntensity(let r):   return "\(r)/4 (high intensity)"
        case .activeRecovery(let r):  return "\(r)/4 (recovery)"
        case .cooldown:               return "Cool-down"
        }
    }

    /// Only warm-up and cooldown are skippable in-session (spec §7).
    public var isSkippable: Bool {
        switch self {
        case .warmUp, .cooldown:      return true
        case .highIntensity, .activeRecovery: return false
        }
    }

    /// Fractional HR-target band `[lo, hi]` of HRmax, or `nil` when the phase has
    /// no HR target (warm-up/cooldown). High: 85–95%; recovery: 65–70% (spec §3).
    public var targetFraction: ClosedRange<Double>? {
        switch self {
        case .highIntensity:      return 0.85...0.95
        case .activeRecovery:     return 0.65...0.70
        case .warmUp, .cooldown:  return nil
        }
    }

    /// Color of the phase that follows this one, for the anticipatory fill in
    /// the phase-flow indicator (spec §6): the color creeping in as this phase's
    /// disc shrinks previews what's coming next. `nil` after cooldown, where
    /// there's nothing left to anticipate.
    public var nextRingColor: RingColor? {
        switch self {
        case .warmUp:                      return .red
        case .highIntensity(let r) where r < 4: return .green
        case .highIntensity:               return .blue   // round 4 → straight to cooldown
        case .activeRecovery:               return .red
        case .cooldown:                     return nil
        }
    }
}

public enum RingColor: Equatable, Sendable, Codable {
    case blue, red, green
}

/// One ordered block in the session, with its duration and cumulative start
/// offset from the session origin (before any pauses/skips are applied).
public struct Phase: Equatable, Sendable {
    public let kind: PhaseKind
    public let duration: TimeInterval
    public let startOffset: TimeInterval

    public var endOffset: TimeInterval { startOffset + duration }
}

/// The fixed protocol structure. Non-configurable in v1 (spec §2): durations,
/// counts and ordering are baked in; only the ramp duration is a shared tunable.
public struct ProtocolConfig: Equatable, Sendable {
    public let phases: [Phase]
    /// Seconds over which the target line ramps from the phase-start HR to the
    /// band before holding flat (spec §3).
    public let rampDuration: TimeInterval

    public var totalDuration: TimeInterval { phases.last?.endOffset ?? 0 }

    public init(blocks: [(kind: PhaseKind, duration: TimeInterval)], rampDuration: TimeInterval) {
        var offset: TimeInterval = 0
        var built: [Phase] = []
        built.reserveCapacity(blocks.count)
        for block in blocks {
            built.append(Phase(kind: block.kind, duration: block.duration, startOffset: offset))
            offset += block.duration
        }
        self.phases = built
        self.rampDuration = rampDuration
    }

    /// Canonical Norwegian 4x4 (spec §2). Total runtime = 31 min (warm-up 3 +
    /// 4×4 high + 3×3 recovery + cooldown 3). Note: the spec's prose says
    /// "≈ 34 minutes", but the enumerated block structure sums to 31; the block
    /// structure is authoritative, so total is derived, never hardcoded.
    public static let norwegian4x4 = ProtocolConfig(
        blocks: [
            (.warmUp, 3 * 60),
            (.highIntensity(round: 1), 4 * 60),
            (.activeRecovery(round: 1), 3 * 60),
            (.highIntensity(round: 2), 4 * 60),
            (.activeRecovery(round: 2), 3 * 60),
            (.highIntensity(round: 3), 4 * 60),
            (.activeRecovery(round: 3), 3 * 60),
            (.highIntensity(round: 4), 4 * 60),
            (.cooldown, 3 * 60),
        ],
        rampDuration: 60
    )

    /// Index of the phase active at `elapsed` seconds, or `nil` once the session
    /// has run past its total duration.
    public func phaseIndex(atElapsed elapsed: TimeInterval) -> Int? {
        guard elapsed >= 0, elapsed < totalDuration else { return nil }
        // Phases are contiguous and ordered; linear scan is fine for 9 blocks.
        for (index, phase) in phases.enumerated() where elapsed < phase.endOffset {
            return index
        }
        return nil
    }
}

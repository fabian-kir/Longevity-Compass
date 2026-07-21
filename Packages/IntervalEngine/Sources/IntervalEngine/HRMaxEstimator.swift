import Foundation

/// Estimates HRmax by blending the Tanaka population formula with the user's own
/// observed max from recent vigorous workouts (spec §3).
///
/// Pure value math: the caller (app layer) is responsible for pulling
/// date-of-birth and the observed 90-day max from HealthKit and passing them in.
/// The estimator never touches HealthKit itself, keeping the package
/// platform-agnostic (spec §5.1).
public enum HRMaxEstimator {

    /// Tanaka et al.: `208 − 0.7 × age`. This is the floor/fallback used when the
    /// user has no workout history.
    public static func tanaka(age: Double) -> Double {
        208 - 0.7 * age
    }

    /// Age in (fractional) years from date of birth to `now`.
    public static func age(dateOfBirth: Date, now: Date = Date()) -> Double {
        now.timeIntervalSince(dateOfBirth) / (365.25 * 24 * 60 * 60)
    }

    /// Blended HRmax estimate.
    ///
    /// - Whichever is higher wins: a personal observed ceiling beats the
    ///   population formula (spec §3). The formula is the floor when no observed
    ///   value is available.
    /// - Returns `nil` only when neither input is available (no DOB and no
    ///   observed max) — the app treats that as "no HR bands", i.e. timer-only.
    ///
    /// - Parameters:
    ///   - dateOfBirth: HealthKit DOB, if known.
    ///   - observedMaxLast90d: highest HR (bpm) seen in vigorous workouts over the
    ///     last 90 days, if any.
    public static func estimate(
        dateOfBirth: Date?,
        now: Date = Date(),
        observedMaxLast90d: Double?
    ) -> Double? {
        let formula = dateOfBirth.map { tanaka(age: age(dateOfBirth: $0, now: now)) }
        switch (formula, observedMaxLast90d) {
        case let (f?, o?): return max(f, o)
        case let (f?, nil): return f
        case let (nil, o?): return o
        case (nil, nil):    return nil
        }
    }
}

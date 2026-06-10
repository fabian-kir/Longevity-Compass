import Foundation

enum AppleHealthLink {
    static let url = URL(string: "x-apple-health://")!

    enum Destination {
        case appleHealth
        case trackTab
    }

    /// Where a "Track now" tap should route, given a domain.
    static func destination(for domain: HealthDomain) -> Destination {
        switch domain {
        case .bloodPressure, .bodyComposition, .sleep, .cardio, .strength:
            return .appleHealth
        case .protein, .fiber, .omega3, .alcohol, .nicotine, .dental:
            return .trackTab
        }
    }

    /// Short hint about where this metric lives inside the Health app.
    /// Apple does not document deep-link URLs to specific Health sections,
    /// so we open Health to its root and tell the user where to go.
    static func healthLocationHint(for domain: HealthDomain) -> String? {
        switch domain {
        case .bloodPressure:    "Browse → Vitals → Blood Pressure"
        case .bodyComposition:  "Browse → Body Measurements → Weight"
        case .sleep:            "Browse → Sleep"
        case .cardio:           "Browse → Activity → Workouts"
        case .strength:         "Browse → Activity → Workouts (Strength)"
        default:                nil
        }
    }
}

import IntervalEngine
import WatchKit

/// Maps engine `HapticCommand`s to watchOS Taptic types (spec §4). The watch uses
/// the system `WKInterfaceDevice` haptics rather than CoreHaptics patterns: they
/// are tuned for the wrist and distinct enough for eyes-free coaching.
@MainActor
final class WatchHapticEngine {
    /// The single directional taps were too faint on-wrist mid-run. We keep the
    /// directional *meaning* but raise salience: `.notification` is the strongest
    /// wrist tap, and repeating it as a short burst makes the cue unmistakable and
    /// eyes-free. Tap count also encodes meaning (2 = adjust, 3 = new phase).
    func play(_ command: HapticCommand) {
        switch command {
        case .goHarder:        burst(.notification, times: 2, gap: 0.17)   // "push" — strong double
        case .chill:           burst(.directionDown, times: 2, gap: 0.22)  // "ease off" — softer, still doubled
        case .phaseTransition: burst(.notification, times: 3, gap: 0.15)   // "new phase" — strong triple
        }
    }

    private func burst(_ type: WKHapticType, times: Int, gap: TimeInterval) {
        let device = WKInterfaceDevice.current()
        device.play(type)
        guard times > 1 else { return }
        for i in 1..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i)) {
                device.play(type)
            }
        }
    }
}

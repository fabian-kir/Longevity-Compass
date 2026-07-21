import CoreHaptics
import Foundation
import IntervalEngine
import UIKit

/// Maps engine `HapticCommand`s to concrete Taptic patterns (spec §4). Uses
/// CoreHaptics for distinct patterns where available, falling back to the
/// simpler `UIFeedbackGenerator` API (e.g. older hardware, Simulator). The
/// engine stays platform-agnostic; all device coupling lives here.
@MainActor
final class N4x4HapticEngine {
    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func prepare() {
        guard supportsHaptics, engine == nil else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        try? engine?.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    func play(_ command: HapticCommand) {
        guard supportsHaptics, let engine else {
            fallback(command)
            return
        }
        do {
            let player = try engine.makePlayer(with: Self.pattern(for: command))
            try player.start(atTime: 0)
        } catch {
            fallback(command)
        }
    }

    private func fallback(_ command: HapticCommand) {
        switch command {
        case .goHarder:        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
        case .chill:           UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
        case .phaseTransition: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private static func pattern(for command: HapticCommand) throws -> CHHapticPattern {
        func tap(_ time: TimeInterval, sharpness: Float, intensity: Float) -> CHHapticEvent {
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                ],
                relativeTime: time
            )
        }
        func buzz(_ time: TimeInterval, duration: TimeInterval, sharpness: Float, intensity: Float) -> CHHapticEvent {
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                ],
                relativeTime: time,
                duration: duration
            )
        }
        // Intensities raised to near-max and a sustained buzz added to "go harder":
        // the prior transient-only taps were too easy to miss mid-effort.
        switch command {
        case .goHarder: // urgent: strong buzz punctuated by two full taps — "push"
            return try CHHapticPattern(events: [
                buzz(0, duration: 0.18, sharpness: 0.9, intensity: 1.0),
                tap(0.22, sharpness: 0.95, intensity: 1.0),
                tap(0.36, sharpness: 0.95, intensity: 1.0),
            ], parameters: [])
        case .chill: // ease off: two firm low taps — noticeable, not alarming
            return try CHHapticPattern(events: [
                tap(0, sharpness: 0.3, intensity: 0.8),
                tap(0.22, sharpness: 0.3, intensity: 0.7),
            ], parameters: [])
        case .phaseTransition: // new phase: crisp full-intensity triple
            return try CHHapticPattern(events: [
                tap(0, sharpness: 0.7, intensity: 1.0),
                tap(0.12, sharpness: 0.7, intensity: 1.0),
                tap(0.24, sharpness: 0.7, intensity: 1.0),
            ], parameters: [])
        }
    }
}

import IntervalEngine
import SwiftUI

/// Compact watch screen for a Norwegian 4x4 session (spec §6.2): a phase-progress
/// ring with the live HR at its center, phase/round label and time remaining, plus
/// a swipe-left page carrying the Skip/Pause/End controls (spec §7).
struct ContentView: View {
    @State private var model = WatchN4x4SessionModel()

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.stage {
            case .idle:                 idle
            case .active, .mirroring:   session
            case .done:                 completion
            }
        }
        .onAppear { model.onAppear() }
        .alert(timerOnlyTitle, isPresented: $model.showTimerOnlyWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(timerOnlyMessage)
        }
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(spacing: 12) {
            MjolnirIcon()
                .frame(width: 26, height: 30)
                .foregroundStyle(.cyan)
            Text("Norwegian 4×4")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.startPrimary() }
            } label: {
                Text("Start").frame(maxWidth: .infinity)
            }
            .tint(.cyan)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Active / mirroring

    private var session: some View {
        TabView {
            metricsPage.tag(0)
            if model.canControl { controlsPage.tag(1) }
        }
    }

    private var metricsPage: some View {
        let output = model.output
        return VStack(spacing: 6) {
            RingView(
                progress: output?.phaseProgress ?? 0,
                color: output?.ringColor.swiftUIColor ?? .blue
            ) {
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Text(hrText).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        cueArrow
                    }
                    Text("bpm").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)

            Text(output?.phaseLabel ?? "—")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(Self.clock(output?.timeRemainingInPhase ?? 0)) left")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            if let hint = targetHintText {
                Label(hint, systemImage: "scope")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            if model.stage == .mirroring {
                Label("Mirroring phone", systemImage: "iphone")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var cueArrow: some View {
        switch model.output?.deadBandState ?? .noTarget {
        case .below: Image(systemName: "arrow.up").foregroundStyle(.red).font(.headline)
        case .above: Image(systemName: "arrow.down").foregroundStyle(.blue).font(.headline)
        case .inRange, .noTarget: EmptyView()
        }
    }

    private var controlsPage: some View {
        VStack(spacing: 8) {
            if model.canSkip {
                Button { model.skip() } label: {
                    Label("Skip", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                }
            }
            Button { model.pauseResume() } label: {
                let paused = model.output?.isPaused ?? false
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            Button(role: .destructive) { model.end() } label: {
                Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Completion

    private var completion: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36)).foregroundStyle(.green)
            Text("Complete").font(.headline)
            if let output = model.output {
                Text("\(Self.clock(output.elapsed)) total")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                Task { await model.startPrimary() }
            } label: {
                Text("Again").frame(maxWidth: .infinity)
            }
            .tint(.cyan)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Helpers

    private var timerOnlyTitle: String {
        switch model.timerOnlyReason {
        case .noHRMax:                   return "No HR zones"
        case .sensorFailed, .noReadings: return "Timer only"
        }
    }

    private var timerOnlyMessage: String {
        switch model.timerOnlyReason {
        case .noHRMax:
            return "Couldn't estimate your max heart rate. Add your date of birth in the Health app for HR-zone coaching. Running timer and phases only for now."
        case .sensorFailed:
            return "Couldn't start heart-rate sensing on the watch. Running timer and phases only — no HR coaching."
        case .noReadings:
            return "No heart-rate readings are coming through. Running timer and phases only — no HR coaching."
        }
    }

    /// Subtle current target-band hint (bpm). Nil for warm-up/cooldown/timer-only;
    /// during the 60s ramp the band collapses to a single moving value.
    private var targetHintText: String? {
        guard let t = model.output?.target else { return nil }
        let lo = Int(t.lowerBound.rounded()), hi = Int(t.upperBound.rounded())
        return lo == hi ? "\(lo)" : "\(lo)–\(hi)"
    }

    private var hrText: String {
        if let hr = model.latestHR ?? model.output?.trailingHR {
            return String(Int(hr.rounded()))
        }
        return "—"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView()
}

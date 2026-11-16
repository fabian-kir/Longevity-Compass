import IntervalEngine
import IntervalUI
import SwiftUI

/// Compact watch screen for a Norwegian 4x4 session (spec §6.2): a phase-progress
/// ring with the live HR at its center, phase/round label and time remaining, plus
/// a swipe-left page carrying the Skip/Pause/End controls (spec §7).
struct ContentView: View {
    let model: WatchN4x4SessionModel
    @State private var selectedPage = 0

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
        ZStack {
            WatchAmbientBackdrop(tint: N4x4Palette.accent)

            VStack(spacing: 9) {
                MjolnirIcon()
                    .frame(width: 28, height: 33)
                    .foregroundStyle(N4x4Palette.accent)
                    .padding(12)
                    .glassEffect(.regular.tint(N4x4Palette.accent.opacity(0.14)), in: Circle())

                VStack(spacing: 2) {
                    Text("Norwegian 4×4")
                        .font(.headline)
                    Text("31 MIN · HR GUIDED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.55)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                Button {
                    Task { await model.startPrimary() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(N4x4Palette.accent)
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Active / mirroring

    private var session: some View {
        let output = model.output
        return ZStack {
            PhaseFlowView(
                progress: output?.phaseProgress ?? 0,
                color: output?.ringColor.swiftUIColor ?? N4x4Palette.warmUp,
                nextColor: output?.phase.nextRingColor?.swiftUIColor,
                backgroundColor: .black,
                minimumCoreRadius: 24,
                animatesProgress: false,
                showsSpecularHighlight: false
            ) { EmptyView() }

            TabView(selection: $selectedPage) {
                metricsPage.tag(0)
                if model.canControl { controlsPage.tag(1) }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .onChange(of: model.canControl) { _, canControl in
                if !canControl { selectedPage = 0 }
            }
        }
    }

    private var metricsPage: some View {
        let output = model.output
        return VStack(spacing: 7) {
            Text(output?.phaseLabel ?? "—")
                .font(.caption2.weight(.bold))
                .tracking(0.25)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).minimumScaleFactor(0.7)

            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                    Text(hrText)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    cueArrow
                }
                Text("BPM")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.62))

                Text(Self.clock(output?.timeRemainingInPhase ?? 0))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(output?.isPaused == true ? "PAUSED" : "REMAINING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
            }

            sessionStatus
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var sessionStatus: some View {
        if model.heartRateSource == .watch {
            Label("Wrist HR", systemImage: "applewatch")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
        } else if let hint = targetHintText {
            Label(hint, systemImage: "scope")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        } else {
            Label("No target", systemImage: "scope")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private var cueArrow: some View {
        switch model.output?.deadBandState ?? .noTarget {
        case .below:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(N4x4Palette.effort).font(.headline)
        case .above:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(N4x4Palette.warmUp).font(.headline)
        case .inRange:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(N4x4Palette.recovery).font(.headline)
        case .noTarget:
            EmptyView()
        }
    }

    private var controlsPage: some View {
        VStack(spacing: 9) {
            Button { model.pauseResume() } label: {
                let paused = model.output?.isPaused ?? false
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.glassProminent)
            .tint(model.output?.isPaused == true ? N4x4Palette.recovery : N4x4Palette.accent)

            HStack(spacing: 8) {
                if model.canSkip {
                    Button { model.skip() } label: {
                        watchControlLabel("Skip", symbol: "forward.end.fill")
                    }
                    .buttonStyle(.glass)
                }

                Button(role: .destructive) { model.end() } label: {
                    watchControlLabel("End", symbol: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
            }
        }
        .padding(.horizontal, 8)
    }

    private func watchControlLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.body)
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    // MARK: - Completion

    private var completion: some View {
        ZStack {
            WatchAmbientBackdrop(tint: N4x4Palette.recovery)

            VStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.tint(N4x4Palette.recovery.opacity(0.34)), in: Circle())
                Text("Complete").font(.headline)
                if let output = model.output {
                    Text("\(Self.clock(output.elapsed)) total")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button {
                    Task { await model.startPrimary() }
                } label: {
                    Label("Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(N4x4Palette.recovery)
            }
            .padding(.horizontal, 8)
        }
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
            return "Heart rate can still be shown, but target zones need an HRmax estimate. Add your date of birth or recent heart-rate history in the Health app."
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
        // Both devices render the same authoritative trailing value.
        if let hr = model.output?.trailingHR {
            return String(Int(hr.rounded()))
        }
        return "—"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct WatchAmbientBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [tint.opacity(0.34), tint.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 150
            )
            RadialGradient(
                colors: [tint.opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 4,
                endRadius: 120
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView(model: WatchN4x4SessionModel())
}

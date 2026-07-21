import IntervalEngine
import SwiftUI

/// Phone screen for a live Norwegian 4x4 session (spec §6.1): a center timer
/// inside a current-phase progress ring, phase label, HR + guidance cue, and
/// the Skip / Pause / End controls.
struct N4x4View: View {
    @Environment(AppServices.self) private var services
    @State private var model = N4x4SessionModel()

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isRunning || model.isMirroring {
                activeSession(model)
            } else if let output = model.output, output.isFinished {
                completion(output)
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("N4x4")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.onAppear(healthKit: services.healthKit, dateOfBirth: services.healthSnapshot.dateOfBirth)
        }
        .alert("Timer-only mode", isPresented: $model.showTimerOnlyWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No heart-rate source is available, so this session runs the timer and phases only — you won't get HR-based haptic coaching. Pair an Apple Watch to enable guidance.")
        }
    }

    // MARK: - Idle / start

    private var idle: some View {
        VStack(spacing: 28) {
            Spacer()
            MjolnirIcon()
                .frame(width: 48, height: 56)
                .foregroundStyle(AppTab.n4x4.tint)
            VStack(spacing: 8) {
                Text("Norwegian 4×4")
                    .font(.title2.bold())
                Text("Warm-up · 4 × (4 min hard / 3 min easy) · cooldown\n≈ 31 min")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            estimatedMaxLabel
            Spacer()
            Button {
                Task { await model.start(healthKit: services.healthKit, dateOfBirth: services.healthSnapshot.dateOfBirth) }
            } label: {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTab.n4x4.tint)
        }
        .padding(24)
    }

    @ViewBuilder
    private var estimatedMaxLabel: some View {
        if let hrMax = model.hrMax {
            Label("Estimated HRmax \(Int(hrMax.rounded())) bpm", systemImage: "heart.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Active

    private func activeSession(_ model: N4x4SessionModel) -> some View {
        let output = model.output
        return VStack(spacing: 24) {
            Spacer()
            RingView(
                progress: output?.phaseProgress ?? 0,
                color: (output?.ringColor.swiftUIColor ?? .blue)
            ) {
                VStack(spacing: 6) {
                    Text(Self.clock(output?.timeRemainingInPhase ?? 0))
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(output?.phaseLabel ?? "—")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 280, height: 280)

            guidanceRow(output)
            targetHint(output)
            totalRemainingLabel(output)
            if model.isMirroring {
                Label("Mirroring Apple Watch", systemImage: "applewatch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            // Controls belong to the primary only; while mirroring, the Watch owns them.
            if !model.isMirroring {
                controls(model, output: output)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func guidanceRow(_ output: EngineOutput?) -> some View {
        HStack(spacing: 24) {
            VStack(spacing: 2) {
                Text(hrText(output))
                    .font(.title.bold().monospacedDigit())
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            cue(output)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func cue(_ output: EngineOutput?) -> some View {
        switch output?.deadBandState ?? .noTarget {
        case .below:
            Label("Go harder", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.red)
                .font(.headline)
        case .above:
            Label("Ease off", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.headline)
        case .inRange:
            Label("In range", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
        case .noTarget:
            targetlessCue(output)
        }
    }

    @ViewBuilder
    private func targetlessCue(_ output: EngineOutput?) -> some View {
        // No target this tick (warm-up/cooldown or no HR). If there's a live HR
        // we're simply between target bands; if not, we're running timer-only.
        if (model.latestHR ?? output?.trailingHR) == nil {
            Label("Timer only", systemImage: "timer")
                .foregroundStyle(.secondary)
                .font(.headline)
        } else {
            Text("—").foregroundStyle(.secondary).font(.headline)
        }
    }

    /// Subtle current target-band hint (bpm) under the guidance row, so the user
    /// can see where the session is steering HR without a full chart. Hidden for
    /// warm-up/cooldown/timer-only; during the 60s ramp the band is a single value.
    @ViewBuilder
    private func targetHint(_ output: EngineOutput?) -> some View {
        if let t = output?.target {
            let lo = Int(t.lowerBound.rounded()), hi = Int(t.upperBound.rounded())
            Label(lo == hi ? "Target \(lo) bpm" : "Target \(lo)–\(hi) bpm", systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func totalRemainingLabel(_ output: EngineOutput?) -> some View {
        if let output {
            Text("\(Self.clock(output.totalRemaining)) left overall")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func controls(_ model: N4x4SessionModel, output: EngineOutput?) -> some View {
        HStack(spacing: 16) {
            if model.canSkip {
                Button { model.skip() } label: {
                    controlLabel("Skip", "forward.end.fill")
                }
                .buttonStyle(.bordered)
            }
            Button { model.pauseResume() } label: {
                let paused = output?.isPaused ?? false
                controlLabel(paused ? "Resume" : "Pause", paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) { model.end() } label: {
                controlLabel("End", "stop.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private func controlLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    // MARK: - Completion

    private func completion(_ output: EngineOutput) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Session complete")
                .font(.title2.bold())
            Text("\(Self.clock(output.elapsed)) total")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await model.start(healthKit: services.healthKit, dateOfBirth: services.healthSnapshot.dateOfBirth) }
            } label: {
                Text("Start again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTab.n4x4.tint)
        }
        .padding(24)
    }

    // MARK: - Helpers

    private func hrText(_ output: EngineOutput?) -> String {
        if let hr = model.latestHR ?? output?.trailingHR {
            return String(Int(hr.rounded()))
        }
        return "—"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

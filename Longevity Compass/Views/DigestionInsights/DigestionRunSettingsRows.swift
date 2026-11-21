import DigestionInsightsEngine
import SwiftUI

/// "Run analysis now" and last-run diagnostics, inside the Settings
/// "Digestion Insights" section (B11).
struct DigestionRunSettingsRows: View {
    @Environment(AppServices.self) private var services

    private var service: DigestionAnalysisService { services.digestion }

    var body: some View {
        if service.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Analysing… attempt \(service.currentAttempt) of \(HealthThresholds.Digestion.attempts.count)")
                    Spacer()
                    Text(service.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: service.progress)
            }
            Button("Stop analysis", role: .destructive) { service.cancel() }
        } else if services.isTrackingDigestion {
            Button("Run analysis now") { service.start() }
        }

        if let run = service.latestRun, run.status != .running {
            DisclosureGroup("Last run") {
                diagnosticRow("Date", run.startedAt.formatted(date: .abbreviated, time: .shortened))
                diagnosticRow("Duration", Self.duration(of: run))
                diagnosticRow("Attempts", "\(run.attempts)")
                diagnosticRow("Status", run.status.label)
                if let diagnostics = service.latestDiagnostics {
                    diagnosticRow("Max R̂", Self.number(diagnostics.maxRhat, digits: 3))
                    diagnosticRow("Min bulk ESS", Self.number(diagnostics.minBulkESS, digits: 0))
                    diagnosticRow("Divergences", "\(diagnostics.divergences)")
                }
            }
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }

    static func duration(of run: DigestionAnalysisRun) -> String {
        guard let end = run.finishedAt else { return "—" }
        let seconds = max(0, end.timeIntervalSince(run.startedAt))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(digits))) : "—"
    }
}

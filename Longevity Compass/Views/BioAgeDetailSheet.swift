import SwiftUI

// MARK: - Z-score bar (reusable)
//
// Replaces flat "−1.0 yr" chips on the bio-age contributor rows and the
// per-reading rows in the calculation sheet. The bar shows where the user
// sits relative to the age-matched population:
//
//   - centerline = typical (z = 0)
//   - marker = clamped z, with a "favorable to the right" convention
//
// The signed-z convention from the engine is "+ = better than typical", so a
// favorable user reading lands to the right of the baseline (greener) and an
// unfavorable reading lands to the left (oranger).

struct ZScoreBar: View {
    let zScore: Double
    /// Marker colour. Callers pass the same accent as the row's icon and years
    /// label, so a reading that moves the estimate is never shown as neutral
    /// just because its z-score is small (a heavily weighted marker can shift
    /// years at |z| < 0.5).
    let accent: Color

    /// Soft clamp range so a runaway z (e.g. extreme outlier value) doesn't
    /// push the marker off the visible track.
    private static let visibleRange: ClosedRange<Double> = -3...3

    private var clampedZ: Double {
        min(max(zScore, Self.visibleRange.lowerBound), Self.visibleRange.upperBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let mid = width / 2
            // Map clamped z in [-3, 3] to [0, width].
            let normalized = (clampedZ - Self.visibleRange.lowerBound)
                / (Self.visibleRange.upperBound - Self.visibleRange.lowerBound)
            let markerX = normalized * width

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)

                // Center tick (typical)
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: 10)
                    .offset(x: mid - 0.5)

                // Marker
                Circle()
                    .fill(accent)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                    )
                    .frame(width: 10, height: 10)
                    .offset(x: markerX - 5)
                    .shadow(color: accent.opacity(0.35), radius: 2, x: 0, y: 1)
            }
            .frame(height: 12, alignment: .center)
        }
        .frame(width: 88, height: 12)
        .accessibilityLabel("z-score \(String(format: "%+.1f", zScore)) — \(zScore > 0 ? "favorable" : "unfavorable")")
    }
}

// MARK: - Years label
//
// Small companion to the z-bar — preserves the absolute years number as a
// secondary cue. Sign convention mirrors the existing contributor chip.

struct YearsBadgeLabel: View {
    let years: Double
    var accent: Color = .secondary

    var body: some View {
        let sign = years < 0 ? "−" : "+"
        let mag = abs(years)
        Text(String(format: "%@%.1f yr", sign, mag))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(accent)
    }
}

// MARK: - "How this was calculated" sheet

struct BioAgeDetailSheet: View {
    let estimate: BioAgeEstimate

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppServices.self) private var services
    @State private var suppressedExpanded: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    baselineSection
                    factorSections
                    if !suppressedReadings.isEmpty {
                        SuppressedLeversSection(
                            readings: suppressedReadings,
                            isExpanded: $suppressedExpanded
                        )
                    }
                    if !sharpenSuggestions.isEmpty {
                        SharpenSection(
                            suggestions: sharpenSuggestions,
                            onTap: handleSharpenTap
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .navigationTitle("How this was calculated")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Sections

    private var baselineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Starting point")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(baselineCopy)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: AppTab.focus.tint, cornerRadius: 16, tintOpacity: 0.22)
    }

    private var baselineCopy: String {
        let chrono = String(format: "%.1f", estimate.chronologicalAge)
        let bio = String(format: "%.1f", estimate.biologicalAge)
        let absDelta = abs(estimate.delta)
        let direction: String
        if estimate.delta <= -0.25 {
            direction = String(format: "we subtracted %.1f years", absDelta)
        } else if estimate.delta >= 0.25 {
            direction = String(format: "we added %.1f years", absDelta)
        } else {
            direction = "the net change was about zero"
        }
        return "Starting from your chronological age of \(chrono), \(direction) for the inputs below, landing at a biological age of \(bio)."
    }

    @ViewBuilder
    private var factorSections: some View {
        let groups = groupedFactors
        if groups.isEmpty {
            Text("Not enough inputs yet to break down the estimate.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(groups, id: \.factor) { group in
                FactorSection(factor: group.factor, readings: group.readings, estimate: estimate)
            }
        }
    }

    private struct FactorGroup {
        let factor: BioFactor
        let readings: [BioInputReading]
    }

    private var groupedFactors: [FactorGroup] {
        let live = estimate.readings.filter { !$0.suppressedByDownstream }
        let grouped = Dictionary(grouping: live) { $0.factor }
        return grouped
            .map { FactorGroup(factor: $0.key, readings: $0.value.sorted { abs($0.rawYearsImpact) > abs($1.rawYearsImpact) }) }
            .sorted { $0.factor.displayOrder < $1.factor.displayOrder }
    }

    private var suppressedReadings: [BioInputReading] {
        estimate.readings.filter { $0.suppressedByDownstream }
    }

    // MARK: Sharpen suggestions

    /// Signals we'd most like to see if they're missing. Matches the high-value
    /// markers called out in the task spec.
    private static let highValueSignals: [BioSignal] = [
        .apoB, .hba1c, .hsCrp, .hdl, .vo2Max, .waist
    ]

    private var sharpenSuggestions: [BioSignal] {
        let present = Set(estimate.readings.map { $0.signal })
        return Self.highValueSignals.filter { !present.contains($0) }
    }

    private func handleSharpenTap(_ signal: BioSignal) {
        switch signal.presentationDomain {
        case .bloodwork:
            services.selectedTab = .bloodwork
            dismiss()
        case .bodyComposition, .sleep, .strength, .nicotine, .alcohol,
             .protein, .fiber, .omega3, .dental, .bloodPressure:
            // No in-app destination for these domains anymore (Track tab removed).
            break
        case .cardio:
            // Cardio signals (VO2 max, RHR, HRV) come from Apple Health rather
            // than in-app logging — deep-link out so the user can connect or
            // record the missing source.
            openURL(AppleHealthLink.url)
            dismiss()
        }
    }
}

// MARK: - Per-factor section

private struct FactorSection: View {
    let factor: BioFactor
    let readings: [BioInputReading]
    let estimate: BioAgeEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(factor.displayName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            VStack(spacing: 8) {
                ForEach(readings, id: \.signal) { reading in
                    LeverRow(reading: reading, estimate: estimate)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 14)
        }
    }
}

// MARK: - Single reading row

private struct LeverRow: View {
    let reading: BioInputReading
    let estimate: BioAgeEstimate

    /// Minimum |Δyears| to surface the sensitivity caption. Below this the
    /// number adds noise more than insight (e.g. signals near a factor cap, or
    /// signals whose effective weight is small relative to other readings in
    /// the same factor).
    private static let sensitivityDisplayThreshold: Double = 0.1

    private var accent: Color {
        if reading.rawYearsImpact < -0.25 { return .green }
        if reading.rawYearsImpact >  0.25 { return .orange }
        return .secondary
    }

    /// Sensitivity caption — only surfaced on fitness rows for now (the
    /// engineering-flavoured signals where a local-slope readout reads as
    /// "tunable lever"). Hidden when below the display threshold.
    private var sensitivityCaption: String? {
        guard reading.signal.factor == .fitness else { return nil }
        guard let dDelta = estimate.sensitivity(of: reading.signal) else { return nil }
        guard abs(dDelta) >= Self.sensitivityDisplayThreshold else { return nil }
        let sign = dDelta < 0 ? "−" : "+"
        return String(format: "10%% better → %@%.1f y on delta", sign, abs(dDelta))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: reading.signal.presentationDomain.systemImageName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(accent)
                .glassEffect(.regular.tint(accent.opacity(0.22)), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(reading.signal.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !valueDetail.isEmpty {
                    Text(valueDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = reading.processingNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let caption = sensitivityCaption {
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                ZScoreBar(zScore: reading.zScore, accent: accent)
                YearsBadgeLabel(years: reading.rawYearsImpact, accent: accent)
            }
        }
    }

    private var valueDetail: String {
        // Flat-penalty signals (nicotine, alcohol) have no meaningful reference
        // mean — and the signal name is already shown in the row label, so we
        // suppress the secondary line entirely.
        if reading.signal == .nicotine || reading.signal == .alcohol {
            return ""
        }
        let valueStr = formatValue(reading.value, signal: reading.signal)
        let meanStr = formatValue(reading.referenceMean, signal: reading.signal)
        return "\(valueStr) · typical \(meanStr)"
    }

    private func formatValue(_ v: Double, signal: BioSignal) -> String {
        switch signal {
        case .hba1c:            return String(format: "%.1f%%", v)
        case .hsCrp:            return String(format: "%.1f", pow(10, v))   // engine stores log10
        case .hrv, .rhr,
             .apoB, .ldl, .hdl, .fastingGlucose, .eGFR, .alt,
             .bloodPressure,
             .vo2Max, .dailySteps, .exerciseMinutes, .waist:
            return String(format: "%.0f", v)
        case .fastingInsulin, .trigHdlRatio,
             .homocysteine, .sleep, .nutrition, .weightTrend:
            return String(format: "%.1f", v)
        case .strengthSessions: return String(format: "%.0f", v)
        case .nicotine, .alcohol: return ""
        }
    }
}

// MARK: - Suppressed levers (Layer A zeroed)

private struct SuppressedLeversSection: View {
    let readings: [BioInputReading]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Levers")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Currently not counted because recent measurements already reflect them")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(readings, id: \.signal) { reading in
                        SuppressedLeverRow(reading: reading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }
}

private struct SuppressedLeverRow: View {
    let reading: BioInputReading

    private var explanation: String {
        // Generic phrasing — Layer A may suppress against bloodwork or fresh
        // fitness signals (VO2 / RHR / HRV), so we no longer name a specific
        // downstream marker here.
        let signalName = reading.signal.displayName
        return "\(signalName) — your recent measurements already capture the effect of this behavior on your bio-age. It's still worth fixing — see the drivers map for guidance."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: reading.signal.presentationDomain.systemImageName)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .glassEffect(.regular.tint(Color.secondary.opacity(0.18)), in: Circle())
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sharpen-your-estimate footer

private struct SharpenSection: View {
    let suggestions: [BioSignal]
    let onTap: (BioSignal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sharpen your estimate")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { signal in
                    SharpenInputRow(signal: signal) {
                        onTap(signal)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 14)
        }
    }
}

private struct SharpenInputRow: View {
    let signal: BioSignal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: signal.presentationDomain.systemImageName)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(AppTab.focus.tint)
                    .glassEffect(.regular.tint(AppTab.focus.tint.opacity(0.22)), in: Circle())
                Text(suggestionCopy)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var suggestionCopy: String {
        switch signal {
        case .apoB:   return "Add a recent ApoB to sharpen the lipids factor."
        case .hba1c:  return "Log HbA1c to sharpen the metabolic factor."
        case .hsCrp:  return "Add hs-CRP to capture inflammation."
        case .hdl:    return "Log HDL-C to round out lipid coverage."
        case .vo2Max: return "Record a VO2 max workout to sharpen cardio fitness."
        case .waist:  return "Log waist circumference to sharpen body composition."
        default:      return "Add \(signal.displayName) to sharpen your estimate."
        }
    }
}

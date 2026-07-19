import Foundation
import HealthKit

/// Result of evaluating a single marker against the research-backed band data.
struct BloodworkEvaluation {
    let flag: BloodworkFlag
    let band: BloodworkMarkerEntry.Variant.Band?
    let variant: BloodworkMarkerEntry.Variant?
    let parsedValue: Double?
    /// Set when the engine declined to flag the marker (e.g. hs-CRP during an
    /// acute illness, custom marker with no JSON entry, value couldn't be parsed).
    /// Drives a small caption in the UI explaining why no colour is shown.
    let suppressedReason: String?

    var entry: BloodworkMarkerEntry? {
        guard let band = band else { return nil }
        // band lookup happens after entry lookup, but we don't pass entry through;
        // callers that need the full entry should resolve from BloodworkResearch.
        _ = band
        return nil
    }

    static let unknown = BloodworkEvaluation(
        flag: .unknown,
        band: nil,
        variant: nil,
        parsedValue: nil,
        suppressedReason: nil
    )
}

/// Stateless engine that maps a marker reading (name + value string + unit + user
/// profile + per-panel context) onto a band from the research JSON. The output
/// flag is what the rest of the app stores and renders.
enum BloodworkEvaluator {

    /// Markers whose values are biologically meaningless during acute illness
    /// or injury (acute-phase reactants). When the user has flagged the panel
    /// as drawn during sickness, we suppress good/borderline/bad colouring on
    /// these and surface a "interpret with caution" caption instead.
    private static let acutePhaseSuppressed: Set<String> = [
        "hs-crp", "ferritin", "albumin"
    ]

    static func evaluate(
        markerName: String,
        rawValue: String,
        unit: String?,
        sex: HKBiologicalSex,
        dateOfBirth: Date?,
        acutePhaseAtDraw: Bool,
        referenceDate: Date = .now
    ) -> BloodworkEvaluation {

        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }

        let parsed = parseNumeric(trimmed)
        guard let entry = BloodworkResearch.entry(for: markerName) else {
            return BloodworkEvaluation(
                flag: .unknown,
                band: nil,
                variant: nil,
                parsedValue: parsed,
                suppressedReason: "Not in marker library — value stored without a reference range."
            )
        }

        if acutePhaseAtDraw, acutePhaseSuppressed.contains(entry.id) {
            return BloodworkEvaluation(
                flag: .unknown,
                band: nil,
                variant: nil,
                parsedValue: parsed,
                suppressedReason: "Acute-phase reactant — value is unreliable during illness or injury."
            )
        }

        guard let value = parsed else {
            return BloodworkEvaluation(
                flag: .unknown,
                band: nil,
                variant: nil,
                parsedValue: nil,
                suppressedReason: "Could not read this as a number — value stored as text."
            )
        }

        let normalised = normalise(value: value, fromUnit: unit, entry: entry)
        let age = age(from: dateOfBirth, on: referenceDate)
        let variant = pickVariant(entry: entry, sex: sex, age: age)
        guard let band = band(in: variant, for: normalised) else {
            return BloodworkEvaluation(
                flag: .unknown,
                band: nil,
                variant: variant,
                parsedValue: normalised,
                suppressedReason: nil
            )
        }
        return BloodworkEvaluation(
            flag: flag(from: band.status),
            band: band,
            variant: variant,
            parsedValue: normalised,
            suppressedReason: nil
        )
    }

    // MARK: - Numeric parsing

    /// Accepts "5.2", "5,2", "  108 ". Rejects "<5", "negative", "trace" — those
    /// stay as text and the marker is flagged unknown.
    static func parseNumeric(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    // MARK: - Unit normalisation

    /// If the user entered a value in an alternate unit listed in the JSON,
    /// convert it back to the primary unit so the bands apply. Conversion
    /// uses the JSON's `factor` field: primary × factor = alternate, so
    /// alternate ÷ factor = primary.
    private static func normalise(
        value: Double,
        fromUnit unit: String?,
        entry: BloodworkMarkerEntry
    ) -> Double {
        guard let unit = unit?.trimmingCharacters(in: .whitespaces),
              !unit.isEmpty,
              unit.caseInsensitiveCompare(entry.unit.primary) != .orderedSame
        else { return value }
        if let alt = entry.unit.alternates.first(where: {
            $0.unit.caseInsensitiveCompare(unit) == .orderedSame
        }), alt.factor != 0 {
            return value / alt.factor
        }
        return value
    }

    // MARK: - Variant + band selection

    private static func pickVariant(
        entry: BloodworkMarkerEntry,
        sex: HKBiologicalSex,
        age: Int?
    ) -> BloodworkMarkerEntry.Variant {
        let sexKey: String? = {
            switch sex {
            case .male:   return "male"
            case .female: return "female"
            default:      return nil
            }
        }()

        let scored = entry.variants.map { variant -> (BloodworkMarkerEntry.Variant, Int) in
            var score = 0
            // Sex match: specific > any.
            if let sexKey, variant.appliesTo.sex == sexKey { score += 4 }
            else if variant.appliesTo.sex == "any" { score += 1 }
            else { return (variant, -1) } // sex specified and doesn't match → ineligible
            // Age match.
            if let age {
                let lowOK = variant.appliesTo.ageMin.map { age >= $0 } ?? true
                let highOK = variant.appliesTo.ageMax.map { age <= $0 } ?? true
                if lowOK && highOK {
                    if variant.appliesTo.ageMin != nil || variant.appliesTo.ageMax != nil {
                        score += 2
                    }
                } else {
                    return (variant, -1)
                }
            } else if variant.appliesTo.ageMin != nil || variant.appliesTo.ageMax != nil {
                // Age-constrained variant but we don't know age — ineligible.
                return (variant, -1)
            }
            return (variant, score)
        }
        let best = scored.filter { $0.1 >= 0 }.max(by: { $0.1 < $1.1 })?.0
        // Fallback: the unconditional `any` variant (always present per schema).
        return best
            ?? entry.variants.first(where: {
                $0.appliesTo.sex == "any"
                && $0.appliesTo.ageMin == nil
                && $0.appliesTo.ageMax == nil
            })
            ?? entry.variants[0]
    }

    private static func band(
        in variant: BloodworkMarkerEntry.Variant,
        for value: Double
    ) -> BloodworkMarkerEntry.Variant.Band? {
        for band in variant.bands {
            let aboveMin = band.min.map { value >= $0 } ?? true
            let belowMax = band.max.map { value < $0 } ?? true
            if aboveMin && belowMax { return band }
        }
        return variant.bands.last
    }

    // MARK: - Helpers

    private static func flag(from status: String) -> BloodworkFlag {
        switch status {
        case "good":       return .good
        case "borderline": return .borderline
        case "bad":        return .bad
        default:           return .unknown
        }
    }

    static func age(from dob: Date?, on referenceDate: Date = .now) -> Int? {
        guard let dob else { return nil }
        return Calendar.current.dateComponents([.year], from: dob, to: referenceDate).year
    }
}

// MARK: - Convenience on the marker model

extension BloodworkMarker {
    /// Re-evaluates this marker against the JSON-backed bands using the supplied
    /// profile + per-panel context, then writes the resulting flag back. Returns
    /// the full evaluation for views that want to render band position / suppressed
    /// reasons / interventions alongside the colour.
    @discardableResult
    func reevaluate(
        sex: HKBiologicalSex,
        dateOfBirth: Date?,
        acutePhaseAtDraw: Bool
    ) -> BloodworkEvaluation {
        let result = BloodworkEvaluator.evaluate(
            markerName: name,
            rawValue: value,
            unit: unit,
            sex: sex,
            dateOfBirth: dateOfBirth,
            acutePhaseAtDraw: acutePhaseAtDraw
        )
        flag = result.flag
        return result
    }
}

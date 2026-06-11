import Foundation
import SwiftData

enum BloodworkFlag: String, Codable, CaseIterable, Identifiable {
    case good
    case borderline
    case bad
    case unknown

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .good:       "Good"
        case .borderline: "Borderline"
        case .bad:        "Bad"
        case .unknown:    "Unsure"
        }
    }

    var domainStatus: DomainStatus {
        switch self {
        case .good:       .good
        case .borderline: .borderline
        case .bad:        .bad
        case .unknown:    .unknown
        }
    }
}

@Model
final class BloodworkPanel {
    var id: UUID
    var date: Date
    var labName: String?
    var notes: String?
    @Relationship(deleteRule: .cascade, inverse: \BloodworkMarker.panel)
    var markers: [BloodworkMarker]

    init(
        id: UUID = UUID(),
        date: Date = .now,
        labName: String? = nil,
        notes: String? = nil,
        markers: [BloodworkMarker] = []
    ) {
        self.id = id
        self.date = date
        self.labName = labName
        self.notes = notes
        self.markers = markers
    }

    /// Worst flag among markers — drives the recheck cadence.
    var worstFlag: BloodworkFlag {
        if markers.contains(where: { $0.flag == .bad })        { return .bad }
        if markers.contains(where: { $0.flag == .borderline }) { return .borderline }
        if markers.allSatisfy({ $0.flag == .good })            { return .good }
        return .unknown
    }
}

@Model
final class BloodworkMarker {
    var id: UUID
    var name: String
    var value: String         // free-form so units / qualifiers ("<5", "negative") work
    var unit: String?
    var referenceRange: String?
    var flagRaw: String
    var panel: BloodworkPanel?

    init(
        id: UUID = UUID(),
        name: String,
        value: String = "",
        unit: String? = nil,
        referenceRange: String? = nil,
        flag: BloodworkFlag = .unknown
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.flagRaw = flag.rawValue
    }

    var flag: BloodworkFlag {
        get { BloodworkFlag(rawValue: flagRaw) ?? .unknown }
        set { flagRaw = newValue.rawValue }
    }
}

/// Common longevity-relevant markers prefilled when starting a new panel.
/// The user can add or remove rows freely.
enum BloodworkMarkerCatalog {

    enum Tier: String, CaseIterable, Identifiable {
        case core
        case extended
        case specialized

        var id: String { rawValue }

        var title: String {
            switch self {
            case .core:        "Core panel"
            case .extended:    "Extended"
            case .specialized: "Specialized"
            }
        }

        var subtitle: String {
            switch self {
            case .core:
                "High value-per-dollar. Ask for these every time."
            case .extended:
                "Useful add-ons if budget allows or symptoms warrant."
            case .specialized:
                "Only worth ordering if you have a specific reason."
            }
        }
    }

    struct Suggestion: Identifiable {
        let id = UUID()
        let name: String
        let unit: String
        let tier: Tier
        /// One-line "what this signals" — shown inline next to the marker.
        let purpose: String
        /// Longer explanation — shown in the marker guide.
        let detail: String
    }

    static let defaults: [Suggestion] = [
        // MARK: Core

        Suggestion(
            name: "ApoB",
            unit: "mg/dL",
            tier: .core,
            purpose: "Atherogenic particles — best single lipid marker for cardiovascular risk.",
            detail: "ApoB directly counts the LDL, VLDL, and Lp(a) particles that drive plaque. Many clinicians now prefer it over LDL-C because two people with the same LDL can have very different particle counts. If you only get one lipid number, get this."
        ),
        Suggestion(
            name: "LDL-C",
            unit: "mg/dL",
            tier: .core,
            purpose: "Standard cholesterol marker; ordered by default at most labs.",
            detail: "LDL cholesterol concentration. Cheap, widely available, and what most physicians will discuss. Useful as a cross-check on ApoB. Trend over time matters more than any single value."
        ),
        Suggestion(
            name: "HDL-C",
            unit: "mg/dL",
            tier: .core,
            purpose: "Low HDL flags elevated cardiovascular risk.",
            detail: "HDL reverse-transports cholesterol back to the liver. Very low HDL is a meaningful risk signal. Very high HDL is not protective on its own — context matters."
        ),
        Suggestion(
            name: "Triglycerides",
            unit: "mg/dL",
            tier: .core,
            purpose: "Rises with insulin resistance and excess refined carbs / alcohol.",
            detail: "Fasted triglycerides above ~150 mg/dL hint at metabolic stress. The triglycerides-to-HDL ratio is a useful quick read on insulin resistance."
        ),
        Suggestion(
            name: "HbA1c",
            unit: "%",
            tier: .core,
            purpose: "3-month average blood sugar — gold standard for prediabetes screening.",
            detail: "Reflects average glucose over the prior ~3 months. Stable, less noisy than fasting glucose, and the primary test used to diagnose prediabetes (5.7–6.4%) and diabetes (≥6.5%)."
        ),
        Suggestion(
            name: "Fasting glucose",
            unit: "mg/dL",
            tier: .core,
            purpose: "Snapshot of current glucose regulation; cheap and ubiquitous.",
            detail: "Easier to misinterpret than HbA1c (a bad night's sleep or recent stress can spike it), but always included in basic panels. Pair with HbA1c."
        ),
        Suggestion(
            name: "hs-CRP",
            unit: "mg/L",
            tier: .core,
            purpose: "Systemic inflammation; predicts heart disease risk beyond lipids.",
            detail: "High-sensitivity C-reactive protein. Persistently >2 mg/L (in the absence of acute illness) is associated with elevated cardiovascular risk. Skip the test if you have an obvious acute infection — it will be misleading."
        ),

        // MARK: Extended

        Suggestion(
            name: "Fasting insulin",
            unit: "µIU/mL",
            tier: .extended,
            purpose: "Earliest signal of insulin resistance — often rises before glucose does.",
            detail: "Glucose can look normal for years while insulin climbs to keep it that way. Fasting insulin (and HOMA-IR derived from it) catches insulin resistance earlier than HbA1c. Skipped by many standard panels — usually has to be requested."
        ),
        Suggestion(
            name: "eGFR",
            unit: "mL/min",
            tier: .extended,
            purpose: "Kidney filtration rate — included in most basic panels anyway.",
            detail: "Estimated glomerular filtration rate. Declines naturally with age; a steep drop is the signal. Calculated from creatinine."
        ),
        Suggestion(
            name: "ALT",
            unit: "U/L",
            tier: .extended,
            purpose: "Liver health; elevations often flag fatty liver / metabolic syndrome.",
            detail: "Alanine aminotransferase. Mildly elevated ALT in someone with metabolic markers off-track usually points to non-alcoholic fatty liver. Cheap and almost always included in a basic metabolic panel."
        ),
        Suggestion(
            name: "Vitamin D (25-OH)",
            unit: "ng/mL",
            tier: .extended,
            purpose: "Very common deficiency, especially in winter / indoor lifestyles.",
            detail: "25-hydroxyvitamin D is the storage form. Deficiency is widespread and easy to fix. Target ~30–60 ng/mL for most adults."
        ),
        Suggestion(
            name: "TSH",
            unit: "mIU/L",
            tier: .extended,
            purpose: "Thyroid screen — explains fatigue, weight, mood changes.",
            detail: "Thyroid-stimulating hormone. Out-of-range TSH is the entry point to a thyroid workup. If TSH is off, ask for free T4 and free T3."
        ),

        // MARK: Specialized

        Suggestion(
            name: "Ferritin",
            unit: "ng/mL",
            tier: .specialized,
            purpose: "Iron stores — only order if fatigued, low energy, or heavy periods.",
            detail: "Reflects body iron stores. Low ferritin is a common, easily fixable cause of fatigue. Very high ferritin can flag inflammation or, rarely, hemochromatosis. Don't add to a standard panel without a reason."
        ),
        Suggestion(
            name: "Homocysteine",
            unit: "µmol/L",
            tier: .specialized,
            purpose: "Vascular risk add-on; often redundant if ApoB + hs-CRP are clean.",
            detail: "Elevated homocysteine has been linked to cardiovascular and cognitive risk, but the evidence is mixed and treatment (B-vitamin supplementation) hasn't reliably reduced events. Order if a clinician specifically wants it."
        ),
    ]

    static func suggestions(for tier: Tier) -> [Suggestion] {
        defaults.filter { $0.tier == tier }
    }
}

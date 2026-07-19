import Foundation

/// Decoded shape of `Resources/bloodwork_markers.json`. The file is the single
/// source of truth for marker metadata, reference bands, causes, interventions
/// and citations — everything the bloodwork section evaluates and explains.
struct BloodworkMarkerEntry: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let aliases: [String]
    let unit: Unit
    let tier: String
    let category: String
    let description: String
    let whatItSignals: String
    let variants: [Variant]
    let causesHigh: [String]
    let causesLow: [String]
    let easiestInterventions: [String]
    let sources: [Source]

    struct Unit: Codable, Hashable {
        let primary: String
        let alternates: [Alternate]

        struct Alternate: Codable, Hashable {
            let unit: String
            let factor: Double
            let note: String?
        }
    }

    struct Variant: Codable, Hashable {
        let appliesTo: AppliesTo
        let bands: [Band]

        struct AppliesTo: Codable, Hashable {
            let sex: String           // "male" | "female" | "any"
            let ageMin: Int?
            let ageMax: Int?

            enum CodingKeys: String, CodingKey {
                case sex
                case ageMin = "age_min"
                case ageMax = "age_max"
            }
        }

        struct Band: Codable, Hashable {
            let label: String
            let min: Double?
            let max: Double?
            let status: String        // "good" | "borderline" | "bad"
        }

        enum CodingKeys: String, CodingKey {
            case appliesTo = "applies_to"
            case bands
        }
    }

    struct Source: Codable, Hashable {
        let publisher: String
        let title: String
        let url: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, unit, tier, category, description, variants, sources
        case whatItSignals = "what_it_signals"
        case causesHigh = "causes_high"
        case causesLow = "causes_low"
        case easiestInterventions = "easiest_interventions"
    }
}

struct BloodworkResearchFile: Codable {
    let schemaVersion: Int
    let lastUpdated: String
    let notes: String?
    let markers: [BloodworkMarkerEntry]

    enum CodingKeys: String, CodingKey {
        case markers, notes
        case schemaVersion = "schema_version"
        case lastUpdated = "last_updated"
    }
}

enum BloodworkResearch {

    /// Loaded once at first access, kept in memory for the life of the process.
    static let all: [BloodworkMarkerEntry] = load().markers

    static let byName: [String: BloodworkMarkerEntry] = {
        var map: [String: BloodworkMarkerEntry] = [:]
        for entry in all {
            map[entry.name.lowercased()] = entry
            for alias in entry.aliases {
                map[alias.lowercased()] = entry
            }
        }
        return map
    }()

    static func entry(for markerName: String) -> BloodworkMarkerEntry? {
        byName[markerName.lowercased()]
    }

    private static func load() -> BloodworkResearchFile {
        guard let url = Bundle.main.url(forResource: "bloodwork_markers", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("bloodwork_markers.json missing from bundle")
            return BloodworkResearchFile(schemaVersion: 0, lastUpdated: "", notes: nil, markers: [])
        }
        do {
            return try JSONDecoder().decode(BloodworkResearchFile.self, from: data)
        } catch {
            assertionFailure("bloodwork_markers.json failed to decode: \(error)")
            return BloodworkResearchFile(schemaVersion: 0, lastUpdated: "", notes: nil, markers: [])
        }
    }
}

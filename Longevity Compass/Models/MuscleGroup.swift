import Foundation

/// Fixed vocabulary of muscle groups an exercise can train.
///
/// The raw values are the *exact* strings the LLM is constrained to emit when it
/// auto-classifies an exercise (see `OpenRouterClient.classifyExerciseMuscles`).
/// Keeping this a closed enum means the balance aggregation always sums into
/// deterministic buckets — free-text muscle names ("pecs" vs "chest") would break it.
enum MuscleGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case chest
    case upperBack
    case lats
    case traps
    case lowerBack
    case frontDelts
    case sideDelts
    case rearDelts
    case biceps
    case triceps
    case forearms
    case core
    case obliques
    case glutes
    case quads
    case hamstrings
    case adductors
    case calves
    case fullBody
    case cardio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chest:      "Chest"
        case .upperBack:  "Upper back"
        case .lats:       "Lats"
        case .traps:      "Traps"
        case .lowerBack:  "Lower back"
        case .frontDelts: "Front delts"
        case .sideDelts:  "Side delts"
        case .rearDelts:  "Rear delts"
        case .biceps:     "Biceps"
        case .triceps:    "Triceps"
        case .forearms:   "Forearms"
        case .core:       "Core"
        case .obliques:   "Obliques"
        case .glutes:     "Glutes"
        case .quads:      "Quads"
        case .hamstrings: "Hamstrings"
        case .adductors:  "Adductors"
        case .calves:     "Calves"
        case .fullBody:   "Full body"
        case .cardio:     "Cardio"
        }
    }

    /// Coarse bucket used for the weekly muscle-balance view.
    var region: MuscleRegion {
        switch self {
        case .chest:                                    .chest
        case .upperBack, .lats, .traps, .lowerBack:     .back
        case .frontDelts, .sideDelts, .rearDelts:       .shoulders
        case .biceps, .triceps, .forearms:              .arms
        case .core, .obliques:                          .core
        case .glutes, .quads, .hamstrings,
             .adductors, .calves:                       .legs
        case .fullBody:                                 .fullBody
        case .cardio:                                   .cardio
        }
    }

    /// Case-insensitive, punctuation-tolerant lookup so we can salvage slightly
    /// off LLM output ("front_delts", "Front Delts") without dropping it.
    static func from(loose raw: String) -> MuscleGroup? {
        let key = raw.lowercased().filter { $0.isLetter }
        return allCases.first { $0.rawValue.lowercased() == key }
    }
}

enum MuscleRegion: String, CaseIterable, Codable, Sendable {
    case chest
    case back
    case shoulders
    case arms
    case core
    case legs
    case fullBody
    case cardio

    var displayName: String {
        switch self {
        case .chest:     "Chest"
        case .back:      "Back"
        case .shoulders: "Shoulders"
        case .arms:      "Arms"
        case .core:      "Core"
        case .legs:      "Legs"
        case .fullBody:  "Full body"
        case .cardio:    "Cardio"
        }
    }
}

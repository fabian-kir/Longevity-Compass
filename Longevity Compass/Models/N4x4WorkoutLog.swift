import Foundation
import IntervalEngine
import SwiftData

enum N4x4Equipment: String, CaseIterable, Codable, Identifiable {
    case unspecified
    case stepper
    case treadmill
    case stationaryBike
    case rowingMachine
    case elliptical
    case outdoor
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unspecified: return "Not set"
        case .stepper: return "Stepper"
        case .treadmill: return "Treadmill"
        case .stationaryBike: return "Stationary bike"
        case .rowingMachine: return "Rowing machine"
        case .elliptical: return "Elliptical"
        case .outdoor: return "Outdoor"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .unspecified: return "figure.run"
        case .stepper: return "figure.stair.stepper"
        case .treadmill: return "figure.run.treadmill"
        case .stationaryBike: return "figure.indoor.cycle"
        case .rowingMachine: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .outdoor: return "figure.run"
        case .other: return "figure.mixed.cardio"
        }
    }

    var isIndoor: Bool? {
        switch self {
        case .outdoor: return false
        case .unspecified: return nil
        default: return true
        }
    }
}

enum N4x4HealthKitSaveState: String, Codable {
    case notRequested
    case requested
    case saved
    case failed
}

struct N4x4WorkoutFrame: Codable, Equatable, Identifiable {
    let capturedAt: Date
    let elapsed: TimeInterval
    let phase: PhaseKind
    let bpm: Double?
    let targetLower: Double?
    let targetUpper: Double?

    var id: Date { capturedAt }

    init(capturedAt: Date = .now, output: EngineOutput) {
        self.capturedAt = capturedAt
        self.elapsed = output.elapsed
        self.phase = output.phase
        self.bpm = output.trailingHR
        self.targetLower = output.target?.lowerBound
        self.targetUpper = output.target?.upperBound
    }

    var targetMidpoint: Double? {
        guard let targetLower, let targetUpper else { return nil }
        return (targetLower + targetUpper) / 2
    }
}

struct N4x4WorkoutDetails: Equatable {
    var equipment: N4x4Equipment = .unspecified
}

@Model
final class N4x4WorkoutLog {
    @Attribute(.unique) var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval
    var isCompleted: Bool
    var equipmentRaw: String
    var machineCalories: Double?
    var machineDistanceKilometers: Double?
    var machineSteps: Int?
    var notes: String
    var estimatedHRMax: Double?
    var averageHeartRate: Double?
    var peakHeartRate: Double?
    var targetAdherence: Double?
    var averageOneMinuteRise: Double?
    var averageOneMinuteRecovery: Double?
    var healthKitSaveStateRaw: String
    var healthKitError: String?
    @Attribute(.externalStorage) var framesData: Data

    init(
        sessionID: UUID,
        startedAt: Date,
        estimatedHRMax: Double?,
        equipment: N4x4Equipment
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = nil
        self.duration = 0
        self.isCompleted = false
        self.equipmentRaw = equipment.rawValue
        self.machineCalories = nil
        self.machineDistanceKilometers = nil
        self.machineSteps = nil
        self.notes = ""
        self.estimatedHRMax = estimatedHRMax
        self.averageHeartRate = nil
        self.peakHeartRate = nil
        self.targetAdherence = nil
        self.averageOneMinuteRise = nil
        self.averageOneMinuteRecovery = nil
        self.healthKitSaveStateRaw = N4x4HealthKitSaveState.notRequested.rawValue
        self.healthKitError = nil
        self.framesData = Data()
    }

    var equipment: N4x4Equipment {
        get { N4x4Equipment(rawValue: equipmentRaw) ?? .unspecified }
        set { equipmentRaw = newValue.rawValue }
    }

    var healthKitSaveState: N4x4HealthKitSaveState {
        get { N4x4HealthKitSaveState(rawValue: healthKitSaveStateRaw) ?? .notRequested }
        set { healthKitSaveStateRaw = newValue.rawValue }
    }

    var frames: [N4x4WorkoutFrame] {
        get {
            guard !framesData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([N4x4WorkoutFrame].self, from: framesData)) ?? []
        }
        set {
            framesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
}


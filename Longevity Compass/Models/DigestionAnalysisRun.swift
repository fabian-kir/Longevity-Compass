import Foundation
import SwiftData

/// Outcome of one Digestion Insights run (one night, or one "Run analysis now").
enum DigestionRunStatus: String, Codable {
    case running
    case ok
    case notConverged
    case insufficientData
    case cancelled
    case failed

    var label: String {
        switch self {
        case .running:          "Running"
        case .ok:               "Finished"
        case .notConverged:     "Not converged"
        case .insufficientData: "Not enough data"
        case .cancelled:        "Stopped before finishing"
        case .failed:           "Failed"
        }
    }

    /// Results of this run may be shown (B2: never from an unconverged run).
    var isShowable: Bool { self == .ok || self == .insufficientData }
}

/// One stored analysis run. The app keeps the latest run and the last showable one.
/// Seed and fingerprint are UInt64 values stored as decimal strings.
@Model
final class DigestionAnalysisRun {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var statusRaw: String
    /// Attempt number reached (1…3).
    var attempts: Int
    var seed: String
    var inputFingerprint: String
    /// Exact `AnalysisInput` of the last attempt, including config and seed.
    var inputJSON: String?
    /// `AnalysisResult` of the last attempt that returned one.
    var resultJSON: String?
    /// `RunDiagnostics` of the last attempt that returned one.
    var diagnosticsJSON: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date? = nil,
        status: DigestionRunStatus = .running,
        attempts: Int = 0,
        seed: UInt64 = 0,
        inputFingerprint: UInt64 = 0,
        inputJSON: String? = nil,
        resultJSON: String? = nil,
        diagnosticsJSON: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.statusRaw = status.rawValue
        self.attempts = attempts
        self.seed = String(seed)
        self.inputFingerprint = String(inputFingerprint)
        self.inputJSON = inputJSON
        self.resultJSON = resultJSON
        self.diagnosticsJSON = diagnosticsJSON
    }

    var status: DigestionRunStatus {
        get { DigestionRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var seedValue: UInt64 { UInt64(seed) ?? 0 }
    var fingerprintValue: UInt64 { UInt64(inputFingerprint) ?? 0 }
}

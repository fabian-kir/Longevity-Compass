import Foundation

struct ExportPayload: Encodable {
    let exportedAt: Date
    let appVersion: String
    let manualEntries: [ManualEntryDTO]
    let snapshots: [SnapshotDTO]
    let priorityHistory: [PriorityDTO]

    struct ManualEntryDTO: Encodable {
        let id: UUID
        let entryType: String
        let date: Date
        let primaryValue: Double?
        let secondaryValue: Double?
        let tertiaryValue: Double?
        let booleanValue: Bool?
        let categorical: String?
        let notes: String?
    }

    struct SnapshotDTO: Encodable {
        let id: UUID
        let metricType: String
        let value: Double
        let secondaryValue: Double?
        let unit: String
        let source: String
        let date: Date
    }

    struct PriorityDTO: Encodable {
        let id: UUID
        let generatedAt: Date
        let domain: String
        let status: String
        let trend: String
        let priorityScore: Double
        let reason: String
    }
}

enum ExportService {

    static func makePayload(store: LocalDataStore) -> ExportPayload {
        let entries = store.fetchAllManualEntries().map {
            ExportPayload.ManualEntryDTO(
                id: $0.id,
                entryType: $0.entryTypeRaw,
                date: $0.date,
                primaryValue: $0.primaryValue,
                secondaryValue: $0.secondaryValue,
                tertiaryValue: $0.tertiaryValue,
                booleanValue: $0.booleanValue,
                categorical: $0.categoricalRaw,
                notes: $0.notes
            )
        }
        let snaps = store.fetchAllSnapshots().map {
            ExportPayload.SnapshotDTO(
                id: $0.id,
                metricType: $0.metricTypeRaw,
                value: $0.value,
                secondaryValue: $0.secondaryValue,
                unit: $0.unit,
                source: $0.sourceRaw,
                date: $0.date
            )
        }
        let history = store.fetchPriorityHistory().map {
            ExportPayload.PriorityDTO(
                id: $0.id,
                generatedAt: $0.generatedAt,
                domain: $0.domainRaw,
                status: $0.statusRaw,
                trend: $0.trendRaw,
                priorityScore: $0.priorityScore,
                reason: $0.reason
            )
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return ExportPayload(
            exportedAt: .now,
            appVersion: version,
            manualEntries: entries,
            snapshots: snaps,
            priorityHistory: history
        )
    }

    static func writeJSON(_ payload: ExportPayload) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let timestamp = ISO8601DateFormatter().string(from: payload.exportedAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "longevity-compass-\(timestamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

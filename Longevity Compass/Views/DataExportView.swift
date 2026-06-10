import SwiftUI
import HealthKit

struct DataExportView: View {
    @Environment(AppServices.self) private var services

    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showExportError = false
    @State private var exportError: String?

    @State private var apiKeyInput: String = ""
    @State private var modelInput: String = ""
    @State private var apiSaved: Bool = false

    var body: some View {
        Form {
            Section("Privacy") {
                Text("All data stays on this iPhone. No cloud sync. No analytics. No account.")
                    .font(.subheadline)
            }

            Section("Apple Health") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(services.healthKit.isAvailable
                         ? (services.healthKit.authorizationRequested ? "Permissions requested" : "Not requested")
                         : "Unavailable on this device")
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Last read")
                    Spacer()
                    Text(services.healthKit.lastSyncDate.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await services.healthKit.requestAuthorization()
                        await services.refresh()
                    }
                } label: {
                    Label("Re-check Apple Health permissions", systemImage: "heart.text.square")
                }
                if let error = services.healthKit.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("OpenRouter (nutrition AI)") {
                HStack {
                    Text("API key")
                    Spacer()
                    Text(services.openRouter.hasAPIKey ? "Set" : "Not set")
                        .foregroundStyle(services.openRouter.hasAPIKey ? .green : .secondary)
                }
                SecureField("sk-or-…", text: $apiKeyInput)
                HStack {
                    Button {
                        services.openRouter.setAPIKey(apiKeyInput)
                        apiKeyInput = ""
                        apiSaved = true
                    } label: { Text("Save key") }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    if services.openRouter.hasAPIKey {
                        Button(role: .destructive) {
                            services.openRouter.setAPIKey("")
                        } label: { Text("Remove key") }
                        .buttonStyle(.bordered)
                    }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    Text(services.openRouter.model).font(.caption).foregroundStyle(.secondary)
                }
                TextField("anthropic/claude-sonnet-4.6", text: $modelInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    services.openRouter.setModel(modelInput.isEmpty ? HealthThresholds.OpenRouter.defaultModel : modelInput)
                    modelInput = ""
                } label: { Text("Update model") }
                .disabled(modelInput.isEmpty)

                if let digest = services.nutritionDigest {
                    HStack {
                        Text("Cost this month")
                        Spacer()
                        Text(String(format: "$%.4f", digest.costThisMonthUSD)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Cost all-time")
                        Spacer()
                        Text(String(format: "$%.4f", digest.costAllTimeUSD)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Text("Get a key at openrouter.ai → top right → Keys → Create. Photos and meal descriptions are sent to OpenRouter, which forwards them to the model provider you chose (Claude Sonnet 4.6 by default). Per-entry cost is calculated locally from token usage at \(String(format: "$%.2f", HealthThresholds.OpenRouter.inputUSDPerMillion))/M input + \(String(format: "$%.2f", HealthThresholds.OpenRouter.outputUSDPerMillion))/M output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let err = services.openRouter.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Notifications") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(notificationStatusLabel).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await services.notifications.requestAuthorization()
                    }
                } label: {
                    Label("Re-request permission", systemImage: "bell")
                }
            }

            Section("Export") {
                Button {
                    do {
                        let payload = ExportService.makePayload(store: services.store)
                        exportURL = try ExportService.writeJSON(payload)
                    } catch {
                        exportError = error.localizedDescription
                        showExportError = true
                    }
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Share file: \(url.lastPathComponent)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }

            Section("Danger zone") {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete all local data", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Data")
        .alert("Delete everything?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await services.deleteAllLocalData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all manual entries, snapshots, and priority history from this device. Apple Health data is untouched.")
        }
        .alert("Export failed", isPresented: $showExportError, presenting: exportError) { _ in
            Button("OK", role: .cancel) {}
        } message: { e in
            Text(e)
        }
    }

    private var notificationStatusLabel: String {
        switch services.notifications.authorizationStatus {
        case .authorized:    "Allowed"
        case .provisional:   "Allowed (quiet)"
        case .denied:        "Denied — change in Settings"
        case .notDetermined: "Not requested"
        case .ephemeral:     "Ephemeral"
        @unknown default:    "Unknown"
        }
    }
}

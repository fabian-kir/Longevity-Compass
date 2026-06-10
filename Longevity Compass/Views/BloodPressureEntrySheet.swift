import SwiftUI

struct BloodPressureEntrySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var systolicText: String = ""
    @State private var diastolicText: String = ""
    @State private var date: Date = .now
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Systolic")
                        Spacer()
                        TextField("120", text: $systolicText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("mmHg")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Diastolic")
                        Spacer()
                        TextField("80", text: $diastolicText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("mmHg")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Blood Pressure")
                } footer: {
                    Text("Enter your systolic (top) and diastolic (bottom) numbers.")
                }

                Section("Date & Time") {
                    DatePicker("Measured at", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Log Blood Pressure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let sys = Double(systolicText), let dia = Double(diastolicText) else { return false }
        return (60...250).contains(sys) && (40...150).contains(dia)
    }

    private func save() {
        guard let sys = Double(systolicText), let dia = Double(diastolicText) else { return }
        isSaving = true
        Task {
            do {
                try await services.logBloodPressure(systolic: sys, diastolic: dia, date: date)
                dismiss()
            } catch {
                errorMessage = "Could not save to Apple Health: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}

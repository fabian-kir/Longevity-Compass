import SwiftUI
import SwiftData
import PhotosUI

struct AddEditExerciseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let existing: ExerciseDef?

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var photoData: Data?
    @State private var usePhoto: Bool
    @State private var photoItem: PhotosPickerItem?

    private static let symbols: [String] = [
        "dumbbell.fill",
        "figure.strengthtraining.traditional",
        "figure.strengthtraining.functional",
        "figure.core.training",
        "figure.gymnastics",
        "figure.arms.open",
        "figure.flexibility",
        "figure.pilates",
        "figure.yoga",
        "figure.highintensity.intervaltraining",
        "figure.rowing",
        "figure.boxing",
        "figure.kickboxing",
        "figure.martial.arts",
        "figure.wrestling",
        "figure.climbing",
        "figure.jumprope",
        "bolt.fill",
        "flame.fill",
        "star.fill",
        "trophy.fill",
        "heart.fill",
        "circle.grid.3x3.fill",
        "arrow.up.circle.fill",
    ]

    init(existing: ExerciseDef? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _selectedSymbol = State(initialValue: existing?.sfSymbol ?? "dumbbell.fill")
        _photoData = State(initialValue: existing?.photoData)
        _usePhoto = State(initialValue: existing?.photoData != nil)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Exercise name", text: $name)
            }

            Section {
                Picker("Icon type", selection: $usePhoto) {
                    Text("Symbol").tag(false)
                    Text("Photo").tag(true)
                }
                .pickerStyle(.segmented)

                if usePhoto {
                    HStack(spacing: 14) {
                        if let data = photoData, let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .frame(width: 64, height: 64)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                        }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text(photoData == nil ? "Choose Photo" : "Change Photo")
                        }
                        .onChange(of: photoItem) { _, item in
                            Task {
                                photoData = try? await item?.loadTransferable(type: Data.self)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button {
                                selectedSymbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        selectedSymbol == symbol
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .foregroundStyle(selectedSymbol == symbol ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("Icon")
            }
        }
        .navigationTitle(existing == nil ? "New Exercise" : "Edit Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let photo = usePhoto ? photoData : nil
        if let ex = existing {
            ex.name = trimmed
            ex.sfSymbol = selectedSymbol
            ex.photoData = photo
        } else {
            context.insert(ExerciseDef(name: trimmed, sfSymbol: selectedSymbol, photoData: photo))
        }
        try? context.save()
        dismiss()
    }
}

import SwiftUI
import SwiftData

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.sortOrder) private var exercises: [ExerciseDef]

    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(exercises) { exercise in
                NavigationLink {
                    AddEditExerciseView(existing: exercise)
                } label: {
                    ExerciseDefRow(def: exercise)
                }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(exercises[i]) }
                try? context.save()
            }
            .onMove { from, to in
                var mutable = exercises
                mutable.move(fromOffsets: from, toOffset: to)
                for (i, ex) in mutable.enumerated() { ex.sortOrder = i }
                try? context.save()
            }
        }
        .navigationTitle("Exercises")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                AddEditExerciseView()
            }
        }
    }
}

// MARK: - Shared row

struct ExerciseDefRow: View {
    let def: ExerciseDef

    var body: some View {
        HStack(spacing: 12) {
            if let data = def.photoData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: def.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.tint(AppTab.train.tint.opacity(0.22)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(def.name)
        }
    }
}

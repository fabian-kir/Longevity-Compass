import Foundation
import SwiftData

struct WorkoutSet: Codable, Identifiable {
    var id: UUID = UUID()
    var weightKg: Double = 0
    var reps: Int = 1
}

@Model
final class ExerciseEntry {
    var date: Date
    var exerciseName: String
    var exerciseSymbol: String
    var setsData: Data

    init(date: Date = .now, name: String, symbol: String, sets: [WorkoutSet] = []) {
        self.date = date
        self.exerciseName = name
        self.exerciseSymbol = symbol
        self.setsData = (try? JSONEncoder().encode(sets)) ?? Data()
    }

    var sets: [WorkoutSet] {
        get { (try? JSONDecoder().decode([WorkoutSet].self, from: setsData)) ?? [] }
        set { setsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

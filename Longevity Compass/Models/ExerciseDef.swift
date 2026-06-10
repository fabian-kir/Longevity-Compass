import Foundation
import SwiftData

@Model
final class ExerciseDef {
    var name: String
    var sfSymbol: String
    @Attribute(.externalStorage) var photoData: Data?
    var sortOrder: Int

    init(name: String, sfSymbol: String = "dumbbell.fill", photoData: Data? = nil, sortOrder: Int = 0) {
        self.name = name
        self.sfSymbol = sfSymbol
        self.photoData = photoData
        self.sortOrder = sortOrder
    }
}

import Foundation
import SwiftData

@Model
final class ExerciseDef {
    var name: String
    var sfSymbol: String
    @Attribute(.externalStorage) var photoData: Data?
    var sortOrder: Int

    // Cumulative AI image-generation usage across all regenerations of this def.
    var imageModel: String?
    var imageInputTokens: Int?
    var imageOutputTokens: Int?
    var imageCostUSD: Double?
    var imageGeneratedAt: Date?

    init(name: String, sfSymbol: String = "dumbbell.fill", photoData: Data? = nil, sortOrder: Int = 0) {
        self.name = name
        self.sfSymbol = sfSymbol
        self.photoData = photoData
        self.sortOrder = sortOrder
    }
}

struct ExerciseImageDigest {
    let defsWithGeneratedImage: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCostUSD: Double
    let lastGeneratedAt: Date?

    static let empty = ExerciseImageDigest(
        defsWithGeneratedImage: 0,
        totalInputTokens: 0,
        totalOutputTokens: 0,
        totalCostUSD: 0,
        lastGeneratedAt: nil
    )

    init(defs: [ExerciseDef]) {
        let withCost = defs.filter { ($0.imageCostUSD ?? 0) > 0 }
        defsWithGeneratedImage = withCost.count
        totalInputTokens  = withCost.reduce(0) { $0 + ($1.imageInputTokens  ?? 0) }
        totalOutputTokens = withCost.reduce(0) { $0 + ($1.imageOutputTokens ?? 0) }
        totalCostUSD      = withCost.reduce(0) { $0 + ($1.imageCostUSD      ?? 0) }
        lastGeneratedAt   = withCost.compactMap { $0.imageGeneratedAt }.max()
    }

    init(defsWithGeneratedImage: Int, totalInputTokens: Int, totalOutputTokens: Int, totalCostUSD: Double, lastGeneratedAt: Date?) {
        self.defsWithGeneratedImage = defsWithGeneratedImage
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCostUSD = totalCostUSD
        self.lastGeneratedAt = lastGeneratedAt
    }
}

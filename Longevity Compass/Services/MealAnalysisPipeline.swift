import Foundation
import UIKit

enum MealAnalysisError: LocalizedError {
    case noNetwork
    case noUsableResult(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noNetwork:
            return "No network connection."
        case .noUsableResult(let e):
            return "Could not analyse meal: \(e.localizedDescription)"
        }
    }
}

/// Sends an intentionally captured meal photo to the AI fingerprint flow.
/// Live barcode recognition is owned separately by `MealCaptureCoordinator`.
enum MealAnalysisPipeline {

    static func analyze(image: UIImage, openRouter: OpenRouterClient) async throws -> MealFingerprintAnalysis {
        guard let jpeg = image.jpegForAnalysis() else {
            throw MealAnalysisError.noUsableResult(underlying: NSError(
                domain: "MealAnalysisPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not JPEG-encode capture."]
            ))
        }
        do {
            return try await openRouter.analyzeMealFingerprint(imageJPEG: jpeg)
        } catch {
            throw MealAnalysisError.noUsableResult(underlying: error)
        }
    }
}

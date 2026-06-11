import Foundation
import UIKit
import Vision

enum MealAnalysisOutcome {
    case barcode(OpenFoodFactsProduct)
    case aiFingerprint(MealFingerprintAnalysis)
}

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

/// Given a captured meal photo, decide whether it's a packaged product (barcode found)
/// or a plated meal (hand off to AI). Barcode detection runs locally; AI runs over the network.
enum MealAnalysisPipeline {

    static func analyze(image: UIImage, openRouter: OpenRouterClient) async throws -> MealAnalysisOutcome {
        if let barcode = await detectBarcode(in: image) {
            do {
                let product = try await OpenFoodFactsClient.lookup(barcode: barcode)
                return .barcode(product)
            } catch OpenFoodFactsError.notFound {
                // Fall through to AI: the barcode is unknown to Open Food Facts, but the
                // photo itself may still describe a meal worth analysing.
            } catch {
                // Network or parse failure on the OFF call — try AI as a fallback.
            }
        }

        guard let jpeg = image.jpegForAnalysis() else {
            throw MealAnalysisError.noUsableResult(underlying: NSError(
                domain: "MealAnalysisPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not JPEG-encode capture."]
            ))
        }
        do {
            let result = try await openRouter.analyzeMealFingerprint(imageJPEG: jpeg)
            return .aiFingerprint(result)
        } catch {
            throw MealAnalysisError.noUsableResult(underlying: error)
        }
    }

    // MARK: - Barcode detection (Vision)

    private static func detectBarcode(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation), options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest { req, _ in
                    let payload = (req.results as? [VNBarcodeObservation])?
                        .compactMap { $0.payloadStringValue }
                        .first { !$0.isEmpty }
                    cont.resume(returning: payload)
                }
                request.symbologies = [.ean13, .ean8, .upce, .code128, .code39, .qr, .pdf417]
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func cgOrientation(_ ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}

import AVFoundation
import SwiftUI
import UIKit

@Observable
@MainActor
final class MealCaptureCoordinator: NSObject {

    struct BarcodeDetection: Identifiable, Equatable, Sendable {
        let id: UUID
        let payload: String
        let detectedAt: Date
    }

    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    private(set) var authorization: Authorization = .undetermined
    private(set) var isSessionRunning: Bool = false
    private(set) var captureError: String?
    private(set) var detectedBarcode: BarcodeDetection?

    nonisolated(unsafe) let session: AVCaptureSession = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let metadataOutput = AVCaptureMetadataOutput()
    nonisolated private let sessionQueue = DispatchQueue(label: "meal.capture.session")
    nonisolated(unsafe) private var didConfigure = false
    @ObservationIgnored
    nonisolated(unsafe) private var isBarcodeDetectionEnabled = true
    @ObservationIgnored
    nonisolated(unsafe) private var barcodeStabilizer = LiveBarcodeStabilizer()

    private var captureContinuation: CheckedContinuation<UIImage, Error>?

    override init() {
        super.init()
        refreshAuthorization()
    }

    func refreshAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: authorization = .undetermined
        case .authorized:    authorization = .granted
        case .denied:        authorization = .denied
        case .restricted:    authorization = .restricted
        @unknown default:    authorization = .denied
        }
    }

    func requestAuthorization() async {
        if authorization == .undetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .granted : .denied
        }
    }

    func start() async {
        await requestAuthorization()
        guard authorization == .granted else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                Task { @MainActor in
                    self.isSessionRunning = self.session.isRunning
                    cont.resume()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            Task { @MainActor in
                self.isSessionRunning = false
            }
        }
    }

    func capturePhoto() async throws -> UIImage {
        guard authorization == .granted else {
            throw CaptureError.notAuthorized
        }
        return try await withCheckedThrowingContinuation { cont in
            captureContinuation = cont
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func consumeBarcodeDetection(id: UUID) {
        guard detectedBarcode?.id == id else { return }
        suspendBarcodeDetection()
    }

    func suspendBarcodeDetection() {
        detectedBarcode = nil
        sessionQueue.async { [weak self] in
            self?.isBarcodeDetectionEnabled = false
        }
    }

    /// Re-enables live recognition after product lookup or confirmation finishes.
    /// The stabilizer intentionally keeps the last delivered code suppressed until
    /// that code leaves the frame, preventing an immediate re-open.
    func resumeBarcodeDetection() {
        detectedBarcode = nil
        sessionQueue.async { [weak self] in
            self?.isBarcodeDetectionEnabled = true
        }
    }

    enum CaptureError: LocalizedError {
        case notAuthorized
        case captureFailed(String)
        case noImageData

        var errorDescription: String? {
            switch self {
            case .notAuthorized:        return "Camera access is not authorized."
            case .captureFailed(let m): return "Capture failed: \(m)"
            case .noImageData:          return "Capture returned no image."
            }
        }
    }

    nonisolated private func configureIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !didConfigure else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            Task { @MainActor in self.captureError = "No back camera available." }
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            let retailTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
            metadataOutput.metadataObjectTypes = retailTypes.filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }
        }

        session.commitConfiguration()
        didConfigure = true
    }
}

extension MealCaptureCoordinator: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        Task { @MainActor in
            if let error {
                captureContinuation?.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
                captureContinuation = nil
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                captureContinuation?.resume(throwing: CaptureError.noImageData)
                captureContinuation = nil
                return
            }
            captureContinuation?.resume(returning: image)
            captureContinuation = nil
        }
    }
}

extension MealCaptureCoordinator: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isBarcodeDetectionEnabled else { return }

        let payload = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap(\.stringValue)
            .first { !$0.isEmpty }

        guard let stablePayload = barcodeStabilizer.observe(payload) else { return }
        let detection = BarcodeDetection(id: UUID(), payload: stablePayload, detectedAt: .now)
        Task { @MainActor [weak self] in
            guard let self, self.detectedBarcode == nil else { return }
            self.detectedBarcode = detection
        }
    }
}

/// Requires a barcode to persist across multiple metadata callbacks and suppresses
/// repeat delivery until several empty frames confirm it has left the camera view.
nonisolated struct LiveBarcodeStabilizer {
    private var candidate: String?
    private var consecutiveMatches = 0
    private var consecutiveMisses = 0
    private var suppressedPayload: String?

    private let matchesRequired: Int
    private let missesRequiredToReset: Int

    init(matchesRequired: Int = 3, missesRequiredToReset: Int = 5) {
        self.matchesRequired = matchesRequired
        self.missesRequiredToReset = missesRequiredToReset
    }

    mutating func observe(_ payload: String?) -> String? {
        guard let payload, !payload.isEmpty else {
            consecutiveMisses += 1
            candidate = nil
            consecutiveMatches = 0
            if consecutiveMisses >= missesRequiredToReset {
                suppressedPayload = nil
            }
            return nil
        }

        consecutiveMisses = 0
        guard payload != suppressedPayload else { return nil }

        if candidate == payload {
            consecutiveMatches += 1
        } else {
            candidate = payload
            consecutiveMatches = 1
        }

        guard consecutiveMatches >= matchesRequired else { return nil }
        suppressedPayload = payload
        candidate = nil
        consecutiveMatches = 0
        return payload
    }
}

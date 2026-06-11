import AVFoundation
import SwiftUI
import UIKit

@Observable
@MainActor
final class MealCaptureCoordinator: NSObject {

    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    private(set) var authorization: Authorization = .undetermined
    private(set) var isSessionRunning: Bool = false
    private(set) var captureError: String?

    nonisolated(unsafe) let session: AVCaptureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "meal.capture.session")
    private var didConfigure = false

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

    private func configureIfNeeded() {
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

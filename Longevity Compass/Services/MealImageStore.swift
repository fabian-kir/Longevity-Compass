import Foundation
import UIKit

/// Disk store for meal photos so logged entries can show what was eaten.
/// JPEGs live in ApplicationSupport/MealImages/<uuid>.jpg.
enum MealImageStore {

    private static let fileManager = FileManager.default

    static func directory() -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("MealImages", isDirectory: true)
    }

    @discardableResult
    static func saveJPEG(_ data: Data, id: UUID = UUID()) -> String? {
        let fileName = "\(id.uuidString).jpg"
        let url = directory().appendingPathComponent(fileName)
        do {
            try ensureDirectoryExists()
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// Convenience for direct UIImage input.
    static func save(image: UIImage) -> String? {
        guard let jpeg = image.jpegForAnalysis() else { return nil }
        return saveJPEG(jpeg)
    }

    /// Move a JPEG that already exists on disk (e.g. from the pending-meal queue)
    /// into the store, returning the new filename. Falls back to copy + delete.
    static func ingest(jpegAt sourceURL: URL) -> String? {
        let fileName = "\(UUID().uuidString).jpg"
        let destination = directory().appendingPathComponent(fileName)
        do {
            try ensureDirectoryExists()
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            return fileName
        } catch {
            return nil
        }
    }

    static func image(for fileName: String?) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = directory().appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
    }

    static func delete(fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        let url = directory().appendingPathComponent(fileName)
        try? fileManager.removeItem(at: url)
    }

    static func wipeAll() {
        let dir = directory()
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try? fileManager.removeItem(at: dir)
    }

    private static func ensureDirectoryExists() throws {
        let dir = directory()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

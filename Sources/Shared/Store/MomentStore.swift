import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// Image files for moments, kept in the App Group container so the widget can
/// read them without going near the network.
///
/// Two sizes are written per moment: a full-size copy for the app and a small
/// one for the widget. Widget extensions have a hard memory ceiling, and
/// decoding a full-resolution photo there is the fastest way to get jetsammed.
struct MomentStore {
    static let shared = MomentStore()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentStore")

    /// Longest edge, in pixels.
    private static let fullMaxDimension: CGFloat = 1280
    private static let thumbMaxDimension: CGFloat = 512
    private static let fullQuality: CGFloat = 0.75
    private static let thumbQuality: CGFloat = 0.7

    var directory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) else {
            return nil
        }
        let dir = container.appendingPathComponent("Moments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func imageURL(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id).jpg")
    }

    func thumbURL(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id)-thumb.jpg")
    }

    // MARK: - Writing

    #if canImport(UIKit)
    /// Writes both sizes. Returns the JPEG data so a caller can hand it
    /// straight to CloudKit without re-reading from disk.
    @discardableResult
    func write(_ image: UIImage, id: String) throws -> (full: Data, thumb: Data) {
        guard let full = Self.jpeg(image,
                                   maxDimension: Self.fullMaxDimension,
                                   quality: Self.fullQuality),
              let thumb = Self.jpeg(image,
                                    maxDimension: Self.thumbMaxDimension,
                                    quality: Self.thumbQuality) else {
            throw MomentStoreError.encodingFailed
        }
        try write(full: full, thumb: thumb, id: id)
        return (full, thumb)
    }

    func image(for id: String) -> UIImage? {
        guard let url = imageURL(for: id) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Always prefer this in the widget.
    func thumbnail(for id: String) -> UIImage? {
        guard let url = thumbURL(for: id) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func jpeg(_ image: UIImage,
                             maxDimension: CGFloat,
                             quality: CGFloat) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1

        guard scale < 1 else { return image.jpegData(compressionQuality: quality) }

        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
    #endif

    func write(full: Data, thumb: Data, id: String) throws {
        guard let fullURL = imageURL(for: id), let thumbURL = thumbURL(for: id) else {
            throw MomentStoreError.containerUnavailable
        }
        try full.write(to: fullURL, options: .atomic)
        try thumb.write(to: thumbURL, options: .atomic)
    }

    // MARK: - Housekeeping

    func delete(id: String) {
        [imageURL(for: id), thumbURL(for: id)]
            .compactMap { $0 }
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Drops files for moments no longer in the index, so the container can't
    /// grow without bound.
    func prune(keeping ids: some Collection<String>) {
        guard let directory else { return }
        let keep = Set(ids)
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let name = url.deletingPathExtension().lastPathComponent
            let id = name.hasSuffix("-thumb") ? String(name.dropLast("-thumb".count)) : name
            if !keep.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum MomentStoreError: LocalizedError {
    case containerUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "The shared App Group container isn't available."
        case .encodingFailed:
            return "Couldn't encode that image."
        }
    }
}

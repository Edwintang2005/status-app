import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// Moment media files in the App Group container. Visual moments get a full-size
/// copy plus a widget thumbnail (widgets have a hard memory ceiling and must not
/// decode full-resolution photos); a voice memo is a single `.m4a`.
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

    /// AAC/MPEG-4: the format every Apple playback and notification API accepts.
    func audioURL(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id).m4a")
    }

    // MARK: - Writing

    #if canImport(UIKit)
    /// Writes both sizes; returns the JPEG data so callers can upload to
    /// CloudKit without re-reading from disk.
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

    /// Decoded-thumbnail cache; `NSCache` self-evicts under pressure, which
    /// matters in the widget's tight memory budget.
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    /// Always prefer this over `image(for:)` in the widget and in grids.
    func thumbnail(for id: String) -> UIImage? {
        if let cached = Self.thumbnailCache.object(forKey: id as NSString) { return cached }
        guard let url = thumbURL(for: id),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.thumbnailCache.setObject(image, forKey: id as NSString)
        return image
    }

    func hasThumbnail(for id: String) -> Bool {
        guard let url = thumbURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Evicts one decoded thumbnail; must accompany any file deletion or the
    /// cache keeps serving an image whose files are gone.
    private static func evictThumbnail(id: String) {
        thumbnailCache.removeObject(forKey: id as NSString)
    }

    static func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
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

    /// Moves a finished recording into the App Group under the moment's id
    /// (move, not copy, so the recorder's temp directory doesn't fill up).
    func adoptAudio(from source: URL, id: String) throws {
        guard let destination = audioURL(for: id) else {
            throw MomentStoreError.containerUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // Different volumes, or a source someone else still owns.
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    func writeAudio(_ data: Data, id: String) throws {
        guard let url = audioURL(for: id) else {
            throw MomentStoreError.containerUnavailable
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Housekeeping

    /// Whether the full-size image is on this device; entries older than the
    /// cache limit answer `false` until re-fetched.
    func hasImage(for id: String) -> Bool {
        guard let url = imageURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func hasAudio(for id: String) -> Bool {
        guard let url = audioURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Prefer this over `hasImage(for:)` anywhere a voice memo can turn up —
    /// a memo has no image and would look permanently unavailable.
    func hasMedia(for moment: Moment) -> Bool {
        moment.isVoice ? hasAudio(for: moment.id) : hasImage(for: moment.id)
    }

    /// The playable/loadable file, or `nil` when it isn't cached here.
    func mediaURL(for moment: Moment) -> URL? {
        guard let url = moment.isVoice ? audioURL(for: moment.id) : imageURL(for: moment.id),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func delete(id: String) {
        [imageURL(for: id), thumbURL(for: id), audioURL(for: id)]
            .compactMap { $0 }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        #if canImport(UIKit)
        Self.evictThumbnail(id: id)
        #endif
    }

    /// Throwaway copy for `UNNotificationAttachment`, which takes ownership of
    /// the file it's handed and must never get the App Group original.
    func temporaryAttachmentCopy(for moment: Moment, suffix: String) -> URL? {
        guard let source = moment.isVoice
                ? audioURL(for: moment.id)
                : thumbURL(for: moment.id),
              FileManager.default.fileExists(atPath: source.path) else { return nil }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(moment.id)-\(suffix).\(source.pathExtension)")
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: source, to: temp)
            return temp
        } catch {
            log.error("Couldn't stage attachment for \(moment.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Drops files for moments no longer in the index. Files newer than
    /// `graceInterval` are spared — media is written before its index entry, and
    /// a prune in that gap would delete the only copy. Pass 0 only for a full wipe.
    func prune(keeping ids: some Collection<String>, graceInterval: TimeInterval = 300) {
        guard let directory else { return }
        let keep = Set(ids)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents {
            let name = url.deletingPathExtension().lastPathComponent
            let id = name.hasSuffix("-thumb") ? String(name.dropLast("-thumb".count)) : name
            guard !keep.contains(id) else { continue }
            if graceInterval > 0,
               let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                   .contentModificationDate,
               Date().timeIntervalSince(modified) < graceInterval {
                continue
            }
            try? FileManager.default.removeItem(at: url)
            #if canImport(UIKit)
            Self.evictThumbnail(id: id)
            #endif
        }
    }
}

enum MomentStoreError: LocalizedError {
    case containerUnavailable
    case encodingFailed
    case audioMissing

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "The shared App Group container isn't available."
        case .encodingFailed:
            return "Couldn't encode that image."
        case .audioMissing:
            return "That recording is no longer on this device."
        }
    }
}

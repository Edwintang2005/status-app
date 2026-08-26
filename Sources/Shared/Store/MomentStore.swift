import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// Media files for moments, kept in the App Group container so the widget can
/// read them without going near the network.
///
/// Two sizes are written per visual moment: a full-size copy for the app and a
/// small one for the widget. Widget extensions have a hard memory ceiling, and
/// decoding a full-resolution photo there is the fastest way to get jetsammed.
///
/// A voice memo is a single `.m4a` instead — nothing resizes, and the widget
/// never decodes it. Its `Moment.waveform` is what gets drawn.
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

    /// AAC in an MPEG-4 container: small, and the one format every Apple
    /// playback and notification-attachment API accepts without conversion.
    func audioURL(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id).m4a")
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

    /// Decoded thumbnails, so scrolling the library grid isn't re-reading and
    /// re-decoding the same JPEGs. `NSCache` evicts itself under pressure,
    /// which matters in the widget's tight memory budget.
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

    /// Moves a finished recording out of wherever it was captured and into the
    /// App Group under the moment's id. A move rather than a copy: the
    /// recorder's temporary file has no other reader, and leaving a duplicate
    /// behind is how a temp directory quietly fills up.
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

    /// Whether the full-size image is on this device. History entries older
    /// than the cache limit will answer `false` until re-fetched.
    func hasImage(for id: String) -> Bool {
        guard let url = imageURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func hasAudio(for id: String) -> Bool {
        guard let url = audioURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The file this moment actually needs, whichever kind it is. Prefer this
    /// over `hasImage(for:)` anywhere a voice memo can turn up — a memo has no
    /// image and would otherwise look permanently unavailable.
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
    }

    /// A throwaway copy for `UNNotificationAttachment`, which takes ownership
    /// of whatever file it's handed and must never be given the App Group
    /// original. Audio attaches too — it's what puts a play button on the
    /// expanded notification for a voice memo.
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

    /// Drops files for moments no longer in the index, so the container can't
    /// grow without bound. Extension-agnostic on purpose: one moment may own a
    /// `.jpg` pair or a single `.m4a`, and both are keyed by the same id.
    ///
    /// Files newer than `graceInterval` are off limits: the app writes a
    /// moment's media *before* it records the index entry, and a push-driven
    /// prune in the notification extension can land in that gap — deleting a
    /// just-captured voice memo whose only copy this is. Pass `0` only when
    /// the intent is a full wipe.
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

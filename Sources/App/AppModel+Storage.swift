import Foundation
import os

// Settings' "Downloaded media": what this iPhone keeps of moments iCloud still holds.
extension AppModel {
    /// Not while an archive runs: it fetches missing media, then copies it,
    /// and a clear in between would leave its photos unrecovered.
    var canClearDownloadedMedia: Bool { archiveProgress == nil && !isClearingMedia }

    /// Bytes "Clear downloaded media" would free: moment files outside
    /// `Outbox.mediaToKeep`, plus this app's temporary leftovers. `nil` when
    /// the index can't be read.
    func downloadedMediaSize() async -> Int? {
        guard let keep = outbox.mediaToKeep() else { return nil }
        let spared = archiveToShare
        return await Task.detached(priority: .utility) {
            MomentStore.shared.downloadedSize(keeping: keep)
                + AppModel.leftovers(sparing: spared).reduce(0) { $0 + $1.bytes }
        }.value
    }

    /// Full photos and memos are fetched back from iCloud when opened. Returns
    /// the bytes freed, or `nil` with the reason presented.
    func clearDownloadedMedia() async -> Int? {
        guard canClearDownloadedMedia else { return nil }
        isClearingMedia = true
        defer { isClearingMedia = false }
        guard let keep = outbox.mediaToKeep() else {
            errorTitle = String(localized: "Couldn't clear downloaded media")
            errorMessage = String(localized: "Your history couldn't be read just now, so nothing was removed. Try again in a moment.")
            return nil
        }
        let spared = archiveToShare
        let freed = await Task.detached(priority: .userInitiated) {
            let leftovers = AppModel.leftovers(sparing: spared)
            let removed = leftovers.filter { (try? FileManager.default.removeItem(at: $0.url)) != nil }
            return MomentStore.shared.clearDownloaded(keeping: keep) + removed.reduce(0) { $0 + $1.bytes }
        }.value
        log.notice("Cleared \(freed) bytes of downloaded media.")
        reload()
        return freed
    }

    /// This app's temporary files past the grace window — notification
    /// attachment copies, abandoned recordings, finished archives — except a
    /// device-only archive still waiting to be shared (`archiveToShare`).
    nonisolated private static func leftovers(sparing archive: URL?,
                                              graceInterval: TimeInterval = 300,
                                              now: Date = Date()) -> [(url: URL, bytes: Int)] {
        let fileManager = FileManager.default
        let spared = archive?.resolvingSymlinksInPath().path
        let entries = (try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries.compactMap { url in
            let path = url.resolvingSymlinksInPath().path
            if let spared, spared == path || spared.hasPrefix(path + "/") { return nil }
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) < graceInterval { return nil }
            return (url, size(of: url))
        }
    }

    nonisolated private static func size(of url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return values.fileSize ?? 0
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: keys) } }
            .filter { $0.isRegularFile == true }
            .reduce(0) { $0 + ($1.fileSize ?? 0) }
    }
}

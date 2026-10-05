import Foundation
import os

/// The full moment history, as a JSON file in the App Group. Kept out of
/// `Snapshot` so widget renders stay small. Entries are metadata only; media
/// files live in `MomentStore` and may not be on this device.
/// `@unchecked`: the file, `readFailed` and the cache are only touched under
/// `lock` (the getter is for tests).
final class MomentIndex: @unchecked Sendable {
    static let shared = MomentIndex()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentIndex")
    /// App and notification extension both write. `lock` guards in-process;
    /// `crossLock` stops a concurrent cross-process load→modify→save from
    /// dropping the other side's insert for good.
    private let lock = NSLock()
    private let crossLock: CrossProcessLock
    private let fileURL: URL?
    /// Runs when the file is found corrupt; the default clears the CloudKit
    /// change tokens so the next refresh rebuilds the index from the zone.
    private let onCorrupt: () -> Void
    /// The file exists but couldn't be read (data protection before first
    /// unlock, an I/O error). Writing then would replace the whole history with
    /// one delta, and pruning against it would delete media, so both wait.
    private(set) var readFailed = false
    /// The last list read or written, keyed by the file's identity: a refresh
    /// loads the index several times, and only another process's write (an
    /// atomic replace, so a new inode and mtime) makes decoding it again worth it.
    private var cache: (key: FileKey, moments: [Moment])?

    private struct FileKey: Equatable {
        let modified: Date?
        let size: Int?
        let inode: Int?
    }

    /// Waveforms as bytes: the index is rewritten whole on every change.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[Moment.compactWaveformsKey] = true
        return encoder
    }()

    /// `fileURL` defaults to the App Group file; tests pass a temporary one.
    init(fileURL: URL? = nil, onCorrupt: (() -> Void)? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("moments-index.json")
        // Beside the file: the container root in production, a test's own directory in tests.
        self.crossLock = CrossProcessLock(name: "moments-index.lock",
                                          directory: self.fileURL?.deletingLastPathComponent())
        self.onCorrupt = onCorrupt ?? {
            for key in ["private", "shared"] { SharedStore.shared.setChangeToken(nil, for: key) }
        }
    }

    /// Newest first.
    func load() -> [Moment] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// `nil` when the file exists but couldn't be read, judged under the lock.
    func loadReadable() -> [Moment]? {
        lock.lock()
        defer { lock.unlock() }
        let all = loadUnlocked()
        return readFailed ? nil : all
    }

    private func fileKey(_ url: URL) -> FileKey? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileKey(modified: attributes[.modificationDate] as? Date,
                       size: (attributes[.size] as? NSNumber)?.intValue,
                       inode: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }

    /// `writing` only under `crossLock`: entries that failed to decode are then
    /// dealt with for good — bytes kept, the zone asked to refill them, the
    /// rest saved — where a plain read just leaves the file be.
    private func loadUnlocked(writing: Bool = false) -> [Moment] {
        guard let fileURL else { return [] }
        let key = fileKey(fileURL)
        if let key, let cache, cache.key == key {
            readFailed = false
            return cache.moments
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
            readFailed = false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            readFailed = false
            cache = nil
            return []
        } catch {
            readFailed = true
            cache = nil
            log.error("Moment index unreadable, leaving it untouched: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decoded: LossyArray<Moment>
        do {
            decoded = try JSONDecoder.shared.decode(LossyArray<Moment>.self, from: data)
        } catch {
            log.error("Corrupt moment index: \(error.localizedDescription)")
            // Preserve the bytes rather than letting the next save overwrite them,
            // then clear the sync cursors so the next refresh pulls the whole zone
            // and rebuilds the index from CloudKit.
            let sidecar = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.moveItem(at: fileURL, to: sidecar)
            cache = nil
            onCorrupt()
            return []
        }
        guard decoded.dropped == 0 else {
            // One bad entry costs itself, not the history — and never the
            // unsent sends beside it, which exist nowhere else.
            log.error("Moment index: \(decoded.dropped) unreadable entries skipped.")
            if writing {
                try? data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
                onCorrupt()
                saveUnlocked(decoded.elements)
            }
            return decoded.elements
        }
        if let key { cache = (key, decoded.elements) }
        return decoded.elements
    }

    private func saveUnlocked(_ moments: [Moment]) {
        guard let fileURL, !readFailed else { return }
        do {
            // The cap never drops a send still waiting to upload: it has no
            // cloud copy, and leaving the index takes it out of the retry queue.
            let pendingBeyondCap = moments.dropFirst(AppConfig.momentHistoryLimit)
                .filter { $0.fromMe && !$0.uploaded }
            let trimmed = Array(moments.prefix(AppConfig.momentHistoryLimit)) + pendingBeyondCap
            try Self.encoder.encode(trimmed).write(to: fileURL, options: .atomic)
            cache = fileKey(fileURL).map { ($0, trimmed) }
        } catch {
            cache = nil
            log.error("Failed to write moment index: \(error.localizedDescription)")
        }
    }

    /// Newest first; ties by id, so the order never depends on how a merge went.
    private static func newestFirst(_ a: Moment, _ b: Moment) -> Bool {
        a.sentAt != b.sentAt ? a.sentAt > b.sentAt : a.id > b.id
    }

    /// Inserts or replaces by id, keeping the list ordered newest first.
    @discardableResult
    func insert(_ moments: [Moment]) -> [Moment] {
        insertReadable(moments) ?? moments
    }

    /// The same, but `nil` when the file couldn't be read — judged under the
    /// lock, so a caller never prunes media against a delta-only list.
    /// `cleared` is built *inside* the lock: a fresh start another process
    /// committed and purged after this delta was parsed still keeps its
    /// history out (`FreshStartPolicy.clearedFilter`).
    func insertReadable(_ moments: [Moment], cleared: (() -> (Moment) -> Bool)? = nil) -> [Moment]? {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            var byID: [String: Moment] = [:]
            for moment in loadUnlocked(writing: true) where byID[moment.id] == nil { byID[moment.id] = moment }
            let isCleared = cleared?() ?? { _ in false }
            for moment in moments where !isCleared(moment) {
                var moment = moment
                // `seen` is local-only; a full resync re-inserts everything, and
                // without this merge heard voice memos would re-badge as new.
                if let existing = byID[moment.id] {
                    moment.seen = moment.seen || existing.seen
                    // All local-only fields are sticky: a copy rebuilt from a
                    // CloudKit record carries none of them, and every delta that
                    // re-delivers a moment (own-send echoes, full resyncs) would
                    // otherwise wipe seen times and partner receipts.
                    moment.seenAt = moment.seenAt ?? existing.seenAt
                    moment.seenByPartnerAt = moment.seenByPartnerAt ?? existing.seenByPartnerAt
                    moment.uploaded = moment.uploaded || existing.uploaded
                    // Moments never change after sending, so words already held
                    // beat a copy that arrived with its encrypted fields empty.
                    if moment.caption.isEmpty { moment.caption = existing.caption }
                    if moment.senderName.isEmpty { moment.senderName = existing.senderName }
                    if moment.waveform.isEmpty { moment.waveform = existing.waveform }
                }
                byID[moment.id] = moment
            }
            var all = Array(byID.values)
            // A date a skewed clock stamped in the future would pin that entry
            // as newest for good; healed to now, which keeps it in place today.
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            for index in all.indices where TrustedTime.isFuture(all[index].sentAt, now: now) {
                all[index].sentAt = now
            }
            all.sort(by: Self.newestFirst)
            saveUnlocked(all)
            return readFailed ? nil : all
        }
    }

    /// Marks entries as looked-at. Returns the updated list.
    @discardableResult
    func markSeen(ids: some Collection<String>) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            let targets = Set(ids)
            var all = loadUnlocked(writing: true)
            var changed = false
            // Whole seconds, like every persisted date: the value is compared
            // against its own ISO-8601 copy once it comes back in a receipt.
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            for index in all.indices where targets.contains(all[index].id) && !all[index].seen {
                all[index].seen = true
                all[index].seenAt = now
                changed = true
            }
            if changed { saveUnlocked(all) }
            return all
        }
    }

    /// Folds the partner's read receipts into own moments. Sticky: a receipt
    /// map shrinking (capped, or receipts turned off) never un-sees anything.
    @discardableResult
    func applyPartnerReceipts(_ map: [String: Date]) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            var all = loadUnlocked(writing: true)
            var changed = false
            for index in all.indices where all[index].fromMe {
                guard let seenAt = map[all[index].id],
                      all[index].seenByPartnerAt != seenAt else { continue }
                all[index].seenByPartnerAt = seenAt
                changed = true
            }
            if changed { saveUnlocked(all) }
            return all
        }
    }

    /// Marks entries as safely on the server. Returns the updated list.
    @discardableResult
    func markUploaded(ids: some Collection<String>) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            let targets = Set(ids)
            var all = loadUnlocked(writing: true)
            var changed = false
            for index in all.indices where targets.contains(all[index].id) && !all[index].uploaded {
                all[index].uploaded = true
                changed = true
            }
            if changed { saveUnlocked(all) }
            return all
        }
    }

    /// After a full-zone fetch: own moments marked uploaded that the zone did
    /// not return were never stored (a save whose failure went unnoticed) and
    /// go back in the retry queue. Only those whose media is still here — a
    /// pending entry without media is dropped by the retry as a ghost, and the
    /// local copy is all that's left of these. Sends from before a fresh
    /// start's epoch (`clearedBefore`) were cleared, not lost, and stay out.
    /// Returns what was re-queued.
    @discardableResult
    func requeueMissingUploads(delivered: Set<String>,
                               hasMedia: (Moment) -> Bool,
                               clearedBefore: Date? = nil) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            var all = loadUnlocked(writing: true)
            var requeued: [Moment] = []
            for index in all.indices
            where all[index].fromMe && all[index].uploaded
                && !delivered.contains(all[index].id)
                && all[index].sentAt >= (clearedBefore ?? .distantPast)
                && hasMedia(all[index]) {
                all[index].uploaded = false
                requeued.append(all[index])
            }
            if !requeued.isEmpty { saveUnlocked(all) }
            return requeued
        }
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        crossLock.withLock {
            var all = loadUnlocked(writing: true)
            all.removeAll { $0.id == id }
            saveUnlocked(all)
        }
    }

    /// One lock for many — a fresh start's local clear.
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        crossLock.withLock {
            var all = loadUnlocked(writing: true)
            let before = all.count
            all.removeAll { ids.contains($0.id) }
            if all.count != before { saveUnlocked(all) }
        }
    }

    func knownIDs() -> Set<String> {
        Set(load().map(\.id))
    }

    /// Drops everything except own sends that never reached CloudKit — the
    /// one thing a wipe can't get back from the zone. Returns what was kept.
    @discardableResult
    func retainPendingUploads() -> [Moment] {
        lock.lock()
        defer { lock.unlock() }
        return crossLock.withLock {
            let kept = loadUnlocked(writing: true).filter { $0.fromMe && !$0.uploaded }
            saveUnlocked(kept)
            return kept
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        // Locked: an extension's in-flight `insert` could otherwise rewrite the
        // file right after the delete, undoing the wipe.
        crossLock.withLock {
            // The sidecars too: salvage must never bring an ex's unsent sends back.
            let sidecar = fileURL.appendingPathExtension("corrupt")
            for url in [fileURL, sidecar, sidecar.appendingPathExtension("salvaged")] {
                try? FileManager.default.removeItem(at: url)
            }
            cache = nil
        }
    }

    /// Own sends an older build's strict decode took with it into the `.corrupt`
    /// sidecar: those whose media is still here go back in the retry queue.
    /// Looked at once — the sidecar is then kept as `.corrupt.salvaged`.
    @discardableResult
    func salvagePendingUploads(hasMedia: (Moment) -> Bool) -> [Moment] {
        guard let fileURL else { return [] }
        let sidecar = fileURL.appendingPathExtension("corrupt")
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return crossLock.withLock {
            guard let data = try? Data(contentsOf: sidecar) else { return [] }
            var all = loadUnlocked(writing: true)
            guard !readFailed else { return [] }
            let known = Set(all.map(\.id))
            let salvaged = ((try? JSONDecoder.shared.decode(LossyArray<Moment>.self, from: data))?.elements ?? [])
                .filter { $0.fromMe && !$0.uploaded && !known.contains($0.id) && hasMedia($0) }
            let done = sidecar.appendingPathExtension("salvaged")
            try? FileManager.default.removeItem(at: done)
            try? FileManager.default.moveItem(at: sidecar, to: done)
            guard !salvaged.isEmpty else { return [] }
            all += salvaged
            all.sort(by: Self.newestFirst)
            saveUnlocked(all)
            log.notice("Recovered \(salvaged.count) unsent moment(s) from a corrupt index.")
            return salvaged
        }
    }
}

/// Decodes an array element by element, skipping any that fail: one bad entry
/// (or one a newer build wrote) costs itself, not the whole file.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var dropped = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try container.decode(Lossy.self).value {
                elements.append(element)
            } else {
                dropped += 1
            }
        }
    }

    /// Always decodes, so the container moves past a bad element.
    private struct Lossy: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }
}

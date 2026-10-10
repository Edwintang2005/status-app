import Foundation
import os

/// One entry in the rolling status log.
struct StatusHistoryEntry: Codable, Hashable, Identifiable {
    var emoji: String
    var message: String
    var isCelebration: Bool
    /// The status's `wordsAt` in whole seconds — the dedup key alongside
    /// `fromMe`. Whole, since ISO-8601 JSON drops fractions and a fractional
    /// date never equals its own stored copy (invariant 14).
    var at: Date
    var fromMe: Bool

    var id: String { "\(fromMe ? "me" : "them")-\(at.timeIntervalSince1970)" }

    init(emoji: String, message: String, isCelebration: Bool, at: Date, fromMe: Bool) {
        self.emoji = emoji
        self.message = message
        self.isCelebration = isCelebration
        self.at = at.wholeSeconds
        self.fromMe = fromMe
    }

    init(_ payload: StatusPayload, fromMe: Bool) {
        self.init(emoji: payload.emoji,
                  message: payload.message,
                  isCelebration: payload.isCelebration,
                  // When the words were set, like the `StatusLog` record's name.
                  at: payload.wordsAt,
                  fromMe: fromMe)
    }

    private enum CodingKeys: String, CodingKey {
        case emoji, message, isCelebration, at, fromMe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "💭"
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        isCelebration = try container.decodeIfPresent(Bool.self, forKey: .isCelebration) ?? false
        at = try container.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        fromMe = try container.decodeIfPresent(Bool.self, forKey: .fromMe) ?? false
    }
}

/// Rolling log of both sides' statuses, as a JSON file in the App Group. Fed
/// from two sources that dedup into one entry: the current `Status` record as
/// it changes, and the per-change `StatusLog` records, which is what makes the
/// log come back on a reinstall. Written from every process that notices a
/// status change, hence the cross-process lock; dedup is by `(fromMe, at)`.
/// `@unchecked`: the file, `readFailed` and the cache are only touched under `lock`.
final class StatusHistoryLog: @unchecked Sendable {
    static let shared = StatusHistoryLog()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "StatusHistoryLog")
    private let lock = NSLock()
    private let crossLock: CrossProcessLock
    private let fileURL: URL?
    /// Runs when entries are lost to corruption; the default clears the
    /// CloudKit change tokens so the next refresh re-fetches the `StatusLog` records.
    private let onCorrupt: () -> Void
    /// The file exists but couldn't be read (before first unlock, an I/O
    /// error): nothing is saved over it — only the newest 150 a side come
    /// back from the zone — like `MomentIndex.readFailed`.
    private(set) var readFailed = false
    /// The last list read or written, by file identity, like `MomentIndex`'s.
    private var cache: (key: FileIdentity, entries: [StatusHistoryEntry])?

    /// `fileURL` defaults to the App Group file; tests pass a temporary one.
    init(fileURL: URL? = nil, onCorrupt: (() -> Void)? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("status-history.json")
        // Beside the file: the container root in production, a test's own directory in tests.
        self.crossLock = CrossProcessLock(name: "status-history.lock",
                                          directory: self.fileURL?.deletingLastPathComponent())
        self.onCorrupt = onCorrupt ?? {
            SharedStore.shared.clearChangeTokens()
        }
    }

    /// Newest first.
    func load() -> [StatusHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// `nil` when the file exists but couldn't be read, judged under the lock.
    func loadReadable() -> [StatusHistoryEntry]? {
        lock.lock()
        defer { lock.unlock() }
        let all = loadUnlocked()
        return readFailed ? nil : all
    }

    /// Appends the payload unless an entry with the same `(fromMe, wordsAt)`
    /// is already there — safe to call from repeated deltas and full resyncs.
    func record(_ payload: StatusPayload, fromMe: Bool) {
        // Skip placeholders that were never a real status.
        guard payload.updatedAt > .distantPast else { return }
        // Built as an entry so both sides of the dedup carry the same
        // whole-second timestamp — see `StatusHistoryEntry.at`.
        record([StatusHistoryEntry(payload, fromMe: fromMe)])
    }

    /// Batch form, one lock for a whole delta (a resync delivers the entire
    /// cloud log at once). Same dedup; existing entries win.
    /// `cleared` is built inside the lock, like `MomentIndex.insertReadable`'s.
    func record(_ entries: [StatusHistoryEntry], cleared: (() -> (StatusHistoryEntry) -> Bool)? = nil) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        crossLock.withLock {
            var all = loadUnlocked(writing: true)
            var known = Set(all.map(\.id))
            var changed = false
            let isCleared = cleared?() ?? { _ in false }
            for entry in entries where !isCleared(entry) && known.insert(entry.id).inserted {
                all.append(entry)
                changed = true
            }
            guard changed else { return }
            all.sort { $0.at > $1.at }
            saveUnlocked(all)
        }
    }

    /// Drops entries by dedup key — how a `StatusLog` record's deletion (the
    /// cloud cap pruning the oldest) is mirrored locally.
    func remove(fromMe: Bool, at dates: [Date]) {
        guard !dates.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        crossLock.withLock {
            // `Int(exactly:)`, so a non-finite date can never trap here.
            let targets = Set(dates.compactMap { $0.wholeSecondsSince1970 })
            var all = loadUnlocked(writing: true)
            let before = all.count
            all.removeAll {
                guard $0.fromMe == fromMe,
                      let seconds = $0.at.wholeSecondsSince1970 else { return false }
                return targets.contains(seconds)
            }
            if all.count != before { saveUnlocked(all) }
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        crossLock.withLock {
            // The sidecar too: an unlink must not leave the ex's statuses behind.
            for url in [fileURL, fileURL.appendingPathExtension("corrupt")] {
                try? FileManager.default.removeItem(at: url)
            }
            cache = nil
        }
    }

    /// `writing` only under `crossLock`: entries that failed to decode are then
    /// dealt with for good — bytes kept, the zone asked to refill them, the
    /// rest saved — where a plain read just leaves the file be.
    private func loadUnlocked(writing: Bool = false) -> [StatusHistoryEntry] {
        guard let fileURL else { return [] }
        let key = FileIdentity(fileURL)
        if let key, let cache, cache.key == key {
            readFailed = false
            return cache.entries
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
            log.error("Status history unreadable, leaving it untouched: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decoded: LossyArray<StatusHistoryEntry>
        do {
            decoded = try JSONDecoder.shared.decode(LossyArray<StatusHistoryEntry>.self, from: data)
        } catch {
            log.error("Corrupt status history: \(error.localizedDescription)")
            // Bytes kept in the sidecar; the zone's `StatusLog` records refill the
            // newest of each side on the full resync the token clear forces.
            let sidecar = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.moveItem(at: fileURL, to: sidecar)
            cache = nil
            onCorrupt()
            return []
        }
        // Duplicates by dedup key collapse; the next save persists the cleaned list.
        var seen = Set<String>()
        let entries = decoded.elements.filter { seen.insert($0.id).inserted }
        guard decoded.dropped == 0 else {
            log.error("Status history: \(decoded.dropped) unreadable entries skipped.")
            if writing {
                try? data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
                onCorrupt()
                saveUnlocked(entries)
            }
            return entries
        }
        if let key { cache = (key, entries) }
        return entries
    }

    private func saveUnlocked(_ entries: [StatusHistoryEntry]) {
        guard let fileURL, !readFailed else { return }
        do {
            let trimmed = Array(entries.prefix(AppConfig.statusHistoryLimit))
            try JSONEncoder.shared.encode(trimmed).write(to: fileURL, options: .atomic)
            cache = FileIdentity(fileURL).map { ($0, trimmed) }
        } catch {
            cache = nil
            log.error("Failed to write status history: \(error.localizedDescription)")
        }
    }
}

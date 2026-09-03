import Foundation
import os

/// One entry in the rolling status log.
struct StatusHistoryEntry: Codable, Hashable, Identifiable {
    var emoji: String
    var message: String
    var isCelebration: Bool
    /// The status's own `updatedAt`, truncated to whole seconds — also the
    /// dedup key alongside `fromMe`. Truncated because the log round-trips
    /// through ISO-8601 JSON, which drops fractional seconds: a fractional
    /// date would never equal its own stored copy, so the same status logged
    /// once locally and once from the CloudKit echo appeared twice.
    var at: Date
    var fromMe: Bool

    var id: String { "\(fromMe ? "me" : "them")-\(at.timeIntervalSince1970)" }

    init(emoji: String, message: String, isCelebration: Bool, at: Date, fromMe: Bool) {
        self.emoji = emoji
        self.message = message
        self.isCelebration = isCelebration
        self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
        self.fromMe = fromMe
    }

    init(_ payload: StatusPayload, fromMe: Bool) {
        self.init(emoji: payload.emoji,
                  message: payload.message,
                  isCelebration: payload.isCelebration,
                  at: payload.updatedAt,
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
final class StatusHistoryLog {
    static let shared = StatusHistoryLog()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "StatusHistoryLog")
    private let lock = NSLock()
    private let crossLock = CrossProcessLock(name: "status-history.lock")
    private let fileURL: URL?

    /// `fileURL` defaults to the App Group file; tests pass a temporary one.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("status-history.json")
    }

    /// Newest first.
    func load() -> [StatusHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// Appends the payload unless an entry with the same `(fromMe, updatedAt)`
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
    func record(_ entries: [StatusHistoryEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        crossLock.withLock {
            var all = loadUnlocked()
            var known = Set(all.map(\.id))
            var changed = false
            for entry in entries where known.insert(entry.id).inserted {
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
            let targets = Set(dates.map { Int($0.timeIntervalSince1970.rounded(.down)) })
            var all = loadUnlocked()
            let before = all.count
            all.removeAll { $0.fromMe == fromMe && targets.contains(Int($0.at.timeIntervalSince1970)) }
            if all.count != before { saveUnlocked(all) }
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        crossLock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func loadUnlocked() -> [StatusHistoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let entries = try JSONDecoder.shared.decode([StatusHistoryEntry].self, from: data)
            // Self-heal duplicates written before dedup dates were second-
            // normalized; the next save persists the cleaned list.
            var seen = Set<String>()
            return entries.filter { seen.insert($0.id).inserted }
        } catch {
            log.error("Corrupt status history: \(error.localizedDescription)")
            // Preserve the bytes; unlike the moment index there is no server copy
            // to rebuild from, so never overwrite them silently.
            let sidecar = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.moveItem(at: fileURL, to: sidecar)
            return []
        }
    }

    private func saveUnlocked(_ entries: [StatusHistoryEntry]) {
        guard let fileURL else { return }
        do {
            let trimmed = Array(entries.prefix(AppConfig.statusHistoryLimit))
            try JSONEncoder.shared.encode(trimmed).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write status history: \(error.localizedDescription)")
        }
    }
}

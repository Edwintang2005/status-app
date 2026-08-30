import Foundation
import os

/// The full moment history, as a JSON file in the App Group. Kept out of
/// `Snapshot` so widget renders stay small. Entries are metadata only; media
/// files live in `MomentStore` and may not be on this device.
final class MomentIndex {
    static let shared = MomentIndex()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentIndex")
    /// App and notification extension both write. `lock` guards in-process;
    /// `crossLock` stops a concurrent cross-process load→modify→save from
    /// dropping the other side's insert for good.
    private let lock = NSLock()
    private let crossLock = CrossProcessLock(name: "moments-index.lock")

    private var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("moments-index.json")
    }

    /// Newest first.
    func load() -> [Moment] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [Moment] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder.shared.decode([Moment].self, from: data)
        } catch {
            log.error("Corrupt moment index: \(error.localizedDescription)")
            // Preserve the bytes rather than letting the next save overwrite them,
            // then clear the sync cursors so the next refresh pulls the whole zone
            // and rebuilds the index from CloudKit.
            let sidecar = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.moveItem(at: fileURL, to: sidecar)
            for key in ["private", "shared"] { SharedStore.shared.setChangeToken(nil, for: key) }
            return []
        }
    }

    private func saveUnlocked(_ moments: [Moment]) {
        guard let fileURL else { return }
        do {
            let trimmed = Array(moments.prefix(AppConfig.momentHistoryLimit))
            try JSONEncoder.shared.encode(trimmed).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write moment index: \(error.localizedDescription)")
        }
    }

    /// Inserts or replaces by id, keeping the list ordered newest first.
    @discardableResult
    func insert(_ moments: [Moment]) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            var all = loadUnlocked()
            for moment in moments {
                var moment = moment
                // `seen` is local-only; a full resync re-inserts everything, and
                // without this merge heard voice memos would re-badge as new.
                if let existing = all.first(where: { $0.id == moment.id }) {
                    moment.seen = moment.seen || existing.seen
                    // Sticky like `seen`: a copy fetched back from CloudKit
                    // proves the upload happened; uploaded never reverts to pending.
                    moment.uploaded = moment.uploaded || existing.uploaded
                }
                all.removeAll { $0.id == moment.id }
                all.append(moment)
            }
            all.sort { $0.sentAt > $1.sentAt }
            saveUnlocked(all)
            return all
        }
    }

    /// Marks entries as looked-at. Returns the updated list.
    @discardableResult
    func markSeen(ids: some Collection<String>) -> [Moment] {
        lock.lock()
        defer { lock.unlock() }

        return crossLock.withLock {
            let targets = Set(ids)
            var all = loadUnlocked()
            var changed = false
            for index in all.indices where targets.contains(all[index].id) && !all[index].seen {
                all[index].seen = true
                all[index].seenAt = Date()
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
            var all = loadUnlocked()
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
            var all = loadUnlocked()
            var changed = false
            for index in all.indices where targets.contains(all[index].id) && !all[index].uploaded {
                all[index].uploaded = true
                changed = true
            }
            if changed { saveUnlocked(all) }
            return all
        }
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        crossLock.withLock {
            var all = loadUnlocked()
            all.removeAll { $0.id == id }
            saveUnlocked(all)
        }
    }

    func knownIDs() -> Set<String> {
        Set(load().map(\.id))
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        // Locked: an extension's in-flight `insert` could otherwise rewrite the
        // file right after the delete, undoing the wipe.
        crossLock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

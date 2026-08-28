import Foundation
import os

/// The full moment history, as a JSON file in the App Group.
///
/// Deliberately *not* part of `Snapshot`: that lives in `UserDefaults` and is
/// decoded by the widget on every single render, so it must stay small. The
/// history can run to hundreds of entries and is only ever read by the app's
/// gallery, so it gets its own file.
///
/// Entries are metadata only — a few hundred bytes each. The image files they
/// point at are managed separately by `MomentStore` and may or may not be on
/// this device; see `MomentStore.hasImage(for:)`.
final class MomentIndex {
    static let shared = MomentIndex()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentIndex")
    /// The app and the notification service extension can both write. Atomic
    /// file replacement plus this lock keeps a torn read impossible within a
    /// process; `crossLock` extends the guarantee across processes, where a
    /// concurrent load→modify→save would otherwise drop the other side's
    /// insert (and with the change token already advanced, drop it for good).
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
            log.error("Corrupt moment index, starting over: \(error.localizedDescription)")
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
                // `seen` is local-only state — a re-fetched CloudKit record knows
                // nothing about it, and a full resync (expired change token)
                // re-inserts everything. Without this merge, every heard voice
                // memo re-badges as new.
                if let existing = all.first(where: { $0.id == moment.id }) {
                    moment.seen = moment.seen || existing.seen
                    // Sticky in the same direction as `seen`: a copy fetched
                    // back from CloudKit proves the upload happened — even one
                    // the sender's app died before acknowledging — and nothing
                    // ever makes an uploaded moment pending again.
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
        // Under the cross-process lock like every other write: an extension's
        // in-flight `insert` would otherwise rewrite the file right after
        // this deletes it, undoing the wipe.
        crossLock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

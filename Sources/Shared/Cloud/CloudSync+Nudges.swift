import CloudKit
import Foundation
import os

// The heart. Claims the cooldown under the lock before any network call
// (CLAUDE.md invariant 7).
extension CloudSync {
    /// Writes the partner-visible nudge record. Its own record type, so its
    /// subscription can carry a real alert. Returns `false` if the cooldown hasn't elapsed.
    @discardableResult
    func sendNudge() async throws -> Bool {
        let store = SharedStore.shared
        // Whole seconds: `now` is read back from the snapshot (ISO-8601, no
        // fraction) in the failure path and compared for equality.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        // Check and claim inside one `mutate` under the cross-process lock: the
        // app and the widget intent run in different processes, and an unlocked
        // check let two nudges through one cooldown.
        let allowed = await MainActor.run { () -> Bool in
            var claimed = false
            _ = store.mutate(reloadWidgets: false) { snapshot in
                if let last = snapshot.lastNudgeSentAt,
                   now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                    return
                }
                // Claim the cooldown before the network call so a double-tap
                // can't slip a second nudge through mid-flight.
                snapshot.lastNudgeSentAt = now
                // A retry is underway; the failure notice has done its job.
                snapshot.lastNudgeFailedAt = nil
                claimed = true
            }
            return claimed
        }
        guard allowed else { return false }

        do {
            let pairing = try await requirePairing()
            let database = self.database(for: pairing)
            let recordID = CKRecord.ID(recordName: pairing.role.nudgeRecordName,
                                       zoneID: zoneID(for: pairing))

            return try await withZoneRecovery(pairing) {
                // Another device of ours, or a tap still in flight, may write first;
                // each attempt refetches and increments on top.
                let next = try await retryingConflicts("Nudge") {
                    try await saveNudge(to: recordID, in: database, at: now)
                }

                await MainActor.run {
                    _ = store.mutate { snapshot in
                        snapshot.mine?.nudgeCount = next
                        snapshot.mine?.lastNudgeAt = now
                        snapshot.lastNudgeFailedAt = nil
                    }
                }
                return true
            }
        } catch {
            // Release the cooldown for immediate retry and record the failure —
            // the lock-screen widget has no other way to show an offline tap
            // didn't send. Only if our own claim is still standing: another
            // process may have claimed (and sent) since, and clearing that
            // live cooldown would let a second nudge straight through.
            await MainActor.run {
                _ = store.mutate { snapshot in
                    guard snapshot.lastNudgeSentAt == now else { return }
                    snapshot.lastNudgeSentAt = nil
                    snapshot.lastNudgeFailedAt = Date()
                }
            }
            throw error
        }
    }

    /// One fetch-increment-save of the nudge record. Returns the new count.
    func saveNudge(to recordID: CKRecord.ID,
                           in database: CKDatabase,
                           at now: Date) async throws -> Int {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.nudge, recordID: recordID)
        // The intent's deadline cancels rather than waits; the failure path
        // below must get to release the cooldown before WidgetKit suspends us.
        try Task.checkCancellation()
        // Clamped: the share lets the partner write this record too, and a
        // planted `Int.max` would trap the increment on every tap.
        let current = min(max(record[Field.count] as? Int ?? 0, 0), AppConfig.nudgeCountCeiling)
        let next = current + 1
        record[Field.count] = next as CKRecordValue
        record[Field.sentAt] = now as CKRecordValue
        // Change-tag checked: two taps racing on slow signal would otherwise both
        // write the same count, and the second heart would arrive silent.
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged)
        try Self.confirmSaved(result, recordID)
        return next
    }
}

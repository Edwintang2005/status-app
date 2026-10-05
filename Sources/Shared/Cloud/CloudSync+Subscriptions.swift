import CloudKit
import Foundation
import os

// The three database subscriptions and the legacy silent one they replace.
extension CloudSync {
    /// Three database subscriptions filtered by record type. `alertBody` makes a
    /// push visible and survive force-quit. The text stays generic because CloudKit
    /// composes it server-side and cannot read `encryptedValues`; the service
    /// extension replaces it with the decrypted content on-device.
    func registerSubscription() async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)

        let existing = (try? await database.allSubscriptions()) ?? []
        let existingIDs = Set(existing.map(\.subscriptionID))

        var toSave: [CKSubscription] = []

        if !existingIDs.contains(SubscriptionID.status) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.status)
            subscription.recordType = RecordType.status
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.status
            // Visible so Notification Centre keeps status history, but deliberately
            // no sound or time-sensitivity — a note, not an interruption.
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }
        // The legacy silent status subscription would double-fire alongside the visible one.
        let toDelete = existingIDs.contains(SubscriptionID.legacySilentStatus)
            ? [SubscriptionID.legacySilentStatus]
            : []

        if !existingIDs.contains(SubscriptionID.nudge) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.nudge)
            subscription.recordType = RecordType.nudge
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.nudge
            info.soundName = "default"
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }

        if !existingIDs.contains(SubscriptionID.moment) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.moment)
            subscription.recordType = RecordType.moment
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.moment
            info.soundName = "default"
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }

        guard !toSave.isEmpty || !toDelete.isEmpty else { return }

        do {
            _ = try await database.modifySubscriptions(saving: toSave, deleting: toDelete)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            log.notice("Subscriptions already registered.")
        }
    }

    /// Unpaired cleanup: removes every subscription of ours from both databases
    /// (the role decided which one held them, and that's gone with the pairing).
    /// Subscriptions belong to the account, so under positive proof of another
    /// one this refuses — deleting that account's would silence *its* pairing.
    func deleteAllSubscriptions(ownedBy userRecordName: String?) async throws {
        if let expected = userRecordName, let current = await currentUserRecordName(), current != expected {
            throw SyncError.differentAccount
        }
        for database in [container.privateCloudDatabase, container.sharedCloudDatabase] {
            let deleted: [CKSubscription.ID: Result<Void, Error>]
            do {
                deleted = try await database.modifySubscriptions(saving: [], deleting: SubscriptionID.all).deleteResults
            } catch let error as CKError where error.code == .partialFailure {
                deleted = (error.partialErrorsByItemID ?? [:]).reduce(into: [:]) { results, entry in
                    if let id = entry.key as? CKSubscription.ID { results[id] = .failure(entry.value) }
                }
            }
            guard Self.subscriptionsGone(deleted) else { throw SyncError.saveUnconfirmed }
        }
    }

    /// Every deletion landed or found nothing to delete.
    static func subscriptionsGone(_ results: [CKSubscription.ID: Result<Void, Error>]) -> Bool {
        results.values.allSatisfy { result in
            switch result {
            case .success: return true
            case .failure(let error): return (error as? CKError)?.code == .unknownItem
            }
        }
    }
}

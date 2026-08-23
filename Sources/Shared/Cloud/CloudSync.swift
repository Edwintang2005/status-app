import CloudKit
import Foundation
import os

/// Errors surfaced to the UI. Anything else is passed through as the raw
/// `CKError` so the message in Settings stays honest.
enum SyncError: LocalizedError {
    case notPaired
    case iCloudUnavailable(CKAccountStatus)
    case shareURLMissing
    case cloudKitDisabled

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "This device isn't paired yet."
        case .iCloudUnavailable(let status):
            switch status {
            case .noAccount:
                return "Sign in to iCloud in Settings to use \(AppConfig.appName)."
            case .restricted:
                return "iCloud is restricted on this device."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Try again shortly."
            default:
                return "iCloud isn't available right now."
            }
        case .shareURLMissing:
            return "CloudKit didn't return an invite link. Try again."
        case .cloudKitDisabled:
            return """
            This build was compiled without CloudKit, so pairing is unavailable. \
            Rebuild without TETHER_LOCAL_MODE and sign with your Apple \
            Developer team.
            """
        }
    }
}

/// All CloudKit access, for both the app and the widget extension.
///
/// Pairing uses a **zone-wide `CKShare`**: whoever pairs first owns a custom
/// zone in their private database and shares the whole zone; the other side
/// accepts and sees that zone in their shared database. Both partners can then
/// write into it. Each side writes exactly one record, named after its role,
/// which is why neither device ever needs to learn the other's CloudKit user ID.
actor CloudSync: SyncBackend {
    static let shared = CloudSync()

    /// `nil` only in `TETHER_LOCAL_MODE` builds.
    private let container: CKContainer?
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "CloudSync")

    private enum RecordType {
        static let status = "Status"
        static let moment = "Moment"
    }

    private enum Field {
        // Encrypted: only the two devices can read these, not CloudKit's
        // server-side indexes.
        static let emoji = "emoji"
        static let message = "message"
        static let displayName = "displayName"
        // Plain: needed for cheap comparison and never revealing.
        static let updatedAt = "updatedAt"
        static let nudgeCount = "nudgeCount"
        static let lastNudgeAt = "lastNudgeAt"

        // Moment. `image`/`thumb` are CKAssets, which CloudKit encrypts by
        // default — they must NOT go through `encryptedValues`.
        static let momentID = "momentID"
        static let kind = "kind"
        static let caption = "caption"
        static let senderName = "senderName"
        static let sentAt = "sentAt"
        static let image = "image"
        static let thumb = "thumb"
    }

    private static let subscriptionID = "couple-zone-changes"

    /// `CKContainer(identifier:)` traps at launch when the identifier isn't in
    /// the running binary's entitlements — which is true of any unsigned build.
    /// Compiling with `TETHER_LOCAL_MODE` skips creating it. That build talks
    /// to `LocalSync` instead, so this type is never used there — but the guard
    /// keeps a stray `CloudSync.shared` from taking the whole app down.
    init(container: CKContainer? = nil) {
        #if TETHER_LOCAL_MODE
        self.container = container
        #else
        self.container = container ?? CKContainer(identifier: AppConfig.cloudContainerID)
        #endif
    }

    private func requireContainer() throws -> CKContainer {
        guard let container else { throw SyncError.cloudKitDisabled }
        return container
    }

    // MARK: - Account

    func accountStatus() async throws -> CKAccountStatus {
        try await requireContainer().accountStatus()
    }

    func readiness() async -> BackendReadiness {
        do {
            let status = try await accountStatus()
            guard status == .available else {
                return .unavailable(SyncError.iCloudUnavailable(status).errorDescription ?? "")
            }
            return .ready
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .unavailable(message)
        }
    }

    private func requireAvailableAccount() async throws {
        let status = try await requireContainer().accountStatus()
        guard status == .available else { throw SyncError.iCloudUnavailable(status) }
    }

    // MARK: - Pairing

    /// Owner side. Creates the shared zone (if needed), shares it zone-wide, and
    /// returns the invite link to hand to the partner.
    ///
    /// The share is created with `publicPermission = .readWrite` so the partner
    /// can join from the link alone — no need to know their Apple Account
    /// address. `lockPairing()` closes it afterwards.
    func createPairInvite(displayName: String) async throws -> URL {
        try await requireAvailableAccount()

        let database = try requireContainer().privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName,
                                     ownerName: CKCurrentUserDefaultName)

        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                                 deleting: [])

        let share: CKShare
        if let existing = try await existingZoneShare(in: database, zoneID: zoneID) {
            share = existing
        } else {
            let newShare = CKShare(recordZoneID: zoneID)
            newShare[CKShare.SystemFieldKey.title] = "\(AppConfig.appName) — \(displayName)" as CKRecordValue
            newShare.publicPermission = .readWrite
            let result = try await database.modifyRecords(saving: [newShare], deleting: [])
            share = try Self.firstSavedRecord(from: result) as? CKShare ?? newShare
        }

        guard let url = share.url else { throw SyncError.shareURLMissing }

        let info = PairingInfo(role: .owner,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date())
        await MainActor.run { SharedStore.shared.pairing = info }
        try await bootstrapAfterPairing(displayName: displayName)
        return url
    }

    /// Owner side. Revokes link-based joining once the partner is in, so a
    /// forwarded or screenshotted link can't add a third person.
    func lockPairing() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { throw SyncError.notPaired }

        let database = try requireContainer().privateCloudDatabase
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else { return }
        share.publicPermission = .none
        _ = try await database.modifyRecords(saving: [share], deleting: [])
    }

    /// Participant side. Called from the scene delegate when iOS hands us an
    /// accepted `CKShare.Metadata`.
    func acceptShare(_ metadata: CKShare.Metadata, displayName: String) async throws {
        try await requireAvailableAccount()
        _ = try await requireContainer().accept(metadata)

        let zoneID = metadata.share.recordID.zoneID
        let info = PairingInfo(role: .participant,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date())
        await MainActor.run { SharedStore.shared.pairing = info }
        try await bootstrapAfterPairing(displayName: displayName)
    }

    /// Publish an opening status and register for change pushes, so the other
    /// side sees something the moment pairing completes.
    private func bootstrapAfterPairing(displayName: String) async throws {
        try? await registerSubscription()
        try await publish(.initial(displayName: displayName))
        let theirs = (try? await refresh())?.partnerStatus
        // Seed the nudge watermark from whatever is already on the server, so
        // pairing against an existing history doesn't fire a burst of stale
        // "thinking of you" notifications.
        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.lastSeenPartnerNudgeCount = theirs?.nudgeCount ?? 0 }
        }
    }

    private func existingZoneShare(in database: CKDatabase,
                                   zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let zones = try await database.recordZones(for: [zoneID])
        guard case .success(let zone)? = zones[zoneID],
              let shareID = zone.share?.recordID else { return nil }
        let records = try await database.records(for: [shareID])
        guard case .success(let record)? = records[shareID] else { return nil }
        return record as? CKShare
    }

    // MARK: - Reading and writing status

    /// Writes this device's own status record. Only ever touches the record
    /// belonging to our own role, so the two phones can never conflict.
    func publish(_ payload: StatusPayload) async throws {
        let pairing = try await requirePairing()
        let database = try self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.statusRecordName,
                                   zoneID: zoneID(for: pairing))

        do {
            try await saveStatus(payload, to: recordID, in: database)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device of ours wrote first; take the server copy and
            // reapply on top of it.
            log.notice("Status conflict, retrying against server record.")
            try await saveStatus(payload, to: recordID, in: database)
        }

        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.mine = payload }
        }
    }

    private func saveStatus(_ payload: StatusPayload,
                            to recordID: CKRecord.ID,
                            in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.status, recordID: recordID)
        apply(payload, to: record)
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }

    /// Pulls both status records plus the partner's latest moment, and folds
    /// everything into the shared snapshot.
    @discardableResult
    func refresh() async throws -> RefreshResult {
        let pairing = try await requirePairing()
        let database = try self.database(for: pairing)
        let zone = zoneID(for: pairing)

        let mineID = CKRecord.ID(recordName: pairing.role.statusRecordName, zoneID: zone)
        let theirsID = CKRecord.ID(recordName: pairing.role.other.statusRecordName, zoneID: zone)

        let results = try await database.records(for: [mineID, theirsID])
        let mine = Self.payload(from: results[mineID])
        let theirs = Self.payload(from: results[theirsID])

        await MainActor.run {
            _ = SharedStore.shared.mutate {
                if let mine { $0.mine = mine }
                if let theirs { $0.theirs = theirs }
                $0.isPaired = true
                $0.lastSyncedAt = Date()
            }
        }

        let newMoment = try? await fetchPartnerMoment(pairing: pairing, in: database, zone: zone)
        return RefreshResult(partnerStatus: theirs, newPartnerMoment: newMoment ?? nil)
    }

    /// Checks the partner's moment slot cheaply, and only pays for the image
    /// download when the id is one this device hasn't stored yet.
    private func fetchPartnerMoment(pairing: PairingInfo,
                                    in database: CKDatabase,
                                    zone: CKRecordZone.ID) async throws -> Moment? {
        let recordID = CKRecord.ID(recordName: pairing.role.other.momentRecordName, zoneID: zone)

        // Assets are excluded from this fetch on purpose — it runs on every
        // push, and re-downloading a photo we already have would be wasteful.
        let meta = try await database.records(for: [recordID],
                                              desiredKeys: [Field.momentID, Field.sentAt])
        guard case .success(let stub)? = meta[recordID],
              let remoteID = stub[Field.momentID] as? String else { return nil }

        let alreadyHave = await MainActor.run {
            SharedStore.shared.snapshot.moments.contains { $0.id == remoteID }
        }
        guard !alreadyHave else { return nil }

        guard let record = try await fetchRecord(recordID, in: database),
              let kindRaw = record[Field.kind] as? String,
              let kind = Moment.Kind(rawValue: kindRaw) else { return nil }

        let store = MomentStore.shared
        try Self.copyAsset(record[Field.image] as? CKAsset, to: store.imageURL(for: remoteID))
        try Self.copyAsset(record[Field.thumb] as? CKAsset, to: store.thumbURL(for: remoteID))

        let moment = Moment(
            id: remoteID,
            kind: kind,
            caption: record.encryptedValues[Field.caption] as? String ?? "",
            senderName: record.encryptedValues[Field.senderName] as? String ?? "",
            sentAt: record[Field.sentAt] as? Date ?? record.modificationDate ?? Date(),
            fromMe: false
        )
        await MainActor.run { SharedStore.shared.record(moment) }
        return moment
    }

    private static func copyAsset(_ asset: CKAsset?, to destination: URL?) throws {
        guard let source = asset?.fileURL, let destination else { return }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - Moments

    /// Overwrites this device's single moment slot. The image files are
    /// already on disk under `moment.id`.
    func send(_ moment: Moment) async throws {
        let pairing = try await requirePairing()
        let database = try self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.momentRecordName,
                                   zoneID: zoneID(for: pairing))

        let store = MomentStore.shared
        guard let fullURL = store.imageURL(for: moment.id),
              let thumbURL = store.thumbURL(for: moment.id) else {
            throw MomentStoreError.containerUnavailable
        }

        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.moment, recordID: recordID)
        record[Field.momentID] = moment.id as CKRecordValue
        record[Field.kind] = moment.kind.rawValue as CKRecordValue
        record[Field.sentAt] = moment.sentAt as CKRecordValue
        record.encryptedValues[Field.caption] = moment.caption
        record.encryptedValues[Field.senderName] = moment.senderName
        record[Field.image] = CKAsset(fileURL: fullURL)
        record[Field.thumb] = CKAsset(fileURL: thumbURL)

        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }

    // MARK: - Nudges

    /// Bumps the counter on our own record. The partner's device notices the
    /// higher count on its next fetch and raises a local notification.
    /// Returns `false` if the cooldown hasn't elapsed.
    @discardableResult
    func sendNudge() async throws -> Bool {
        let store = SharedStore.shared
        let now = Date()

        let allowed = await MainActor.run { () -> Bool in
            if let last = store.snapshot.lastNudgeSentAt,
               now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                return false
            }
            // Claim the cooldown before the network call so a double-tap can't
            // slip a second nudge through while the first is in flight.
            store.mutate(reloadWidgets: false) { $0.lastNudgeSentAt = now }
            return true
        }
        guard allowed else { return false }

        do {
            let pairing = try await requirePairing()
            let database = try self.database(for: pairing)
            let recordID = CKRecord.ID(recordName: pairing.role.statusRecordName,
                                       zoneID: zoneID(for: pairing))

            let existing = try await fetchRecord(recordID, in: database)
            let record = existing ?? CKRecord(recordType: RecordType.status, recordID: recordID)
            if existing == nil {
                let name = await MainActor.run { store.snapshot.mine?.displayName ?? "Me" }
                apply(.initial(displayName: name), to: record)
            }

            let current = record[Field.nudgeCount] as? Int ?? 0
            record[Field.nudgeCount] = (current + 1) as CKRecordValue
            record[Field.lastNudgeAt] = now as CKRecordValue

            _ = try await database.modifyRecords(saving: [record],
                                                 deleting: [],
                                                 savePolicy: .changedKeys)

            await MainActor.run {
                _ = store.mutate { snapshot in
                    snapshot.mine?.nudgeCount = current + 1
                    snapshot.mine?.lastNudgeAt = now
                }
            }
            return true
        } catch {
            // Release the cooldown so a failed nudge can be retried immediately.
            await MainActor.run {
                _ = store.mutate(reloadWidgets: false) { $0.lastNudgeSentAt = nil }
            }
            throw error
        }
    }

    // MARK: - Push subscriptions

    /// A database subscription fires a silent push whenever anything in the
    /// shared zone changes. Query subscriptions aren't available on the shared
    /// database, which is why this is database-scoped rather than record-scoped.
    func registerSubscription() async throws {
        let pairing = try await requirePairing()
        let database = try self.database(for: pairing)

        let existing = try? await database.allSubscriptions()
        if existing?.contains(where: { $0.subscriptionID == Self.subscriptionID }) == true { return }

        let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        // Database subscriptions are silent by design; the app turns the wake-up
        // into a user-visible notification itself.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        } catch let error as CKError where error.code == .serverRejectedRequest {
            log.notice("Subscription already registered.")
        }
    }

    // MARK: - Unpairing

    /// Owner deletes the zone (which revokes the share); participant just stops
    /// listening. Either way local state is cleared.
    func unpair() async {
        if let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
           let database = try? self.database(for: pairing) {
            _ = try? await database.modifySubscriptions(saving: [],
                                                        deleting: [Self.subscriptionID])
            if pairing.role == .owner {
                _ = try? await database.modifyRecordZones(saving: [],
                                                          deleting: [zoneID(for: pairing)])
            }
        }
        await MainActor.run { SharedStore.shared.resetPairing() }
    }

    // MARK: - Helpers

    private func requirePairing() async throws -> PairingInfo {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            throw SyncError.notPaired
        }
        return pairing
    }

    private func database(for pairing: PairingInfo) throws -> CKDatabase {
        let container = try requireContainer()
        return pairing.role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for pairing: PairingInfo) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: pairing.zoneName, ownerName: pairing.zoneOwnerName)
    }

    private func fetchRecord(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func apply(_ payload: StatusPayload, to record: CKRecord) {
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.displayName] = payload.displayName
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        record[Field.nudgeCount] = payload.nudgeCount as CKRecordValue
        if let lastNudgeAt = payload.lastNudgeAt {
            record[Field.lastNudgeAt] = lastNudgeAt as CKRecordValue
        }
    }

    private static func payload(from result: Result<CKRecord, Error>?) -> StatusPayload? {
        guard case .success(let record)? = result else { return nil }
        return StatusPayload(
            emoji: record.encryptedValues[Field.emoji] as? String ?? "💭",
            message: record.encryptedValues[Field.message] as? String ?? "",
            displayName: record.encryptedValues[Field.displayName] as? String ?? "",
            updatedAt: record[Field.updatedAt] as? Date ?? record.modificationDate ?? Date(),
            nudgeCount: record[Field.nudgeCount] as? Int ?? 0,
            lastNudgeAt: record[Field.lastNudgeAt] as? Date
        )
    }

    private static func firstSavedRecord(
        from result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                      deleteResults: [CKRecord.ID: Result<Void, Error>])
    ) throws -> CKRecord? {
        for (_, saveResult) in result.saveResults {
            return try saveResult.get()
        }
        return nil
    }
}

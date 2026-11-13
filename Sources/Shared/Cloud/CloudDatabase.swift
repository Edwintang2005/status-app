import CloudKit

/// The CloudKit calls syncing and unlinking make — `CKDatabase` in the app, a
/// fake in tests (`FakeCloudDatabase`), so `refresh` and `unpair` run under
/// `make test`. Change tokens travel as their archived bytes, as `SharedStore`
/// keeps them.
protocol CloudDatabase: Sendable {
    /// One change fetch: everything since `token`, or one batch of up to `batchLimit` records.
    func zoneChanges(zone: CKRecordZone.ID, since token: Data?, batchLimit: Int?,
                     desiredKeys: [String]) async throws -> CloudSync.ZoneChanges
    /// Bytes this database can resume a fetch from; anything else starts over.
    func canResume(from token: Data) -> Bool
    /// Records by ID, at `.userInitiated`: someone is waiting (see `changesOperation`).
    func fetchRecords(_ ids: [CKRecord.ID],
                      desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord.ID: Result<CKRecord, Error>]
    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID],
                       savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                       atomically: Bool) async throws -> CloudSync.ModifyResult
    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws
        -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, Error>],
            deleteResults: [CKRecordZone.ID: Result<Void, Error>])
    func recordZones(for ids: [CKRecordZone.ID]) async throws -> [CKRecordZone.ID: Result<CKRecordZone, Error>]
    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws
        -> (saveResults: [CKSubscription.ID: Result<CKSubscription, Error>],
            deleteResults: [CKSubscription.ID: Result<Void, Error>])
}

/// The stores `CloudSync` files into: the App Group's own in the app and its
/// extensions, temporary ones in a test.
struct CloudStores: Sendable {
    var shared: SharedStore
    var index: MomentIndex
    var media: MomentStore
    var statusLog: StatusHistoryLog
    var recaps: RecapStore

    static var live: CloudStores {
        CloudStores(shared: .shared, index: .shared, media: .shared, statusLog: .shared, recaps: .shared)
    }

    /// Erases every cached moment file and the index that lists them. With
    /// `keepingPendingUploads`, own sends that never reached CloudKit survive —
    /// they exist nowhere else, and a re-pairing to the same zone re-sends them.
    func eraseLocalMedia(keepingPendingUploads: Bool = false) {
        let kept = keepingPendingUploads ? index.retainPendingUploads() : []
        if !keepingPendingUploads { index.clear() }
        statusLog.clear()
        // No grace window: an unlink erases everything, even seconds-old recordings.
        media.prune(keeping: kept.map(\.id), graceInterval: 0)
        MomentStore.clearThumbnailCache()
        recaps.removeAll()
    }
}

extension CKOperation.Configuration {
    /// Someone is waiting — a banner, a tap, the open app — so never CloudKit's
    /// default QoS, which is discretionary (see `CloudSync.changesOperation`).
    static var waited: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        return configuration
    }
}

extension CKDatabase {
    /// This database's calls in `body` at `.userInitiated` (`Configuration.waited`).
    func waited<R>(_ body: @Sendable (CKDatabase) async throws -> R) async throws -> R {
        try await configuredWith(configuration: .waited, body: body)
    }
}

extension CKDatabase: CloudDatabase {
    func canResume(from token: Data) -> Bool {
        CloudSync.decodeToken(token) != nil
    }

    func fetchRecords(_ ids: [CKRecord.ID],
                      desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        try await waited { try await $0.records(for: ids, desiredKeys: desiredKeys) }
    }

    func zoneChanges(zone: CKRecordZone.ID, since token: Data?, batchLimit: Int?,
                     desiredKeys: [String]) async throws -> CloudSync.ZoneChanges {
        let operation = CloudSync.changesOperation(zone: zone, since: CloudSync.decodeToken(token),
                                                   batchLimit: batchLimit, desiredKeys: desiredKeys)
        let changes = CloudSync.ZoneChanges()
        operation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record): changes.records.append(record)
            case .failure: changes.failedIDs.append(recordID)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            changes.deletedIDs.append(recordID)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let value):
                changes.token = CloudSync.encodeToken(value.serverChangeToken)
                changes.moreComing = value.moreComing
            case .failure(let error):
                changes.zoneError = error
            }
        }

        // Without the cancellation handler the operation runs to completion regardless,
        // stalling the widget's getTimeline for the full network duration.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zoneError = changes.zoneError {
                            continuation.resume(throwing: zoneError)
                        } else {
                            continuation.resume(returning: changes)
                        }
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

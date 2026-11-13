import CloudKit
import Foundation

/// iCloud for `CloudSync` in a test: change fetches answered from a script,
/// every write recorded and answered per item as configured. Tokens are plain
/// bytes (`token("t1")`).
final class FakeCloudDatabase: CloudDatabase, @unchecked Sendable {
    struct Batch {
        var records: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var failedIDs: [CKRecord.ID] = []
        var token: Data?
        var moreComing = false
    }

    private let lock = NSLock()
    /// Answered in order; an `Error` throws instead.
    private var script: [Result<Batch, Error>] = []
    /// Called as each fetch is answered, before it returns: something landing mid-fetch.
    var duringFetch: (() -> Void)?
    private(set) var fetchedSince: [Data?] = []
    private(set) var deletedRecords: [CKRecord.ID] = []
    private(set) var deletedZones: [CKRecordZone.ID] = []
    var zoneDeleteResult: (CKRecordZone.ID) -> Result<Void, Error>? = { _ in .success(()) }
    var zones: [CKRecordZone.ID: Result<CKRecordZone, Error>] = [:]

    func answer(_ batch: Batch) { lock.withLock { script.append(.success(batch)) } }
    func fail(_ error: Error) { lock.withLock { script.append(.failure(error)) } }

    static func token(_ name: String) -> Data { Data(name.utf8) }

    func zoneChanges(zone: CKRecordZone.ID, since token: Data?, oneBatch: Bool,
                     desiredKeys: [String]) async throws -> CloudSync.ZoneChanges {
        let next = lock.withLock { () -> Result<Batch, Error>? in
            fetchedSince.append(token)
            return script.isEmpty ? nil : script.removeFirst()
        }
        duringFetch?()
        let batch = try (next ?? .success(Batch())).get()
        let changes = CloudSync.ZoneChanges()
        changes.records = batch.records
        changes.deletedIDs = batch.deletedIDs
        changes.failedIDs = batch.failedIDs
        changes.token = batch.token
        changes.moreComing = batch.moreComing
        return changes
    }

    func canResume(from token: Data) -> Bool { true }

    /// What a fetch by ID answers, by record name; a name not here isn't answered at all.
    var byName: [String: Result<CKRecord, Error>] = [:]
    /// Thrown by the next fetch by ID instead of answering.
    var fetchByIDError: Error?
    /// How long a fetch by ID takes to answer: a stall.
    var fetchByIDDelay: Duration?
    private(set) var fetchedByID: [[String]] = []

    func fetchRecords(_ ids: [CKRecord.ID],
                      desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        // Recorded as asked, before any stall: a fetch cut off still happened.
        let delay = lock.withLock { () -> Duration? in
            fetchedByID.append(ids.map(\.recordName))
            return fetchByIDDelay
        }
        if let delay { try await Task.sleep(for: delay) }
        return try lock.withLock {
            if let error = fetchByIDError {
                fetchByIDError = nil
                throw error
            }
            var answers: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for id in ids { answers[id] = byName[id.recordName] }
            return answers
        }
    }

    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID],
                       savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                       atomically: Bool) async throws -> CloudSync.ModifyResult {
        lock.withLock { deletedRecords += deleting }
        return (saveResults: Dictionary(uniqueKeysWithValues: saving.map { ($0.recordID, .success($0)) }),
                deleteResults: Dictionary(uniqueKeysWithValues: deleting.map { ($0, .success(())) }))
    }

    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws
        -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, Error>],
            deleteResults: [CKRecordZone.ID: Result<Void, Error>]) {
        lock.withLock { deletedZones += deleting }
        var results: [CKRecordZone.ID: Result<Void, Error>] = [:]
        for id in deleting { results[id] = zoneDeleteResult(id) }
        return (saveResults: [:], deleteResults: results)
    }

    func recordZones(for ids: [CKRecordZone.ID]) async throws -> [CKRecordZone.ID: Result<CKRecordZone, Error>] {
        zones.filter { ids.contains($0.key) }
    }

    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws
        -> (saveResults: [CKSubscription.ID: Result<CKSubscription, Error>],
            deleteResults: [CKSubscription.ID: Result<Void, Error>]) {
        (saveResults: [:], deleteResults: Dictionary(uniqueKeysWithValues: deleting.map { ($0, .success(())) }))
    }
}

import XCTest

/// A value a `@Sendable` test closure can set and the test read afterwards.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension XCTestCase {
    /// Every store in a fresh temporary directory, never the App Group (`.shared`).
    func makeStores(paired role: PairRole? = .owner) -> CloudStores {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedStringAppTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedStore(defaults: temporaryDefaults())
        if let role {
            shared.pairing = PairingInfo(role: role, zoneName: AppConfig.coupleZoneName,
                                         zoneOwnerName: "__defaultOwner__", pairedAt: Fixtures.t0, userRecordName: "_me")
        }
        return CloudStores(shared: shared,
                           index: MomentIndex(fileURL: directory.appendingPathComponent("moments-index.json"), onCorrupt: {}),
                           media: MomentStore(directory: directory.appendingPathComponent("Moments", isDirectory: true)),
                           statusLog: StatusHistoryLog(fileURL: directory.appendingPathComponent("status-log.json"), onCorrupt: {}),
                           recaps: RecapStore(directory: directory.appendingPathComponent("Recaps", isDirectory: true)))
    }

    @MainActor
    func makeModel(paired role: PairRole? = .owner,
                   backend: FakeAppBackend = FakeAppBackend()) -> (AppModel, FakeAppBackend, CloudStores) {
        let stores = makeStores(paired: role)
        let model = AppModel(stores: stores, backend: backend, environment: .detached)
        return (model, backend, stores)
    }
}

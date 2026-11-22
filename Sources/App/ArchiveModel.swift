import Foundation
import os

/// What the archive asks of the model that owns it. Held weakly.
@MainActor
protocol ArchiveHost: AnyObject {
    var isPaired: Bool { get }
    var history: [Moment] { get }
    var snapshot: Snapshot { get }
    var myDisplayName: String { get }
    var partnerName: String { get }
    var hiddenPartnerStatusAt: Date? { get }
    /// Settings' "Clear downloaded media" is deleting: an archive started now
    /// could find a file on this phone and lose it before copying it.
    var isClearingMedia: Bool { get }
    func keepAwake(_ reason: AppModel.KeepAwake, _ on: Bool)
    func present(_ error: Error, title: String?)
}

/// "Save memories": the whole zone's history, merged with this phone's, written
/// out as plain files (`MemoryArchive`) before anything may be deleted (`EndingPlan`).
@MainActor
@Observable
final class ArchiveModel {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Archive")

    /// `0...1` while an archive is being written, `nil` otherwise.
    private(set) var progress: Double?
    /// The last archive that only reached this device — offered for sharing
    /// before any delete. Settings presents it, then clears it.
    var toShare: URL?

    @ObservationIgnored private var task: Task<ArchiveOutcome?, Never>?
    /// Bumped per archive and by a cancel: a cancelled run winding down in the
    /// background no longer reports progress or offers a share.
    @ObservationIgnored private var run = 0

    @ObservationIgnored weak var host: (any ArchiveHost)?
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let statusLog: StatusHistoryLog
    @ObservationIgnored private let backend: () -> any AppBackend
    @ObservationIgnored private let write: MemoryArchive.Writer

    init(store: SharedStore, statusLog: StatusHistoryLog, backend: @escaping () -> any AppBackend,
         write: @escaping MemoryArchive.Writer = MemoryArchive.write) {
        self.store = store
        self.statusLog = statusLog
        self.backend = backend
        self.write = write
    }

    /// Paired, the zone may hold more than this phone's capped index, statuses included.
    var hasMemories: Bool { host?.isPaired == true || host?.history.isEmpty == false }
    var canArchive: Bool { hasMemories && progress == nil && host?.isClearingMedia != true }

    /// Most media is fetched back from CloudKit (hence progress), and it must
    /// finish *before* anything is deleted. An unreachable zone still archives
    /// this phone's copy; `ArchiveOutcome.gate` says what that allows.
    /// - Parameter offeringShare: `false` leaves a device-only archive for the
    ///   caller to offer: Settings presents `toShare`, and a view pushed over it can't.
    @discardableResult
    func archive(offeringShare: Bool = true) async -> ArchiveOutcome? {
        run += 1
        let run = run
        progress = 0
        // Thousands of downloads: a sleeping screen would stall them before the delete it guards.
        host?.keepAwake(.archive, true)
        let task = Task { await writeArchive(offeringShare: offeringShare, run: run) }
        self.task = task
        let outcome = await task.value
        if self.run == run {
            progress = nil
            self.task = nil
            host?.keepAwake(.archive, false)
        }
        return outcome
    }

    /// Settings' and the fresh start's Cancel: stops the archive, removing what it staged.
    func cancel() {
        task?.cancel()
        task = nil
        run += 1
        progress = nil
        host?.keepAwake(.archive, false)
    }

    private func writeArchive(offeringShare: Bool, run: Int) async -> ArchiveOutcome? {
        guard let host else { return nil }
        let backend = backend()
        var zone: ArchiveContents.Zone?
        do {
            zone = try await withDeadline(AppConfig.refreshDeadline) { try await backend.archiveZone() }
        } catch {
            Self.log.error("Archive couldn't read the zone: \(error.localizedDescription); archiving this iPhone's copy.")
        }
        let contents = ArchiveContents.merged(zone: zone,
                                              localMoments: host.history,
                                              localStatuses: statusLog.load(),
                                              anniversary: host.snapshot.anniversary,
                                              hidden: store.hiddenMomentIDs)
        do {
            let outcome = try await write(contents, host.myDisplayName, host.partnerName,
                                          host.hiddenPartnerStatusAt) { fraction in
                Task { @MainActor in
                    guard self.run == run else { return }
                    self.progress = fraction
                }
            }
            guard self.run == run else { return nil }
            if outcome.destination == .deviceOnly, offeringShare {
                // Nothing is safe yet: the folder only exists here until the user saves it somewhere.
                toShare = outcome.folder
            }
            return outcome
        } catch is CancellationError {
            return nil
        } catch {
            guard self.run == run else { return nil }
            host.present(error, title: String(localized: "Couldn't save your memories"))
            return nil
        }
    }
}

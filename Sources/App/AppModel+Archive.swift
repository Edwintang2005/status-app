import Foundation
import os

// The memories archive.
extension AppModel {
    // MARK: - Memories

    /// Paired, the zone may hold more than this phone's capped index, statuses included.
    var hasMemoriesToArchive: Bool { isPaired || !history.isEmpty }
    var canArchiveMemories: Bool { hasMemoriesToArchive && archiveProgress == nil }

    /// Writes the whole zone's history, merged with this phone's, out as plain
    /// files in iCloud Drive. Most media is fetched back from CloudKit (hence
    /// progress), and it must finish *before* anything is deleted. An unreachable
    /// zone still archives this phone's copy; `Outcome.isComplete` says which.
    /// `offeringShare: false` leaves a device-only archive for the caller to
    /// offer: Settings presents `archiveToShare`, and a view pushed over it can't.
    @discardableResult
    func archiveMemories(offeringShare: Bool = true) async -> MemoryArchive.Outcome? {
        archiveRun += 1
        let run = archiveRun
        archiveProgress = 0
        let task = Task { await writeArchive(offeringShare: offeringShare, run: run) }
        archiveTask = task
        let outcome = await task.value
        if archiveRun == run {
            archiveProgress = nil
            archiveTask = nil
        }
        return outcome
    }

    /// Settings' and the fresh start's Cancel: stops the archive, removing what it staged.
    func cancelArchive() {
        archiveTask?.cancel()
        archiveTask = nil
        archiveRun += 1
        archiveProgress = nil
    }

    private func writeArchive(offeringShare: Bool, run: Int) async -> MemoryArchive.Outcome? {
        var zone: ArchiveContents.Zone?
        do {
            zone = try await bounded(AppConfig.refreshDeadline) { try await $0.archiveZone() }
        } catch {
            log.error("Archive couldn't read the zone: \(error.localizedDescription); archiving this iPhone's copy.")
        }
        let contents = ArchiveContents.merged(zone: zone,
                                              localMoments: history,
                                              localStatuses: StatusHistoryLog.shared.load(),
                                              anniversary: snapshot.anniversary,
                                              hidden: store.hiddenMomentIDs)

        do {
            let outcome = try await MemoryArchive.write(contents,
                                                        myName: myDisplayName,
                                                        partnerName: partnerName,
                                                        reportedStatusAt: hiddenPartnerStatusAt) { fraction in
                Task { @MainActor in
                    guard self.archiveRun == run else { return }
                    self.archiveProgress = fraction
                }
            }
            guard archiveRun == run else { return nil }
            if outcome.destination == .deviceOnly, offeringShare {
                // Nothing is safe yet: the folder only exists here until the user saves it somewhere.
                archiveToShare = outcome.folder
            }
            return outcome
        } catch is CancellationError {
            return nil
        } catch {
            guard archiveRun == run else { return nil }
            present(error, title: String(localized: "Couldn't save your memories"))
            return nil
        }
    }
}

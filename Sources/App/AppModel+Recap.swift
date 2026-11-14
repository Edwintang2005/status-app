import Foundation
import os

// The year in review: Home's seasonal card, Settings' row, and what goes in.
extension AppModel {
    /// Home's card: from Christmas midday through January, once that year has pictures
    /// here, until opened or waved away.
    var recapPeriodOnHome: RecapPlan.Period? {
        if recapCardPreview { return .lastTwelveMonths }
        // Not "your year together" once they've left; Settings still has it.
        guard !snapshot.partnerHasLeft,
              let year = RecapPlan.yearOnOffer(), recapNoticeDismissed != year,
              hasRecap(for: .year(year)) else { return nil }
        return .year(year)
    }

    func dismissRecapNotice() {
        recapCardPreview = false
        if let year = RecapPlan.yearOnOffer() { persist(year, \.recapNoticeDismissed, \.recapNoticeDismissed) }
        syncRecapReminder()
    }

    /// Reschedules only when the plan moved, since `reload` runs after nearly everything.
    func syncRecapReminder() {
        let plan = RecapPlan.reminder(paired: isPaired && !snapshot.partnerHasLeft,
                                      hasPictures: { self.hasRecap(for: .year($0)) },
                                      dismissed: recapNoticeDismissed)
        if case .some(let scheduled) = scheduledRecapReminder, scheduled == plan { return }
        scheduledRecapReminder = .some(plan)
        // Chained: a remove-then-add overlapping another could leave a stale one behind.
        let previous = recapReminderSync
        recapReminderSync = Task {
            await previous?.value
            await NotificationManager.scheduleRecapReminder(plan)
        }
    }

    /// From this phone's index: a recap needs a picture to build around.
    func hasRecap(for period: RecapPlan.Period) -> Bool {
        let interval = period.interval()
        return history.contains { $0.isPicture && interval.contains($0.sentAt) }
    }

    /// This phone's copy, merged with the whole zone like the archive only when
    /// the period reaches past the index's cap (`RecapPlan.needsZone`).
    /// An unreachable zone recaps this phone's copy, `complete` false: shown
    /// with a note and never kept as the year's video. Partner words go through
    /// moderation: only what may be shown goes in.
    func recapPlan(for period: RecapPlan.Period) async -> (plan: RecapPlan, complete: Bool)? {
        var zone: ArchiveContents.Zone?
        var complete = true
        if isPaired, RecapPlan.needsZone(index: history, interval: period.interval(),
                                         complete: HistoryCoverage.isComplete(store.historyCoverage)) {
            do {
                zone = try await bounded(AppConfig.refreshDeadline) { try await $0.archiveZone() }
            } catch {
                complete = false
                log.error("Recap couldn't read the zone: \(error.localizedDescription); using this iPhone's copy.")
            }
        }
        let contents = ArchiveContents.merged(zone: zone,
                                              localMoments: history,
                                              localStatuses: StatusHistoryLog.shared.load(),
                                              anniversary: snapshot.anniversary,
                                              hidden: store.hiddenMomentIDs)
        let reportedAt = hiddenPartnerStatusAt
        let sealedAt = snapshot.sealedPartnerWordsAt
        let filterOn = contentFilterEnabled
        let statuses = contents.statuses.filter {
            !$0.moderation(reportedAt: reportedAt, sealedAt: sealedAt, filterEnabled: filterOn).message.isPlaceholder
        }
        return RecapPlan.make(period, moments: contents.moments, statuses: statuses).map { ($0, complete) }
    }

    func recapWords(for plan: RecapPlan) -> RecapVideo.Words {
        let me = myDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch plan.period {
        case .year(let year):
            return RecapVideo.Words(myName: me.isEmpty ? String(localized: "You") : me,
                                    partnerName: partnerName,
                                    title: String(year),
                                    closing: String(localized: "Here's to \(String(year + 1))"),
                                    filterEnabled: contentFilterEnabled)
        case .lastTwelveMonths:
            let span = plan.interval.start.formatted(.dateTime.month(.abbreviated).year())
                + " – " + plan.interval.end.formatted(.dateTime.month(.abbreviated).year())
            return RecapVideo.Words(myName: me.isEmpty ? String(localized: "You") : me,
                                    partnerName: partnerName,
                                    title: span,
                                    closing: String(localized: "Here's to what's next"),
                                    filterEnabled: contentFilterEnabled)
        }
    }
}

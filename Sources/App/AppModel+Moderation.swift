import Foundation
import os
import UIKit

// Terms, reports, the word filter's reveal and blocking (guideline 1.2).
extension AppModel {
    // MARK: - Safety (guideline 1.2)

    func acceptTerms() {
        store.acceptedTermsVersion = AppConfig.termsVersion
        termsAccepted = true
    }

    /// The current partner status has been reported: its text stays hidden.
    var isPartnerStatusReported: Bool {
        guard let theirs = snapshot.theirs, let hidden = hiddenPartnerStatusAt else { return false }
        return theirs.wordsAt == hidden || theirs.updatedAt == hidden
    }

    /// The filter-hidden words of their current status were revealed on this iPhone.
    var partnerStatusRevealed: Bool {
        guard let revealed = revealedPartnerWordsAt else { return false }
        return snapshot.theirs?.wordsAt == revealed
    }

    /// "Show hidden text": the words are on screen now, so the read receipt may go.
    func revealPartnerStatus() {
        revealedPartnerWordsAt = snapshot.theirs?.wordsAt
        markPartnerStatusSeen()
    }

    /// Removes the moment from this device for good and mails the report.
    /// Only ever the partner's — there's nothing to report about your own.
    func report(_ moment: Moment) {
        guard !moment.fromMe else { return }
        var hidden = store.hiddenMomentIDs
        hidden.insert(moment.id)
        store.hiddenMomentIDs = hidden
        MomentIndex.shared.remove(id: moment.id)
        MomentStore.shared.delete(id: moment.id)
        store.refreshDerived()
        reload()
        sendReport(Report.Details(kind: moment.noun,
                                  identifier: moment.id,
                                  senderName: moment.senderName,
                                  text: moment.caption,
                                  pairing: store.pairing,
                                  reporterName: myDisplayName))
    }

    /// Hides the partner's current status text (until they set another) and mails the report.
    func reportPartnerStatus() {
        guard let theirs = snapshot.theirs else { return }
        // The words' date, so the partner renaming themselves doesn't unhide them.
        persist(theirs.wordsAt, \.hiddenPartnerStatusAt, \.hiddenPartnerStatusAt)
        SharedStore.reloadWidgets()
        sendReport(Report.Details(kind: "status",
                                  identifier: "status at \(theirs.updatedAt.formatted(.iso8601))",
                                  senderName: theirs.displayName,
                                  text: "\(theirs.emoji) \(theirs.message)",
                                  pairing: store.pairing,
                                  reporterName: myDisplayName))
    }

    /// Blocks the partner: everything they sent leaves this iPhone at once, the
    /// link ends, their invites are refused from now on, and the developer is
    /// told. Local removal is not conditional on iCloud — a block must land
    /// even offline — so, unlike `unlink`, a failed cloud step is reported
    /// afterwards rather than stopping it.
    func block() async {
        isBusy = true
        defer { isBusy = false }
        let name = partnerName
        let status = snapshot.theirs
        let pairing = store.pairing
        let backend = backend
        let names = await backend.recordBlockedPartner()

        var cloudProblem: String?
        do {
            try await backend.unpair()
        } catch {
            cloudProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        finishUnlink(startingOver: false)

        sendReport(Report.Details(kind: "blocked user",
                                  identifier: names.isEmpty ? "(unknown record)" : names.joined(separator: ", "),
                                  senderName: name,
                                  text: status.map { "\($0.emoji) \($0.message)" } ?? "",
                                  pairing: pairing,
                                  reporterName: myDisplayName))
        if let cloudProblem {
            errorTitle = String(localized: "Blocked, not yet unlinked")
            errorMessage = String(localized: "\(name) is blocked and everything they sent has been removed from this iPhone. iCloud couldn't be reached to finish the unlink (\(cloudProblem)), so what you sent may still be in the shared space; try Settings → Unlink later if it reappears.")
        }
    }

    /// Opens Mail with the report. Without a mail account the text goes to the
    /// clipboard instead (this iPhone only, expiring), with the address to send it to.
    private func sendReport(_ details: Report.Details) {
        let body = Report.body(for: details)
        guard let url = Report.mailURL(for: details) else { return }
        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            Task { @MainActor in
                Clipboard.copy(text: body, localOnly: true)
                self.noticeMessage = String(localized: "Mail isn't set up on this iPhone, so the report has been copied to your clipboard for the next \(Clipboard.lifetimeMinutes) minutes. Please email it to \(AppConfig.supportEmail).")
            }
        }
    }
}

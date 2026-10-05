import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Edited locally, committed once on submit or dismiss. Binding straight to
    /// the model published per keystroke (racing writes, and clearing the field
    /// mid-edit flipped the app back to the welcome screen under this sheet).
    @State private var draftName = ""
    @State private var confirmingUnlink = false
    @State private var confirmingWipe = false
    @State private var confirmingBlock = false
    @State private var confirmingReopen = false
    /// Set when the iCloud side of an unlink failed, so a local-only reset can
    /// be offered explicitly rather than silently taken.
    @State private var offeringLocalOnly: Ending?
    /// Why the cloud unlink failed, shown inside the local-only dialog — an
    /// alert and a dialog presented in the same turn lose one of them.
    @State private var localOnlyReason: String?
    /// Outcome of a successful archive, for the alert saying where it went.
    @State private var archiveSummary: ArchiveSummary?
    /// An incomplete archive's summary, held behind its share sheet.
    @State private var summaryAfterShare: ArchiveSummary?
    /// An unlink/wipe waiting behind a device-only archive's share sheet;
    /// re-offered once that sheet closes instead of being silently dropped.
    @State private var pendingEndingAfterShare: Ending?
    @State private var confirmingEndingAfterShare: Ending?
    /// Seven taps on the Version row reveal diagnostics in Release builds —
    /// support needs the report from real installs, not just Debug ones.
    @State private var versionTapCount = 0
    @State private var editingOurDate = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            // Everyday first, danger last: Block, Unlink and Delete are the only red
            // rows, and each confirmation carries the full consequences. One page,
            // so every dialog below keeps its host.
            Form {
                Section {
                    LabeledContent("Your name") {
                        TextField("Your name", text: $draftName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit { commitName() }
                    }
                    LabeledContent("Nudges and moments") {
                        Text(notificationLabel)
                            .foregroundStyle(Theme.mutedText)
                    }
                    if notificationStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else if notificationStatus == .notDetermined {
                        // The system prompt was never shown (or was dismissed
                        // by a relaunch); "Not set" alone was a dead end.
                        Button("Turn on") {
                            Task {
                                await NotificationManager.requestAuthorizationIfNeeded()
                                notificationStatus = await NotificationManager.authorizationStatus()
                            }
                        }
                    }
                } header: {
                    Text("You")
                        .foregroundStyle(Theme.mutedText)
                        .accessibilityIdentifier("settings.section.header")
                } footer: {
                    Group {
                        Text("Your name is what \(model.partnerName) sees on everything you send.")
                    }
                    // The system footer grey is ~3.6:1 on the cream backdrop; this is AA.
                    .foregroundStyle(Theme.mutedText)
                }

                Section {
                    if model.isPaired {
                        Toggle("Read receipts", isOn: $model.readReceiptsEnabled)
                    }
                    if model.canEditAnniversary {
                        ourDateRow
                    }
                    if model.isPaired {
                        Toggle("Milestone reminders", isOn: $model.milestoneRemindersEnabled)
                    }
                    NavigationLink("Lock Screen widget") {
                        LockScreenWidgetHelp(partnerName: model.partnerName)
                    }
                } header: {
                    Text("Together")
                        .foregroundStyle(Theme.mutedText)
                        .accessibilityIdentifier("settings.section.header")
                } footer: {
                    Group {
                        if model.isPaired {
                            Text("Read receipts show \(model.partnerName) when you've looked, and you theirs, while you both have them on. Milestone reminders send a note on the morning of each one — a month, a year — that only says there's something to celebrate.")
                        }
                    }
                    .foregroundStyle(Theme.mutedText)
                }

                if model.role == .owner {
                    inviteSection
                }

                if model.hasMemoriesToArchive || model.isPaired {
                    Section {
                        if model.hasMemoriesToArchive {
                            Button {
                                Task { await saveMemories(then: nil) }
                            } label: {
                                HStack {
                                    Label("Save memories to iCloud…", systemImage: "square.and.arrow.down")
                                    Spacer(minLength: 12)
                                    if let progress = model.archiveProgress {
                                        ProgressView(value: progress)
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                        Text("\(Int(progress * 100))%")
                                            .font(Theme.rounded(13))
                                            .foregroundStyle(Theme.mutedText)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            // Primary, not accent: a Form tints buttons, and crimson read as destructive.
                            .tint(.primary)
                            .disabled(!model.canArchiveMemories)
                            if model.archiveProgress != nil {
                                Button("Cancel saving memories") { model.cancelArchive() }
                                    .tint(.primary)
                            }
                        }
                        if model.isPaired {
                            NavigationLink {
                                FreshStartView()
                            } label: {
                                LabeledContent("Fresh start", value: freshStartSummary)
                            }
                        }
                    } header: {
                        Text("Memories")
                            .foregroundStyle(Theme.mutedText)
                            .accessibilityIdentifier("settings.section.header")
                    } footer: {
                        Group {
                            Text(memoriesFooter)
                        }
                        .foregroundStyle(Theme.mutedText)
                    }
                }

                Section {
                    Toggle("Hide strong language", isOn: $model.contentFilterEnabled)
                    if let url = Report.mailURL(subject: "\(AppConfig.appName) report", body: "") {
                        Link(destination: url) {
                            Label("Report a problem", systemImage: "flag")
                        }
                        .tint(.primary)
                    }
                    NavigationLink("Terms of Use") {
                        TermsView(readOnly: true)
                    }
                    if model.isPaired {
                        Button("Block \(model.partnerName)…", role: .destructive) {
                            confirmingBlock = true
                        }
                    }
                } header: {
                    Text("Safety")
                        .foregroundStyle(Theme.mutedText)
                        .accessibilityIdentifier("settings.section.header")
                } footer: {
                    Group {
                        Text(safetyFooter)
                    }
                    .foregroundStyle(Theme.mutedText)
                }

                Section {
                    Button(unlinkLabel, role: .destructive) {
                        confirmingUnlink = true
                    }
                    Button("Delete everything and start over", role: .destructive) {
                        confirmingWipe = true
                    }
                } header: {
                    Text("Ending the link")
                        .foregroundStyle(Theme.mutedText)
                        .accessibilityIdentifier("settings.section.header")
                } footer: {
                    Group {
                        Text("Each asks first, and says exactly what goes.")
                    }
                    .foregroundStyle(Theme.mutedText)
                }

                Section {
                    LabeledContent("Version", value: versionString)
                        .contentShape(Rectangle())
                        .onTapGesture { versionTapCount += 1 }
                        // Seven taps is no way in under VoiceOver or Voice Control.
                        .accessibilityAction(named: Text("Show diagnostics")) { versionTapCount = 7 }
                    if showsDiagnostics {
                        NavigationLink("iCloud diagnostics") {
                            DiagnosticsView()
                        }
                    }
                } footer: {
                    Group {
                        Text("Statuses are stored in your own iCloud with the text end-to-end encrypted. Photos, drawings and voice memos are CloudKit assets, which are encrypted by default.")
                    }
                    .foregroundStyle(Theme.mutedText)
                }
            }
            .scrollContentBackground(.hidden)
            .hardTopScrollEdge()
            .background(Theme.Background())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $editingOurDate) {
                AnniversaryEditorView(mode: .edit)
                    .environment(model)
            }
            .task { notificationStatus = await NotificationManager.authorizationStatus() }
            // Re-check when the user returns from the Settings app.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { notificationStatus = await NotificationManager.authorizationStatus() }
            }
            .onAppear { draftName = model.myDisplayName }
            // Home's partner-left notice: straight to the dialog that saves and unlinks.
            .task {
                guard model.unlinkRequested else { return }
                model.unlinkRequested = false
                // After the sheet's own presentation: a dialog raised mid-transition is dropped.
                try? await Task.sleep(for: .milliseconds(400))
                confirmingUnlink = true
            }
            // Leaving the sheet commits whatever edit was in progress.
            .onDisappear { commitName() }
            // RootView's copy of this alert sits underneath this sheet, where
            // it cannot present — host it here too.
            .alert(model.errorAlertTitle,
                   isPresented: Binding(get: { model.errorMessage != nil },
                                        set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            // The cached link can be closed from another device — confirm it
            // against CloudKit rather than trusting the cached copy.
            .task { await model.refreshInviteURL() }
            // Here, not on the invite section: presentations inside a Form's rows don't reliably show.
            .modifier(InviteDialogs(confirmingReopen: $confirmingReopen))
            .confirmationDialog(unlinkTitle,
                                isPresented: $confirmingUnlink,
                                titleVisibility: .visible) {
                if model.hasMemoriesToArchive {
                    Button("Save memories, then unlink") {
                        Task { await saveMemories(then: .unlink) }
                    }
                }
                Button("Unlink", role: .destructive) {
                    Task { await end(.unlink) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unlinkFooter)
            }
            .confirmationDialog("Block \(model.partnerName)?",
                                isPresented: $confirmingBlock,
                                titleVisibility: .visible) {
                Button("Block and report", role: .destructive) {
                    Task {
                        await model.block()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything \(model.partnerName) sent is removed from this iPhone immediately, the link ends, their invites are refused from now on, and we're notified. There is no undo.")
            }
            .confirmationDialog("Delete everything and start over?",
                                isPresented: $confirmingWipe,
                                titleVisibility: .visible) {
                if model.hasMemoriesToArchive {
                    Button("Save memories, then delete") {
                        Task { await saveMemories(then: .wipe) }
                    }
                }
                Button("Delete everything", role: .destructive) {
                    Task { await end(.wipe) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(wipeFooter)
            }
            .confirmationDialog("Couldn't reach iCloud",
                                isPresented: Binding(get: { offeringLocalOnly != nil },
                                                     set: { if !$0 { offeringLocalOnly = nil } }),
                                titleVisibility: .visible) {
                Button("Remove from this iPhone only", role: .destructive) {
                    let ending = offeringLocalOnly ?? .unlink
                    offeringLocalOnly = nil
                    model.forceLocalReset(startingOver: ending == .wipe)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { offeringLocalOnly = nil }
            } message: {
                Text((localOnlyReason.map { $0 + "\n\n" } ?? "")
                     + String(localized: "Nothing was deleted from iCloud, so what you've shared is still in \(model.partnerName)'s copy. You can clear this iPhone now and try again from a better connection, or cancel and wait."))
            }
            // Only reachable when iCloud Drive wasn't available; nothing has
            // been deleted yet, so dismissing this can't lose the archive.
            .sheet(isPresented: Binding(get: { model.archiveToShare != nil },
                                        set: { if !$0 { model.archiveToShare = nil } }),
                   onDismiss: {
                       model.archiveToShare = nil
                       if let summary = summaryAfterShare {
                           summaryAfterShare = nil
                           archiveSummary = summary
                       }
                       if let pending = pendingEndingAfterShare {
                           pendingEndingAfterShare = nil
                           confirmingEndingAfterShare = pending
                       }
                   }) {
                if let url = model.archiveToShare {
                    ShareSheet(url: url)
                }
            }
            .confirmationDialog(
                confirmingEndingAfterShare == .wipe
                    ? "Delete everything and start over?"
                    : unlinkTitle,
                isPresented: Binding(get: { confirmingEndingAfterShare != nil },
                                     set: { if !$0 { confirmingEndingAfterShare = nil } }),
                titleVisibility: .visible
            ) {
                Button(confirmingEndingAfterShare == .wipe ? "Delete everything" : "Unlink",
                       role: .destructive) {
                    let ending = confirmingEndingAfterShare ?? .unlink
                    confirmingEndingAfterShare = nil
                    Task { await end(ending) }
                }
                Button("Not now", role: .cancel) { confirmingEndingAfterShare = nil }
            } message: {
                Text("The archive was only shared from this iPhone — continue only if you saved it somewhere safe.")
            }
            .alert("Memories saved", isPresented: Binding(get: { archiveSummary != nil },
                                                          set: { if !$0 { archiveSummary = nil } })) {
                Button("OK", role: .cancel) { archiveSummary = nil }
            } message: {
                Text(archiveSummary?.text ?? "")
            }
        }
    }

    /// Owner's invite link, kept reachable here because RootView replaces the
    /// screen that created it. Its own property: inline it timed out the type-checker.
    @ViewBuilder
    private var inviteSection: some View {
        Section {
            if model.inviteClosed {
                LabeledContent("Status", value: String(localized: "Closed"))
                // Still worth sharing: the closed link re-admits the existing
                // partner on a new phone, and admits nobody else.
                if let url = model.inviteURL {
                    InviteShareLink(url: url) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    CopyLinkButton(url: url, prominent: false)
                }
                // The way back if a close strands the partner (`inviteLeftClosed`).
                Button("Reopen the invite link") { confirmingReopen = true }
                    .disabled(model.isChangingInviteLink)
            } else {
                // Absent only until `refreshInviteURL()` returns — a loading
                // state, not an empty one.
                if let url = model.inviteURL {
                    InviteLinkText(url: url)
                    InviteShareLink(url: url) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    CopyLinkButton(url: url, prominent: false)
                } else if model.inviteLinkUnavailable {
                    // No share on the server — say so rather than spin, without
                    // claiming it was closed (nothing here means the partner joined).
                    LabeledContent("Status", value: String(localized: "Unavailable"))
                } else {
                    LabeledContent("Status") {
                        ProgressView().controlSize(.small)
                    }
                }
                // Not red: it asks first (re-seating the partner), and it reopens.
                Button("Close the invite link") {
                    Task { await model.closeInvite() }
                }
                .foregroundStyle(Theme.accentText)
                .disabled(model.isChangingInviteLink)
            }
        } header: {
            Text("Invite link")
                .foregroundStyle(Theme.mutedText)
                .accessibilityIdentifier("settings.section.header")
        } footer: {
            Group {
                Text(inviteFooter)
            }
            .foregroundStyle(Theme.mutedText)
        }
    }

    /// Pulled out of the section: inline it timed out the type-checker. The
    /// link does *not* close itself once the partner joins — CloudKit can't
    /// convert a link-joined participant in one step (CLAUDE.md invariant 9),
    /// so the copy says what actually happens in each state.
    private var inviteFooter: String {
        if model.inviteClosed {
            return String(localized: "Closed. Nobody new can use the link you sent, even if it was forwarded or screenshotted. If \(model.partnerName) is already in, it still re-admits them on a new phone.")
        }
        // `theirs` is only a hint that they're in (they may have joined and not
        // posted yet), so neither branch claims to know for certain.
        if model.snapshot.theirs != nil {
            return String(localized: "\(model.partnerName) is in, and the link still admits anyone holding it. Closing it re-seats them privately — have them ready to tap the link once more.")
        }
        return String(localized: "Anyone holding the link can join. If \(model.partnerName) hasn't joined yet, closing it simply shuts it; once they're in, closing asks them to tap the link once more.")
    }

    private var safetyFooter: String {
        String(localized: "Long-press a status or open a photo's menu to report it. Reports and blocks go to \(AppConfig.supportEmail) and are acted on within 24 hours.")
    }

    private var memoriesFooter: String {
        String(localized: "Saving copies everything into iCloud Drive as ordinary files. A fresh start clears your shared history from both iPhones once you both agree.")
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var showsDiagnostics: Bool {
        #if DEBUG
        true
        #else
        versionTapCount >= 7
        #endif
    }

    /// The owner's date, in plain sight: the secret is the count, not the date.
    private var ourDateRow: some View {
        Button {
            editingOurDate = true
        } label: {
            LabeledContent("Our date") {
                if let anniversary = model.anniversary {
                    Text(anniversary.startsAt,
                         format: Date.FormatStyle(date: .abbreviated, time: .omitted,
                                                  timeZone: anniversary.timeZone))
                } else {
                    Text("Not set")
                }
            }
        }
        .tint(.primary)
    }

    private var freshStartSummary: String {
        switch model.freshStartPhase {
        case .idle: return ""
        case .asked: return String(localized: "Asked")
        case .theyAsked: return String(localized: "\(model.partnerName) asked")
        case .agreed: return String(localized: "Agreed")
        case .starting, .clearing: return String(localized: "Clearing")
        case .waitingForPartner: return String(localized: "Your side is done")
        }
    }

    private struct ArchiveSummary: Identifiable {
        let id = UUID()
        let text: String
    }


    /// A blank name never commits ("" means "no name" and would swap the screen
    /// under this sheet for onboarding). `model.hasName` gates it because a wipe
    /// dismisses this sheet — `onDisappear` would write the stale draft back
    /// onto a model that just deliberately forgot it.
    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.hasName, !trimmed.isEmpty, trimmed != model.myDisplayName else { return }
        model.myDisplayName = trimmed
    }

    /// Archives first, and deletes only if the archive is complete and reached
    /// iCloud Drive. A device-only archive shows the share sheet, holding the
    /// ending until that sheet closes — see `pendingEndingAfterShare`.
    private func saveMemories(then ending: Ending?) async {
        guard let outcome = await model.archiveMemories() else { return }

        // Part of the history would be deleted with no copy kept: stop, say so,
        // and leave the ending for the user to choose again.
        if ending != nil, !outcome.isComplete {
            let summary = ArchiveSummary(text: successText(outcome) + " "
                + String(localized: "Nothing was unlinked, because the archive isn't complete."))
            // A device-only archive's share sheet is already up; one presentation at a time.
            if outcome.destination == .deviceOnly {
                summaryAfterShare = summary
            } else {
                archiveSummary = summary
            }
            return
        }

        switch outcome.destination {
        case .iCloudDrive:
            guard let ending else {
                archiveSummary = ArchiveSummary(text: successText(outcome))
                return
            }
            await end(ending)
        case .deviceOnly:
            // `model.archiveToShare` is set, which brings up the share sheet.
            pendingEndingAfterShare = ending
        }
    }

    private func successText(_ outcome: MemoryArchive.Outcome) -> String {
        let moments = outcome.momentCount == 1
            ? String(localized: "1 moment")
            : String(localized: "\(outcome.momentCount) moments")
        let statuses = outcome.statusCount == 1
            ? String(localized: "1 status")
            : String(localized: "\(outcome.statusCount) statuses")
        var text = outcome.destination == .iCloudDrive
            ? String(localized: "\(moments) and \(statuses) saved to iCloud Drive › \(AppConfig.appName) › \(outcome.folder.lastPathComponent).")
            : String(localized: "\(moments) and \(statuses) saved on this iPhone only.")
        if outcome.unrecovered > 0 {
            text += " " + String(localized: "\(outcome.unrecovered) couldn't be fetched back from iCloud and are listed in Memories.txt without a file.")
        }
        if !outcome.includesZone {
            text += " " + String(localized: "iCloud couldn't be reached, so it holds only what was on this iPhone.")
        } else if outcome.unreadable > 0 {
            text += " " + String(localized: "\(outcome.unreadable) items in iCloud couldn't be read on this iPhone and were left out.")
        }
        return text
    }

    /// Which of the two endings a dialog is confirming.
    private enum Ending {
        case unlink
        case wipe
    }

    private var unlinkLabel: String {
        String(localized: "Unlink from \(model.partnerName)")
    }

    private var unlinkTitle: String {
        String(localized: "Unlink from \(model.partnerName)?")
    }

    /// The two roles genuinely differ — the owner holds the shared space, the
    /// other person is a guest in it — so each hears exactly what leaves and stays.
    private var unlinkFooter: String {
        if model.role == .owner, model.partnerHasLeft {
            return String(localized: "\(model.partnerName) has already left. Deletes the shared space from your iCloud, with everything you sent. Your name stays on this iPhone, so you can send a new invite link.")
        }
        if model.role == .owner {
            return String(localized: "Deletes the shared space from your iCloud: both your statuses, and every photo, drawing and voice memo either of you sent. \(model.partnerName)'s app unlinks itself within a few minutes of next opening. Your name stays on this iPhone, so you can pair again.")
        }
        return String(localized: "Deletes everything you sent — your status, your photos, drawings and voice memos — out of the shared space, then leaves it. Anything \(model.partnerName) sent stays in their own iCloud, which is theirs to delete. Your name stays on this iPhone, so you can pair again.")
    }

    private var wipeFooter: String {
        String(localized: "Does everything unlinking does, and also forgets your name and clears every photo, drawing and voice memo held on this iPhone. \(AppConfig.appName) starts as it did the day you installed it. There is no undo.")
    }

    /// Try the cloud; only claim it's done when it is.
    private func end(_ ending: Ending) async {
        if await model.unlink(startingOver: ending == .wipe) {
            dismiss()
        } else {
            // Move the reason into the dialog rather than racing it with the alert.
            localOnlyReason = model.errorMessage
            model.errorMessage = nil
            offeringLocalOnly = ending
        }
    }

    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return String(localized: "On")
        case .denied: return String(localized: "Off")
        default: return String(localized: "Not set")
        }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

/// The invite section's confirmations and result, hosted at the Form level.
/// Its own modifier: inline in `body` it timed out the type-checker.
private struct InviteDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var confirmingReopen: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Close the invite link?",
                                isPresented: Binding(get: { model.confirmingInviteReseat },
                                                     set: { model.confirmingInviteReseat = $0 }),
                                titleVisibility: .visible) {
                Button("Close and re-seat \(model.partnerName)", role: .destructive) {
                    Task { await model.closeInviteReseatingPartner() }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("\(model.partnerName) joined through this link, so closing it briefly takes them off your shared space and re-adds them privately. Have them ready: they tap the invite link once more to get back in. If anything fails, the app tries to reopen the link and tells you how it went.")
            }
            .confirmationDialog("Reopen the invite link?",
                                isPresented: $confirmingReopen,
                                titleVisibility: .visible) {
                Button("Reopen") { Task { await model.reopenInvite() } }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Anyone who has the link will be able to join again. Reopen it if \(model.partnerName) can't get back in.")
            }
            .alert("Invite link", isPresented: Binding(get: { model.inviteNotice != nil },
                                                       set: { if !$0 { model.inviteNotice = nil } })) {
                Button("OK", role: .cancel) { model.inviteNotice = nil }
            } message: {
                Text(model.inviteNotice ?? "")
            }
    }
}

/// The Lock Screen widget's how-to, a page of its own rather than a row that
/// looked tappable and wasn't.
private struct LockScreenWidgetHelp: View {
    let partnerName: String

    var body: some View {
        ZStack {
            Theme.Background()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Touch and hold your Lock Screen.")
                    step(2, "Tap Customize, then the Lock Screen.")
                    step(3, "Tap the widget row and add \(AppConfig.appName).")
                    Text("\(partnerName)'s status, and the heart that sends a nudge, without unlocking.")
                        .font(Theme.rounded(15))
                        .foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding(20)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle("Lock Screen widget")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(Theme.rounded(16, .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.accent, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.rounded(17))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .card(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): ") + Text(text))
    }
}

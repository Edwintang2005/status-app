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
    /// Set when the iCloud side of an unlink failed, so a local-only reset can
    /// be offered explicitly rather than silently taken.
    @State private var offeringLocalOnly: Ending?
    /// Why the cloud unlink failed, shown inside the local-only dialog — an
    /// alert and a dialog presented in the same turn lose one of them.
    @State private var localOnlyReason: String?
    /// Outcome of a successful archive, for the alert saying where it went.
    @State private var archiveSummary: ArchiveSummary?
    /// An unlink/wipe waiting behind a device-only archive's share sheet;
    /// re-offered once that sheet closes instead of being silently dropped.
    @State private var pendingEndingAfterShare: Ending?
    @State private var confirmingEndingAfterShare: Ending?
    /// Seven taps on the Version row reveal diagnostics in Release builds —
    /// support needs the report from real installs, not just Debug ones.
    @State private var versionTapCount = 0
    /// A long press on the title reveals the owner's anniversary row — the
    /// date behind the easter egg, kept out of the ordinary list.
    @State private var showsOurDate = false
    @State private var editingOurDate = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Your name") {
                        TextField("Your name", text: $draftName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit { commitName() }
                    }
                } footer: {
                    Text("This is the name \(model.partnerName) sees on your status, your nudges and anything you send. Their name is theirs to set.")
                }

                Section("Notifications") {
                    LabeledContent("Nudges and moments") {
                        Text(notificationLabel)
                            .foregroundStyle(.secondary)
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
                }

                Section {
                    Toggle("Hide strong language", isOn: $model.contentFilterEnabled)
                    if model.isPaired {
                        Button("Block \(model.partnerName)…", role: .destructive) {
                            confirmingBlock = true
                        }
                    }
                    NavigationLink("Terms of Use") {
                        TermsView(readOnly: true)
                    }
                    if let url = Report.mailURL(subject: "\(AppConfig.appName) report", body: "") {
                        Link("Report a problem", destination: url)
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text(safetyFooter)
                }

                if model.isPaired {
                    Section {
                        Toggle("Read receipts", isOn: $model.readReceiptsEnabled)
                    } footer: {
                        Text("Lets \(model.partnerName) see when you've looked at what they sent, and shows you the same for your sends while they have it on too. Turning it off stops sharing new ones.")
                    }
                }

                if showsOurDate, model.canEditAnniversary {
                    ourDateSection
                }

                if model.role == .owner {
                    inviteSection
                }

                if !model.history.isEmpty {
                    Section {
                        Button {
                            Task { await saveMemories(then: nil) }
                        } label: {
                            HStack {
                                Text("Save memories to iCloud…")
                                Spacer(minLength: 12)
                                if let progress = model.archiveProgress {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                    Text("\(Int(progress * 100))%")
                                        .font(Theme.rounded(13))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .disabled(!model.canArchiveMemories)
                    } footer: {
                        Text(archiveFooter)
                    }
                }

                Section {
                    Button(unlinkLabel, role: .destructive) {
                        confirmingUnlink = true
                    }
                } footer: {
                    Text(unlinkFooter)
                }

                Section {
                    Button("Delete everything and start over", role: .destructive) {
                        confirmingWipe = true
                    }
                } footer: {
                    Text(wipeFooter)
                }

                Section {
                    LabeledContent("Version", value: versionString)
                        .contentShape(Rectangle())
                        .onTapGesture { versionTapCount += 1 }
                    if showsDiagnostics {
                        NavigationLink("iCloud diagnostics") {
                            DiagnosticsView()
                        }
                    }
                } footer: {
                    Text("Statuses are stored in your own iCloud with the text end-to-end encrypted. Photos, drawings and voice memos are CloudKit assets, which are encrypted by default.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Background())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.headline)
                        .onLongPressGesture(minimumDuration: 1.2) {
                            guard model.canEditAnniversary else { return }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.smooth) { showsOurDate = true }
                        }
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityAction(named: Text("Our date")) {
                            if model.canEditAnniversary { showsOurDate = true }
                        }
                }
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
            // Leaving the sheet commits whatever edit was in progress.
            .onDisappear { commitName() }
            // RootView's copy of this alert sits underneath this sheet, where
            // it cannot present — host it here too.
            .alert("Something went wrong",
                   isPresented: Binding(get: { model.errorMessage != nil },
                                        set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            // The cached link can be closed from another device — confirm it
            // against CloudKit rather than trusting the cached copy.
            .task { await model.refreshInviteURL() }
            .confirmationDialog(unlinkTitle,
                                isPresented: $confirmingUnlink,
                                titleVisibility: .visible) {
                if !model.history.isEmpty {
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
                if !model.history.isEmpty {
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
                    ShareLink(item: url) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    CopyLinkButton(url: url, prominent: false)
                }
            } else {
                // Absent only until `refreshInviteURL()` returns — a loading
                // state, not an empty one.
                if let url = model.inviteURL {
                    InviteLinkText(url: url)
                    ShareLink(item: url) {
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
                Button("Close the invite link", role: .destructive) {
                    Task { await model.closeInvite() }
                }
            }
        } header: {
            Text("Invite link")
        } footer: {
            Text(inviteFooter)
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
            return String(localized: "\(model.partnerName) is in, and the link still admits anyone holding it. Closing it now would also remove them: to close it safely, have them on standby and use iCloud diagnostics (tap Version seven times) → Promote partner & close invite. They confirm by tapping the link once.")
        }
        return String(localized: "Anyone holding the link can join. If \(model.partnerName) hasn't joined yet, you can close it now and create a fresh one — once they're in, closing is done from iCloud diagnostics with them on standby.")
    }

    private var safetyFooter: String {
        String(localized: "The filter hides strong language in what \(model.partnerName) sends; long-press a status or open a photo's menu to report it, which removes it from this iPhone at once. Reports and blocks go to \(AppConfig.supportEmail) and are acted on within 24 hours.")
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

    private var ourDateSection: some View {
        Section {
            Button {
                editingOurDate = true
            } label: {
                LabeledContent("Our date") {
                    if let anniversary = model.anniversary {
                        Text(anniversary.startsAt,
                             format: Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                      timeZone: anniversary.timeZone))
                    } else {
                        Text("Not set")
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Just for you two")
        } footer: {
            Text("The day the hidden count starts from. \(model.partnerName) sees the same count; only you can change the date.")
        }
    }

    private struct ArchiveSummary: Identifiable {
        let id = UUID()
        let text: String
    }

    private var archiveFooter: String {
        String(localized: "Copies every photo, drawing and voice memo — with the date, the caption and who sent it — into iCloud Drive › \(AppConfig.appName), as ordinary files that open in anything. Nothing is deleted, and the archive stays after you unlink.")
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

    /// Archives first, and deletes only if the archive reached iCloud Drive.
    /// A device-only archive shows the share sheet, holding the ending until
    /// that sheet closes — see `pendingEndingAfterShare`.
    private func saveMemories(then ending: Ending?) async {
        guard let outcome = await model.archiveMemories() else { return }

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
        var text = outcome.momentCount == 1
            ? String(localized: "1 moment saved to iCloud Drive › \(AppConfig.appName) › \(outcome.folder.lastPathComponent).")
            : String(localized: "\(outcome.momentCount) moments saved to iCloud Drive › \(AppConfig.appName) › \(outcome.folder.lastPathComponent).")
        if outcome.unrecovered > 0 {
            text += " " + String(localized: "\(outcome.unrecovered) couldn't be fetched back from iCloud and are listed in Memories.txt without a file.")
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

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
                    }
                }

                if model.isPaired {
                    Section {
                        Toggle("Read receipts", isOn: $model.readReceiptsEnabled)
                    } footer: {
                        Text("Lets \(model.partnerName) see when you've looked at what they sent, and shows you the same for your sends while they have it on too. Turning it off stops sharing new ones.")
                    }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
                     + "Nothing was deleted from iCloud, so what you've shared is still in \(model.partnerName)'s copy. You can clear this iPhone now and try again from a better connection, or cancel and wait.")
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
                LabeledContent("Status", value: "Closed")
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
                    LabeledContent("Status", value: "Unavailable")
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

    /// Pulled out of the section: inline it timed out the type-checker.
    private var inviteFooter: String {
        if model.inviteClosed {
            return "Closed automatically when \(model.partnerName) joined. Nobody "
                + "else can use the link you sent, even if it was forwarded or "
                + "screenshotted. \(model.partnerName) can still use it to rejoin "
                + "on a new phone."
        }
        return "Anyone holding the link can still join. It closes itself the "
            + "moment \(model.partnerName) does — close it now if you sent it to "
            + "the wrong person."
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

    private struct ArchiveSummary: Identifiable {
        let id = UUID()
        let text: String
    }

    private var archiveFooter: String {
        "Copies every photo, drawing and voice memo — with the date, the caption "
            + "and who sent it — into iCloud Drive › \(AppConfig.appName), as ordinary "
            + "files that open in anything. Nothing is deleted, and the archive "
            + "stays after you unlink."
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
        var text = "\(outcome.momentCount) moment\(outcome.momentCount == 1 ? "" : "s") "
            + "saved to iCloud Drive › \(AppConfig.appName) › "
            + "\(outcome.folder.lastPathComponent)."
        if outcome.unrecovered > 0 {
            text += " \(outcome.unrecovered) couldn't be fetched back from iCloud and are "
                + "listed in Memories.txt without a file."
        }
        return text
    }

    /// Which of the two endings a dialog is confirming.
    private enum Ending {
        case unlink
        case wipe
    }

    private var unlinkLabel: String {
        "Unlink from \(model.partnerName)"
    }

    private var unlinkTitle: String {
        "Unlink from \(model.partnerName)?"
    }

    /// The two roles genuinely differ — the owner holds the shared space, the
    /// other person is a guest in it — so each hears exactly what leaves and stays.
    private var unlinkFooter: String {
        if model.role == .owner {
            return "Deletes the shared space from your iCloud: both your statuses, "
                + "and every photo, drawing and voice memo either of you sent. "
                + "\(model.partnerName)'s app unlinks itself the next time it opens. "
                + "Your name stays on this iPhone, so you can pair again."
        }
        return "Deletes everything you sent — your status, your photos, drawings "
            + "and voice memos — out of the shared space, then leaves it. Anything "
            + "\(model.partnerName) sent stays in their own iCloud, which is theirs "
            + "to delete. Your name stays on this iPhone, so you can pair again."
    }

    private var wipeFooter: String {
        return "Does everything unlinking does, and also forgets your name and "
            + "clears every photo, drawing and voice memo held on this iPhone. \(AppConfig.appName) "
            + "starts as it did the day you installed it. There is no undo."
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
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Not set"
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

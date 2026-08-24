import SwiftUI
import UserNotifications

/// Which demo sheet is showing. Declared unconditionally so the `.sheet`
/// modifier below doesn't need to appear and disappear between build
/// configurations; in CloudKit builds nothing ever sets it.
enum DemoSheet: String, Identifiable {
    case status
    case moment
    case voice

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmingUnlink = false
    @State private var confirmingWipe = false
    /// Set when the iCloud side of an unlink failed, so the only remaining
    /// option — leaving their copy alone and cutting this phone loose — can be
    /// offered explicitly rather than silently taken.
    @State private var offeringLocalOnly: Ending?
    /// The outcome of a successful archive, for the alert that says where it
    /// went. Not the archive itself — by then it's out of the app's hands.
    @State private var archiveSummary: ArchiveSummary?
    /// Owned here, not by the Section. A `.sheet` attached to a `Section`
    /// inside a `Form` dismisses the enclosing sheet instead of presenting.
    @State private var demoSheet: DemoSheet?
    /// Counts taps on the Version row towards revealing the demo controls.
    /// Deliberately not persisted — the count restarts every time Settings
    /// opens, so a half-finished sequence can't linger.
    @State private var versionTaps = 0

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Your name") {
                        TextField("Your name", text: $model.myDisplayName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
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

                #if TETHER_LOCAL_MODE
                if model.isDemoUnlocked {
                Section {
                    LabeledContent("Their name") {
                        TextField("Partner", text: $model.demoPartnerName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    Button("Set their status…") { demoSheet = .status }
                    Button("Make them nudge you") {
                        Task { await model.simulatePartnerNudge() }
                    }
                    Button("Send yourself a photo or doodle…") { demoSheet = .moment }
                    Button("Send yourself a voice memo…") { demoSheet = .voice }
                } header: {
                    Text("Demo controls")
                } footer: {
                    Text("Drive the other side of the conversation, including the name they'd have set for themselves. Everything here behaves exactly as a real update would — widgets and notifications included.\n\nHidden by default. Tap Version seven times to bring it back.")
                }
                }
                #else
                if model.role == .owner {
                    Section {
                        Button("Close the invite link") {
                            Task { await model.lockPairing() }
                        }
                    } footer: {
                        Text("Stops anyone else joining with a link you've already sent. Do this once your partner is paired.")
                    }
                }
                #endif

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
                        // The hidden switch for the demo controls. A row, not a
                        // button, so it reads as what it is — a version number
                        // — to anyone who isn't counting taps.
                        .contentShape(Rectangle())
                        .onTapGesture(perform: countVersionTap)

                    #if TETHER_LOCAL_MODE
                    if model.isDemoUnlocked {
                        Button("Hide demo controls") { model.hideDemoControls() }
                    }
                    #endif
                } footer: {
                    // Deliberately no longer points at "the controls above":
                    // they're hidden until the switch above is found.
                    Text(model.isLocalDemo
                         ? "Demo build. Nothing is sent anywhere — the other side of the conversation is simulated on this device."
                         : "Statuses are stored in your own iCloud with the text end-to-end encrypted. Photos, drawings and voice memos are CloudKit assets, which are encrypted by default.")
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
            .confirmationDialog(unlinkTitle,
                                isPresented: $confirmingUnlink,
                                titleVisibility: .visible) {
                if !model.history.isEmpty {
                    Button("Save memories, then \(model.isLocalDemo ? "reset" : "unlink")") {
                        Task { await saveMemories(then: .unlink) }
                    }
                }
                Button(model.isLocalDemo ? "Reset" : "Unlink", role: .destructive) {
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
                Text("Nothing was deleted from iCloud, so what you've shared is still in \(model.partnerName)'s copy. You can clear this iPhone now and try again from a better connection, or cancel and wait.")
            }
            .sheet(item: $demoSheet) { sheet in
                demoSheetContent(sheet)
            }
            // Only reachable when iCloud Drive wasn't available. Nothing has
            // been deleted at this point, so the archive can't be lost by
            // dismissing this.
            .sheet(isPresented: Binding(get: { model.archiveToShare != nil },
                                        set: { if !$0 { model.archiveToShare = nil } })) {
                if let url = model.archiveToShare {
                    ShareSheet(url: url)
                }
            }
            .alert("Memories saved", isPresented: Binding(get: { archiveSummary != nil },
                                                          set: { if !$0 { archiveSummary = nil } })) {
                Button("OK", role: .cancel) { archiveSummary = nil }
            } message: {
                Text(archiveSummary?.text ?? "")
            }
        }
    }

    @ViewBuilder
    private func demoSheetContent(_ sheet: DemoSheet) -> some View {
        #if TETHER_LOCAL_MODE
        switch sheet {
        case .status:
            MoodPickerView(title: "\(model.partnerName)'s status",
                           initialEmoji: model.snapshot.theirs?.emoji ?? "",
                           initialMessage: model.snapshot.theirs?.message ?? "",
                           initialIsCelebration: model.snapshot.theirs?.isCelebration ?? false) { emoji, message, isCelebration in
                Task {
                    await model.simulatePartnerStatus(emoji: emoji,
                                                      message: message,
                                                      isCelebration: isCelebration)
                }
            }
        case .moment:
            MomentComposerView(title: "Send as \(model.partnerName)",
                               sendLabel: "Receive") { image, kind, caption in
                Task { await model.simulatePartnerMoment(image: image, kind: kind, caption: caption) }
            }
            .environment(model)
        case .voice:
            // Recorded on this device but filed as though it arrived, so the
            // notification, the widget and the history all behave exactly as
            // they would for a real memo.
            VoiceMemoComposerView(title: "Record as \(model.partnerName)",
                                  sendLabel: "Receive") { url, duration, waveform, caption in
                Task {
                    await model.simulatePartnerVoiceMemo(fileURL: url,
                                                         duration: duration,
                                                         waveform: waveform,
                                                         caption: caption)
                }
            }
            .environment(model)
        }
        #else
        EmptyView()
        #endif
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Seven taps, the same count iOS itself uses for its hidden switches.
    /// A no-op in CloudKit builds: there is no demo code in them to reveal.
    private func countVersionTap() {
        #if TETHER_LOCAL_MODE
        guard !model.isDemoUnlocked else { return }
        versionTaps += 1
        switch versionTaps {
        case 7:
            versionTaps = 0
            model.unlockDemoControls()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case 4...:
            // A nudge that something is counting, only once you're most of the
            // way there — otherwise a stray tap gives the game away.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
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

    /// Archives first, and only then does the thing that deletes.
    ///
    /// The order is the whole point. If the archive reached iCloud Drive it is
    /// safe and the ending can go ahead; if it only reached this device, the
    /// share sheet comes up and the ending is deliberately *not* performed —
    /// deleting the originals while the only copy sits in a temporary folder
    /// would be the exact failure this feature exists to prevent.
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
            break
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
        model.isLocalDemo ? "Reset demo" : "Unlink from \(model.partnerName)"
    }

    private var unlinkTitle: String {
        model.isLocalDemo ? "Reset the demo?" : "Unlink from \(model.partnerName)?"
    }

    /// Says exactly what leaves and what stays. The two roles genuinely differ
    /// — the owner holds the shared space, the other person is a guest in it —
    /// and glossing over that is the one thing nobody would forgive.
    private var unlinkFooter: String {
        if model.isLocalDemo {
            return "Clears the demo partner and everything sent locally. Your name stays."
        }
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
        let first = model.isLocalDemo ? "Clears the demo" : "Does everything unlinking does"
        return "\(first), and also forgets your name and clears every photo, "
            + "drawing and voice memo held on this iPhone. \(AppConfig.appName) "
            + "starts as it did the day you installed it. There is no undo."
    }

    /// Both endings run the same way: try the cloud, and only claim it's done
    /// when it is.
    private func end(_ ending: Ending) async {
        if await model.unlink(startingOver: ending == .wipe) {
            dismiss()
        } else {
            // `model.errorMessage` already says what went wrong; this offers
            // the only thing left.
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

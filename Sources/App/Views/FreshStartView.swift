import SwiftUI

/// Asking for, agreeing to and following a fresh start: the shared history
/// cleared from both iPhones and iCloud while the link carries on. Pushed from
/// Settings, presented from the Home card. Saving memories comes first —
/// skippable behind a confirmation — and an incomplete archive stops before
/// anything is asked or agreed. Its own alerts: pushed over Settings, the
/// model's shared error alert would be presented by two views at once.
struct FreshStartView: View {
    @Environment(AppModel.self) private var model

    private enum Action: Identifiable {
        case ask
        case agree

        var id: Self { self }
    }

    @State private var confirmingSkip: Action?
    @State private var confirmingWithdraw = false
    /// A device-only archive, offered for sharing before the action goes on.
    @State private var shareURL: URL?
    @State private var actionAfterShare: Action?
    @State private var noticeAfterShare: String?
    @State private var confirmingAfterShare: Action?
    @State private var notice: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                phaseContent
            } footer: {
                Group {
                    Text(footer)
                }
                // The system footer grey is ~3.6:1 on the cream backdrop; this is AA.
                .foregroundStyle(Theme.mutedText)
            }
            if let progress = model.archiveProgress {
                Section {
                    LabeledContent("Saving memories") {
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                    Button("Cancel saving memories") { model.cancelArchive() }
                }
            }
            actions
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Background())
        .navigationTitle("Fresh start")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(skipTitle,
                            isPresented: Binding(get: { confirmingSkip != nil },
                                                 set: { if !$0 { confirmingSkip = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmingSkip) { action in
            Button(action == .ask ? "Ask without saving" : "Agree without saving", role: .destructive) {
                Task { await perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Nothing is saved anywhere first. Once you've both agreed, every photo, drawing, voice memo and status in your history is gone from both iPhones and iCloud.")
        }
        .confirmationDialog("Withdraw your request?",
                            isPresented: $confirmingWithdraw,
                            titleVisibility: .visible) {
            Button("Withdraw") { Task { await withdraw() } }
            Button("Keep asking", role: .cancel) {}
        } message: {
            Text("Nothing has been cleared. \(model.partnerName) won't be asked any more.")
        }
        // Only for an archive iCloud Drive couldn't take: nothing has been asked
        // or agreed yet, so closing it can't lose anything.
        .sheet(isPresented: Binding(get: { shareURL != nil },
                                    set: { if !$0 { shareURL = nil } }),
               onDismiss: {
                   shareURL = nil
                   if let text = noticeAfterShare {
                       noticeAfterShare = nil
                       notice = text
                   }
                   if let action = actionAfterShare {
                       actionAfterShare = nil
                       confirmingAfterShare = action
                   }
               }) {
            if let shareURL {
                ShareSheet(url: shareURL)
            }
        }
        .confirmationDialog(confirmingAfterShare == .agree ? "Agree to the fresh start?" : "Ask for a fresh start?",
                            isPresented: Binding(get: { confirmingAfterShare != nil },
                                                 set: { if !$0 { confirmingAfterShare = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmingAfterShare) { action in
            Button(action == .ask ? "Ask" : "Agree", role: .destructive) {
                Task { await perform(action) }
            }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("The archive was only shared from this iPhone — continue only if you saved it somewhere safe.")
        }
        .alert("Fresh start", isPresented: Binding(get: { notice != nil },
                                                   set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Where it stands

    @ViewBuilder
    private var phaseContent: some View {
        switch model.freshStartPhase {
        case .idle(let lastCleared):
            Text("Clear your shared history and carry on together.")
                .font(Theme.rounded(17, .semibold))
            if let lastCleared {
                LabeledContent("Last fresh start") {
                    Text(lastCleared, format: .dateTime.day().month().year())
                }
            }
        case .asked(let since):
            if let since {
                RelativeTime(since) { when in
                    Text("You asked \(model.partnerName) for a fresh start \(when).")
                }
            } else {
                Text("You asked \(model.partnerName) for a fresh start.")
            }
            Text("Nothing is cleared until they agree. The request stays until you withdraw it.")
                .foregroundStyle(.secondary)
        case .theyAsked(let asked):
            RelativeTime(asked) { when in
                Text("\(model.partnerName) asked for a fresh start \(when).")
                    .font(Theme.rounded(17, .semibold))
            }
            Text("If you agree, the history you share is cleared from both iPhones and iCloud. Agreeing can't be undone.")
                .foregroundStyle(.secondary)
        case .agreed:
            Text("You've agreed.")
                .font(Theme.rounded(17, .semibold))
            Text("\(model.partnerName)'s iPhone starts the clear the next time \(AppConfig.appName) opens there; this one follows.")
                .foregroundStyle(.secondary)
        case .starting:
            busyRow(String(localized: "\(model.partnerName) agreed. Starting the clear…"))
        case .clearing:
            if model.isClearingHistory {
                busyRow(String(localized: "Clearing your shared history…"))
            } else if let failure = model.freshStartFailure {
                Text("The clear couldn't finish yet.")
                    .font(Theme.rounded(17, .semibold))
                Text(failure)
                    .foregroundStyle(.secondary)
            } else {
                busyRow(String(localized: "Getting ready to clear…"))
            }
        case .waitingForPartner:
            Text("Your side is cleared.")
                .font(Theme.rounded(17, .semibold))
            Text("\(model.partnerName)'s iPhone clears theirs the next time \(AppConfig.appName) opens there.")
                .foregroundStyle(.secondary)
        }
        if model.freshStartSending {
            Text("Waiting to reach iCloud — it's sent as soon as it can be.")
                .foregroundStyle(.secondary)
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let busy = working || model.isChangingFreshStart || model.archiveProgress != nil
        switch model.freshStartPhase {
        case .idle, .waitingForPartner:
            Section {
                Button("Save memories, then ask…") { Task { await saveThen(.ask) } }
                    .disabled(busy || !model.canArchiveMemories)
                Button("Ask without saving…", role: .destructive) { confirmingSkip = .ask }
                    .disabled(busy)
            }
        case .asked:
            Section {
                Button("Withdraw the request", role: .destructive) { confirmingWithdraw = true }
                    .disabled(busy || model.freshStartSending)
            }
        case .theyAsked:
            Section {
                Button("Save memories, then agree…") { Task { await saveThen(.agree) } }
                    .disabled(busy || !model.canArchiveMemories)
                Button("Agree without saving…", role: .destructive) { confirmingSkip = .agree }
                    .disabled(busy)
            }
        case .clearing:
            if model.freshStartFailure != nil, !model.isClearingHistory {
                Section {
                    Button("Try again") { Task { await model.advanceFreshStart() } }
                }
            }
        case .agreed, .starting:
            EmptyView()
        }
    }

    private var skipTitle: String {
        confirmingSkip == .agree
            ? String(localized: "Agree without saving memories?")
            : String(localized: "Ask without saving memories?")
    }

    private var footer: String {
        String(localized: "A fresh start clears every photo, drawing and voice memo, the status history and read receipts — from both iPhones and from iCloud. Your link, both current statuses, the heart and your date stay. It needs you both: one asks, the other agrees, and nothing is cleared before that. Anything still waiting to send goes afterwards.")
    }

    /// Archives first, and goes on only if the archive is complete and reached
    /// iCloud Drive; a device-only one is offered for sharing, then confirmed.
    private func saveThen(_ action: Action) async {
        working = true
        defer { working = false }
        guard let outcome = await model.archiveMemories(offeringShare: false) else { return }
        let saved = outcome.destination == .iCloudDrive
            ? String(localized: "Memories saved to iCloud Drive › \(AppConfig.appName) › \(outcome.folder.lastPathComponent).")
            : String(localized: "Memories saved on this iPhone only.")
        if !outcome.isComplete {
            let text = saved + " " + String(localized: "Some of your history couldn't be read from iCloud, so nothing was asked or agreed. Try again with a better connection.")
            if outcome.destination == .deviceOnly {
                noticeAfterShare = text
                shareURL = outcome.folder
            } else {
                notice = text
            }
            return
        }
        switch outcome.destination {
        case .iCloudDrive:
            await perform(action, after: saved)
        case .deviceOnly:
            actionAfterShare = action
            shareURL = outcome.folder
        }
    }

    private func perform(_ action: Action, after saved: String? = nil) async {
        working = true
        defer { working = false }
        let message: String?
        switch action {
        case .ask: message = await model.askForFreshStart()
        case .agree: message = await model.agreeToFreshStart()
        }
        let text = [saved, message].compactMap { $0 }.joined(separator: " ")
        if !text.isEmpty { notice = text }
    }

    private func withdraw() async {
        if let message = await model.withdrawFreshStart() { notice = message }
    }
}

#if DEBUG
#Preview("Fresh start") {
    NavigationStack {
        FreshStartView()
    }
    .environment(AppModel.previewModel())
    .tint(Theme.accent)
}
#endif

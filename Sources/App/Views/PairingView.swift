import SwiftUI

/// Two ways in: create an invite link, or tap the one your partner sent — the
/// CloudKit share link carries the whole handshake.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool
    /// Which button's work `isBusy` is, so the spinner shows on the one tapped.
    @State private var startingNewSpace = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 28) {
                header

                if let message = model.readinessMessage {
                    warning(message)
                }

                nameRow

                cloudActions

                privacyNote
            }
            .padding(20)
            .containerRelativeFrame(.horizontal)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if name.isEmpty { name = model.myDisplayName } }
        .task { await model.checkForRejoinablePairing() }
        // Committed when editing ends, not per keystroke: each key reloaded the
        // widget timelines, and clearing the field flipped `hasName` false and
        // yanked this screen away mid-edit.
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
        .onDisappear { commitName() }
        .confirmationDialog("Delete your old shared space?",
                            isPresented: $model.confirmingReplacePairing,
                            titleVisibility: .visible) {
            Button("Delete it and start a new one", role: .destructive) {
                startNewSpace(replacingExisting: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceMessage)
        }
    }

    /// Says who the deletion reaches, and offers Rejoin only when it's on screen.
    private var replaceMessage: String {
        let what = model.replacingSpaceHasPartner
            ? String(localized: "This iCloud account still has a shared space with someone in it. A new link can't reuse it without handing its whole history to whoever joins, so starting over deletes it for both of you — every status, photo and memo — and unlinks them.")
            : String(localized: "This iCloud account still has an earlier shared space. A new link can't reuse it without handing what's in it to whoever joins, so starting over deletes it — every status, photo and memo in it.")
        return model.rejoinablePairing == nil ? what : what + " " + String(localized: "To keep it, tap Rejoin instead.")
    }

    private func startNewSpace(replacingExisting: Bool = false) {
        nameFocused = false
        commitName()  // The invite carries the name; don't race the focus change.
        startingNewSpace = true
        Task {
            await model.createInvite(replacingExisting: replacingExisting)
            startingNewSpace = false
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty field commits nothing — there is no sensible nameless state.
    private func commitName() {
        guard !trimmedName.isEmpty, trimmedName != model.myDisplayName else { return }
        model.myDisplayName = trimmedName
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("💛")
                .font(.system(size: 64))
                .padding(.top, 32)
            Text(AppConfig.appName)
                .font(Theme.rounded(34, .bold))
            Text("A glance at each other, from anywhere.")
                .font(Theme.rounded(16))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    /// A confirmation, not a question — `WelcomeView` already asked. Editable
    /// so a typo can be fixed before the name is sent to someone else.
    private var nameRow: some View {
        HStack(spacing: 12) {
            Text("You'll appear as")
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.mutedText)

            TextField("Your name", text: $name)
                .font(Theme.rounded(17, .semibold))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { commitName() }
        }
        .card(padding: 16)
    }

    // MARK: - CloudKit

    @ViewBuilder
    private var cloudActions: some View {
        VStack(spacing: 14) {
            if model.rejoinablePairing != nil {
                rejoinCard
            }

            if let url = model.inviteURL {
                inviteReady(url: url)
            } else if model.rejoinablePairing != nil {
                // Not a second primary button beside Rejoin: on a new phone this
                // is the one that would replace the space (it asks first).
                Button { startNewSpace() } label: {
                    HStack(spacing: 6) {
                        Text("Start a new shared space instead…")
                        if model.isBusy && startingNewSpace { ProgressView().controlSize(.small) }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .font(Theme.rounded(15, .medium))
                .foregroundStyle(.primary.opacity(0.7))
                .disabled(trimmedName.isEmpty || model.isBusy)
            } else {
                Button { startNewSpace() } label: {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Create invite link")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(trimmedName.isEmpty || model.isBusy)
                .opacity(trimmedName.isEmpty ? 0.5 : 1)
            }

            Text("Or, if they've already sent you a link, just tap it — this app will open and pair itself.")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    /// Shown when the server still holds this account's pairing (new phone,
    /// fresh install): one tap brings the whole shared space back.
    private var rejoinCard: some View {
        VStack(spacing: 16) {
            Text("Your shared space is still in iCloud")
                .font(Theme.rounded(17, .semibold))
            Text("This iCloud account is already paired. Rejoin and the statuses, photos and memos come back on their own.")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)

            Button {
                nameFocused = false
                commitName()
                Task { await model.rejoin(name: trimmedName) }
            } label: {
                if model.isBusy && !startingNewSpace {
                    ProgressView().tint(.white)
                } else {
                    Text("Rejoin")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(trimmedName.isEmpty || model.isBusy)
            .opacity(trimmedName.isEmpty ? 0.5 : 1)
        }
        .card()
    }

    private func inviteReady(url: URL) -> some View {
        VStack(spacing: 16) {
            Text("Send this to your partner")
                .font(Theme.rounded(17, .semibold))
            Text("They tap it to join. If they don't have \(AppConfig.appName) yet, they install it, then tap the link again.")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)

            InviteLinkText(url: url)

            InviteShareLink(url: url) {
                Label("Share invite link", systemImage: "square.and.arrow.up")
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent, in: Capsule())
            }

            CopyLinkButton(url: url)

            // Nobody has joined yet — this only discards the invite; the name stays.
            Button("Start over") { Task { await model.unlink(startingOver: false) } }
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.mutedText)
        }
        .card()
    }

    // MARK: - Chrome

    private func warning(_ message: String) -> some View {
        Label {
            Text(message).font(Theme.rounded(14))
        } icon: {
            Image(systemName: "exclamationmark.icloud")
        }
        .foregroundStyle(Theme.warmText)
        .card(padding: 16)
    }

    private var privacyNote: some View {
        Label {
            Text("Your statuses, photos and drawings are end-to-end encrypted in your own iCloud. No servers, no accounts, no ads.")
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.mutedText)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.mint)
        }
        .padding(.horizontal, 12)
    }
}

#if DEBUG
#Preview("Pairing") {
    ZStack {
        Theme.Background()
        PairingView()
    }
    .environment(AppModel.previewModel(paired: false))
    .tint(Theme.accent)
}
#endif

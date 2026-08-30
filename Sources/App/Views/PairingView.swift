import SwiftUI

/// Two ways in: create an invite link, or tap the one your partner sent — the
/// CloudKit share link carries the whole handshake.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
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
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if name.isEmpty { name = model.myDisplayName } }
        // Committed when editing ends, not per keystroke: each key reloaded the
        // widget timelines, and clearing the field flipped `hasName` false and
        // yanked this screen away mid-edit.
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
        .onDisappear { commitName() }
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// A confirmation, not a question — `WelcomeView` already asked. Editable
    /// so a typo can be fixed before the name is sent to someone else.
    private var nameRow: some View {
        HStack(spacing: 12) {
            Text("You'll appear as")
                .font(Theme.rounded(14))
                .foregroundStyle(.secondary)

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
            if let url = model.inviteURL {
                inviteReady(url: url)
            } else {
                Button {
                    nameFocused = false
                    commitName()  // The invite carries the name; don't race the focus change.
                    Task { await model.createInvite() }
                } label: {
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private func inviteReady(url: URL) -> some View {
        VStack(spacing: 16) {
            Text("Send this to your partner")
                .font(Theme.rounded(17, .semibold))
            Text("They tap it once. That's the whole setup.")
                .font(Theme.rounded(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            InviteLinkText(url: url)

            ShareLink(item: url) {
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
                .foregroundStyle(.secondary)
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
        .foregroundStyle(Theme.warm)
        .card(padding: 16)
    }

    private var privacyNote: some View {
        Label {
            Text("Your statuses, photos and drawings are end-to-end encrypted in your own iCloud. No servers, no accounts, no ads.")
                .font(Theme.rounded(12))
                .foregroundStyle(.secondary)
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

import SwiftUI

/// Two ways in: create an invite link, or tap the one your partner sent. There
/// are no accounts, no sign-up and no email addresses to type — the CloudKit
/// share link carries the whole handshake.
///
/// In `make local` builds there's no CloudKit at all, so this collapses to a
/// single button that pairs you with a fictional partner.
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

                nameCard

                #if TETHER_LOCAL_MODE
                demoActions
                #else
                cloudActions
                #endif

                privacyNote
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if name.isEmpty { name = model.myDisplayName } }
        .onChange(of: name) { _, newValue in model.myDisplayName = newValue }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.isLocalDemo ? "What's your name?" : "What should they call you?")
                .font(Theme.rounded(15, .medium))
                .foregroundStyle(.secondary)

            TextField("Your name", text: $name)
                .font(Theme.rounded(20, .semibold))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .card()
    }

    // MARK: - Local demo

    #if TETHER_LOCAL_MODE
    @ViewBuilder
    private var demoActions: some View {
        VStack(spacing: 14) {
            Button {
                nameFocused = false
                Task { await model.startDemo() }
            } label: {
                if model.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text("Start demo")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(trimmedName.isEmpty || model.isBusy)
            .opacity(trimmedName.isEmpty ? 0.5 : 1)

            Label {
                Text("This build has no iCloud. You'll be paired with a stand-in partner you can drive yourself from Settings — set their status, make them nudge you, send yourself photos. Widgets work for real.")
                    .font(Theme.rounded(13))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "hammer")
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 4)
        }
    }

    #else

    // MARK: - CloudKit

    @ViewBuilder
    private var cloudActions: some View {
        VStack(spacing: 14) {
            if let url = model.inviteURL {
                inviteReady(url: url)
            } else {
                Button {
                    nameFocused = false
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

            ShareLink(item: url) {
                Label("Share invite link", systemImage: "square.and.arrow.up")
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent, in: Capsule())
            }

            Button("Start over") { Task { await model.unpair() } }
                .font(Theme.rounded(14))
                .foregroundStyle(.secondary)
        }
        .card()
    }
    #endif

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
            Text(model.isLocalDemo
                 ? "Nothing leaves this device in demo mode."
                 : "Your statuses, photos and drawings are end-to-end encrypted in your own iCloud. No servers, no accounts, no ads.")
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

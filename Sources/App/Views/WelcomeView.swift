import CloudKit
import SwiftUI

/// Asks the one question the app can't answer itself: what should the other
/// person call you? Doubles as the join screen for invite links.
struct WelcomeView: View {
    enum Mode: Equatable {
        /// First install: ask, then hand over to pairing.
        case firstRun
        /// A share link is waiting on a name before it can be accepted.
        case joining(ownerName: String?)
    }

    let mode: Mode

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isJoining: Bool {
        if case .joining = mode { return true }
        return false
    }

    var body: some View {
        ZStack {
            Theme.Background()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    mark
                    headline
                    field
                    Spacer(minLength: 28)
                    actions
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 28)
                .frame(minHeight: 560)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            // Pre-filled when the invitee has used the app before.
            if name.isEmpty { name = model.myDisplayName }
            nameFocused = true
        }
    }

    // MARK: - Pieces

    private var mark: some View {
        Text(isJoining ? "💌" : "💛")
            .font(.system(size: 68))
            .padding(.bottom, 22)
    }

    private var headline: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.rounded(30, .bold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(Theme.rounded(16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .padding(.bottom, 30)
    }

    private var title: String {
        switch mode {
        case .firstRun:
            return "Welcome to \(AppConfig.appName)"
        case .joining(let ownerName):
            guard let ownerName, !ownerName.isEmpty else { return "You've been invited" }
            return "\(ownerName) invited you"
        }
    }

    private var subtitle: String {
        isJoining
            ? "One more thing before you're in: what should they call you?"
            : "A glance at each other, from anywhere. First — what should they call you?"
    }

    private var field: some View {
        VStack(spacing: 8) {
            TextField("Your name", text: $name)
                .font(Theme.rounded(24, .semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit(commit)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("You can change this later in Settings.")
                .font(Theme.rounded(12))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            Button(action: commit) {
                if model.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text(isJoining ? "Join \(joinTarget)" : "Continue")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(trimmed.isEmpty || model.isBusy)
            .opacity(trimmed.isEmpty ? 0.5 : 1)

            if isJoining {
                Button("Not now") { model.declineInvite() }
                    .font(Theme.rounded(14))
                    .foregroundStyle(.secondary)
            }

            Label {
                Text(isJoining
                     ? "You'll share one private space in iCloud — just the two of you."
                     : "No account, no email, no password. Your name stays on your phones and in your own iCloud.")
                    .font(Theme.rounded(12))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.mint)
            }
            .padding(.top, 4)
        }
    }

    private var joinTarget: String {
        if case .joining(let ownerName) = mode, let ownerName, !ownerName.isEmpty {
            return ownerName
        }
        return "them"
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        nameFocused = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        if isJoining {
            Task { await model.acceptInvite(name: trimmed) }
        } else {
            model.setName(trimmed)
        }
    }
}

#if DEBUG
#Preview("First run") {
    WelcomeView(mode: .firstRun)
        .environment(AppModel.previewModel(paired: false))
        .tint(Theme.accent)
}

#Preview("Joining") {
    WelcomeView(mode: .joining(ownerName: "Sam"))
        .environment(AppModel.previewModel(paired: false))
        .tint(Theme.accent)
}
#endif

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Puts the invite link on the clipboard, and says so — copying is silent, and
/// a button that gives back nothing gets pressed twice and still not trusted.
struct CopyLinkButton: View {
    let url: URL
    /// `true` in the pairing flow; `false` in Settings `Form` rows, which
    /// supply their own styling.
    var prominent: Bool = true

    @State private var copied = false

    var body: some View {
        Button {
            copy()
        } label: {
            if prominent {
                label
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            } else {
                label
            }
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: copied)
        .accessibilityLabel(copied ? "Link copied" : "Copy link")
    }

    private var label: some View {
        Label(copied ? "Copied" : "Copy link",
              systemImage: copied ? "checkmark" : "doc.on.doc")
    }

    /// Both representations deliberately: Messages/Mail want the URL type so
    /// the link arrives tappable; plenty of apps only read plain text.
    private func copy() {
        Clipboard.copy([
            UTType.url.identifier: url,
            UTType.utf8PlainText.identifier: url.absoluteString,
        ], localOnly: false)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The share sheet with a message around the link: a partner without the app
/// lands on iCloud's web page, and nothing there says to come back and tap it again.
struct InviteShareLink<Label: View>: View {
    let url: URL
    @ViewBuilder var label: Label

    var body: some View {
        ShareLink(item: url,
                  subject: Text("Join me on \(AppConfig.appName)"),
                  message: Text("Get \(AppConfig.appName) from the App Store first, then come back and tap this link to join me.")) {
            label
        }
    }
}

/// The link itself, shown and selectable — a failed share sheet, or a partner
/// who wants it read out over the phone, both need it visible.
struct InviteLinkText: View {
    let url: URL

    var body: some View {
        Text(url.absoluteString)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown once when an invite is created. A sheet, not part of `PairingView`:
/// creating the invite flips `isPaired`, which swaps that screen away before
/// it could show the link. Settings keeps a copy for afterwards.
struct InviteLinkSheet: View {
    let url: URL
    let partnerName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "link")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 24)

                        Text("Send this to \(partnerName)")
                            .font(Theme.rounded(24, .bold))
                            .multilineTextAlignment(.center)

                        Text("They tap it and you're linked — no accounts, nothing to type. If they don't have \(AppConfig.appName) yet, they install it first, then tap the link again.")
                            .font(Theme.rounded(15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        VStack(spacing: 14) {
                            InviteLinkText(url: url)

                            InviteShareLink(url: url) {
                                Label("Share link", systemImage: "square.and.arrow.up")
                                    .font(Theme.rounded(17, .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(Theme.accent, in: Capsule())
                            }

                            CopyLinkButton(url: url)
                        }
                        .card()

                        Label {
                            Text("The link is the only way in, so send it to \(partnerName) alone. You can find it again — and close it — in Settings.")
                                .font(Theme.rounded(12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Theme.mint)
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(20)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Invite link") {
    InviteLinkSheet(url: URL(string: "https://www.icloud.com/share/0abcdefghijklmnopqrstuvwxy")!,
                    partnerName: "Sam")
        .tint(Theme.accent)
}
#endif

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
                    .foregroundStyle(Theme.accent)
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
        UIPasteboard.general.items = [[
            UTType.url.identifier: url,
            UTType.utf8PlainText.identifier: url.absoluteString,
        ]]
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
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

                        Text("They tap it once and you're linked. That's the whole setup — no accounts, nothing to type.")
                            .font(Theme.rounded(15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        VStack(spacing: 14) {
                            InviteLinkText(url: url)

                            ShareLink(item: url) {
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
                            Text("The link closes itself the moment \(partnerName) joins, so a forwarded copy can't add anyone else. You can find it again in Settings until then.")
                                .font(Theme.rounded(12))
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Theme.mint)
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(20)
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

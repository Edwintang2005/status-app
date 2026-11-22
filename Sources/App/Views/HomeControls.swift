import SwiftUI

/// Home's offline notice: everything on this iPhone still works, and what's
/// queued goes when the connection does.
struct OfflineBanner: View {
    let pendingCount: Int
    let mobileDataDenied: Bool
    /// Reconnecting won't send it: the owner's iCloud has no room.
    let storageFull: Bool

    private var title: String {
        mobileDataDenied ? String(localized: "Mobile data is off for \(AppConfig.appName)") : String(localized: "You're offline")
    }

    private var detail: String {
        switch pendingCount {
        case 1... where storageFull: String(localized: "What you've sent is saved here, waiting for iCloud space.")
        case 0 where mobileDataDenied: String(localized: "Turn it on in Settings, or join Wi-Fi. You can still look back and send.")
        case 0: String(localized: "You can still look back and send — it goes when you reconnect.")
        case 1: String(localized: "1 thing will send when you're back online.")
        default: String(localized: "\(pendingCount) things will send when you're back online.")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(Theme.rounded(17, .semibold))
                .foregroundStyle(Theme.warmText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.rounded(15, .semibold))
                Text(detail)
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .card(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The bottom line: sync state, and — as a pill — a send just confirmed or
/// one still waiting, which taps to retry.
struct SyncFooter: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let inputs: SyncFooterLine.Inputs
    let onRetry: () -> Void
    var onSync: () -> Void = {}

    nonisolated static func == (lhs: SyncFooter, rhs: SyncFooter) -> Bool {
        lhs.inputs == rhs.inputs
    }

    var body: some View {
        let line = SyncFooterLine(inputs)
        HStack(spacing: 6) {
            switch line {
            case .sent:
                Label("Sent to \(inputs.partnerName)", systemImage: "checkmark")
                    .modifier(FooterPill(tint: Theme.accentText))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            case .offline(let lastSyncedAt):
                Image(systemName: "wifi.slash")
                // How fresh the screen is; the offline card up top carries what's queued.
                if let lastSyncedAt {
                    RelativeTime(lastSyncedAt) { Text("Offline · synced \($0)") }
                } else {
                    Text("Offline")
                }
            case .syncing(let restoring):
                ProgressView().controlSize(.mini)
                Text(restoring ? "Restoring your history…" : "Syncing…")
            case .iCloudAttention:
                // The full story is in the notice at the top.
                Image(systemName: "exclamationmark.icloud")
                Text("iCloud needs attention")
            case .sending:
                ProgressView().controlSize(.mini)
                Text("Sending…")
            case .waiting(let label, let storageFull):
                Button(action: onRetry) {
                    Label(label, systemImage: storageFull ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                        .modifier(FooterPill(tint: Theme.warmText))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Retries the send now")
            case .failing(let lastSyncedAt):
                Button(action: onSync) {
                    Group {
                        if let lastSyncedAt {
                            RelativeTime(lastSyncedAt) { Text("Couldn't sync · last synced \($0)") }
                        } else {
                            Text("Couldn't sync · tap to try again")
                        }
                    }
                    .modifier(FooterPill(tint: Theme.warmText))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tries syncing again now")
            case .synced(let lastSyncedAt):
                Image(systemName: "checkmark.icloud")
                RelativeTime(lastSyncedAt) { Text("Synced \($0)") }
            case .neverSynced:
                Image(systemName: "icloud.slash")
                Text("Not synced yet")
            }
        }
        .font(Theme.rounded(12))
        .foregroundStyle(Theme.mutedText)
        .padding(.top, 4)
        .accessibilityElement(children: line.isButton ? .contain : .combine)
    }
}

/// The footer's send state, as a pill rather than a line of small print.
private struct FooterPill: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(Theme.rounded(13, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Owns its countdown so ticking is scoped to this button and no timer runs
/// outside the cooldown after a nudge (`AppConfig.nudgeCooldown`). A failed
/// send says so on the button for `AppConfig.nudgeFailureNotice`, like the
/// lock-screen heart — no alert.
struct NudgeButton: View {
    let lastSentAt: Date?
    let lastFailedAt: Date?
    /// On its way: shown, and not tappable again, until the call returns.
    let sending: Bool
    let action: () async -> Void

    @State private var remaining: TimeInterval = 0
    @State private var failed = false

    private var ready: Bool { remaining == 0 }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if sending {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accentText)
                    Text("Sending…")
                }
            } else if !ready {
                Label("Sent · \(Int(remaining.rounded(.up)))s", systemImage: "checkmark")
            } else if failed {
                Label("Didn't send · tap to retry", systemImage: "heart.slash.fill")
            } else {
                Label("Send a heart", systemImage: "heart.fill")
            }
        }
        // Accent, not warm: the heart wears the red string's crimson. In flight
        // and sent it steps back to the secondary look, which is AA in both modes.
        .buttonStyle(NudgeButtonStyle(calm: sending || !ready,
                                      tint: failed ? Theme.warmDeep : Theme.accent))
        .disabled(sending || !ready)
        .accessibilityLabel(sending ? "Sending a heart" : !ready ? "Heart sent"
                            : failed ? "Heart didn't send. Send again" : "Send a heart")
        .animation(.smooth, value: ready)
        .animation(.smooth, value: failed)
        .animation(.smooth, value: sending)
        .nudgeCooldown(after: lastSentAt, remaining: $remaining)
        .task(id: lastFailedAt) { await watchFailure() }
    }

    private func watchFailure() async {
        let left = lastFailedAt.map { AppConfig.nudgeFailureNotice - Date().timeIntervalSince($0) } ?? 0
        failed = left > 0
        guard left > 0 else { return }
        try? await Task.sleep(for: .seconds(left))
        if !Task.isCancelled { failed = false }
    }
}

/// The heart's look: the primary crimson while it can be tapped, the
/// secondary tint (crimson text, AA) while it's sending or cooling down.
private struct NudgeButtonStyle: ButtonStyle {
    let calm: Bool
    let tint: Color

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if calm {
            SecondaryButtonStyle(prominent: true).makeBody(configuration: configuration)
        } else {
            PrimaryButtonStyle(tint: tint).makeBody(configuration: configuration)
        }
    }
}

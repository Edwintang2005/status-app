import SwiftUI

/// Home's offline notice: everything on this iPhone still works, and what's
/// queued goes when the connection does.
struct OfflineBanner: View {
    let pendingCount: Int
    let mobileDataDenied: Bool
    /// Reconnecting won't send it: the owner's iCloud has no room.
    let storageFull: Bool

    private var title: String {
        mobileDataDenied ? String(localized: "Mobile data is off for Red String") : String(localized: "You're offline")
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
    let partnerName: String
    let showsSent: Bool
    let isOffline: Bool
    let lastSyncedAt: Date?
    let isRefreshing: Bool
    let needsICloudAttention: Bool
    let isSending: Bool
    let pendingCount: Int
    /// The only thing waiting is the status on screen.
    let onlyStatusPending: Bool
    let storageFull: Bool
    let isParticipant: Bool
    let onRetry: () -> Void

    nonisolated static func == (lhs: SyncFooter, rhs: SyncFooter) -> Bool {
        lhs.partnerName == rhs.partnerName && lhs.showsSent == rhs.showsSent && lhs.isOffline == rhs.isOffline
            && lhs.lastSyncedAt == rhs.lastSyncedAt && lhs.isRefreshing == rhs.isRefreshing
            && lhs.needsICloudAttention == rhs.needsICloudAttention && lhs.isSending == rhs.isSending
            && lhs.pendingCount == rhs.pendingCount && lhs.onlyStatusPending == rhs.onlyStatusPending
            && lhs.storageFull == rhs.storageFull && lhs.isParticipant == rhs.isParticipant
    }

    /// Says whose storage is full when that's why sends are stuck — only the owner can fix it.
    private var pendingLabel: String {
        if pendingCount == 1, onlyStatusPending, !storageFull {
            return String(localized: "Your status is waiting to send · tap to retry")
        }
        guard storageFull else {
            return pendingCount == 1
                ? String(localized: "1 waiting to send · tap to retry")
                : String(localized: "\(pendingCount) waiting to send · tap to retry")
        }
        return isParticipant
            ? String(localized: "\(partnerName)'s iCloud is full · \(pendingCount) waiting · tap to retry")
            : String(localized: "Your iCloud is full · \(pendingCount) waiting · tap to retry")
    }

    /// The retry button is up: combining for VoiceOver would swallow its action.
    private var showsRetry: Bool {
        !showsSent && !isOffline && !isRefreshing && !needsICloudAttention && !isSending && pendingCount > 0
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsSent {
                Label("Sent to \(partnerName)", systemImage: "checkmark")
                    .modifier(FooterPill(tint: Theme.accentText))
                    .transition(.opacity)
            } else if isOffline {
                // Ahead of the rest: offline, a refresh fails at once and readiness reads as a network error.
                Image(systemName: "wifi.slash")
                // How fresh the screen is; the offline card up top carries what's queued.
                if let lastSyncedAt {
                    RelativeTime(lastSyncedAt) { Text("Offline · synced \($0)") }
                } else {
                    Text("Offline")
                }
            } else if isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if needsICloudAttention {
                // The full story is in the notice at the top.
                Image(systemName: "exclamationmark.icloud")
                Text("iCloud needs attention")
            } else if isSending {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            } else if pendingCount > 0 {
                // Ahead of "Synced …", which would mislead while a send is
                // still sitting on this device.
                Button(action: onRetry) {
                    Label(pendingLabel,
                          systemImage: storageFull ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                        .modifier(FooterPill(tint: Theme.warmText))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Retries the send now")
            } else if let lastSyncedAt {
                Image(systemName: "checkmark.icloud")
                RelativeTime(lastSyncedAt) { Text("Synced \($0)") }
            } else {
                Image(systemName: "icloud.slash")
                Text("Not synced yet")
            }
        }
        .font(Theme.rounded(12))
        .foregroundStyle(Theme.mutedText)
        .padding(.top, 4)
        .accessibilityElement(children: showsRetry ? .contain : .combine)
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
                Label("Sent · \(Int(remaining))s", systemImage: "checkmark")
            } else if failed {
                Label("Didn't send · tap to retry", systemImage: "heart.slash.fill")
            } else {
                Label("Thinking of you", systemImage: "heart.fill")
            }
        }
        // Accent, not warm: the heart wears the red string's crimson. In flight
        // and sent it steps back to the secondary look, which is AA in both modes.
        .buttonStyle(NudgeButtonStyle(calm: sending || !ready,
                                      tint: failed ? Theme.warmDeep : Theme.accent))
        .disabled(sending || !ready)
        .accessibilityLabel(sending ? "Sending a nudge" : !ready ? "Nudge sent"
                            : failed ? "Nudge didn't send. Send again" : "Send a nudge")
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
            // The primary's metrics, so the button doesn't change size between states.
            configuration.label
                .font(Theme.rounded(17, .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.accent.opacity(0.12), in: Capsule())
        } else {
            PrimaryButtonStyle(tint: tint).makeBody(configuration: configuration)
        }
    }
}

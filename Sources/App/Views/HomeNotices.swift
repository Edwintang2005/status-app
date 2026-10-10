import SwiftUI

/// Home's one-at-a-time notices (`HomeView.activeNotice` picks the most urgent).
enum HomeNotice: Equatable {
    case partnerLeft, extraMembers(Int), iCloud(String), freshStartStuck, freshStartRequest
    case notificationsOff(NotificationsNotice), closeLink, widgetTip

    /// Urgent ones sit above the partner card; the rest below the send row.
    var urgent: Bool {
        switch self {
        case .partnerLeft, .extraMembers, .iCloud, .freshStartStuck: true
        case .freshStartRequest, .notificationsOff, .closeLink, .widgetTip: false
        }
    }
}

/// A notice's words; what its buttons do is Home's.
struct HomeNoticeView: View, Equatable {
    let notice: HomeNotice
    let partnerName: String
    let isOwner: Bool
    /// The close handshake is running: the card's action waits.
    let busy: Bool
    let onAction: () -> Void
    let onDismiss: () -> Void

    nonisolated static func == (lhs: HomeNoticeView, rhs: HomeNoticeView) -> Bool {
        lhs.notice == rhs.notice && lhs.partnerName == rhs.partnerName
            && lhs.isOwner == rhs.isOwner && lhs.busy == rhs.busy
    }

    var body: some View {
        switch notice {
        case .partnerLeft:
            // Settings' unlink dialog already offers "Save memories, then unlink".
            // The space is the owner's: only they have something left to delete.
            HomeNoticeCard(systemImage: "person.crop.circle.badge.xmark",
                           title: "\(partnerName) left your shared space",
                           message: isOwner
                               ? "They unlinked on their iPhone, so what they sent has gone from here too. What you sent is still in your iCloud. Save your memories and unlink, then send a new invite link — to them or someone new."
                               : "They unlinked, so what they sent has gone from here too. Save your memories, then unlink to leave the shared space.",
                           actionTitle: "Save and unlink…",
                           dismissTitle: "Dismiss",
                           urgent: true,
                           onDismiss: onDismiss,
                           action: onAction)
        case .extraMembers(let count):
            HomeNoticeCard(systemImage: "person.2.badge.gearshape",
                           title: "Someone else has joined",
                           message: "\(count) people besides you are on your shared space, not just \(partnerName). Closing the invite link can't remove them. If that isn't right, unlink in Settings — it deletes the shared space for both of you — and send \(partnerName) a new link.",
                           actionTitle: "Open Settings",
                           urgent: true,
                           action: onAction)
        case .iCloud(let problem):
            HomeNoticeCard(systemImage: "exclamationmark.icloud",
                           title: "iCloud needs attention",
                           message: "\(problem)",
                           actionTitle: "Check again",
                           urgent: true,
                           action: onAction)
        case .freshStartStuck:
            HomeNoticeCard(systemImage: "exclamationmark.arrow.circlepath",
                           title: "Your fresh start hasn't finished",
                           message: "This iPhone couldn't clear its side yet. It tries again whenever the app opens.",
                           actionTitle: "Review…",
                           urgent: true,
                           action: onAction)
        case .freshStartRequest:
            // The request's only delivery: no push, no banner (it rides any refresh).
            HomeNoticeCard(systemImage: "sparkles",
                           title: "\(partnerName) asked for a fresh start",
                           message: "Clearing the history you share — moments, status history and read receipts — from both iPhones. Your link, your statuses and the heart stay. Nothing changes unless you agree.",
                           actionTitle: "Review…",
                           dismissTitle: "Not now",
                           onDismiss: onDismiss,
                           action: onAction)
        case .notificationsOff(let problem):
            HomeNoticeCard(systemImage: problem == .focusBlocked ? "moon" : "bell.slash",
                           title: notificationsTitle(problem),
                           message: notificationsMessage(problem),
                           actionTitle: "Open Settings",
                           dismissTitle: "Not now",
                           onDismiss: onDismiss,
                           action: onAction)
        case .closeLink:
            HomeNoticeCard(systemImage: "lock.open",
                           title: "\(partnerName)'s in",
                           message: "Your invite link still lets anyone who has it join. Close it while you're together: \(partnerName) taps the link once more to get back in.",
                           actionTitle: "Close the link…",
                           dismissTitle: "Don't show again",
                           busy: busy,
                           onDismiss: onDismiss,
                           action: onAction)
        case .widgetTip:
            HomeNoticeCard(systemImage: "lock.iphone",
                           title: "Put \(partnerName) on your Lock Screen",
                           message: "Touch and hold your Lock Screen, tap Customize, then the Lock Screen, and add \(AppConfig.appName) to the widget row: their status, and the heart that sends a nudge, without unlocking.",
                           actionTitle: "Got it",
                           action: onAction)
        }
    }

    private func notificationsTitle(_ problem: NotificationsNotice) -> LocalizedStringKey {
        switch problem {
        case .off: "Notifications are off"
        case .bannersOff: "Banners are off"
        case .focusBlocked: "Hearts wait out your Focus"
        }
    }

    private func notificationsMessage(_ problem: NotificationsNotice) -> LocalizedStringKey {
        switch problem {
        case .off: "You won't know when \(partnerName) sends a heart, a status or a moment until you open the app. Turn notifications on for \(AppConfig.appName) in Settings."
        case .bannersOff: "\(partnerName)'s hearts and moments arrive silently in Notification Center. Turn on banners for \(AppConfig.appName) in Settings."
        case .focusBlocked: "Time Sensitive notifications are off for \(AppConfig.appName), so a heart from \(partnerName) waits until a Focus ends."
        }
    }
}

/// One notice's card: a title, the words, an action and maybe a dismissal.
private struct HomeNoticeCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    var dismissTitle: LocalizedStringKey?
    /// Orange for a warning, crimson otherwise — each in its AA-safe shade.
    var urgent = false
    /// The action is running (the close handshake takes seconds): not tappable again.
    var busy = false
    var onDismiss: () -> Void = {}
    let action: () -> Void

    private var tint: Color { urgent ? Theme.warmText : Theme.accentText }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(Theme.rounded(16, .semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            // A plain colour, not the hierarchical `.primary`, which turns vibrant
            // (and under 4.5:1) on the card's material.
            Text(message)
                .font(Theme.rounded(14))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.notice.message")
            HStack(spacing: 20) {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(actionTitle)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .font(Theme.rounded(15, .semibold))
                .foregroundStyle(tint)
                .disabled(busy)
                if let dismissTitle {
                    Button(action: onDismiss) {
                        Text(dismissTitle)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(Theme.rounded(15))
                    .foregroundStyle(Theme.mutedText)
                    .disabled(busy)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .accessibilityElement(children: .contain)
    }
}

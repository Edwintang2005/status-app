import SwiftUI

// Home's cards take plain values and compare equal on them (`.equatable()`),
// so a refresh that changes nothing they draw doesn't rebuild them.

/// Their status, their last heart, and the way into the status history.
struct PartnerCard: View, Equatable {
    let partnerName: String
    /// `nil` until their first status.
    let status: ModeratedStatus?
    let wordsAt: Date
    let lastHeartAt: Date?
    let partnerHasLeft: Bool
    /// Bumped as a status or heart lands while Home is in front: the flourish.
    let statusArrivals: Int
    let heartArrivals: Int
    let onOpen: () -> Void
    let onReport: () -> Void
    let onReveal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingReport = false

    /// Their heart shows for a day: the banner is swept when the app opens, so
    /// otherwise nothing in the app would say it came.
    private static let heartShownFor: TimeInterval = 24 * 60 * 60

    nonisolated static func == (lhs: PartnerCard, rhs: PartnerCard) -> Bool {
        lhs.partnerName == rhs.partnerName && lhs.status == rhs.status && lhs.wordsAt == rhs.wordsAt
            && lhs.lastHeartAt == rhs.lastHeartAt && lhs.partnerHasLeft == rhs.partnerHasLeft
            && lhs.statusArrivals == rhs.statusArrivals && lhs.heartArrivals == rhs.heartArrivals
    }

    var body: some View {
        // Once a minute: the heart line's expiry and VoiceOver's "… ago".
        TimelineView(.everyMinute) { context in
            card(now: context.date)
        }
    }

    private func heartAt(now: Date) -> Date? {
        guard let at = lastHeartAt, now.timeIntervalSince(at) < Self.heartShownFor else { return nil }
        // A clock ahead of ours never reads "in 3 hours".
        return min(at, now)
    }

    private func card(now: Date) -> some View {
        let heartAt = heartAt(now: now)
        return Button(action: onOpen) {
            content(heartAt: heartAt)
        }
        .buttonStyle(.plain)
        .overlay {
            Theme.cardShape
                .strokeBorder(Theme.accent, lineWidth: 2)
                .keyframeAnimator(initialValue: 0.0, trigger: statusArrivals + heartArrivals) { glow, opacity in
                    glow.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0.7, duration: 0.15)
                        LinearKeyframe(0, duration: 0.9)
                    }
                }
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if !reduceMotion { risingHeart }
        }
        .accessibilityLabel(summary(heartAt: heartAt, now: now))
        .accessibilityHint("Shows status history")
        .contextMenu { moderationActions }
        // Guideline 1.2: reachable under VoiceOver and Voice Control, not only by long-press.
        .accessibilityActions { moderationActions }
        .confirmationDialog("Report this status?",
                            isPresented: $confirmingReport,
                            titleVisibility: .visible) {
            Button("Report", role: .destructive, action: onReport)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text is hidden on this iPhone straight away, and the details go to us by email. We act on reports within 24 hours.")
        }
    }

    private var risingHeart: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 26))
            .foregroundStyle(Theme.accent)
            .keyframeAnimator(initialValue: FloatingHeart(), trigger: heartArrivals) { heart, value in
                heart.opacity(value.opacity).offset(y: value.rise).scaleEffect(value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(1, duration: 0.45)
                    LinearKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.rise) {
                    CubicKeyframe(-48, duration: 1.0)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.2, duration: 0.3)
                    CubicKeyframe(0.9, duration: 0.7)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var moderationActions: some View {
        if let status, !status.isReported {
            Button(role: .destructive) {
                confirmingReport = true
            } label: {
                Label("Report this status…", systemImage: "flag")
            }
            if status.isFiltered, status.message.isPlaceholder {
                Button(action: onReveal) {
                    Label("Show hidden text", systemImage: "eye")
                }
            }
        }
    }

    /// VoiceOver's reading of the card: name, emoji, message, age.
    private func summary(heartAt: Date?, now: Date) -> String {
        guard let status else {
            return String(localized: "\(partnerName): waiting for their first status")
        }
        let words = status.message.text.isEmpty ? "" : " \(status.message.text)"
        var summary = "\(partnerName): \(status.emoji)\(words), \(wordsAt.relativeWording(asOf: now))"
        if let heartAt {
            summary += String(localized: ". Thinking of you, \(heartAt.relativeWording(asOf: now))")
        }
        return summary
    }

    private func content(heartAt: Date?) -> some View {
        HStack(spacing: 14) {
            if let status {
                // Emoji-only is a status, not a missing one: the emoji stands alone.
                Text(status.emoji)
                    .font(.system(size: status.message.text.isEmpty ? 56 : 46))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: status.emoji)

                VStack(alignment: .leading, spacing: 2) {
                    Text(partnerName).eyebrow()
                    if !status.message.text.isEmpty {
                        Text(status.message.text)
                            .font(Theme.rounded(20, .semibold))
                            .lineLimit(2)
                            // Wrap within the proposed width rather than reporting a
                            // single-line ideal (invariant 18).
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(status.message.isPlaceholder ? Theme.mutedText : .primary)
                            .contentTransition(.opacity)
                            .animation(.smooth, value: status.message.text)
                    }
                    RelativeTime(wordsAt)
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                    if let heartAt {
                        RelativeTime(heartAt) { when in
                            Label("thinking of you · \(when)", systemImage: "heart.fill")
                        }
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : heartArrivals)
                        .padding(.top, 3)
                    }
                }
            } else {
                Text("💭").font(.system(size: 46)).opacity(0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(partnerName).eyebrow()
                    (partnerHasLeft ? Text("Left your shared space") : Text("Waiting for their first status"))
                        .font(Theme.rounded(16, .medium))
                        .foregroundStyle(Theme.mutedText)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "clock.arrow.circlepath")
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(.tertiary)
        }
        .card(padding: 16)
    }
}

/// The partner card's rising heart, one keyframe track per property.
private struct FloatingHeart {
    var opacity = 0.0
    var rise = 0.0
    var scale = 0.6
}

/// Your status, with its receipt or "not sent yet"; tapping opens the picker.
struct MyStatusRow: View, Equatable {
    let mine: StatusPayload?
    /// Not in iCloud yet, and not being sent right now.
    let unsent: Bool
    let seenAt: Date?
    let onOpen: () -> Void

    nonisolated static func == (lhs: MyStatusRow, rhs: MyStatusRow) -> Bool {
        lhs.mine == rhs.mine && lhs.unsent == rhs.unsent && lhs.seenAt == rhs.seenAt
    }

    private var hasWords: Bool { mine?.message.isEmpty == false }

    /// An emoji-only status is a status: the emoji stands beside an invitation
    /// to add words, rather than "Set your status" or a blank line.
    private var text: String {
        guard let mine else { return String(localized: "Set your status") }
        if !mine.message.isEmpty { return mine.message }
        return mine.emoji.isEmpty ? String(localized: "Set your status") : String(localized: "Tap to add words")
    }

    var body: some View {
        // Once a minute, for VoiceOver's "Seen … ago"; the line itself ticks on its own.
        TimelineView(.everyMinute) { context in
            row.accessibilityLabel(summary(now: context.date))
        }
    }

    private var row: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(mine?.emoji ?? "➕")
                    .font(.system(size: 26))

                VStack(alignment: .leading, spacing: 1) {
                    Text(text)
                        .font(hasWords ? Theme.rounded(17, .semibold) : Theme.rounded(16))
                        // `Color.primary`: the hierarchical style goes vibrant on the material.
                        .foregroundStyle(hasWords ? Color.primary : Theme.mutedText)
                        .lineLimit(1)
                    if unsent {
                        // Retried on every refresh; the footer offers it now.
                        Label("Not sent yet · will retry", systemImage: "icloud.and.arrow.up")
                            .font(Theme.rounded(12, .semibold))
                            .foregroundStyle(Theme.warmText)
                    } else if let seenAt {
                        // The status read receipt — read receipts on, both sides.
                        RelativeTime(seenAt) { when in
                            Label("Seen \(when)", systemImage: "eye.fill")
                        }
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .card(shape: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Changes your status")
    }

    private func summary(now: Date) -> String {
        guard let mine, !mine.message.isEmpty || !mine.emoji.isEmpty else {
            return String(localized: "Set your status")
        }
        var summary = String(localized: "Your status: \(mine.emoji) \(mine.message)")
        if unsent {
            summary += String(localized: ". Not sent yet, will retry")
        } else if let seenAt {
            summary += String(localized: ". Seen \(seenAt.relativeWording(asOf: now))")
        }
        return summary
    }
}

/// Their newest picture — or the first of the unseen ones — opening the gallery.
struct MomentCard: View, Equatable {
    let moment: Moment
    let unseenCount: Int
    /// Captions already moderated: a filtered one reads as no caption.
    let label: String
    let isOffline: Bool
    let onOpen: () -> Void
    /// Fetches the thumbnail when it isn't on this iPhone; `false` if it still isn't.
    let fetchThumbnail: () async -> Bool

    nonisolated static func == (lhs: MomentCard, rhs: MomentCard) -> Bool {
        lhs.moment == rhs.moment && lhs.unseenCount == rhs.unseenCount
            && lhs.label == rhs.label && lhs.isOffline == rhs.isOffline
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                SquareFill {
                    HomeMomentThumbnail(momentID: moment.id, isOffline: isOffline, fetch: fetchThumbnail)
                }
                .clipped()

                HStack(spacing: 8) {
                    Image(systemName: moment.symbolName)
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                    Text(label)
                        .font(Theme.rounded(15, .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unseenCount > 0 {
                        Text(unseenCount == 1 ? "new" : "\(unseenCount) new")
                            .font(Theme.rounded(11, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.warmDeep, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .clipShape(Theme.cardShape)
            .card(shape: Theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseenCount > 1
                            ? String(localized: "\(label). \(unseenCount) new")
                            : unseenCount == 1 ? String(localized: "\(label). New") : label)
        .accessibilityHint("Opens it")
        // On the whole card, not the picture: zooming only the square would be
        // cut off by the card's rounded clip.
        .pinchToZoom()
    }

    /// What the card says under the picture.
    static func label(for moment: Moment, filterEnabled: Bool) -> String {
        guard let caption = moment.displayCaption(filterEnabled: filterEnabled) else {
            return moment.fromMe
                ? String(localized: "You sent a \(moment.noun)")
                : String(localized: "Sent you a \(moment.noun)")
        }
        return moment.fromMe ? String(localized: "You: \(caption)") : caption
    }
}

/// The card's picture, decoded off the main thread; fetched once when it
/// isn't on disk, and tried again on reconnect.
private struct HomeMomentThumbnail: View {
    let momentID: String
    let isOffline: Bool
    let fetch: () async -> Bool

    @State private var image: UIImage?
    @State private var loadedID: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .overlay(Image(systemName: "photo").foregroundStyle(Theme.mutedText))
            }
        }
        .task(id: "\(momentID)-\(isOffline)") {
            let id = momentID
            guard image == nil || loadedID != id else { return }
            var loaded = await Self.load(id)
            if loaded == nil, !Task.isCancelled, await fetch() { loaded = await Self.load(id) }
            guard !Task.isCancelled else { return }
            image = loaded
            loadedID = id
        }
    }

    private static func load(_ id: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { MomentStore.shared.thumbnail(for: id) }.value
    }
}

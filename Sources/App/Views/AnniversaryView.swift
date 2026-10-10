import SwiftUI

/// The last layer of the easter egg: how long the two of them have been tied
/// together, ticking live from the date the owner set, with the next milestone
/// and a celebration on milestone days. Says so while no date is set — and
/// hands the owner the picker.
struct AnniversaryView: View {
    /// The tie's logo flies into this header; `nil` on the plain path.
    var logo: Namespace.ID? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var pieces = ConfettiPiece.emitter(count: 48)
    @State private var opened = Date()
    @State private var editing = false
    @AccessibilityFocusState private var summaryFocused: Bool

    var body: some View {
        ZStack {
            Theme.Background()
            if let anniversary = model.anniversary {
                // A minute's tick for the page; only the count ticks by the second.
                TimelineView(.everyMinute) { context in
                    let now = context.date
                    let milestone = anniversary.milestoneToday(now)

                    // One view, not two: a tuple here is stacked, not layered.
                    content(anniversary, now: now, celebrating: milestone)
                        .overlay {
                            if milestone != nil, !reduceMotion {
                                ConfettiLayer(pieces: pieces, start: opened)
                                    .allowsHitTesting(false)
                                    .ignoresSafeArea()
                            }
                        }
                }
            } else {
                unset
            }

            VStack {
                HStack {
                    Spacer()
                    EggCloseButton()
                }
                Spacer()
            }
            .padding(16)
        }
        .sheet(isPresented: $editing) {
            AnniversaryEditorView(mode: .edit)
        }
        .task {
            opened = .now
            // The tie already buzzed; only a milestone earns a second one.
            if model.anniversary?.milestoneToday(.now) != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            reveal()
            try? await Task.sleep(for: .milliseconds(400))
            summaryFocused = true
        }
        // A date that lands while the screen is open reveals in place.
        .onChange(of: model.anniversary == nil) { _, unset in
            guard !unset else { return }
            revealed = false
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                reveal()
            }
        }
    }

    private func reveal() {
        withAnimation(reduceMotion ? .easeIn(duration: 0.25) : .easeOut(duration: 0.4).delay(0.2)) {
            revealed = true
        }
    }

    /// The pair just tied, settled at the top of every state.
    private var header: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: 150)
            .matchedLogo(logo)
            .shadow(color: Theme.accent.opacity(0.25), radius: 16, y: 6)
            .padding(.top, 40)
            .padding(.bottom, 18)
            .accessibilityHidden(true)
    }

    // MARK: - No date yet

    private var unset: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                VStack(spacing: 16) {
                    if model.canEditAnniversary {
                        ownerUnset
                    } else {
                        partnerUnset
                    }
                }
                .opacity(revealed ? 1 : 0)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .containerRelativeFrame(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var ownerUnset: some View {
        Text("When did you two begin?")
            .font(Theme.rounded(28, .bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($summaryFocused)
        Text("The count starts here, on both phones.")
            .font(Theme.rounded(15))
            .foregroundStyle(Theme.mutedText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if model.anniversaryRequestPending {
            Label("\(model.partnerName) asked for this.", systemImage: "paperplane")
                .font(Theme.rounded(15, .semibold))
                .foregroundStyle(Theme.accentText)
        }
        Button {
            editing = true
        } label: {
            Label("Set our date", systemImage: "calendar.badge.clock")
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.top, 8)
    }

    @ViewBuilder
    private var partnerUnset: some View {
        Text("\(model.partnerName) hasn't set your date yet")
            .font(Theme.rounded(28, .bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($summaryFocused)
        Text("Once they do, the count appears here.")
            .font(Theme.rounded(15))
            .foregroundStyle(Theme.mutedText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if model.canRequestAnniversary {
            // The ask travels with the next sync and greets the owner when
            // they next open the app — no push, by design.
            if let asked = model.anniversaryRequestedAt {
                Button {
                    Task { await model.requestAnniversary() }
                } label: {
                    Label("Ask again", systemImage: "paperplane")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 8)
                if model.snapshot.anniversaryRequestPublished {
                    RelativeTime(asked) { when in
                        Text("Asked \(when). They'll see it next time they open \(AppConfig.appName).")
                    }
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Waiting to send. It goes as soon as you're online.", systemImage: "icloud.and.arrow.up")
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(Theme.warmText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    Task { await model.requestAnniversary() }
                } label: {
                    Label("Ask \(model.partnerName) to set it", systemImage: "paperplane")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Content

    private func content(_ anniversary: Anniversary,
                         now: Date,
                         celebrating: Anniversary.Milestone?) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(spacing: 0) {
                    if let celebrating {
                        Text("Happy \(celebrating.title)")
                            .font(Theme.rounded(34, .bold))
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 18)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        count(anniversary, now: context.date)
                    }

                    breakdown(anniversary, now: now)
                        .padding(.top, 20)

                    VStack(spacing: 12) {
                        sinceCard(anniversary)
                        if let next = anniversary.nextMilestone(after: now) {
                            nextCard(next, anniversary: anniversary, now: now)
                        }
                    }
                    .padding(.top, 30)

                    // Before the partner joins there's no name to put beside ours.
                    if model.snapshot.theirs != nil {
                        Text("\(model.myDisplayName) & \(model.partnerName)")
                            .font(Theme.rounded(15, .medium))
                            .foregroundStyle(Theme.mutedText)
                            .padding(.top, 28)
                    }
                }
                .opacity(revealed ? 1 : 0)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .containerRelativeFrame(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    /// The ticking part: days, and the clock under them.
    private func count(_ anniversary: Anniversary, now: Date) -> some View {
        let (days, clock) = anniversary.elapsed(at: now)
        let since = anniversary.startsAt.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: anniversary.timeZone))
        let digits: ContentTransition = reduceMotion ? .identity : .numericText()

        // One element for VoiceOver, hour-precise: the seconds would re-announce every tick.
        return VStack(spacing: 0) {
            Text("Tied together for")
                .eyebrow(size: 12)

            Text("\(days)")
                .font(Theme.rounded(104, .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(digits)
                .animation(.smooth, value: days)
                .shadow(color: Theme.warm.opacity(0.35), radius: 18)
            Text(days == 1 ? "day" : "days")
                .font(Theme.rounded(20, .medium))
                .foregroundStyle(Theme.mutedText)
                .padding(.top, -8)

            Text(clockString(clock))
                .font(Theme.rounded(30, .medium))
                .monospacedDigit()
                .contentTransition(digits)
                .animation(.smooth(duration: 0.3), value: clock)
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.top, 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tied together for ^[\(days) day](inflect: true) and ^[\(clock / 3600) hour](inflect: true). Since \(since)."))
        .accessibilityFocused($summaryFocused)
    }

    private func breakdown(_ anniversary: Anniversary, now: Date) -> some View {
        let (months, days) = anniversary.monthsAndDays(at: now)

        return Group {
            if months > 0 {
                Text("^[\(months) month](inflect: true), ^[\(days) day](inflect: true)")
            } else {
                Text("^[\(days) day](inflect: true)")
            }
        }
        .font(Theme.rounded(14, .semibold))
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(0.12), in: Capsule())
    }

    /// The owner can tap through to change it; the partner just reads it — as
    /// a plain card, not a disabled button, which rendered greyed as if broken.
    @ViewBuilder
    private func sinceCard(_ anniversary: Anniversary) -> some View {
        if model.canEditAnniversary {
            Button {
                editing = true
            } label: {
                sinceCardContent(anniversary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Changes the date")
        } else {
            sinceCardContent(anniversary)
                .accessibilityElement(children: .combine)
        }
    }

    private func sinceCardContent(_ anniversary: Anniversary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(Theme.rounded(22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Since")
                    .eyebrow()
                Text(anniversary.startsAt,
                     format: Date.FormatStyle(date: .long, time: .shortened, timeZone: anniversary.timeZone))
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.canEditAnniversary {
                    Text("Set by \(model.partnerName)")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.mutedText)
                }
            }
            Spacer(minLength: 0)
            if model.canEditAnniversary {
                Image(systemName: "pencil")
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(Theme.mutedText)
            }
        }
        .card(padding: 16)
    }

    private func nextCard(_ next: Anniversary.Milestone, anniversary: Anniversary, now: Date) -> some View {
        let daysLeft = anniversary.daysUntil(next.date, from: now)

        return HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(Theme.rounded(22))
                .foregroundStyle(Theme.warm)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next up")
                    .eyebrow()
                Text(next.title)
                    .font(Theme.rounded(17, .semibold))
                Text(next.date, format: Date.FormatStyle(date: .complete, timeZone: anniversary.timeZone))
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
            }
            Spacer(minLength: 0)
            Text("in ^[\(daysLeft) day](inflect: true)")
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.warmDeep, in: Capsule())
        }
        .card(padding: 16)
    }

    // MARK: - Formatting

    /// Hours, minutes and seconds spelled out: "16:36:17" read as a time of day.
    private func clockString(_ seconds: Int) -> String {
        String(format: "%dh %02dm %02ds", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

#if DEBUG
#Preview("Anniversary") {
    AnniversaryView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

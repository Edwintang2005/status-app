import SwiftUI

/// The last layer of the easter egg: how long the two of them have been tied
/// together, ticking live from the date the owner set, with the next milestone
/// and a celebration on milestone days. Says so while no date is set — and
/// hands the owner the picker.
struct AnniversaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var pieces = ConfettiPiece.emitter(count: 48)
    @State private var opened = Date()
    @State private var editing = false

    var body: some View {
        ZStack {
            Theme.Background()
            if let anniversary = model.anniversary {
                TimelineView(.periodic(from: .now, by: 1)) { context in
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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(Theme.rounded(14, .bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(20)
        }
        .sheet(isPresented: $editing) {
            AnniversaryEditorView(mode: .edit)
                .environment(model)
        }
        .task {
            opened = .now
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { revealed = true }
        }
    }

    // MARK: - No date yet

    private var unset: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("❤️")
                .font(.system(size: 64))
                .scaleEffect(revealed ? 1 : 0.3)
                .accessibilityHidden(true)
            Text("No date yet")
                .font(Theme.rounded(30, .bold))
            if model.canEditAnniversary {
                Text("Tell the app when the two of you began and the count starts here — on both phones.")
                    .font(Theme.rounded(15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    editing = true
                } label: {
                    Label("Set our date", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
            } else {
                Text("\(model.partnerName) hasn't set the day the two of you began. Once they do, the count appears here.")
                    .font(Theme.rounded(15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.canRequestAnniversary {
                    // The ask travels with the next sync and greets the owner
                    // when they next open the app — no push, by design.
                    Button {
                        Task { await model.requestAnniversary() }
                    } label: {
                        Label("Ask \(model.partnerName) to set it", systemImage: "hand.wave")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
                    if let asked = model.anniversaryRequestedAt {
                        Text("Asked \(asked, format: .relative(presentation: .named)). They'll see it when they next open the app.")
                            .font(Theme.rounded(12))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .opacity(revealed ? 1 : 0)
    }

    // MARK: - Content

    private func content(_ anniversary: Anniversary,
                         now: Date,
                         celebrating: Anniversary.Milestone?) -> some View {
        let elapsed = max(0, now.timeIntervalSince(anniversary.startsAt))
        let days = Int(elapsed / 86_400)
        let clock = Int(elapsed) % 86_400

        return ScrollView {
            VStack(spacing: 0) {
                Text("❤️")
                    .font(.system(size: 64))
                    .scaleEffect(revealed ? 1 : 0.3)
                    .rotationEffect(.degrees(revealed ? 0 : -20))
                    .padding(.top, 36)
                    .padding(.bottom, 22)
                    .accessibilityHidden(true)

                if let celebrating {
                    Text("Happy \(celebrating.title)")
                        .font(Theme.rounded(34, .bold))
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 18)
                }

                Text("Tied together for")
                    .font(Theme.rounded(12, .semibold))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Text("\(days)")
                    .font(Theme.rounded(104, .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: days)
                    .shadow(color: Theme.warm.opacity(0.35), radius: 18)
                Text("^[\(days) day](inflect: true)")
                    .font(Theme.rounded(20, .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, -8)
                    .accessibilityHidden(true)

                Text(clockString(clock))
                    .font(Theme.rounded(30, .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: clock)
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.top, 14)
                    .accessibilityLabel(clockLabel(clock))

                breakdown(anniversary, now: now)
                    .padding(.top, 20)

                VStack(spacing: 12) {
                    sinceCard(anniversary)
                    if let next = anniversary.nextMilestone(after: now) {
                        nextCard(next, anniversary: anniversary, now: now)
                    }
                }
                .padding(.top, 30)

                Text("\(model.myDisplayName) & \(model.partnerName)")
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .containerRelativeFrame(.horizontal)
            .opacity(revealed ? 1 : 0)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tied together for \(days) days")
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
        .foregroundStyle(Theme.accent)
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
                    .font(Theme.rounded(11, .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(anniversary.startsAt,
                     format: Date.FormatStyle(date: .long, time: .shortened, timeZone: anniversary.timeZone))
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.canEditAnniversary {
                Image(systemName: "pencil")
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(.secondary)
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
                    .font(Theme.rounded(11, .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(next.title)
                    .font(Theme.rounded(17, .semibold))
                Text(next.date, format: Date.FormatStyle(date: .complete, timeZone: anniversary.timeZone))
                    .font(Theme.rounded(13))
                    .foregroundStyle(.secondary)
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

    private func clockString(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func clockLabel(_ seconds: Int) -> String {
        String(localized: "and \(seconds / 3600) hours, \(seconds / 60 % 60) minutes, \(seconds % 60) seconds")
    }
}

#if DEBUG
#Preview("Anniversary") {
    AnniversaryView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

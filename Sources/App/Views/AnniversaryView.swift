import SwiftUI

/// The easter egg's clock. Sydney's calendar throughout, so the monthly mark
/// stays on the 5th at 11:02 pm across the daylight-saving change.
enum Anniversary {
    static let timeZone = TimeZone(identifier: "Australia/Sydney")!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// 5 June 2026, 11:02 pm AEST.
    static let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 5,
                                                          hour: 23, minute: 2))!

    struct Milestone {
        let months: Int
        let date: Date

        var title: String {
            if months % 12 == 0 {
                let years = months / 12
                return years == 1 ? String(localized: "1 year") : String(localized: "\(years) years")
            }
            return months == 1 ? String(localized: "1 month") : String(localized: "\(months) months")
        }
    }

    /// Monthly to a year, then yearly; the run is ascending so the first date
    /// past `now` is the next one.
    static func milestones() -> [Milestone] {
        let months = [1, 2, 3, 6, 9, 12] + stride(from: 24, through: 12 * 60, by: 12)
        return months.compactMap { count in
            calendar.date(byAdding: .month, value: count, to: start)
                .map { Milestone(months: count, date: $0) }
        }
    }

    /// From tomorrow: today's milestone is the headline, not what's next.
    static func nextMilestone(after now: Date) -> Milestone? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: now)) else { return nil }
        return milestones().first { $0.date >= tomorrow }
    }

    /// The milestone landing today (Sydney's day), if any — the whole day
    /// celebrates, not just the minute.
    static func milestoneToday(_ now: Date) -> Milestone? {
        milestones().first { calendar.isDate($0.date, inSameDayAs: now) }
    }
}

/// Hidden behind a long press on the home screen's title: how long the two of
/// them have been tied together, ticking live, with the next milestone and a
/// celebration on milestone days.
struct AnniversaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var pieces = ConfettiPiece.emitter(count: 48)
    @State private var opened = Date()

    var body: some View {
        ZStack {
            Theme.Background()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let milestone = Anniversary.milestoneToday(now)

                // One view, not two: a tuple here is stacked, not layered.
                content(now: now, celebrating: milestone)
                    .overlay {
                        if milestone != nil, !reduceMotion {
                            ConfettiLayer(pieces: pieces, start: opened)
                                .allowsHitTesting(false)
                                .ignoresSafeArea()
                        }
                    }
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
        .task {
            opened = .now
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { revealed = true }
        }
    }

    // MARK: - Content

    private func content(now: Date, celebrating: Anniversary.Milestone?) -> some View {
        let elapsed = max(0, now.timeIntervalSince(Anniversary.start))
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
                        .font(.system(size: 34, weight: .bold, design: .rounded))
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
                    .font(.system(size: 104, weight: .bold, design: .rounded))
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
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: clock)
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.top, 14)
                    .accessibilityLabel(clockLabel(clock))

                breakdown(now: now)
                    .padding(.top, 20)

                VStack(spacing: 12) {
                    sinceCard
                    if let next = Anniversary.nextMilestone(after: now) {
                        nextCard(next, now: now)
                    }
                }
                .padding(.top, 30)

                Text("\(model.myDisplayName) & \(model.partnerName)")
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(.tertiary)
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

    /// Calendar months and days between the two *dates*, which is how people
    /// count these things — "3 months today", not "2 months, 30 days" until 11:02 pm.
    private func breakdown(now: Date) -> some View {
        let calendar = Anniversary.calendar
        let parts = calendar.dateComponents([.month, .day],
                                            from: calendar.startOfDay(for: Anniversary.start),
                                            to: calendar.startOfDay(for: now))
        let months = max(0, parts.month ?? 0)
        let days = max(0, parts.day ?? 0)

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

    private var sinceCard: some View {
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
                Text(Anniversary.start, format: startStyle)
                    .font(Theme.rounded(17, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private func nextCard(_ next: Anniversary.Milestone, now: Date) -> some View {
        let daysLeft = Anniversary.calendar.dateComponents(
            [.day],
            from: Anniversary.calendar.startOfDay(for: now),
            to: Anniversary.calendar.startOfDay(for: next.date)).day ?? 0

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
                Text(next.date, format: dayStyle)
                    .font(Theme.rounded(13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("in ^[\(daysLeft) day](inflect: true)")
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.warm, in: Capsule())
        }
        .card(padding: 16)
    }

    // MARK: - Formatting

    private var startStyle: Date.FormatStyle {
        Date.FormatStyle(date: .long, time: .shortened, timeZone: Anniversary.timeZone)
    }

    private var dayStyle: Date.FormatStyle {
        Date.FormatStyle(date: .complete, timeZone: Anniversary.timeZone)
    }

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

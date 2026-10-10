import SwiftUI

/// The rolling status log, grouped by day, filterable by direction. Backed by
/// the cloud `StatusLog` records, so it comes back on a new phone.
struct StatusHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [Row] = []
    @State private var filter: HistoryFilter = .all

    /// An entry and how it may be shown (invariant 20).
    private struct Row: Identifiable {
        let entry: StatusHistoryEntry
        let shown: ModeratedStatus
        var id: String { entry.id }
        var at: Date { entry.at }
        var fromMe: Bool { entry.fromMe }
    }

    private var filtered: [Row] {
        entries.filter { filter.allows(fromMe: $0.fromMe) }
    }

    /// Newest day first; entries within a day stay newest first.
    private var byDay: [(day: Date, entries: [Row])] {
        let grouped = Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.at)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        let partnerName = model.partnerName

        NavigationStack {
            ZStack {
                Theme.Background()

                // A plain stack, not `.safeAreaInset(edge: .top)` (invariant 21).
                VStack(spacing: 0) {
                    HistoryFilterPicker(filter: $filter, partnerName: partnerName)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .zIndex(1)

                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label("No statuses yet", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text("Statuses show up here as they're set, including ones from before this phone.")
                        }
                    } else {
                        List {
                            ForEach(byDay, id: \.day) { group in
                                Section {
                                    ForEach(group.entries) { row in
                                        rowView(row, partnerName: partnerName)
                                    }
                                } header: {
                                    Text(dayLabel(group.day))
                                        .foregroundStyle(Color.primary)
                                        .accessibilityIdentifier("history.day.header")
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .topBarBacking()
                    }
                }
                .topBarBackingCeiling()
            }
            .navigationTitle("Status history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let reportedAt = model.hiddenPartnerStatusAt
            let filterOn = model.contentFilterEnabled
            entries = StatusHistoryLog.shared.load().map {
                Row(entry: $0, shown: $0.moderation(reportedAt: reportedAt, filterEnabled: filterOn))
            }
        }
    }

    private func rowView(_ row: Row, partnerName: String) -> some View {
        let entry = row.entry
        let message = row.shown.message
        return HStack(spacing: 12) {
            // Emoji-only is a status of its own: the emoji, a little larger, and its time.
            Text(row.shown.emoji)
                .font(.system(size: message.text.isEmpty ? 34 : 28))

            VStack(alignment: .leading, spacing: 2) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Theme.rounded(16, .medium))
                        .foregroundStyle(message.isPlaceholder ? Theme.mutedText : .primary)
                }
                Text((entry.fromMe ? String(localized: "You") : partnerName)
                     + " · " + entry.at.formatted(date: .omitted, time: .shortened))
                    .font(Theme.rounded(12))
                    .foregroundStyle(Theme.mutedText)
            }

            Spacer(minLength: 0)

            if entry.isCelebration {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.warm)
                    .accessibilityLabel("Celebration")
            }
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

#if DEBUG
#Preview("Status history") {
    StatusHistoryView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

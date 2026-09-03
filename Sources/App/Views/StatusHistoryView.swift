import SwiftUI

/// The rolling status log, grouped by day, filterable by direction. Backed by
/// the cloud `StatusLog` records, so it comes back on a new phone.
struct StatusHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [StatusHistoryEntry] = []
    @State private var filter: HistoryFilter = .all

    private var filtered: [StatusHistoryEntry] {
        entries.filter { filter.allows(fromMe: $0.fromMe) }
    }

    /// Newest day first; entries within a day stay newest first.
    private var byDay: [(day: Date, entries: [StatusHistoryEntry])] {
        let grouped = Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.at)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("No statuses yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Statuses are logged here from now on, as they happen.")
                    }
                } else {
                    List {
                        ForEach(byDay, id: \.day) { group in
                            Section(dayLabel(group.day)) {
                                ForEach(group.entries) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Status history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                HistoryFilterPicker(filter: $filter, partnerName: model.partnerName)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .task { entries = model.loadStatusHistory() }
    }

    private func row(_ entry: StatusHistoryEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.emoji)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message.isEmpty ? "no message" : entry.message)
                    .font(Theme.rounded(16, .medium))
                    .foregroundStyle(entry.message.isEmpty ? .secondary : .primary)
                Text(who(entry) + " · " + entry.at.formatted(date: .omitted, time: .shortened))
                    .font(Theme.rounded(12))
                    .foregroundStyle(.secondary)
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

    private func who(_ entry: StatusHistoryEntry) -> String {
        entry.fromMe ? "You" : model.partnerName
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
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

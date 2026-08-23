import SwiftUI

/// Two taps to a new status: pick a preset, done. Typing is available but never
/// required — the custom field is seeded from whichever preset you tapped.
struct MoodPickerView: View {
    /// Seeded and titled by the caller: in demo builds this same screen is
    /// reused to set the *partner's* status, where "Your status" would be wrong
    /// and seeding from your own emoji would be misleading.
    var title: String = "Your status"
    var initialEmoji: String = ""
    var initialMessage: String = ""
    let onSelect: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var emoji = ""
    @State private var message = ""
    @State private var query = ""
    @FocusState private var messageFocused: Bool

    /// Groups with their matching presets, empty groups dropped. With ~90
    /// presets, scrolling alone isn't a reasonable way to find one.
    private var filteredGroups: [(group: MoodGroup, moods: [Mood])] {
        MoodGroup.allCases.compactMap { group in
            let matches = group.moods.filter { $0.matches(query) }
            return matches.isEmpty ? nil : (group, matches)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        customRow
                        searchField
                        if filteredGroups.isEmpty {
                            Text("No status matches \u{201C}\(query)\u{201D}")
                                .font(Theme.rounded(15))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(filteredGroups, id: \.group) { entry in
                                section(entry.group, moods: entry.moods)
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { commit() }
                        .font(Theme.rounded(17, .semibold))
                        .disabled(emoji.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            emoji = initialEmoji
            message = initialMessage
        }
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN YOUR WORDS")
                .font(Theme.rounded(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(emoji.isEmpty ? "💭" : emoji)
                    .font(.system(size: 34))
                    .opacity(emoji.isEmpty ? 0.35 : 1)
                    .frame(width: 48)

                TextField("Say anything", text: $message)
                    .font(Theme.rounded(17))
                    .focused($messageFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search statuses", text: $query)
                .font(Theme.rounded(16))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func section(_ group: MoodGroup, moods: [Mood]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.rawValue.uppercased())
                .font(Theme.rounded(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(moods) { mood in
                    moodTile(mood)
                }
            }
        }
    }

    private func moodTile(_ mood: Mood) -> some View {
        let selected = mood.emoji == emoji && mood.label == message

        return Button {
            emoji = mood.emoji
            message = mood.label
            messageFocused = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 6) {
                Text(mood.emoji).font(.system(size: 30))
                Text(mood.label)
                    .font(Theme.rounded(11, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: selected)
    }

    private func commit() {
        guard !emoji.isEmpty else { return }
        onSelect(emoji, message)
        dismiss()
    }
}

#if DEBUG
#Preview("Mood picker") {
    MoodPickerView(initialEmoji: "💼", initialMessage: "working") { _, _ in }
        .tint(Theme.accent)
}
#endif

import SwiftUI

/// Two taps to a new status: pick a preset, done. Typing is available but never
/// required — the custom field is seeded from whichever preset you tapped, and
/// the emoji slot beside it takes any emoji from the keyboard.
struct MoodPickerView: View {
    var initialEmoji: String = ""
    let onSelect: (String, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var emoji = ""
    @State private var message = ""
    @State private var query = ""
    /// Armed by the celebration preset and kept while the wording is retyped —
    /// inferring it from the text would lose it.
    @State private var isCelebration = false
    /// Tile for the selection highlight, tracked by id: a preset tap keeps a
    /// hand-typed message, and some presets share an emoji, so neither identifies the tile.
    @State private var selectedPresetID: String?
    @FocusState private var messageFocused: Bool

    /// Groups with their matching presets, empty groups dropped.
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
            .navigationTitle("Your status")
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
        // Opens ready for a *new* status: the emoji carries over (Set stays
        // enabled) but the message, tile highlight and celebration flag start fresh.
        .onAppear {
            emoji = initialEmoji
        }
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN YOUR WORDS")
                .font(Theme.rounded(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Any emoji at all: tapping opens the emoji keyboard, and a
                // pick hands focus on to the words.
                EmojiField(emoji: $emoji) {
                    selectedPresetID = nil
                    isCelebration = false
                    messageFocused = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .frame(width: 52, height: 48)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(emoji.isEmpty ? String(localized: "Emoji") : String(localized: "Emoji: \(emoji)"))
                .accessibilityHint("Choose any emoji")

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

            if isCelebration { celebrationChip }
        }
        .animation(.smooth(duration: 0.25), value: isCelebration)
    }

    /// The only visible sign of the flag once the wording is edited — and the
    /// only way to turn it off without picking another preset.
    private var celebrationChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(Theme.rounded(13, .semibold))
            Text("Fills their screen when they next open the app")
                .font(Theme.rounded(13, .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                isCelebration = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.rounded(15))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn off the celebration")
        }
        .foregroundStyle(Theme.warm)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.warm.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
                .accessibilityLabel("Clear search")
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
        let selected = mood.id == selectedPresetID

        return Button {
            emoji = mood.emoji
            selectedPresetID = mood.id
            // Seed the field only when that wouldn't erase hand-typed words —
            // tapping a preset then is picking its emoji, not a replacement message.
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || isPresetLabel(message) {
                message = mood.label
            }
            isCelebration = mood.isCelebration
            messageFocused = false
            if mood.isCelebration {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            VStack(spacing: 6) {
                Text(mood.emoji)
                    .font(.system(size: 30))
                    .overlay(alignment: .topTrailing) {
                        if mood.isCelebration {
                            Image(systemName: "sparkles")
                                .font(Theme.rounded(10, .bold))
                                .foregroundStyle(Theme.warm)
                                .offset(x: 10, y: -4)
                        }
                    }
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
        // The emoji is decoration; the label is the status.
        .accessibilityLabel(mood.label)
        .accessibilityValue(mood.isCelebration ? "Celebration" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Whether the text is (still) one of the preset labels — in which case
    /// tapping another preset should swap it as it always has.
    private func isPresetLabel(_ text: String) -> Bool {
        MoodGroup.allCases.contains { $0.moods.contains { $0.label == text } }
    }

    private func commit() {
        guard !emoji.isEmpty else { return }
        onSelect(emoji, message, isCelebration)
        dismiss()
    }
}

// MARK: - Emoji field

/// A one-emoji text field that opens straight onto the emoji keyboard. UIKit,
/// because SwiftUI has no way to ask for that keyboard: a `UITextField` that
/// overrides `textInputMode` (and a non-nil context identifier, which the
/// system needs before it honours the override). Anything typed that isn't an
/// emoji is dropped; the newest emoji wins and the keyboard is dismissed.
private struct EmojiField: UIViewRepresentable {
    @Binding var emoji: String
    /// Called after a new emoji lands, so the caller can move focus along.
    var onPicked: () -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.font = .systemFont(ofSize: 34)
        field.textAlignment = .center
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.attributedPlaceholder = NSAttributedString(
            string: "💭",
            attributes: [.foregroundColor: UIColor.label.withAlphaComponent(0.35),
                         .font: UIFont.systemFont(ofSize: 34)])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: EmojiTextField, context: Context) {
        context.coordinator.parent = self
        if !field.isEditing, field.text != emoji { field.text = emoji }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiField

        init(parent: EmojiField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let typed = field.text ?? ""
            guard let picked = typed.last(where: \.isEmoji) else {
                // Letters, digits, or a clear: back to whatever was there.
                field.text = typed.isEmpty ? "" : parent.emoji
                if typed.isEmpty { parent.emoji = "" }
                return
            }
            let value = String(picked)
            field.text = value
            guard value != parent.emoji else { return }
            parent.emoji = value
            field.resignFirstResponder()
            parent.onPicked()
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

final class EmojiTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

private extension Character {
    /// Emoji proper: pictographs and sequences, not "1" or "#" (which carry the
    /// emoji property but need a variation selector to render as one).
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

#if DEBUG
#Preview("Mood picker") {
    MoodPickerView(initialEmoji: "💼") { _, _, _ in }
        .tint(Theme.accent)
}
#endif

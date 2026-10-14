import SwiftUI

/// Two taps to a new status: pick a preset, done. Typing is available but never
/// required — the custom field is seeded from whichever preset you tapped, and
/// the emoji slot beside it takes any emoji from the keyboard.
struct MoodPickerView: View {
    var initialEmoji: String = ""
    /// The current words, shown as the placeholder so it's clear what Set replaces.
    var currentMessage: String = ""
    /// Your own recent statuses, newest first and distinct — the quick way back.
    var recent: [StatusHistoryEntry] = []
    let onSelect: (String, String, CelebrationStyle?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var emoji = ""
    @State private var message = ""
    @State private var query = ""
    /// Armed only by a celebration preset, by design — never inferred from a
    /// typed emoji — and kept while the wording is retyped.
    @State private var celebration: CelebrationStyle?
    /// Read once, so a picker left open over midnight doesn't reshuffle "Us".
    @State private var today = Date()
    /// Tile for the selection highlight, tracked by id: a preset tap keeps a
    /// hand-typed message, and some presets share an emoji, so neither identifies the tile.
    @State private var selectedPresetID: String?
    /// Set once: a second tap on "Set" while the sheet is on its way out
    /// would send the same status twice.
    @State private var committed = false
    /// Bumped by a tile tap: the tiles sit below the words, so the sheet
    /// scrolls back up to show (and allow editing) what was just picked.
    @State private var wordsScrollRequest = 0
    @FocusState private var messageFocused: Bool

    /// Groups with their matching presets, empty groups dropped.
    private var filteredGroups: [(group: MoodGroup, moods: [Mood])] {
        MoodGroup.allCases.compactMap { group in
            let matches = group.moods(on: today).filter { $0.matches(query) }
            return matches.isEmpty ? nil : (group, matches)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            customRow
                            searchField
                            if query.isEmpty, !recent.isEmpty {
                                recentSection
                            }
                            if filteredGroups.isEmpty {
                                Text("No status matches \u{201C}\(query)\u{201D}")
                                    .font(Theme.rounded(15))
                                    .foregroundStyle(Theme.mutedText)
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
                        .containerRelativeFrame(.horizontal)
                        .id(Self.topID)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: wordsScrollRequest) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            proxy.scrollTo(Self.topID, anchor: .top)
                        }
                    }
                }
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
                        .disabled(!hasChange)
                        .accessibilityHint(hasChange ? "" : "Pick a status or type one")
                }
            }
        }
        .presentationDetents([.large])
        // Opens ready for a *new* status: the emoji carries over but the message,
        // tile highlight and celebration flag start fresh — and Set waits for a
        // change, so one stray tap can't re-post the emoji over your words.
        .onAppear {
            emoji = initialEmoji
        }
    }

    private static let topID = "top"

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section heads in plain primary: grey small caps fell under 4.5:1
            // over the backdrop's crimson corner, where this sheet starts.
            Text("IN YOUR WORDS")
                .eyebrow(size: 12, color: .primary)

            HStack(spacing: 12) {
                // Any emoji at all: tapping opens the emoji keyboard, and a
                // pick hands focus on to the words.
                EmojiField(emoji: $emoji) {
                    selectedPresetID = nil
                    celebration = nil
                    messageFocused = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .frame(width: 52, height: 48)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(emoji.isEmpty ? String(localized: "Emoji") : String(localized: "Emoji: \(emoji)"))
                .accessibilityHint("Choose any emoji")

                TextField(fieldPrompt, text: $message)
                    .font(Theme.rounded(17))
                    .focused($messageFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    // A glance, not a paragraph; widgets truncate anything longer.
                    .onChange(of: message) { _, text in
                        if text.count > AppConfig.statusMessageMaxLength {
                            message = String(text.prefix(AppConfig.statusMessageMaxLength))
                        }
                    }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if emoji.isEmpty, !trimmedMessage.isEmpty {
                Text("Sends with 💬 unless you pick an emoji.")
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
            }
            CharacterCount(count: message.count, limit: AppConfig.statusMessageMaxLength)

            if let celebration { celebrationChip(celebration) }
        }
        .animation(.smooth(duration: 0.25), value: celebration)
    }

    private var fieldPrompt: String {
        if celebration == .reveal { return String(localized: "Your news, kept secret") }
        return currentMessage.isEmpty ? String(localized: "Say anything") : currentMessage
    }

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A tapped tile (even the current status, re-posted on purpose), a
    /// different emoji, or words typed. A surprise needs its news.
    private var hasChange: Bool {
        if celebration == .reveal, trimmedMessage.isEmpty { return false }
        return selectedPresetID != nil || emoji != initialEmoji || !trimmedMessage.isEmpty
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT")
                .eyebrow(size: 12, color: .primary)

            TileGrid {
                ForEach(recent) { entry in
                    tile(emoji: entry.emoji,
                         label: entry.message,
                         selected: selectedPresetID == entry.id,
                         celebration: false) {
                        emoji = entry.emoji
                        message = entry.message
                        selectedPresetID = entry.id
                        celebration = nil
                        messageFocused = false
                        wordsScrollRequest += 1
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
    }

    /// The only visible sign of the celebration once the wording is edited —
    /// and the only way to turn it off without picking another preset.
    private func celebrationChip(_ style: CelebrationStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: style == .reveal ? "gift" : "sparkles")
                .font(Theme.rounded(13, .semibold))
            Text(chipText(style))
                .font(Theme.rounded(13, .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                celebration = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.rounded(15))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn off the celebration")
        }
        .foregroundStyle(Theme.warmText)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.warm.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private func chipText(_ style: CelebrationStyle) -> LocalizedStringKey {
        switch style {
        case .reveal: "Kept secret — even from their Lock Screen — until they scratch it open in the app"
        case .birthday: "They blow out the candles, then your words appear"
        default: "Fills their screen when they next open the app"
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.mutedText)
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
            Text(group.rawValue)
                .eyebrow(size: 12, color: .primary)

            TileGrid {
                ForEach(moods) { mood in
                    moodTile(mood)
                }
            }
        }
    }

    private func moodTile(_ mood: Mood) -> some View {
        tile(emoji: mood.emoji,
             label: mood.label,
             selected: mood.id == selectedPresetID,
             celebration: mood.isCelebration) {
            emoji = mood.emoji
            selectedPresetID = mood.id
            let untouched = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || isPresetLabel(message)
            celebration = mood.celebration
            if mood.celebration == .reveal {
                // The words are the news: a sealed "guess what" would reveal nothing.
                if untouched { message = "" }
                messageFocused = true
            } else {
                // Seed the field only when that wouldn't erase hand-typed words —
                // tapping a preset then is picking its emoji, not a replacement message.
                if untouched { message = mood.label }
                messageFocused = false
            }
            wordsScrollRequest += 1
            if mood.isCelebration {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func tile(emoji: String,
                      label: String,
                      selected: Bool,
                      celebration: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(emoji)
                    .font(.system(size: 30))
                    .overlay(alignment: .topTrailing) {
                        if celebration {
                            Image(systemName: "sparkles")
                                .font(Theme.rounded(10, .bold))
                                .foregroundStyle(Theme.warm)
                                .offset(x: 10, y: -4)
                        }
                    }
                // A recent emoji-only status has no label: the emoji stands alone.
                if !label.isEmpty {
                    Text(label)
                        .font(Theme.rounded(11, .medium))
                        .foregroundStyle(Color.primary)
                        // Wraps rather than shrinks (the audit reads shrunk text as clipped).
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("status.tile.label")
                }
            }
            .frame(maxWidth: .infinity)
            // Grows at large text sizes rather than clipping the label.
            .frame(minHeight: 84)
            .padding(.vertical, 4)
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
        .accessibilityLabel(label.isEmpty ? emoji : label)
        .accessibilityValue(celebration ? "Celebration" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Whether the text is (still) one of the preset labels — in which case
    /// tapping another preset should swap it as it always has.
    private func isPresetLabel(_ text: String) -> Bool {
        MoodGroup.allCases.contains { $0.moods(on: today).contains { $0.label == text } }
    }

    private func commit() {
        guard hasChange, !committed else { return }
        committed = true
        // Words alone go with 💬, as a banner reply does.
        onSelect(emoji.isEmpty ? "💬" : emoji, message, celebration)
        dismiss()
    }
}

// MARK: - Tile grid

/// The adaptive grid, but eager: a `LazyVGrid` guesses the heights of rows it
/// hasn't laid out, so the scroll back up to the words fell short after a flick.
private struct TileGrid: Layout {
    var minimumWidth: CGFloat = 78
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = rows(width: proposal.width, subviews: subviews)
        let height = grid.heights.reduce(0, +) + spacing * CGFloat(max(grid.heights.count - 1, 0))
        return CGSize(width: proposal.width ?? grid.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = rows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in grid.heights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (grid.cellWidth + spacing)
                subviews[index].place(at: CGPoint(x: x + grid.cellWidth / 2, y: y + height / 2),
                                      anchor: .center,
                                      proposal: ProposedViewSize(width: grid.cellWidth, height: nil))
            }
            y += height + spacing
        }
    }

    private func rows(width: CGFloat?, subviews: Subviews) -> (columns: Int, cellWidth: CGFloat, width: CGFloat, heights: [CGFloat]) {
        let width = width ?? (minimumWidth + spacing) * CGFloat(subviews.count) - spacing
        let columns = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cell = ProposedViewSize(width: cellWidth, height: nil)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(cell).height }
                .max() ?? 0
        }
        return (columns, cellWidth, width, heights)
    }
}

// MARK: - Character count

/// Appears as a field nears its cap, so the cut-off is never a surprise.
struct CharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        if count >= limit * 3 / 4 {
            Text("\(count) / \(limit)")
                .font(Theme.rounded(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(count >= limit ? Theme.warmText : Theme.mutedText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("\(count) of \(limit) characters")
        }
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

import SwiftUI

/// Owner only: when the two of them began. Shown as a prompt once the invite
/// link exists, from the hidden row in Settings, and from the count screen
/// while no date is set. Saves in the owner's current time zone.
struct AnniversaryEditorView: View {
    enum Mode { case prompt, edit }

    let mode: Mode

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var confirmingRemoval = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 24)

                        Text("When did the two of you begin?")
                            .font(Theme.rounded(24, .bold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Pick the day, and the minute if you know it. \(model.partnerName) will see the same count, and only you can change it.")
                            .font(Theme.rounded(15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)

                        DatePicker("When it began",
                                   selection: $date,
                                   in: ...Date(),
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .card(padding: 12)

                        Text("It's the start of a count hidden somewhere in the app. Only the two of you can find it.")
                            .font(Theme.rounded(13))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)

                        VStack(spacing: 12) {
                            Button {
                                save()
                            } label: {
                                Label("Save", systemImage: "heart.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle())

                            if mode == .prompt {
                                Button("Not now") {
                                    model.dismissAnniversaryPrompt()
                                    dismiss()
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            } else if model.anniversary != nil {
                                Button("Remove the date", role: .destructive) {
                                    confirmingRemoval = true
                                }
                                .font(Theme.rounded(15, .medium))
                                .padding(.top, 4)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(mode == .prompt ? "One more thing" : "Our date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .edit {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .confirmationDialog("Remove the date?",
                                isPresented: $confirmingRemoval,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await model.setAnniversary(nil) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The count disappears on both phones until a date is set again.")
            }
        }
        // The prompt is answered or skipped, never swiped away half-done.
        .interactiveDismissDisabled(mode == .prompt)
        .onAppear { date = model.anniversary?.startsAt ?? Date() }
    }

    private func save() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let anniversary = Anniversary(startsAt: date)
        // Saved locally before the network call; the sheet needn't wait for it.
        Task { await model.setAnniversary(anniversary) }
        dismiss()
    }
}

#if DEBUG
#Preview("Prompt") {
    AnniversaryEditorView(mode: .prompt)
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

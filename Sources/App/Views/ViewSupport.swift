import SwiftUI

extension Binding {
    /// A presentation flag over an optional: true while it holds a value, and
    /// dismissing clears it.
    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil },
                      set: { if !$0 { wrappedValue = nil } })
    }
}

extension View {
    /// Counts `remaining` down through the nudge cooldown after `sentAt`, once
    /// a second, and stops at zero — so no timer runs outside a cooldown.
    func nudgeCooldown(after sentAt: Date?, remaining: Binding<TimeInterval>) -> some View {
        task(id: sentAt) {
            while !Task.isCancelled {
                remaining.wrappedValue = max(0, AppConfig.nudgeCooldown - Date().timeIntervalSince(sentAt ?? .distantPast))
                guard remaining.wrappedValue > 0 else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// "Hide from widget" / "Show in widget" on the partner's picture the photo
/// widget shows, or one this phone took off it; nothing on any other moment.
struct WidgetPictureToggle: View {
    @Environment(AppModel.self) private var model
    let moment: Moment

    var body: some View {
        let state = model.widgetPictureState(of: moment)
        if state.shown || state.hidden {
            Button {
                Task { await model.setShownInWidget(moment, state.hidden) }
            } label: {
                if state.hidden {
                    Label("Show in widget", systemImage: "rectangle.on.rectangle")
                } else {
                    Label("Hide from widget", systemImage: "rectangle.on.rectangle.slash")
                }
            }
        }
    }
}

extension View {
    /// Reporting a partner moment, from the gallery or the library (guideline 1.2):
    /// one set of words. `onReported` runs after the report, before the dialog clears.
    func reportMomentDialog(_ moment: Binding<Moment?>, model: AppModel,
                            onReported: @escaping (Moment) -> Void = { _ in }) -> some View {
        confirmationDialog("Report this \(moment.wrappedValue?.noun ?? "moment")?",
                           isPresented: moment.isPresent(),
                           titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                if let reporting = moment.wrappedValue {
                    model.report(reporting)
                    onReported(reporting)
                }
                moment.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { moment.wrappedValue = nil }
        } message: {
            Text("It's removed from this iPhone straight away, and an email to us opens with the details — send it and we'll respond within 24 hours.")
        }
    }

    /// Reporting the partner's status, from its card or a celebration. `reveal`,
    /// when the filter hid its words, offers to show them instead.
    func reportStatusDialog(isPresented: Binding<Bool>, onReport: @escaping () -> Void,
                            reveal: (() -> Void)? = nil) -> some View {
        confirmationDialog("Report this status?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Report", role: .destructive, action: onReport)
            if let reveal {
                Button("Show hidden text", action: reveal)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text is hidden on this iPhone straight away, and an email to us opens with the details — send it and we'll respond within 24 hours.")
        }
    }

    /// The confirmation before "Delete for both of you": the same words from the gallery and the library.
    func deleteMomentDialog(_ moment: Binding<Moment?>, model: AppModel) -> some View {
        confirmationDialog("Delete this \(moment.wrappedValue?.noun ?? "moment") for both of you?",
                           isPresented: moment.isPresent(),
                           titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting = moment.wrappedValue {
                    Task { await model.deleteMoment(deleting) }
                }
                moment.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { moment.wrappedValue = nil }
        } message: {
            Text("It's removed from both iPhones and iCloud. Copies already saved to Photos or exported aren't affected.")
        }
    }
}

/// A moment's caption as the composers take it: one line, capped at
/// `captionMaxLength` as typed, its count shown beneath.
struct CaptionField: View {
    @Binding var caption: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 6) {
            TextField("Add a caption (optional)", text: $caption)
                .font(Theme.rounded(16))
                .focused(focus)
                .submitLabel(.done)
                .onChange(of: caption) { _, text in
                    if text.count > AppConfig.captionMaxLength {
                        caption = String(text.prefix(AppConfig.captionMaxLength))
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            CharacterCount(count: caption.count, limit: AppConfig.captionMaxLength)
        }
    }
}

/// How a Save to Photos went, for the button that started it.
enum SaveState: Equatable {
    case idle, saving, saved
    case failed(String)
}

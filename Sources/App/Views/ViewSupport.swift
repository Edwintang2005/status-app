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

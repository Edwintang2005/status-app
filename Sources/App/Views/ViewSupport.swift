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

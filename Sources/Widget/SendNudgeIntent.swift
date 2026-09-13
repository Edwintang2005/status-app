import AppIntents

/// Sends without unlocking or opening the app. Compiled into the widget (the
/// lock-screen heart; WidgetKit reloads the timeline once `perform()` returns)
/// and the app (Siri and Shortcuts via `RedStringShortcuts`).
struct SendNudgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a nudge"
    static let description = IntentDescription("Let them know you're thinking of them.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        // Never surface an error dialog on the lock screen; the next tap retries.
        // Bounded: a WidgetKit kill mid-save would leave the cooldown claimed with
        // no failure stamp — a timeout takes `sendNudge`'s failure path instead.
        _ = try? await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.sendNudge() }
        // In-app (Siri) the model holds its own snapshot copy; a no-op in the widget.
        await MainActor.run {
            NotificationCenter.default.post(name: .pairingDidChange, object: nil)
        }
        return .result()
    }
}

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
        // no failure stamp.
        let started = Date().wholeSeconds
        do {
            _ = try await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.sendNudge() }
        } catch is CancellationError {
            // The deadline abandons the send rather than waiting for it, so its own
            // failure path may never run before WidgetKit suspends us.
            await MainActor.run {
                _ = SharedStore.shared.mutate { NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &$0) }
            }
        } catch {
            // `sendNudge`'s own failure path released the cooldown and stamped it.
        }
        // In-app (Siri) the model holds its own snapshot copy; a no-op in the widget.
        await MainActor.run {
            NotificationCenter.default.post(name: .pairingDidChange, object: nil)
        }
        return .result()
    }
}

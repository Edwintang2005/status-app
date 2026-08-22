import AppIntents
import WidgetKit

/// Runs inside the widget extension, so tapping the lock screen heart sends the
/// nudge without ever unlocking or opening the app. WidgetKit reloads the
/// timeline once `perform()` returns.
struct SendNudgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a nudge"
    static let description = IntentDescription("Let them know you're thinking of them.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        // A failed nudge should never surface as an error dialog on the lock
        // screen; the cooldown is released internally so the next tap retries.
        _ = try? await CloudSync.shared.sendNudge()
        return .result()
    }
}

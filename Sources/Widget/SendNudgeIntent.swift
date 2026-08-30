import AppIntents
import WidgetKit

/// Runs in the widget extension — sends without unlocking or opening the app.
/// WidgetKit reloads the timeline once `perform()` returns.
struct SendNudgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a nudge"
    static let description = IntentDescription("Let them know you're thinking of them.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        // Never surface an error dialog on the lock screen; the next tap retries.
        _ = try? await CloudSync.shared.sendNudge()
        return .result()
    }
}

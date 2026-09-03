import AppIntents

/// Siri and the Shortcuts app: "Send a nudge with Red String". The intent is
/// the lock-screen heart's, compiled into both the app and the widget.
struct RedStringShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendNudgeIntent(),
            phrases: [
                "Send a nudge with \(.applicationName)",
                "Send a heart with \(.applicationName)",
                "Tell them I'm thinking of them with \(.applicationName)",
            ],
            shortTitle: "Send a nudge",
            systemImageName: "heart.fill"
        )
    }
}

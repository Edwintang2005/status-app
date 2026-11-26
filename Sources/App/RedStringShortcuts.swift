import AppIntents

/// Siri and the Shortcuts app: a heart (the lock-screen heart's intent, in both
/// the app and the widget), your status, theirs, and how long you've been together.
struct RedStringShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendNudgeIntent(),
            phrases: [
                "Send a heart with \(.applicationName)",
                "Tell them I'm thinking of them with \(.applicationName)",
            ],
            shortTitle: "Send a heart",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: SetStatusIntent(),
            phrases: [
                "Set my \(.applicationName) status",
                "Set my \(.applicationName) status to \(\.$status)",
                "Update my status in \(.applicationName)",
            ],
            shortTitle: "Set my status",
            systemImageName: "face.smiling"
        )
        AppShortcut(
            intent: PartnerStatusIntent(),
            phrases: [
                "What's my partner up to in \(.applicationName)",
                "Check my partner's status in \(.applicationName)",
            ],
            shortTitle: "Their status",
            systemImageName: "person.wave.2"
        )
        AppShortcut(
            intent: TogetherIntent(),
            phrases: [
                "How long have we been together in \(.applicationName)",
                "How long have we been together on \(.applicationName)",
            ],
            shortTitle: "Days together",
            systemImageName: "infinity"
        )
    }
}

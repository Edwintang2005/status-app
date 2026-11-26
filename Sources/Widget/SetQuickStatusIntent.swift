import AppIntents

/// A quick-status widget button: sets that status without opening the app.
/// Compiled into the widget and the app.
struct SetQuickStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a quick status"
    static let isDiscoverable = false
    // StandBy shows home-screen widgets on a locked phone: whoever's at the nightstand isn't you.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Emoji") var emoji: String
    @Parameter(title: "Words") var message: String

    init() {}

    init(emoji: String, message: String) {
        self.emoji = emoji
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Kept and sent later if iCloud can't be reached now; no error on a widget.
        _ = await QuickStatus.set(emoji: emoji, message: message)
        return .result()
    }
}

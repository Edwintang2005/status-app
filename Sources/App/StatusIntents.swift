import AppIntents

/// One of your statuses Siri and Shortcuts can set: a recent one, or a preset.
struct StatusOption: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    static let defaultQuery = StatusOptionQuery()

    let emoji: String
    let message: String

    /// The status itself: a recent one and the preset it came from are one choice.
    var id: String { "\(emoji)\u{1F}\(message)" }

    /// Siri matches what's said against the title: the words alone, the emoji beside them.
    var displayRepresentation: DisplayRepresentation {
        message.isEmpty
            ? DisplayRepresentation(title: "\(emoji)")
            : DisplayRepresentation(title: "\(message)", subtitle: "\(emoji)")
    }

    init(emoji: String, message: String) {
        self.emoji = emoji
        self.message = message
    }

    init?(id: String) {
        let parts = id.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        self.init(emoji: String(parts[0]), message: String(parts[1]))
    }
}

struct StatusOptionQuery: EntityStringQuery {
    /// Your recent statuses first, then the picker's everyday presets. Not the
    /// celebrations: those are an occasion, chosen in the app.
    static func options(now: Date = Date()) -> [StatusOption] {
        let recent = StatusHistoryEntry.recentOwn(in: StatusHistoryLog.shared.load(), limit: 6)
            .map { StatusOption(emoji: $0.emoji, message: $0.message) }
        let presets = MoodGroup.allCases.flatMap { $0.moods(on: now) }
            .filter { !$0.isCelebration }
            .map { StatusOption(emoji: $0.emoji, message: $0.label) }
        var seen = Set<String>()
        return (recent + presets).filter { seen.insert($0.id).inserted }
    }

    func entities(for identifiers: [String]) async throws -> [StatusOption] {
        identifiers.compactMap(StatusOption.init(id:))
    }

    func suggestedEntities() async throws -> [StatusOption] {
        Self.options()
    }

    /// One answer, so Siri sets it rather than asking you to tap one (`SpokenStatus`).
    func entities(matching string: String) async throws -> [StatusOption] {
        let choices = Self.options().map { (emoji: $0.emoji, message: $0.message) }
        return SpokenStatus.match(string, among: choices).map { [StatusOption(emoji: $0.emoji, message: $0.message)] } ?? []
    }
}

/// "Set my Red String status to Sleeping" — sent like a widget tap (`QuickStatus`).
struct SetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set my status"
    static let description = IntentDescription("Sets the status your partner sees.")
    // Its words are encrypted on the way out; and a locked phone isn't yours to speak for.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    // Asked aloud, answered aloud: "Set my Red String status" → "What's your status?" → "Sleeping".
    @Parameter(title: "Status", requestValueDialog: IntentDialog("What's your status?"))
    var status: StatusOption

    static var parameterSummary: some ParameterSummary {
        Summary("Set my status to \(\.$status)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SharedStore.shared.pairing != nil else {
            return .result(dialog: "You're not linked with anyone yet. Open \(AppConfig.appName) to pair.")
        }
        let failure = await QuickStatus.set(emoji: status.emoji, message: status.message)
        // Run in the app: its offline card and retry pacing learn of it, as of any send.
        if let outbox = AppModel.current?.outbox {
            if let failure { outbox.noteSendFailed(failure) } else { outbox.noteSendSucceeded() }
        }
        return .result(dialog: failure == nil
                       ? "Done. Your status is \(status.emoji) \(status.message)."
                       : "Saved. It sends once iCloud can be reached.")
    }
}

/// "What's my partner up to?" — read aloud through the moderation rules.
struct PartnerStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get my partner's status"
    static let description = IntentDescription("Says your partner's status and how long ago they set it.")
    // Their words, spoken: not to whoever picks up a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = SharedStore.shared
        let line = SpokenLines.partnerStatus(in: store.snapshot, reportedAt: store.hiddenPartnerStatusAt,
                                             filterEnabled: store.contentFilterEnabled)
        return .result(value: line, dialog: "\(line)")
    }
}

/// "How long have we been together?"
struct TogetherIntent: AppIntent {
    static let title: LocalizedStringResource = "How long we've been together"
    static let description = IntentDescription("Says how many days you've been together, and the next milestone.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let line = SpokenLines.together(SharedStore.shared.snapshot.anniversary)
        return .result(value: line, dialog: "\(line)")
    }
}

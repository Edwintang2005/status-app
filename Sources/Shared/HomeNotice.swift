import Foundation

/// Home's one-at-a-time notices: `pick` chooses the most urgent, the view draws it.
enum HomeNotice: Equatable, Sendable {
    case partnerLeft, extraMembers(Int), iCloud(String), freshStartClearing, freshStartStuck, freshStartRequest
    case milestone(MilestoneDay), notificationsOff(NotificationsNotice), closeLink, widgetTip, recap(RecapPlan.Period)

    /// Urgent ones sit above the partner card; the rest below the send row.
    var urgent: Bool {
        switch self {
        case .partnerLeft, .extraMembers, .iCloud, .freshStartClearing, .freshStartStuck: true
        case .freshStartRequest, .milestone, .notificationsOff, .closeLink, .widgetTip, .recap: false
        }
    }

    /// Today's milestone: its title, and its `dayKey` — what "Not now" and the
    /// hearts act on, whatever the clock says by the time they're tapped.
    struct MilestoneDay: Equatable, Sendable {
        var title: String
        var key: String
    }

    /// Everything that could put a notice on Home.
    struct Inputs: Equatable, Sendable {
        var partnerLeft = false
        var extraMembers: Int?
        var iCloudProblem: String?
        var offline = false
        var clearingHistory = false
        var freshStartStuck = false
        var freshStartRequest = false
        var milestone: MilestoneDay?
        var notificationsProblem: NotificationsNotice?
        var closeLink = false
        var widgetTip = false
        var recap: RecapPlan.Period?
    }

    /// The most urgent first: what's broken, then what's asked of you, then tips.
    static func pick(from inputs: Inputs) -> HomeNotice? {
        if inputs.partnerLeft { return .partnerLeft }
        if let count = inputs.extraMembers { return .extraMembers(count) }
        // Offline the account check fails as a network error; the offline card covers it.
        if let problem = inputs.iCloudProblem, !inputs.offline { return .iCloud(problem) }
        if inputs.clearingHistory { return .freshStartClearing }
        if inputs.freshStartStuck { return .freshStartStuck }
        if inputs.freshStartRequest { return .freshStartRequest }
        // The day itself, ahead of tips: it only lasts the day.
        if let day = inputs.milestone { return .milestone(day) }
        if let problem = inputs.notificationsProblem { return .notificationsOff(problem) }
        if inputs.closeLink { return .closeLink }
        if inputs.widgetTip { return .widgetTip }
        if let period = inputs.recap { return .recap(period) }
        return nil
    }
}

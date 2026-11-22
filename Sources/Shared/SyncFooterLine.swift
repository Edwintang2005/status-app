import Foundation

/// Home's footer: one line, the most pressing first — a send just landed, then
/// no connection, a sync running, iCloud needing attention, a send running,
/// sends waiting, syncs failing, and only then how fresh the screen is.
enum SyncFooterLine: Equatable, Sendable {
    case sent
    case offline(lastSyncedAt: Date?)
    /// `restoring`: the history is filling in from nothing — "Syncing…" for minutes reads as stuck.
    case syncing(restoring: Bool)
    case iCloudAttention
    case sending
    case waiting(label: String, storageFull: Bool)
    case failing(lastSyncedAt: Date?)
    case synced(Date)
    case neverSynced

    struct Inputs: Equatable, Sendable {
        var partnerName = ""
        var showsSent = false
        var isOffline = false
        var lastSyncedAt: Date?
        var isRefreshing = false
        var needsICloudAttention = false
        var isSending = false
        var pendingCount = 0
        /// The only thing waiting is the status on screen.
        var onlyStatusPending = false
        var storageFull = false
        var isParticipant = false
        var isRestoring = false
        /// Syncs keep failing: "Synced hours ago" alone looks like nothing's wrong.
        var syncFailing = false
    }

    init(_ inputs: Inputs) {
        if inputs.showsSent {
            self = .sent
        } else if inputs.isOffline {
            // Ahead of the rest: offline, a refresh fails at once and readiness reads as a network error.
            self = .offline(lastSyncedAt: inputs.lastSyncedAt)
        } else if inputs.isRefreshing {
            self = .syncing(restoring: inputs.isRestoring)
        } else if inputs.needsICloudAttention {
            self = .iCloudAttention
        } else if inputs.isSending {
            self = .sending
        } else if inputs.pendingCount > 0 {
            // Ahead of "Synced …", which would mislead while a send is still sitting on this device.
            self = .waiting(label: Self.waitingLabel(inputs), storageFull: inputs.storageFull)
        } else if inputs.syncFailing {
            self = .failing(lastSyncedAt: inputs.lastSyncedAt)
        } else if let lastSyncedAt = inputs.lastSyncedAt {
            self = .synced(lastSyncedAt)
        } else {
            self = .neverSynced
        }
    }

    /// A tap retries: VoiceOver mustn't combine the line and swallow its action.
    var isButton: Bool {
        switch self {
        case .waiting, .failing: true
        default: false
        }
    }

    /// Says whose storage is full when that's why sends are stuck — only the owner can fix it.
    private static func waitingLabel(_ inputs: Inputs) -> String {
        let count = inputs.pendingCount
        if count == 1, inputs.onlyStatusPending, !inputs.storageFull {
            return String(localized: "Your status is waiting to send · tap to retry")
        }
        guard inputs.storageFull else {
            return count == 1
                ? String(localized: "1 waiting to send · tap to retry")
                : String(localized: "\(count) waiting to send · tap to retry")
        }
        return inputs.isParticipant
            ? String(localized: "\(inputs.partnerName)'s iCloud is full · \(count) waiting · tap to retry")
            : String(localized: "Your iCloud is full · \(count) waiting · tap to retry")
    }
}

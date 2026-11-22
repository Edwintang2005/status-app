import Foundation

/// What "save memories" wrote (`MemoryArchive`) — and what it allows before an
/// unlink, a wipe or a fresh start deletes anything (`EndingPlan`).
struct ArchiveOutcome: Sendable {
    enum Destination: Sendable, Equatable {
        /// Saved and safe: nothing more for the user to do.
        case iCloudDrive
        /// On this device only — the caller must offer to share it before anything is deleted.
        case deviceOnly
    }

    let folder: URL
    let destination: Destination
    let momentCount: Int
    let statusCount: Int
    /// Moments whose media couldn't be recovered — listed in the archive, not quietly dropped.
    let unrecovered: Int
    /// Of a kind from a newer build: this one can't save them, so no connection helps.
    let unsupported: Int
    /// With no file in iCloud or on this phone (`ArchiveMedia.gone`): nothing to save,
    /// and nothing a delete could take — but listed, and asked about first.
    let gone: Int
    /// What it allows before a delete (`ArchiveGate`).
    let gate: ArchiveGate
    /// The zone was read, every record in it was readable and every picture and
    /// memo was saved; anything short of that must not be the last copy before a delete.
    var isComplete: Bool { gate == .proceed }
    let includesZone: Bool
    let unreadable: Int
}

extension ArchiveOutcome {
    /// What was saved, and what wasn't and why — Settings' report.
    var summary: String {
        let moments = momentCount == 1
            ? String(localized: "1 moment")
            : String(localized: "\(momentCount) moments")
        let statuses = statusCount == 1
            ? String(localized: "1 status")
            : String(localized: "\(statusCount) statuses")
        var text = destination == .iCloudDrive
            ? String(localized: "\(moments) and \(statuses) saved to iCloud Drive › \(AppConfig.appName) › \(folder.lastPathComponent).")
            : String(localized: "\(moments) and \(statuses) saved on this iPhone only.")
        if unrecovered > 0 {
            text += " " + String(localized: "\(unrecovered) couldn't be fetched back from iCloud and are listed in Memories.txt without a file.")
        }
        if unsupported > 0 {
            text += " " + String(localized: "\(unsupported) need a newer version of \(AppConfig.appName) to be saved — update it from the App Store first.")
        }
        if gone > 0 {
            text += " " + String(localized: "\(gone) are no longer in iCloud: the archive has only what this iPhone kept of them.")
        }
        if !includesZone {
            text += " " + String(localized: "iCloud couldn't be reached, so it holds only what was on this iPhone.")
        } else if unreadable > 0 {
            text += " " + String(localized: "\(unreadable) items in iCloud couldn't be read on this iPhone and were left out.")
        }
        return text
    }
}

/// What comes after "save memories" — the rules that stand between an archive
/// and a delete, shared by Settings' unlink and wipe and the fresh start:
/// part of the history with no copy never goes; moments with no file anywhere
/// are asked about; an archive kept only on this iPhone is shared first.
struct EndingPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        /// Nothing was to end: report what was saved.
        case report
        /// Nothing ends: part of the history would go with no copy kept.
        case refuse
        /// Ask once more first (`check` says why), then end.
        case confirm
        case end
        /// Archive only, kept on this iPhone: the share sheet is all there is.
        case none
    }

    var step: Step
    /// The archive is only on this iPhone: its share sheet comes first, and
    /// `step` follows once it closes.
    var sharesFirst: Bool
    /// The last confirmation's words.
    var check: String

    /// - Parameter ending: an unlink, a wipe or a fresh start waits on this archive.
    init(gate: ArchiveGate, deviceOnly: Bool, ending: Bool) {
        sharesFirst = deviceOnly
        let gone = if case .confirmGone(let count) = gate { count } else { 0 }
        check = Self.check(gone: gone, deviceOnly: deviceOnly)
        if !ending {
            step = deviceOnly ? .none : .report
        } else if gate == .retry || gate == .updateFirst {
            step = .refuse
        } else if deviceOnly || gone > 0 {
            step = .confirm
        } else {
            step = .end
        }
    }

    init(_ outcome: ArchiveOutcome, ending: Bool) {
        self.init(gate: outcome.gate, deviceOnly: outcome.destination == .deviceOnly, ending: ending)
    }

    private static func check(gone: Int, deviceOnly: Bool) -> String {
        var parts: [String] = []
        if gone > 0 {
            parts.append(gone == 1
                ? String(localized: "1 moment is no longer in iCloud, so the archive has only what this iPhone kept of it.")
                : String(localized: "\(gone) moments are no longer in iCloud, so the archive has only what this iPhone kept of them."))
        }
        if deviceOnly {
            parts.append(String(localized: "The archive was only shared from this iPhone — continue only if you saved it somewhere safe."))
        }
        return parts.joined(separator: " ")
    }
}

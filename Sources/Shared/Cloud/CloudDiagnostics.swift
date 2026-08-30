import CloudKit
import Foundation

/// A readable dump of this device's CloudKit state, for what the Console can't
/// answer — chiefly which environment *this phone's* build talks to, the likeliest
/// fault when two paired devices don't sync.
struct CloudDiagnostics: Sendable {
    var environment: CloudEnvironment
    var containerID: String
    var accountStatus: String
    /// Zones in this user's own private database.
    var privateZones: [String]
    /// Zones shared *with* this user — where a participant's data lives.
    var sharedZones: [String]
    var subscriptions: [String]
    var pairing: String
    /// Who is on the paired zone's share, one line each. Readable from both sides.
    var shareParticipants: [String]
    /// The invite link's real state ("open" = anyone with the URL can join),
    /// or `nil` when there is no share to ask.
    var sharePublicPermission: String?
    /// Anything that failed while gathering the above, rather than a silent gap.
    var problems: [String]

    /// One block of text, for pasting into a bug report or a message.
    var report: String {
        var lines = [
            "\(AppConfig.appName) — iCloud diagnostics",
            "Environment: \(environment.label)",
            "Container: \(containerID)",
            "Account: \(accountStatus)",
            "Pairing: \(pairing)",
            "Private zones: \(privateZones.isEmpty ? "none" : privateZones.joined(separator: ", "))",
            "Shared zones: \(sharedZones.isEmpty ? "none" : sharedZones.joined(separator: ", "))",
            "Subscriptions: \(subscriptions.isEmpty ? "none" : subscriptions.joined(separator: ", "))",
            "Invite link: \(sharePublicPermission ?? "no share")",
            "Participants: \(shareParticipants.isEmpty ? "none" : shareParticipants.joined(separator: " | "))",
        ]
        if !problems.isEmpty {
            lines.append("Problems: " + problems.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Which CloudKit environment this build talks to. No API reports it; inferred
/// from code signing, which is what decides it. Development and Production share nothing.
enum CloudEnvironment: Sendable {
    case development
    case production
    case unknown

    var label: String {
        switch self {
        case .development: return "Development (Xcode build)"
        case .production: return "Production (TestFlight or App Store)"
        case .unknown: return "Unknown"
        }
    }

    static var current: CloudEnvironment {
        #if DEBUG
        // Xcode runs use the Debug configuration, signed for development.
        return .development
        #else
        // Release reaches devices via TestFlight or the App Store — both Production.
        return .production
        #endif
    }
}

extension CloudSync {
    /// Reads the account, both databases and the subscription list. Every step is
    /// individually tolerant — a failing call is usually the thing being investigated.
    func diagnostics() async -> CloudDiagnostics {
        var problems: [String] = []

        let account: String
        do {
            account = Self.describe(try await accountStatus())
        } catch {
            account = "unavailable"
            problems.append("account: \(error.localizedDescription)")
        }

        var privateZones: [String] = []
        do {
            privateZones = try await container.privateCloudDatabase.allRecordZones()
                .map(\.zoneID.zoneName)
                .sorted()
        } catch {
            problems.append("private zones: \(error.localizedDescription)")
        }

        var sharedZones: [String] = []
        do {
            // The owner name identifies whose zone this is; an empty list means
            // the participant never actually joined anything.
            sharedZones = try await container.sharedCloudDatabase.allRecordZones()
                .map { "\($0.zoneID.zoneName) (owner \($0.zoneID.ownerName))" }
                .sorted()
        } catch {
            problems.append("shared zones: \(error.localizedDescription)")
        }

        var subscriptions: [String] = []
        let pairing = await MainActor.run { SharedStore.shared.pairing }
        let database = pairing.map { self.database(for: $0) } ?? container.privateCloudDatabase
        do {
            subscriptions = try await database.allSubscriptions()
                .map(\.subscriptionID)
                .sorted()
        } catch {
            problems.append("subscriptions: \(error.localizedDescription)")
        }

        var shareParticipants: [String] = []
        var sharePublicPermission: String?
        if let pairing {
            do {
                if let share = try await pairedZoneShare(for: pairing) {
                    sharePublicPermission = Self.describeLink(share.publicPermission)
                    shareParticipants = share.participants.map {
                        Self.describe($0, currentUser: share.currentUserParticipant)
                    }
                }
            } catch {
                problems.append("share: \(error.localizedDescription)")
            }
        }

        return CloudDiagnostics(
            environment: .current,
            containerID: AppConfig.cloudContainerID,
            accountStatus: account,
            privateZones: privateZones,
            sharedZones: sharedZones,
            subscriptions: subscriptions,
            pairing: Self.describe(pairing),
            shareParticipants: shareParticipants,
            sharePublicPermission: sharePublicPermission,
            problems: problems
        )
    }

    /// The paired zone's share record. `nil` when the zone or share isn't
    /// there — for a diagnostic that's an answer, not a failure.
    private func pairedZoneShare(for pairing: PairingInfo) async throws -> CKShare? {
        let database = self.database(for: pairing)
        let zoneID = CKRecordZone.ID(zoneName: pairing.zoneName,
                                     ownerName: pairing.zoneOwnerName)
        let zones = try await database.recordZones(for: [zoneID])
        guard case .success(let zone)? = zones[zoneID],
              let shareID = zone.share?.recordID else { return nil }
        let records = try await database.records(for: [shareID])
        guard case .success(let record)? = records[shareID] else { return nil }
        return record as? CKShare
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ pairing: PairingInfo?) -> String {
        guard let pairing else { return "not paired" }
        return "\(pairing.role) of \(pairing.zoneName) (owner \(pairing.zoneOwnerName))"
    }

    /// One line per person. Role matters most: a partner still `public` is one
    /// `publicPermission = .none` save away from being removed from the share —
    /// exactly the failure this screen exists to make visible.
    private static func describe(_ participant: CKShare.Participant,
                                 currentUser: CKShare.Participant?) -> String {
        let name = participant.userIdentity.nameComponents.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
        }
        let email = participant.userIdentity.lookupInfo?.emailAddress
        let who = [name, email].compactMap { $0 }.first { !$0.isEmpty } ?? "Unnamed"
        let you = participant == currentUser ? " (you)" : ""
        return "\(who)\(you) — \(describe(participant.role)), "
            + "\(describe(participant.permission)), "
            + describe(participant.acceptanceStatus)
    }

    private static func describe(_ role: CKShare.ParticipantRole) -> String {
        switch role {
        case .owner: return "owner"
        case .privateUser: return "private"
        case .publicUser: return "public"
        case .administrator: return "administrator"
        case .unknown: return "unknown role"
        @unknown default: return "unknown role"
        }
    }

    private static func describe(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .none: return "no access"
        case .readOnly: return "read-only"
        case .readWrite: return "read-write"
        case .unknown: return "unknown permission"
        @unknown default: return "unknown permission"
        }
    }

    private static func describe(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .pending: return "pending"
        case .removed: return "removed"
        case .unknown: return "unknown status"
        @unknown default: return "unknown status"
        }
    }

    /// Phrased as what the link state means, not the enum's name.
    private static func describeLink(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .none: return "closed — nobody can join from the link"
        case .readOnly, .readWrite: return "open — anyone with the link can join"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

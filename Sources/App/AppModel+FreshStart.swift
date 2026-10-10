import Foundation
import os

// The fresh start: both agree, then each phone clears its own history.
extension AppModel {
    // MARK: - Fresh start (clear the history, both agreeing)

    /// Where the fresh start stands on this phone — see `FreshStartPolicy.Phase`.
    var freshStartPhase: FreshStartPolicy.Phase {
        guard let role else { return .idle(lastCleared: nil) }
        return FreshStartPolicy.phase(snapshot.freshStart, role: role)
    }

    /// A change of ours is still waiting to reach iCloud.
    var freshStartSending: Bool { snapshot.freshStart.pendingIntent != nil }
    var isClearingHistory: Bool { outbox.isClearingHistory }
    var freshStartFailure: String? { outbox.freshStartFailure }

    /// The partner's standing ask, unless its Home card was waved away.
    var showsFreshStartRequest: Bool {
        guard isPaired, case .theyAsked(let asked) = freshStartPhase else { return false }
        return snapshot.freshStart.dismissedAsk != asked
    }

    /// The clear is due here but keeps failing — worth a card of its own.
    var freshStartNeedsAttention: Bool {
        guard isPaired, case .clearing = freshStartPhase else { return false }
        return freshStartFailure != nil && !isClearingHistory
    }

    /// Asks for a fresh start. Looks for a standing ask from them first — then
    /// this is theirs to agree to instead. Returns what to tell the user, if anything.
    func askForFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        await refresh()
        switch freshStartPhase {
        case .idle, .waitingForPartner:
            break
        case .theyAsked:
            return String(localized: "\(partnerName) has just asked for a fresh start too — you can agree to theirs instead.")
        default:
            return nil
        }
        do {
            let asked = try await outbox.askForFreshStart()
            reload()
            if !asked {
                return String(localized: "Your last fresh start change is still being sent. Try again in a moment.")
            }
            Task { await advanceFreshStart() }
            return nil
        } catch is CancellationError {
            // Abandoned at the deadline, it may still land: the next refresh reads it back.
            reload()
            return String(localized: "iCloud didn't answer in time. If the request got through, it shows here shortly.")
        } catch {
            reload()
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return String(localized: "Couldn't reach iCloud, so nothing was asked. (\(reason))")
        }
    }

    /// Agrees to the partner's standing ask — final. Re-checked against a fresh
    /// refresh first: agreeing to an ask they've since withdrawn would do nothing.
    func agreeToFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        await refresh()
        guard case .theyAsked(let asked) = freshStartPhase else {
            return String(localized: "\(partnerName) has withdrawn the request, so nothing changes.")
        }
        let result = await outbox.publishFreshStart(.agree(asked))
        reload()
        Task { await advanceFreshStart() }
        if result == nil {
            return String(localized: "Your answer is saved on this iPhone and will be sent once iCloud can be reached.")
        }
        return nil
    }

    /// Takes our ask back, until the partner's phone has committed to it.
    func withdrawFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart, case .asked = freshStartPhase else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        let result = await outbox.publishFreshStart(.withdraw)
        reload()
        switch result {
        case .refused?:
            Task { await advanceFreshStart() }
            return String(localized: "\(partnerName) had already agreed, so the fresh start is going ahead.")
        case nil where freshStartSending:
            return String(localized: "Withdrawn on this iPhone; iCloud will be told once it can be reached.")
        default:
            return nil
        }
    }

    /// The sheet's "Try again", and the start of a clear just agreed.
    func advanceFreshStart() async {
        await outbox.advanceFreshStart()
        reload()
    }

    func dismissFreshStartRequest() {
        guard case .theyAsked(let asked) = freshStartPhase else { return }
        store.mutate(reloadWidgets: false) { $0.freshStart.dismissedAsk = asked }
        reload()
    }
}

import Foundation
import Observation

/// One run of a pass at a time, its rule named at every call rather than read
/// off a flag: a caller arriving mid-run is dropped (`.skipIfBusy`), waits for
/// the run in progress (`.join`), or waits for it and has its own pass run once
/// more after (`.joinAndRerun`) — what it asked for may have landed after the
/// run in progress began. Returning means done, so "fresh as of now" is honest.
@MainActor
@Observable
final class RunGate {
    enum Arrival { case skipIfBusy, join, joinAndRerun }

    private(set) var isRunning = false
    /// A `.joinAndRerun` caller's pass is waiting for the run in progress.
    var isRerunQueued: Bool { queued != nil }
    @ObservationIgnored private var current: Task<Bool, Never>?
    @ObservationIgnored private var queued: (@MainActor () async -> Bool)?

    /// - Returns: whether any pass of the run returned `true`; `nil` when skipped.
    @discardableResult
    func run(_ arrival: Arrival, _ pass: @escaping @MainActor () async -> Bool) async -> Bool? {
        if let current {
            switch arrival {
            case .skipIfBusy: return nil
            case .join: return await current.value
            case .joinAndRerun:
                queued = pass
                return await current.value
            }
        }
        isRunning = true
        let task = Task { @MainActor [weak self] in
            var succeeded = await pass()
            while let next = self?.queued {
                self?.queued = nil
                if await next() { succeeded = true }
            }
            // Cleared here, with no suspension after the last check: a caller
            // arriving now starts a new run rather than joining a finished one.
            self?.current = nil
            self?.isRunning = false
            return succeeded
        }
        current = task
        return await task.value
    }
}

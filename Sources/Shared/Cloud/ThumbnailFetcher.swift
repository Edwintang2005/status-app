import Foundation

/// The library grid's missing thumbnails, as a queue: tiles ask by id, and the
/// fetcher takes up to `batchLimit` per CloudKit request with at most
/// `maxInFlight` requests out — a flick through a reinstalled history was one
/// request per tile. Pure, so the bounds are tested.
struct ThumbnailBatchQueue {
    static let batchLimit = 50
    static let maxInFlight = 2

    /// Oldest request first.
    private(set) var waiting: [String] = []
    private(set) var inFlight: Set<String> = []
    private(set) var batchesInFlight = 0

    /// `false` when it is already queued or on its way.
    @discardableResult
    mutating func request(_ id: String) -> Bool {
        guard !inFlight.contains(id), !waiting.contains(id) else { return false }
        waiting.append(id)
        return true
    }

    /// The tile scrolled away before its batch left. One already out finishes regardless.
    mutating func withdraw(_ id: String) {
        waiting.removeAll { $0 == id }
    }

    /// Newest requests first: mid-flick, the tiles on screen now asked last.
    mutating func nextBatch() -> [String]? {
        guard !waiting.isEmpty, batchesInFlight < Self.maxInFlight else { return nil }
        let batch = Array(waiting.suffix(Self.batchLimit).reversed())
        waiting.removeLast(batch.count)
        inFlight.formUnion(batch)
        batchesInFlight += 1
        return batch
    }

    mutating func finish(_ batch: [String]) {
        inFlight.subtract(batch)
        batchesInFlight = max(0, batchesInFlight - 1)
    }
}

/// Coalesces tiles' thumbnail requests over `coalesceDelay` into batches
/// (`ThumbnailBatchQueue`). `fetch` downloads one batch and returns the ids now
/// on disk; a cancelled caller is withdrawn and answered `false` straight away.
@MainActor
final class ThumbnailFetcher {
    typealias Fetch = @MainActor ([Moment]) async -> Set<String>

    private let fetch: Fetch
    private let coalesceDelay: Duration
    private var queue = ThumbnailBatchQueue()
    private var moments: [String: Moment] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    private var pumpScheduled = false

    init(coalesceDelay: Duration = .milliseconds(100), fetch: @escaping Fetch) {
        self.coalesceDelay = coalesceDelay
        self.fetch = fetch
    }

    /// `true` once its batch brought the thumbnail.
    func thumbnail(for moment: Moment) async -> Bool {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(moment, token: token, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(moment.id, token: token) }
        }
    }

    private func enqueue(_ moment: Moment, token: UUID, continuation: CheckedContinuation<Bool, Never>) {
        guard !Task.isCancelled else {
            continuation.resume(returning: false)
            return
        }
        waiters[moment.id, default: [:]][token] = continuation
        moments[moment.id] = moment
        queue.request(moment.id)
        guard !pumpScheduled else { return }
        pumpScheduled = true
        Task {
            try? await Task.sleep(for: coalesceDelay)
            pumpScheduled = false
            launchBatches()
        }
    }

    private func withdraw(_ id: String, token: UUID) {
        waiters[id]?.removeValue(forKey: token)?.resume(returning: false)
        guard waiters[id]?.isEmpty == true else { return }
        waiters[id] = nil
        guard !queue.inFlight.contains(id) else { return }
        queue.withdraw(id)
        moments[id] = nil
    }

    private func launchBatches() {
        while let batch = queue.nextBatch() {
            let items = batch.compactMap { moments[$0] }
            Task {
                let fetched = await fetch(items)
                finish(batch, fetched: fetched)
            }
        }
    }

    private func finish(_ batch: [String], fetched: Set<String>) {
        queue.finish(batch)
        for id in batch {
            moments[id] = nil
            for continuation in (waiters.removeValue(forKey: id) ?? [:]).values {
                continuation.resume(returning: fetched.contains(id))
            }
        }
        // What queued while these were out goes now: it has already waited.
        launchBatches()
    }
}

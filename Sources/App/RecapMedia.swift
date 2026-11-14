import UIKit

/// The recap's full pictures: this phone's copy at once, iCloud only for the
/// rest — fetched ahead in slide order, a few pictures to a request and a few
/// requests at a time, while earlier slides draw.
final class RecapMedia: Sendable {
    /// Small, so the next slide's picture never waits behind many others.
    static let batchSize = 4
    private let fetches: [String: Task<Void, Never>]

    init(_ moments: [Moment], store: MomentStore = .shared) {
        let backend = Backend.current
        let lanes = AppConfig.archiveFetchConcurrency
        var fetches: [String: Task<Void, Never>] = [:]
        var tails = [Task<Void, Never>?](repeating: nil, count: lanes)
        // Each lane fetches its batches in turn, so the next slides are never queued behind later ones.
        // The first alone, so the opening slide waits on no one else's picture.
        let missing = moments.filter { !store.hasMedia(for: $0) }
        let batches = missing.prefix(1).map { [$0] } + Array(missing.dropFirst()).chunked(into: Self.batchSize)
        for (offset, batch) in batches.enumerated() {
            let previous = tails[offset % lanes]
            let fetch = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                let deadline = AppConfig.archiveItemDeadline + 8 * Double(batch.count)
                try? await withDeadline(deadline) { try await backend.fetchMedia(for: batch) }
            }
            tails[offset % lanes] = fetch
            batch.forEach { fetches[$0.id] = fetch }
        }
        self.fetches = fetches
    }

    var fetching: Int { fetches.count }

    /// Waits for its download if it needed one; one that never came falls back
    /// to the square thumbnail rather than leaving the moment out — `full` false,
    /// so the recap is shown but not kept as the year's.
    func picture(for moment: Moment, store: MomentStore = .shared) async -> (image: UIImage?, full: Bool) {
        // Closing the screen mid-wait drops the queued downloads (one under way runs out its deadline).
        await withTaskCancellationHandler {
            await fetches[moment.id]?.value
        } onCancel: {
            cancel()
        }
        if let image = store.image(for: moment.id) { return (image, true) }
        return (store.thumbnail(for: moment.id), false)
    }

    func cancel() {
        fetches.values.forEach { $0.cancel() }
    }
}

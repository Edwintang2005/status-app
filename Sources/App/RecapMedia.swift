import UIKit

/// The recap's full pictures: this phone's copy at once, iCloud only for the
/// rest — fetched ahead in slide order, a few at a time, while earlier slides draw.
final class RecapMedia: Sendable {
    private let fetches: [String: Task<Void, Never>]

    init(_ moments: [Moment], store: MomentStore = .shared) {
        let backend = Backend.current
        let lanes = AppConfig.archiveFetchConcurrency
        var fetches: [String: Task<Void, Never>] = [:]
        var tails = [Task<Void, Never>?](repeating: nil, count: lanes)
        // Each lane fetches in turn, so the next slide's picture is never queued behind later ones.
        for (offset, moment) in moments.filter({ !store.hasMedia(for: $0) }).enumerated() {
            let previous = tails[offset % lanes]
            let fetch = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                try? await withDeadline(AppConfig.archiveItemDeadline) { try await backend.fetchMedia(for: moment) }
            }
            tails[offset % lanes] = fetch
            fetches[moment.id] = fetch
        }
        self.fetches = fetches
    }

    var fetching: Int { fetches.count }

    /// Waits for its download if it needed one; one that never came falls back
    /// to the square thumbnail rather than leaving the moment out.
    func picture(for moment: Moment, store: MomentStore = .shared) async -> UIImage? {
        // Closing the screen mid-wait drops the queued downloads (one under way runs out its deadline).
        await withTaskCancellationHandler {
            await fetches[moment.id]?.value
        } onCancel: {
            cancel()
        }
        return store.image(for: moment.id) ?? store.thumbnail(for: moment.id)
    }

    func cancel() {
        fetches.values.forEach { $0.cancel() }
    }
}

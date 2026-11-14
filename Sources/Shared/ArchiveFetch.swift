import Foundation

/// How one moment's file fared for the memories archive (`SyncBackend.fetchArchiveMedia`).
enum ArchiveMedia: Sendable, Equatable {
    case saved
    /// The record came back without its file: no retry brings it back, and a
    /// delete can't take what isn't there.
    case gone
    /// iCloud answered "no such record". Gone, if the zone's own listing agrees;
    /// a record the listing just returned is a fetch that failed (`MemoryArchive`).
    case notFound
    /// Not fetched this time (offline, throttled until `retryAt`, timed out): worth another try.
    case failed(retryAt: Date?)
}

/// What the archive's outcome allows before an unlink or a fresh start deletes
/// anything — pure, so Settings and the fresh start judge it alike.
enum ArchiveGate: Equatable, Sendable {
    case proceed
    /// Everything that exists is saved; these moments have no file anywhere to save.
    /// Asked about, never taken silently: the user may want to look first.
    case confirmGone(Int)
    /// A newer build's moments: only an update saves them.
    case updateFirst
    /// The zone couldn't be read whole, or files failed to arrive: a better connection may help.
    case retry

    init(contentsComplete: Bool, unrecovered: Int, unsupported: Int, gone: Int) {
        if !contentsComplete || unrecovered > 0 {
            self = .retry
        } else if unsupported > 0 {
            self = .updateFirst
        } else if gone > 0 {
            self = .confirmGone(gone)
        } else {
            self = .proceed
        }
    }
}

/// The archive's downloads: chunks of `chunkSize` in one request each, written
/// straight into the archive's folder (never through the media cache, whose prune
/// could take an early download before the end), `lanes` chunks at a time, each
/// bounded by its own deadline so one slow chunk can't hold the rest. What failed
/// is tried once more after a pause — iCloud's retry-after when it's throttling,
/// up to a minute — in smaller chunks, as a bulk fetch is what trips a throttle.
struct ArchiveFetcher: Sendable {
    /// Small enough that a chunk arrives within its deadline on a slow link —
    /// `records(for:)` hands back nothing until the whole chunk is in.
    static let chunkSize = 10
    static let retryChunkSize = 5

    /// One chunk's request (`SyncBackend.fetchArchiveMedia`).
    var fetch: @Sendable ([Moment]) async throws -> [String: ArchiveMedia]
    var lanes = 2
    var deadline: @Sendable (_ count: Int) -> TimeInterval = { AppConfig.archiveItemDeadline + 20 * Double($0) }
    var pause: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// A download abandoned at its deadline can still land: its file is then there.
    var landed: @Sendable (Moment) -> Bool = { _ in false }

    /// Every moment's result. Stops starting chunks once cancelled.
    /// - Parameter progress: moments finished so far, after each chunk.
    func run(_ moments: [Moment], progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> [String: ArchiveMedia] {
        guard !moments.isEmpty else { return [:] }
        var results = await pass(moments, chunkSize: Self.chunkSize, progress: progress)
        let failed = moments.filter { if case .failed = results[$0.id] { true } else { false } }
        guard !failed.isEmpty, !Task.isCancelled else { return settle(results, moments) }
        let retryAt = failed.compactMap { if case .failed(let at) = results[$0.id] { at } else { nil } }.max()
        await pause(retryAt.map { min(max($0.timeIntervalSinceNow, 1), 60) } ?? 2)
        guard !Task.isCancelled else { return settle(results, moments) }
        results.merge(await pass(failed, chunkSize: Self.retryChunkSize, progress: { _ in }), uniquingKeysWith: { $1 })
        return settle(results, moments)
    }

    private func settle(_ results: [String: ArchiveMedia], _ moments: [Moment]) -> [String: ArchiveMedia] {
        var settled = results
        for moment in moments {
            switch settled[moment.id] {
            case .saved?, .gone?, .notFound?: continue
            case .failed?, nil: settled[moment.id] = landed(moment) ? .saved : (settled[moment.id] ?? .failed(retryAt: nil))
            }
        }
        return settled
    }

    private func pass(_ moments: [Moment], chunkSize: Int,
                      progress: @escaping @Sendable (Int) -> Void) async -> [String: ArchiveMedia] {
        let chunks = moments.chunked(into: chunkSize)
        var results: [String: ArchiveMedia] = [:]
        var done = 0
        await withTaskGroup(of: [String: ArchiveMedia].self) { group in
            var queue = chunks[...]
            func start(_ chunk: [Moment]) {
                group.addTask { [fetch, deadline] in
                    do {
                        let fetched = try await withDeadline(deadline(chunk.count)) { try await fetch(chunk) }
                        // A record the answer left out wasn't fetched: tried again.
                        var all = fetched
                        for moment in chunk where all[moment.id] == nil { all[moment.id] = .failed(retryAt: nil) }
                        return all
                    } catch {
                        let retryAt: Date? = if case .throttled(let until) = SendFailure(error) { until } else { nil }
                        return Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, .failed(retryAt: retryAt)) })
                    }
                }
            }
            for _ in 0..<max(1, lanes) {
                guard let next = queue.popFirst() else { break }
                start(next)
            }
            for await chunk in group {
                results.merge(chunk, uniquingKeysWith: { $1 })
                done += chunk.count
                progress(done)
                if Task.isCancelled {
                    queue.removeAll()
                } else if let next = queue.popFirst() {
                    start(next)
                }
            }
        }
        return results
    }
}

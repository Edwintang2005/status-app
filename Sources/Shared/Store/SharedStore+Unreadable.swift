import Foundation
import os

/// Records a fetch couldn't read: counted per process, owed and retried by ID,
/// or held with a resync batch (invariant 2).
extension SharedStore {
    /// Per-process count of records whose encrypted fields came back empty —
    /// the evidence for whether background processes lose decryption — and the
    /// records still owed: missed by a fetch (unreadable, or reported but not
    /// handed over) while the change token moved on past them, fetched again by
    /// ID until read (`CloudSync.retryOwedRecords`).
    struct UnreadableTally: Codable, Equatable {
        var counts: [String: Int] = [:]
        var lastAt: Date?
        var owed: [OwedRecord] = []
        /// Owed records that aged out unread (`owedRecordLifetime`): gone until a full resync.
        var abandoned = 0
        /// The last fetch of owed records by ID, by any process (`owedRetrySpacing`).
        var lastRetryAt: Date?
        /// That fetch read nothing: an extension waits longer before trying blind again.
        var lastRetryReadNothing = false
        /// A resync batch a process without the keys held (its token kept, nothing
        /// owed): never retried — the batch comes round again — but still held,
        /// for the banners and the widget's schedule. Replaced by each held pass,
        /// cleared by any that keeps a token.
        /// The partner's moments, their status and the fresh-start records only —
        /// what the held banners and the clear read — the newest `owedRecordLimit`;
        /// `heldCount` is the whole batch's misses, for Diagnostics.
        var held: [String] = []
        var heldCount = 0
        var heldAt: Date?
        /// Spaced looks at a held batch by the app with its keys (`ResyncHold`).
        var heldPasses = 0
        var heldPassAt: Date?

        struct OwedRecord: Codable, Equatable {
            var name: String
            var firstMissedAt: Date
            /// Missed by a full resync: judged as one when it's finally read, against
            /// the mark in force when it was missed (`Snapshot.newsAfter` may have
            /// moved since) — re-fetched history isn't news, a new moment still is.
            var resync = false
            var newsAfter: Date?

            init(name: String, firstMissedAt: Date, resync: Bool = false, newsAfter: Date? = nil) {
                self.name = name
                self.firstMissedAt = firstMissedAt
                self.resync = resync
                self.newsAfter = newsAfter
            }

            private enum CodingKeys: String, CodingKey { case name, firstMissedAt, resync, newsAfter }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                firstMissedAt = try container.decode(Date.self, forKey: .firstMissedAt)
                resync = try container.decodeIfPresent(Bool.self, forKey: .resync) ?? false
                newsAfter = try container.decodeIfPresent(Date.self, forKey: .newsAfter)
            }
        }

        /// What every reader of the old hold asks: which records are still owed or held…
        var heldNames: [String] { owed.map(\.name) + held }
        /// …and since the latest miss — the stale stretch the widget's schedule
        /// and the app's foreground fetch care about; one record stuck for weeks
        /// mustn't stand in for a fresh one.
        var heldSince: Date? { (owed.map(\.firstMissedAt) + [heldAt].compactMap { $0 }).max() }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case counts, lastAt, owed, abandoned, lastRetryAt, lastRetryReadNothing, held, heldCount, heldAt
            case heldPasses, heldPassAt
        }

        /// Hand-written: fields added after the first release fall back (invariant 5).
        /// The pre-list hold's fields are dropped: its records are re-fetched with the delta it pinned.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
            lastAt = try container.decodeIfPresent(Date.self, forKey: .lastAt)
            owed = (try? container.decodeIfPresent(LossyArray<OwedRecord>.self, forKey: .owed))?.elements ?? []
            abandoned = try container.decodeIfPresent(Int.self, forKey: .abandoned) ?? 0
            lastRetryAt = try? container.decodeIfPresent(Date.self, forKey: .lastRetryAt)
            lastRetryReadNothing = (try? container.decodeIfPresent(Bool.self, forKey: .lastRetryReadNothing)) ?? false
            // The old hold's `heldNames` is dropped: its records come back with the delta it pinned.
            held = (try? container.decodeIfPresent([String].self, forKey: .held)) ?? []
            heldAt = try? container.decodeIfPresent(Date.self, forKey: .heldAt)
            heldCount = (try? container.decodeIfPresent(Int.self, forKey: .heldCount)) ?? held.count
            heldPasses = (try? container.decodeIfPresent(Int.self, forKey: .heldPasses)) ?? 0
            heldPassAt = try? container.decodeIfPresent(Date.self, forKey: .heldPassAt)
        }

        var summary: String {
            guard !counts.isEmpty || !owed.isEmpty else { return "none" }
            var parts = counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }
            if let oldest = owed.map(\.firstMissedAt).min() {
                parts.append("\(owed.count) still owed, the oldest since \(oldest.formatted(date: .abbreviated, time: .shortened))")
            }
            if heldCount > 0 { parts.append("a resync batch of \(heldCount) held") }
            if abandoned > 0 { parts.append("gave up on \(abandoned) after \(Int(AppConfig.owedRecordLifetime / 86_400)) days") }
            let last = lastAt.map { " (last \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
            return parts.joined(separator: ", ") + last
        }

        /// Files missed records (new ones only), settles ones read or deleted,
        /// ages out the long-unreadable and keeps the list bounded — pure, for tests.
        mutating func update(missed: [String], resync: Bool = false, newsAfter: Date? = nil,
                             settled: Set<String>, now: Date) {
            owed.removeAll { settled.contains($0.name) }
            for name in missed where !settled.contains(name) && !owed.contains(where: { $0.name == name }) {
                owed.append(OwedRecord(name: name, firstMissedAt: now, resync: resync, newsAfter: resync ? newsAfter : nil))
            }
            let expired = owed.filter { now.timeIntervalSince($0.firstMissedAt) > AppConfig.owedRecordLifetime }
            abandoned += expired.count
            owed.removeAll { now.timeIntervalSince($0.firstMissedAt) > AppConfig.owedRecordLifetime }
            if owed.count > AppConfig.owedRecordLimit {
                abandoned += owed.count - AppConfig.owedRecordLimit
                owed.removeFirst(owed.count - AppConfig.owedRecordLimit)
            }
        }
    }

    private static let tallyLock = CrossProcessLock(name: "unreadable.lock")

    var unreadableTally: UnreadableTally {
        self[Key.unreadable] ?? UnreadableTally()
    }

    /// A fetch's outcome for the owed list, in one locked write: what it missed
    /// (counted against `process`, for Diagnostics; `resync` when the fetch was
    /// one) and what it read or saw deleted.
    /// `holding`: a resync batch held rather than owed — `names` as `held` keeps
    /// them, `count` its whole size, `look` whether it was the app with its keys
    /// (a spaced one counts toward giving up); `tokenKept`: this pass kept a
    /// token, so no batch is held any more.
    func noteFetched(missed: [String], resync: Bool = false, newsAfter: Date? = nil, settled: Set<String>,
                     holding: (names: [String], count: Int, look: Bool)? = nil, tokenKept: Bool = false,
                     now: Date = Date(), process: String = SharedStore.processLabel) {
        guard !missed.isEmpty || !settled.isEmpty || holding != nil || tokenKept else { return }
        Self.tallyLock.withLock {
            var tally = unreadableTally
            let before = tally
            let seen = missed.count + (holding?.count ?? 0)
            if seen > 0 {
                tally.counts[process, default: 0] += seen
                tally.lastAt = now
            }
            tally.update(missed: missed, resync: resync, newsAfter: newsAfter, settled: settled, now: now)
            if let holding {
                if tally.held.isEmpty { tally.heldAt = now }
                tally.held = Array(holding.names.suffix(AppConfig.owedRecordLimit))
                tally.heldCount = holding.count
                if holding.look,
                   now.timeIntervalSince(tally.heldPassAt ?? .distantPast) >= AppConfig.owedRetrySpacing {
                    tally.heldPasses += 1
                    tally.heldPassAt = now
                }
            } else if tokenKept {
                tally.held = []
                tally.heldCount = 0
                tally.heldAt = nil
                tally.heldPasses = 0
                tally.heldPassAt = nil
            }
            guard tally != before else { return }
            self[Key.unreadable] = tally
        }
    }

    /// Claims a fetch of owed records by ID for this process — `nil` when there's
    /// nothing owed or any process did one within `owedRetrySpacing` — handing back
    /// what to fetch, newest first, at most `limit` (an extension's budget).
    /// An extension after a retry that read nothing waits `owedRetryBlindSpacing`:
    /// it can't know the keys are there, and the widget runs every few minutes while held.
    func claimOwedRetry(now: Date = Date(), limit: Int = AppConfig.owedRecordLimit,
                        isExtension: Bool = false) -> [UnreadableTally.OwedRecord]? {
        Self.tallyLock.withLock {
            var tally = unreadableTally
            let spacing = isExtension && tally.lastRetryReadNothing ? AppConfig.owedRetryBlindSpacing
                                                                    : AppConfig.owedRetrySpacing
            guard !tally.owed.isEmpty,
                  now.timeIntervalSince(tally.lastRetryAt ?? .distantPast) >= spacing
                    || (tally.lastRetryAt ?? .distantPast) > now else { return nil }
            tally.lastRetryAt = now
            self[Key.unreadable] = tally
            return Array(tally.owed.suffix(limit).reversed())
        }
    }

    /// A claimed retry that fetched nothing (failed, timed out, cancelled): the
    /// next pass may try at once. Otherwise, whether it read anything.
    func noteOwedRetry(fetched: Bool, readAny: Bool = false) {
        Self.tallyLock.withLock {
            var tally = unreadableTally
            if fetched { tally.lastRetryReadNothing = !readAny } else { tally.lastRetryAt = nil }
            self[Key.unreadable] = tally
        }
    }

    /// Kept current by the app from the protected-data notifications; a locked
    /// phone's background refresh must not count toward giving up. Extensions
    /// never give up regardless. Written on main, read from the sync actor.
    static var protectedDataAvailable: Bool {
        get { protectedData.withLock { $0 } }
        set { protectedData.withLock { $0 = newValue } }
    }
    private static let protectedData = OSAllocatedUnfairLock(initialState: true)

    /// Which of the five processes this is, for the tally above.
    static let processLabel: String = {
        guard let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return "app"
        }
        switch point {
        case "com.apple.widgetkit-extension": return "widget"
        case "com.apple.usernotifications.content-extension": return "expanded banner"
        case "com.apple.share-services": return "share sheet"
        default: return "notification service"
        }
    }()
}

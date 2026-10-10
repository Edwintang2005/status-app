import Foundation

/// One side's `FreshStart` record (`freshstart-<role>`), parsed: where that side
/// stands on clearing the shared history. Every field is encrypted on the record.
struct FreshStartRecord: Codable, Hashable, Sendable {
    enum Stage: Int, Sendable {
        /// Nothing standing; `clearedBefore` still says what was cleared last.
        case idle = 0
        /// Asking. The epoch is the record's own server save time — neither
        /// phone's clock — so "before the request" means the same everywhere.
        case asking = 1
        /// Agreed to the other side's ask named by `epoch`. Final: no taking it back.
        case agreeing = 2
        /// The asker saw the agreement and committed; from here both phones clear.
        case committed = 3
    }

    var stage: Stage
    /// asking: the ask's server save time; agreeing/committed: the ask named.
    var epoch: Date?
    /// The newest epoch this side has finished clearing.
    var clearedBefore: Date?

    init(stage: Stage, epoch: Date? = nil, clearedBefore: Date? = nil) {
        self.stage = stage
        self.epoch = epoch
        self.clearedBefore = clearedBefore
    }

    private enum CodingKeys: String, CodingKey { case stage, epoch, clearedBefore }

    /// Hand-written (invariant 5); a stage a newer build added reads as idle.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(Int.self, forKey: .stage) ?? 0
        stage = Stage(rawValue: raw) ?? .idle
        epoch = try container.decodeIfPresent(Date.self, forKey: .epoch)
        clearedBefore = try container.decodeIfPresent(Date.self, forKey: .clearedBefore)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage.rawValue, forKey: .stage)
        try container.encodeIfPresent(epoch, forKey: .epoch)
        try container.encodeIfPresent(clearedBefore, forKey: .clearedBefore)
    }
}

/// A change this device wants made to its own `FreshStart` record.
enum FreshStartIntent: Hashable, Sendable {
    /// Start asking. Never queued offline: the epoch is when it reaches iCloud.
    case ask
    /// The user agreed to the partner's ask.
    case agree(Date)
    /// Both asked: our later ask becomes agreement to their earlier one.
    case convert(Date)
    /// Asker only, automatic once the partner's agreement is seen.
    case commit(Date)
    case withdraw
    /// This device finished clearing before the epoch.
    case complete(Date)

    var epoch: Date? {
        switch self {
        case .ask, .withdraw: return nil
        case .agree(let date), .convert(let date), .commit(let date), .complete(let date): return date
        }
    }
}

extension FreshStartIntent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, epoch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let epoch = try container.decodeIfPresent(Date.self, forKey: .epoch)
        switch (kind, epoch) {
        case ("ask", _): self = .ask
        case ("withdraw", _): self = .withdraw
        case ("agree", let date?): self = .agree(date)
        case ("convert", let date?): self = .convert(date)
        case ("commit", let date?): self = .commit(date)
        case ("complete", let date?): self = .complete(date)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown intent")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: String = switch self {
        case .ask: "ask"
        case .agree: "agree"
        case .convert: "convert"
        case .commit: "commit"
        case .withdraw: "withdraw"
        case .complete: "complete"
        }
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(epoch, forKey: .epoch)
    }
}

/// What a publish of our record came back with: the record now on the server,
/// or — the state had moved on (a withdraw beat the commit, say) — its copy as is.
enum FreshStartPublishResult: Hashable, Sendable {
    case saved(FreshStartRecord?)
    case refused(FreshStartRecord?)
}

/// The fresh start as this device knows it, inside `Snapshot`.
struct FreshStart: Codable, Hashable, Sendable {
    /// Our record as last written here or read back from this account's devices.
    /// A copy someone else wrote is never adopted (`ParsedDelta`'s authorship check).
    var mine: FreshStartRecord?
    /// What `mine` is waiting to say on the server — the twin of `myStatusPublished`.
    var pendingIntent: FreshStartIntent?
    var theirs: FreshStartRecord?
    /// The newest epoch both sides committed to: what ingestion and the requeue
    /// guard keep out. Only moves forward.
    var clearedBefore: Date?
    /// The newest epoch this device has finished clearing, its zone half and its own copy.
    var finishedBefore: Date?
    /// The partner's ask the Home card was waved away for; the ask itself stands.
    var dismissedAsk: Date?

    init() {}

    /// One delta's worth of `FreshStart` records.
    struct Incoming: Equatable, Sendable {
        var mine: FreshStartRecord?
        var mineErased = false
        var theirs: FreshStartRecord?
        var theirsErased = false

        var isEmpty: Bool { mine == nil && !mineErased && theirs == nil && !theirsErased }
    }

    /// Our own unsent intent outranks the server copy, like the anniversary's.
    mutating func fold(_ incoming: Incoming) {
        if pendingIntent == nil {
            if let mine = incoming.mine {
                self.mine = mine
            } else if incoming.mineErased {
                self.mine = nil
            }
        }
        if let theirs = incoming.theirs {
            self.theirs = theirs
        } else if incoming.theirsErased {
            self.theirs = nil
        }
        noteCommitted()
    }

    /// Sets the local copy to what `intent` will make of it, pending publish.
    /// `false` when the intent can't apply to what's held.
    @discardableResult
    mutating func begin(_ intent: FreshStartIntent) -> Bool {
        switch FreshStartPolicy.transition(intent, from: mine) {
        case .write(let target):
            mine = target
        case .unchanged:
            break
        case .refused:
            return false
        }
        pendingIntent = intent
        return true
    }

    /// The publish of `intent` came back. A newer intent queued meanwhile wins.
    mutating func published(_ intent: FreshStartIntent, _ result: FreshStartPublishResult) {
        guard pendingIntent == intent else { return }
        pendingIntent = nil
        switch result {
        case .saved(let record), .refused(let record):
            mine = record
        }
        noteCommitted()
    }

    /// An ask came back saved (asks are sent directly, never queued).
    mutating func asked(_ result: FreshStartPublishResult) {
        guard pendingIntent == nil else { return }
        switch result {
        case .saved(let record), .refused(let record):
            mine = record
        }
        noteCommitted()
    }

    /// This device cleared everything before `epoch`; its record says so next.
    mutating func finished(_ epoch: Date) {
        finishedBefore = max(finishedBefore ?? .distantPast, epoch)
        clearedBefore = max(clearedBefore ?? .distantPast, epoch)
        begin(.complete(epoch))
    }

    /// Only from published copies: a local commit the server could still refuse
    /// must not move a mark that never comes back down.
    private mutating func noteCommitted() {
        guard pendingIntent == nil,
              let epoch = FreshStartPolicy.committedEpoch(mine: mine, theirs: theirs) else { return }
        clearedBefore = max(clearedBefore ?? .distantPast, epoch)
    }

    /// For Diagnostics: dates only, never content.
    var summary: String {
        func describe(_ record: FreshStartRecord?) -> String {
            guard let record else { return "none" }
            let epoch = record.epoch.map { " \($0.formatted(.iso8601))" } ?? ""
            let cleared = record.clearedBefore.map { ", cleared before \($0.formatted(.iso8601))" } ?? ""
            return "\(record.stage)\(epoch)\(cleared)"
        }
        var parts = ["mine \(describe(mine))", "theirs \(describe(theirs))"]
        if let pendingIntent { parts.append("sending \(pendingIntent)") }
        if let finishedBefore { parts.append("finished here before \(finishedBefore.formatted(.iso8601))") }
        return parts.joined(separator: "; ")
    }

    private enum CodingKeys: String, CodingKey {
        case mine, pendingIntent, theirs, clearedBefore, finishedBefore, dismissedAsk
    }

    /// Hand-written (invariant 5). An intent this build can't read is dropped:
    /// the next refresh reads the record back.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mine = try container.decodeIfPresent(FreshStartRecord.self, forKey: .mine)
        pendingIntent = try? container.decodeIfPresent(FreshStartIntent.self, forKey: .pendingIntent)
        theirs = try container.decodeIfPresent(FreshStartRecord.self, forKey: .theirs)
        clearedBefore = try container.decodeIfPresent(Date.self, forKey: .clearedBefore)
        finishedBefore = try container.decodeIfPresent(Date.self, forKey: .finishedBefore)
        dismissedAsk = try container.decodeIfPresent(Date.self, forKey: .dismissedAsk)
    }
}

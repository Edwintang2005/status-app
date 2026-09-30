/// One fetch at a time. A refresh asked for while one runs is noted and run
/// once more afterwards, not dropped — the fetch in flight may have missed it.
struct RefreshGate: Equatable, Sendable {
    private(set) var isRunning = false
    private var requested = false

    /// `false` when a fetch is already running; the request is then noted,
    /// unless `noteIfBusy` is off (a diagnostics resync is no one's request).
    mutating func begin(noteIfBusy: Bool = true) -> Bool {
        guard !isRunning else {
            if noteIfBusy { requested = true }
            return false
        }
        isRunning = true
        requested = false
        return true
    }

    /// After each pass: whether a request arrived during it (and consumes it).
    mutating func takeRequest() -> Bool {
        defer { requested = false }
        return requested
    }

    mutating func end() {
        isRunning = false
        requested = false
    }
}

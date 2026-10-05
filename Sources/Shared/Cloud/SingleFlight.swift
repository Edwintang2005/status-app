/// Concurrent callers share one run instead of each starting their own. Unlike
/// `RefreshGate` nothing is re-run: a caller joining mid-flight takes that
/// run's answer. The widget's kinds all ask for a timeline at once after a
/// reload, and three identical fetches in a 30 MB process helped no one.
actor SingleFlight<Value: Sendable> {
    private var running: Task<Value, Never>?

    func run(_ body: @escaping @Sendable () async -> Value) async -> Value {
        if let running { return await running.value }
        let task = Task { await body() }
        running = task
        let value = await task.value
        running = nil
        return value
    }
}

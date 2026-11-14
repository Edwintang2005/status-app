# Invariant 1: Cross-process locking

Read before touching `SharedStore.mutate`, `CrossProcessLock`, `MomentIndex`, `StatusHistoryLog`, any claim.

**Cross-process locking.** App, widget and NSE run concurrently: every read-modify-write of `Snapshot` goes through `SharedStore.mutate` (flock, `CrossProcessLock`), `MomentIndex`/`StatusHistoryLog` lock likewise, and check-and-claim decisions happen *inside* one `mutate`.

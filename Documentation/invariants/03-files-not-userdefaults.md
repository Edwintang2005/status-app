# Invariant 3: Shared state lives in files, not UserDefaults

Read before touching `GroupFileStore`, `SharedStore` caches, any new shared state.

**Shared state lives in files, not UserDefaults** (unreliable across the App Group — see `GroupState.swift`). Caches key on the file so another process's write is always seen: `GroupFileStore` caches bytes by `FileIdentity` (device, inode, size, mtime), `SharedStore.decode` reuses a value only for identical bytes, `MomentIndex`/`StatusHistoryLog` cache by file identity.

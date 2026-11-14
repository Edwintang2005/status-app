# Invariant 14: Status history dedups by (fromMe, wordsAt)

Read before touching `StatusHistoryLog`, `StatusPayload.wordsAt`/`nextStamp`, `CloudSync+Status`, any persisted date.

**Status history dedups by `(fromMe, wordsAt)`** across the `Status` record as its words change (`AppModel.setStatus`, `CloudSync.apply`; a rename's own echo is skipped) and the `StatusLog` records, *named* by the whole-second `StatusPayload.wordsAt`.
- `wordsAt` is `updatedAt` unless a rename restamped the record. `wordsSince` is local only, carried across renames at ingestion (`payload(from:)`: same words *and* a changed name — re-picking a status is new), when renaming, and for the *same version* (equal `updatedAt`, same words) in `payload(from:)` and `RefreshDelta`'s merge. Reports, celebrations, the status receipt and the card's time key on it, so a rename moves none of them.
- `StatusPayload.serverSavedAt` (local, whole seconds) orders the partner's copies when both carry it — their `updatedAt` is their phone's clock.
- Pruning is cloud-first: the publisher deletes its own past the cap, every device mirrors (`StatusHistoryLog.remove`). Pre-cloud-log entries are local-only.
- **Persisted dates are whole seconds** — App Group JSON is ISO-8601, which drops fractions, so a fractional `Date` never equals its stored copy. Truncate with `Date.wholeSeconds`: `updatedAt` at creation (`AppModel.statusTimestamp` → `StatusPayload.nextStamp`: strictly after the status it replaces, within `statusStampLeeway` — so two in one second don't share a stamp, and another of our devices' copy stamped a little ahead can't win the save over it) and ingestion (`payload(from:)`), and any new date in an equality/watermark check.

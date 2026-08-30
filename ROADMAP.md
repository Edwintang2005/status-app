# Roadmap

Feature candidates, in recommended build order. Effort: S = hours, M = days, L = a week+.
Any CloudKit field/record-type addition requires re-deploying the schema to Production (README → "Shipping it").

## 1. History filter: sent / received (S)

`Moment.fromMe` already exists on every history entry; this is UI only.
- Segmented control in `MomentLibraryView` (All · From them · From me) filtering `model.history` before the grid.
- Carry the filter into `MomentGalleryView` so paging stays within the filtered set.
- No schema change, no sync change.

## 2. Super nudge — escalate when they spam the heart (S–M)

When one side taps the heart repeatedly in a short window, the other side gets one *stronger* notification instead of a stack of identical ones.
- **Detect on the sender**: the sender's device sees its own tap cadence. In `CloudSync.sendNudge`, track recent send times in `Snapshot`; when ≥3 sends land inside ~60s, write a new `burst` Int field on the existing `Nudge` record (counts/timestamps stay plaintext like `count`).
- **Render on the receiver**: `NotificationService.applyNudge` and `NotificationManager.postNudge` read `burst` and swap wording ("is REALLY thinking of you ❤️‍🔥"), keep `.timeSensitive`, optionally a distinct sound. In-app: a bigger haptic + heart-burst animation (reuse `CelebrationOverlay` machinery at lower intensity).
- Watermark logic (`lastSeenPartnerNudgeCount`) is unchanged — a burst is still just a count increase.
- Schema: one new field on `Nudge`; redeploy.

## 3. Status history (M)

The app keeps only the current status per side; keep a rolling log so "you were asleep when I set that" is legible.
- **Phase 1 — local log (no schema change):** append `{emoji, message, at, fromMe}` to a new App Group JSON file (mirror `MomentIndex`: NSLock + `CrossProcessLock`, cap ~200 entries). Write from the one choke point both the app and the NSE already pass through: `CloudSync.apply`, when `theirs.updatedAt` advances past the last logged entry (dedup by `updatedAt`), and from `publish` for own statuses. Gaps are possible (only the latest status per delta is seen) — acceptable for phase 1.
- **UI:** a "Status history" list reached from the partner card / a toolbar button; grouped by day; reuse the sent/received filter from feature 1.
- **Phase 2 (optional, durable):** one CloudKit `StatusLog` record per status (like moments) if recover-on-reinstall matters. Costs a record per status change; cap with periodic deletion. No new subscription needed — entries ride the existing refresh.

## 4. Read statuses (M–L)

Let the sender see that a moment (and possibly the current status) was seen. Product call first: it changes the relationship dynamics — recommend an explicit two-sided opt-in toggle in Settings.
- **Mechanics:** `Moment.seen` is deliberately local-only; don't sync it directly. Add one record per side, `receipts-<role>`, carrying an encrypted JSON map of the last ~50 `{momentID: seenAt}` plus optionally `statusSeenAt`. The receiver updates it from `AppModel.markSeen`; the sender's refresh folds it into the index as a new local field (`seenByPartnerAt`).
- **UI:** "Seen" tag on own moments in the library/gallery; optionally "Seen 2h ago" under your own status card.
- No new subscription (receipts arrive with any refresh; a push for them isn't worth the noise). Schema: one new record type; redeploy.
- Respect the toggle on both sides: only write receipts when enabled locally, only show when the partner's receipt record exists.

## Also on file (from README "Possible improvements")

- Reactions on a moment (needs a `Reaction` record type + subscription).
- Shared countdown lock-screen widget.

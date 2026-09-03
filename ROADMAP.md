# Roadmap

Effort: S = hours, M = days, L = a week+. Any CloudKit field/record-type
addition requires re-deploying the schema to Production (README → "Shipping it").

## Shipped (September 2026)

- **Core hardening** — a unit-test target (`make test`, 56 XCTest cases over
  `Sources/Shared`: Codable fallbacks, watermarks, `MomentIndex` and
  `StatusHistoryLog` merging, `SharedStore`); `CloudSync` split into one
  extension file per concern; banner actions (heart back on every alert, text
  reply on a status alert → sets your status); a Siri App Shortcut over the
  nudge intent; VoiceOver labels on every icon-only control plus adjustable
  waveform scrubbing; `Theme.rounded` follows Dynamic Type; a String Catalog
  per target with all user-facing strings routed through it. Found along the
  way: `MomentIndex.markSeen` stamped fractional seconds — now whole, per the
  persisted-date rule. No schema changes.
- **App Review 1.2 (user-generated content)** — Terms of Use agreed before
  anything else (`TermsView`, versioned via `AppConfig.termsVersion`); report
  on any partner moment (gallery menu, library long-press) or status (long-press
  the card), removing it locally at once and mailing the developer; Block in
  Settings (local wipe, unlink, future invites refused, developer notified); an
  on-device word filter over the partner's text in the app, notifications and
  widgets; the terms and the 24-hour commitment on the support site.
- **Audit fixes (round one)** — a late-finishing status publish no longer
  reverts a newer status locally or on the server (`saveStatus` skips when the
  server copy is newer); the nudge failure path compares whole-second dates, so
  an offline heart tap releases the cooldown and shows the slashed heart again;
  pending uploads join the media-prune keep-set; a failure between closing the
  invite and confirming the partner's private seat reopens the link; `reload()`
  keeps the closed invite link; read-receipt flushes claim the dirty flag before
  the network call so a mid-flight `markSeen` or toggle is never swallowed.
- **Audit fixes (round two)** — an unlink mid-refresh stops the delta being
  filed and the token persisted, and a new pairing wipes local media first;
  `requirePairing`/`unpair` refuse under a different iCloud account; Settings'
  close is `closeUnusedInvite` (refuses once anyone joined; the promote stays in
  Diagnostics); renames publish without a `StatusLog` record and the partner's
  banner says "is now going by …"; the home-row waveform uses a direction-locked
  UIKit pan so vertical scrolls scroll; rejoin keeps the live status instead of
  publishing "just joined"; derived widget fields recompute under the snapshot
  lock; the notification service stamps the category on every exit and delivers
  exactly once; a failed unlink shows its reason inside the local-only dialog;
  `redstring://` is a registered URL scheme; the Siri intent goes through
  `Backend.current`.
- **Catalogue refresh** — 42 new presets across every group (🎴 playing
  cards, 🙇 begging for forgiveness, 🥪 eating a sandwich among them) and a
  pass over the emoji that didn't match their words: 😤 is now frustrated and
  🎯 determined, 🏫 in class with 🧑‍🏫 kept as teaching, 📞 on a call (☎️ takes over one call away), 🧘 yoga
  and 🪷 meditating, 🌃 early night and 🌅 just woke up, 🧖 relaxing, 📋
  running errands, 😋 hungry with 🤤 moved to "drooling" under Us.
- **Durable status history** — one `StatusLog` record per status change
  (`statuslog-<role>-<seconds>`), written by `CloudSync.publish` alongside the
  `Status` record and folded into `StatusHistoryLog` on refresh; the log now
  survives a reinstall. Each side prunes its own records past
  `AppConfig.statusLogLimit`, and deletions mirror locally. **Schema: the
  `StatusLog` record type must exist in Production before release.**
- **Status read receipts** — "Seen 2h ago" under your own status. Two
  encrypted fields on the existing `Receipt` record (`statusSeenAt`,
  `statusSeenFor`), stamped only from the foreground home screen. **Schema:
  the two new `Receipt` fields must be deployed.**

## Shipped (August 2026)

- **History filter: sent / received** — segmented control in the library and in
  status history (`HistoryFilter` + `HistoryFilterPicker`); the gallery pages
  within the filtered set.
- **Status history** — local rolling log (`StatusHistoryLog`, cap
  `AppConfig.statusHistoryLimit`, 100) written from `AppModel.setStatus` and
  `CloudSync.apply`, shown by `StatusHistoryView` (tap the partner card).
  Local-only: no CloudKit record, gaps possible, doesn't survive reinstall.
- **Read receipts** — toggle in Settings, on by default, gates both
  sending and display. One `Receipt` record per side (`receipt-<role>`) carrying
  an encrypted seen-map; receiver publishes via `flushReceiptsIfNeeded`, sender
  folds it into `Moment.seenByPartnerAt`. Eye badge in the library, "Seen …"
  line in the gallery. **Schema: the `Receipt` record type must exist in
  Production before release** (README → "Shipping it").
- **Waveform scrubbing** — swipe across any playback waveform to seek
  (`ScrubbableWaveform` + `VoicePlayer.seek`); scrubbing an idle memo starts it
  from that point.

## Next

### Super nudge — escalate when they spam the heart (S–M)

When one side taps the heart repeatedly in a short window, the other side gets
one *stronger* notification instead of a stack of identical ones.
- **Detect on the sender**: in `CloudSync.sendNudge`, track recent send times in
  `Snapshot`; when ≥3 sends land inside ~60s, write a `burst` Int field on the
  existing `Nudge` record (plaintext, like `count`).
- **Render on the receiver**: `NotificationService.applyNudge` and
  `NotificationManager.postNudge` read `burst` and swap wording ("is REALLY
  thinking of you ❤️‍🔥"), keep `.timeSensitive`, optionally a distinct sound.
  In-app: bigger haptic + a heart-burst animation (reuse `CelebrationOverlay`
  machinery at lower intensity).
- Watermark logic is unchanged — a burst is still just a count increase.
- Schema: one new field on `Nudge`; redeploy.

### Also on file (from README "Possible improvements")

- Reactions on a moment (needs a `Reaction` record type + subscription). Built
  and removed in September 2026 — the UI never felt right; the sync design
  (one `reaction-<role>-<momentID>` record per person per moment, encrypted
  emoji, own subscription, removal pushes that can't be suppressed) is in the
  git history if it comes back.
- Shared countdown lock-screen widget.

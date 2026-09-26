# Roadmap

Effort: S = hours, M = days, L = a week+. Any CloudKit field/record-type
addition requires re-deploying the schema to Production (README → "Shipping it").

## Shipped (September 2026)

- **Audit fixes (round five)** — "zone gone" needs a second sighting two
  minutes on before a device unlinks itself, so the invite-close handshake
  can't wipe the partner's unsent media (`zoneGoneVerdict`,
  `SyncError.zoneUnreachable`), and when it does unlink, unsent media
  survives and is re-sent if the same zone is accepted again
  (`SharedStore.lastPairing`, `adoptPairing`); a change token cleared by an index rebuild
  mid-refresh is no longer written back; media downloads copy to `.part` then
  rename; the status-log prune is non-atomic and survives pre-cloud entries;
  mid-refresh guards compare the pairing's zone, not its existence; every
  moment in a burst is marked announced and a time floor
  (`lastAnnouncedMomentSentAt`) keeps the banner fallback off re-fetched
  history; the lock-screen intent is bounded by the same 8 s deadline as the
  widget; the model's own refresh no longer triggers a second fetch;
  Notification Centre is cleared only on `.active`. UI: an emoji-only status
  shows the emoji alone instead of "Set your status"; composers block pull-to-dismiss
  and confirm Cancel when there's a doodle, a take or a caption; a reported
  status hides its emoji on Home like everywhere else; every sheet hosts the
  error alert and the anniversary prompt waits for Home's sheets to close;
  `Theme.warmDeep` for orange carrying white text and orange text on cream
  (AA); small tertiary text promoted to secondary; headlines follow Dynamic
  Type; the participant's "Since" card is a card, not a disabled button.
- **Audit fixes (round four) + two small features** — moderation now goes
  through one set of presentation helpers (`Moderation.swift`) on every
  surface: the status widget and the notification service honour a reported
  status, the celebration overlay, the home memo row and the status history
  apply the word filter, and names are filtered like any other partner text.
  A record the foreground app itself can't read on three separate refreshes
  no longer pins the change token forever (`SharedStore.noteUnreadableRecords`;
  Diagnostics shows "gave up on"). A stale delta from a concurrent process
  can't regress the partner's status (`RefreshDelta` newer-wins both ways).
  The notification service claims every banner against the watermarks and
  words an unclaimed push honestly: a second device on the same iCloud
  account ("from another device", silent) or an already-announced event
  (silent), never the partner — unless the extension couldn't decrypt the
  delta (locked phone), when the generic banner stays loud; renames are
  judged against the last announced
  status, so they read right whichever process consumed the delta. Settings
  and the invite sheet no longer promise the link closes itself. Smaller:
  status and caption character caps (`AppConfig`), a "Turn on" button for
  never-asked notifications, distinct VoiceOver names for the drawing
  backdrops, the account lookup runs only when the system reports a change,
  unpinned vertical ScrollViews pinned (invariant 18), ~40 strings routed
  through the String Catalog, the dead `hasRequestedNotifications` flag gone,
  `AppModel` reads only its injected store. Features: the "waiting to send"
  footer is tap-to-retry, and the participant can **ask the owner to set the
  anniversary** from the count screen — one `AnniversaryRequest` record, no
  push, the owner gets the date prompt on next open. **Schema: the
  `AnniversaryRequest` record type must exist in Production before release.**
- **Core hardening** — a unit-test target (`make test`, 56 XCTest cases at the time, over
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
- **Catalogue trim + custom emoji** — five short drawers (Us first, ~90
  presets, food folded into Doing; 🃏 for playing cards) and an emoji slot in
  the picker (`EmojiField`: a UIKit text field that opens the emoji keyboard)
  for everything the presets no longer list.
- **Durable status history** — one `StatusLog` record per status change
  (`statuslog-<role>-<seconds>`), written by `CloudSync.publish` alongside the
  `Status` record and folded into `StatusHistoryLog` on refresh; the log now
  survives a reinstall. Each side prunes its own records past
  `AppConfig.statusLogLimit`, and deletions mirror locally. **Schema: the
  `StatusLog` record type must exist in Production before release.**
- **Audit fixes (round three)** — the anniversary (and any encrypted field)
  can no longer vanish from a background refresh: a record whose encrypted
  fields come back empty is skipped and the change token held so it's fetched
  again (`CloudSync.isReadable`, CLAUDE.md invariant 2); held captions, sender
  names and waveforms beat empty re-deliveries; no 💭 placeholder in the status
  log; the status read receipt clears only from a readable receipt.
  Diagnostics counts unreadable records per process. The snapshot fold
  (`RefreshDelta`) and every notification claim (`AnnouncementPolicy`) are
  pure and under `make test`. No schema changes.
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
  (Superseded by the September durable status history: `StatusLog` records,
  cap now 300.)
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

### Alternate app icons (S)

Let each person pick the Home Screen icon from Settings.
- **Assets**: one more `.appiconset` per variant in
  `Sources/App/Resources/AppIcon.xcassets`, a single 1024px PNG each (iOS 17
  needs no other sizes). Candidates: colour/seasonal takes on the red string;
  the fox-and-fish `Logo` as a hidden unlock once the pair has tied the string.
- **Build**: `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` (or
  `…_INCLUDE_ALL_APPICON_ASSETS: YES`) on the app target in `project.yml` —
  Xcode writes `CFBundleAlternateIcons` itself; no Info.plist edits. Then
  `make project` and commit the regenerated project.
- **UI**: a row of icon previews in `SettingsView` calling
  `UIApplication.setAlternateIconName` (nil restores the default); the current
  choice is read back from `alternateIconName`, so nothing is persisted. iOS
  shows a one-time confirmation alert that can't be suppressed.
- Per device, not synced (widgets and the NSE are unaffected). Could ride
  `Snapshot` later if both phones should match. No schema changes.

### Delete your own moment (S)

The gallery menu exists only for the partner's moments. Own deletion is one
record delete (`moment-<role>-<uuid>`) plus the local `MomentIndex.remove` +
`MomentStore.delete` the deletion mirror already runs on the other phone; the
snapshot's derived fields recompute via `refreshDerived`. Confirm first — it
deletes on both phones.

### Status history: report from the sheet, and live refresh (S)

`StatusHistoryView` loads once (`.task`) and offers no report action; a status
that lands while it's open doesn't appear, and reporting means backing out to
the home card. Reload on `pairingDidChange`, add "Report…" to partner rows
(reuses `reportPartnerStatus` for the current one; older entries need the
report to carry the entry's `at`).

### Heart back on a moment (S)

The banner already offers "Send a heart back" on a moment; the same one-tap
inside the gallery is the light version of the reactions feature that never
felt right. No schema: it's a nudge.

### Offline block should still remember the partner (S)

`recordBlockedPartner` needs the share's participant list from the network,
so an owner who blocks while offline records nobody and the blocked person's
next invite is accepted. Cache the participant record names on each
successful refresh (or `inviteState()`), so the block has something to write.

### Heartbeat moment (M) — feasibility only, not started

Send your heart rate as a moment; the partner opens it and the phone plays a
synthesised lub-dub at that tempo under an animating heart (Digital Touch did
exactly this). Investigated September 2026; the shape that fits the app:
- **No watch app needed.** The iPhone's Health store already holds the
  watch's heart-rate samples (a few minutes old at rest, more frequent when
  moving). A "send my heartbeat" button reads the latest `heartRate` sample
  via HealthKit (read-only entitlement + `NSHealthShareUsageDescription`) and
  sends it as a new `Moment.Kind` (`heartbeat`) with an encrypted `bpm` field,
  no asset. Rides the existing offline retry, receipts, history, moderation
  and notification paths; a stale or missing sample shows "no recent reading"
  rather than sending nothing.
- **Playback is foreground-only.** iOS has no background or lock-screen
  haptic API, and Live Activities and notifications can't carry a rhythm, so
  the receiver is a "feel" screen in the gallery driving a CoreHaptics
  lub-dub pattern at the received tempo. Beat-by-beat data isn't available
  from public APIs either — HealthKit gives a *rate* — so the rhythm is
  synthesised, which is also what makes latency a non-issue.
- **App Review risk — decide before building.** Guideline 5.1.3 says HealthKit
  apps "may not store personal health information in iCloud"; an encrypted
  BPM in a CloudKit record is arguably that. Defence: the field is encrypted
  like every other user word, and the review notes describe it as a tempo for
  a haptic pattern, not health data. If that's not acceptable, the fallback is
  a tapped-in rhythm without HealthKit.
- **Later:** a live session (watchOS target running a workout-style session
  for 1 Hz readings → WatchConnectivity → an ephemeral CloudKit record,
  deleted when the session ends) on top of the same "feel" screen; and if the
  partner also wears a watch, an extended runtime (mindfulness) session can
  tap the wrist with the screen off. Both need both people present at once.
- Schema: one new `Moment` field (`bpm`); redeploy. Widget and NSE untouched
  beyond the new kind's wording.

### Finer detail in doodles (S–M per option)

A fingertip covers too much of a 362 pt canvas for small writing or detail,
and a thinner brush doesn't help when the finger is the problem. Options,
roughly in order of value:
- **Pinch to zoom while drawing** (recommended first). `PKCanvasView` is a
  scroll view with zoom built in: two fingers zoom/pan, one draws; the 2048 px
  export has ~5.7× headroom. Two traps: the photo must move *inside* the
  canvas's content so it zooms with the strokes, and `DrawingController.render`
  exports `canvas.bounds` — under zoom that's the visible region, so export
  the fixed content square instead or strokes land misaligned. Replaces the
  `SheetDragBlocker` (the canvas's own two-finger gestures then win). After,
  trace strokes over a grid photo and measure the sent JPEG in the App Group's
  `Moments/` — that file is exactly what the partner downloads.
- **Writing strip** — a magnified strip along the bottom: write large, it lands
  small on the canvas and auto-advances (GoodNotes' zoom box). Best for words.
- **Offset cursor** — ink appears a fixed distance above the fingertip, so the
  finger never hides the line.
- **Precision mode** — finger movement scaled down (e.g. 3:1) around the
  touch-down point; needs strokes synthesised from `PKStrokePoint`s.
- **Move/resize after drawing** — lasso-select strokes and transform them
  (`PKStroke.transform`); draw big, then shrink.
- **Text tool** — typed words in a handwriting-style font, since tiny
  handwriting is the usual fight.

Checked September 2026: strokes already reach the partner pixel-aligned with
the photo (the export is the only transform; media travels byte-for-byte).

### Library grouped by day, and search (M)

`StatusHistoryView.byDay` already does the grouping; the moment library is a
flat grid. Sections by day plus a caption/sender search field.

### Smaller UX items on file

- "Report a problem" in Settings is a bare `mailto:` `Link` — a silent no-op
  without Mail; the moment/status report path falls back to the clipboard and
  this one should too.
- The general `noticeMessage` alert is titled "Report copied" in `RootView`
  even though the channel is generic.
- A visible character counter near the cap in the status and caption fields
  (the cap itself is enforced).
- Siri's "Send a nudge" while unpaired returns success silently
  (`SendNudgeIntent` swallows the error); a spoken dialog would be kinder.
- Old `StatusLog` entries logged before the cloud log existed are local-only
  and don't survive a reinstall (documented; nothing to do unless it matters).

### Also on file (from README "Possible improvements")

- Reactions on a moment (needs a `Reaction` record type + subscription). Built
  and removed in September 2026 — the UI never felt right; the sync design
  (one `reaction-<role>-<momentID>` record per person per moment, encrypted
  emoji, own subscription, removal pushes that can't be suppressed) is in the
  git history if it comes back.
- Shared countdown lock-screen widget.

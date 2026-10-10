# Roadmap

Effort: S = hours, M = days, L = a week+. Any CloudKit field/record-type
addition requires re-deploying the schema to Production (README → "Shipping it").

What has shipped is in [CHANGELOG.md](CHANGELOG.md).

## Next

### Statuses set while offline only log the last one (S) — pre-existing
Set A then B offline: the reconnect republishes `mine` (B) and logs B, so A
stays in this phone's `StatusHistoryLog` but never gets a `StatusLog` record —
the partner's history skips it and a reinstall loses it. Always true of failed
sends; offline queueing makes it ordinary. Fix: a local-only "unlogged" mark on
own `StatusHistoryEntry`s and a capped republish of their `StatusLog` records.

### Send the queue while the app is suspended (M) — open question
Offline sends go on the reconnect refresh, but `NWPathMonitor` only runs
while the app does: send offline, lock the phone, regain signal, and nothing
leaves until the app is next opened. Options: a `BGAppRefreshTask` scheduled
on backgrounding whenever `pendingSendCount > 0` (needs the `fetch`
background mode and `BGTaskSchedulerPermittedIdentifiers`; iOS runs it at
its own discretion, often within the hour for an app used daily, never
guaranteed), or a `BGProcessingTask` with `requiresNetworkConnectivity`
(runs later still, usually idle/charging). Either runs `refresh()` + the
recovery pass under the existing upload protection. Long-lived CloudKit
operations were considered and set aside — they don't wait for a
connection, and their results arrive only on relaunch.

### Fresh start — follow-ups (S each)

Shipped October 2026 (see CHANGELOG); left on file:
- Verify on the live service, as for the invite handshake: that
  `lastModifiedUserRecordID` names this account (`__defaultOwner__` or its own
  record name) on both databases, so a second device trusts its own record.
  If it doesn't, a second device with an old index still filters (the
  partner's half and `clearedBefore` from the agreement), but won't purge.
- A partner who never opens the app again leaves their half in the zone (and
  in the owner's storage). Each phone hides it; deleting the other side's
  records would undo the creator-check direction (#5/#6). Unlink settles it.
- The asker's archive is taken just before the ask lands: a send in that
  window (an archive's length, normally seconds) is cleared without being in
  the asker's copy — it is in the agreer's, taken after the epoch.
- A moment push that only carried deletions is reworded quietly by the NSE,
  never dropped (no filtering entitlement).
- An older build on a second device of either person neither filters nor
  guards the requeue; after a full resync it could re-send cleared moments.
- `requeueMissingUploads` judges a cleared send by its client `sentAt`, not
  the server time the cut uses: a second device whose clock ran ahead of the
  ask by more than the gap to a send could re-queue that one send after a full
  resync. The index would need each moment's server creation time to close it.
- Nothing clears until the asker's phone commits, and then this phone's own
  zone pass must finish before its copy is purged: Home and the widget keep
  the history until then (the sheet says "waiting"; a failing pass gets its own
  card). Extensions never purge.
- Asks need a connection (an ask queued offline would move the epoch); the
  sheet says so rather than queueing.

### Super nudge — escalate when they spam the heart (S–M)

When one side taps the heart repeatedly in a short window, the other side gets
one *stronger* notification instead of a stack of identical ones.
- **Detect on the sender**: in `CloudSync.sendNudge`, track recent send times in
  `Snapshot`; when ≥3 sends land inside ~60s, write a `burst` Int field on the
  existing `Nudge` record (plaintext, like `count`).
- **Render on the receiver**: `PushBannerPolicy.decide` (the NSE's nudge row) and
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

### Deferred from the October 2026 UX brief

IDs refer to the October design arena's brief (not kept in the repo).
- **FIRST-1 (S–M)** — the owner's first run one interruption at a time: the
  notification prompt after the link sheet, no date sheet before anyone has
  joined (a Home card once they have), and a "Waiting for your partner" card
  with the link. Not yet: the owner isn't ready to change first run.
- **WID-1 (S)** — the small status widget's heart shows sent/failed, bigger target.
- **WID-2 (S)** — status age on the status widgets (live relative time on
  systemSmall, a coarse age on the Lock Screen, dimmed past 12 h).
- **Emoji-only on widgets (S)** — the widgets still print "no message" for an
  emoji-only status (STA-1's widget half).

### Offline block should still remember the partner (S)

`recordBlockedPartner` needs the share's participant list from the network,
so an owner who blocks while offline records nobody and the blocked person's
next invite is accepted. Cache the participant record names on each
successful refresh (or `inviteState()`), so the block has something to write.

### Heartbeat moment (M) — feasibility only, not started

(The receiving side's prerequisite is done: an older build files an unknown
kind as `Moment.Kind.unsupported` — "update Red String to see it" — instead of
losing it past the change token.)

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

### Camera follow-ups (S each, except where noted)

- **Lock Screen camera (M–L):** a `LockedCameraCapture` extension (iOS 18)
  plus a Lock Screen/Control Center control, so the Camera Control or a lock
  screen button opens straight into a moment. New target, entitlements and a
  hand-off of the captured photo to the app on unlock.
- **Back-camera timer cue:** blink the torch through the countdown, like the
  system camera, for a phone propped up facing away.
- **Night mode:** revisit each WWDC; no third-party API as of iOS 26.

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

### Follow-ups from the October 2026 implementation round (S each)

- **"Update to see this" tile.** A moment of a kind from a newer build stays in
  the index but out of `AppModel.history`, so the library and gallery don't
  show it at all; a tile saying "Update Red String to see this" would finish
  the tolerant decoding.
- **`Theme.rounded` doesn't follow a live Dynamic Type change** — it reads
  `UIFontMetrics` when a view renders and nothing re-renders on a size change.
  The UI audit excludes `.dynamicType` for it; read
  `@Environment(\.dynamicTypeSize)` in a modifier (or `@ScaledMetric`), then
  re-enable it in `DemoSmokeTests`. The 1.35× cap is a separate decision.
- **UI audit exclusions** for screenshot-checked misreads (wrapped small text,
  the composer's "Camera", navigation-bar glass buttons): re-check on each new
  iOS/Xcode and drop the ones the audit stops raising.
- **App tint** is now `Theme.accentText` (AA crimson for text) app-wide, which
  also darkens toggle tracks and date-picker selection; revert the one line in
  `RedStringApp` if the brighter crimson is preferred there.
- **App Store link in the invite message** once the app's ID is known
  (`AppConfig.appStoreURL`).
- **The lock-screen heart's account lookup** still precedes its write when the
  shared cache is stale (`sendNudge` → `requirePairing`); running it alongside
  the record fetch needs a `saveNudge` restructure. The app's own refresh can
  still request two widget reloads (apply, then the media prefetch's).
- **The status read receipt** is forward-only by the words' date; after a
  partner's clock ran ahead, a later status with an earlier stamp isn't
  stamped "seen" until the stored stamp is in the past (rare; would need a
  local-only order key on `StatusSeen`).
- **"Invite again" from the partner-left card** opens Settings (a new link
  needs the unlink first); a one-tap unlink-and-reinvite would need the unlink
  confirmation hosted on Home.

### From the October 2026 whole-app review (not picked yet)

Raised by the October audit; none needs a server. Milestone reminders was
picked and shipped (see CHANGELOG).

- **Expiring statuses (M)** — raised independently by all three
  reviewers. "In a meeting until 3", "driving · 30 min": the picker offers
  "for 1 h / until tonight / until I change it"; after `expiresAt` the card,
  widgets and history show it dimmed ("was …"), and the widget timeline gets an
  entry at the expiry instant. Receivers decide locally. *Schema:* one
  encrypted `expiresAt` on `Status` (and `StatusLog`), capped through
  `TrustedTime`, hand-written Codable fallback `nil`; older builds ignore it.
  Batch the redeploy with super nudge's `burst`.
- **Set status from Shortcuts, Focus and Siri, plus a quick-status widget
  (S–M)** — A parameterised `SetStatusIntent` (an `AppEntity` over presets
  and Recent) as App Shortcuts and a `SetFocusFilterIntent` ("Sleep Focus →
  😴"), Siri read-back ("What's Sam up to?" through the moderation helpers), and
  an interactive widget whose buttons are your recent statuses. Publishes
  through the existing offline queue; on failure the widget leaves
  `myStatusPublished` down for the app's republish. No schema.
- **Control Center / Action button heart (S)** — A `ControlWidget`
  (iOS 18, `@available`-gated) over `SendNudgeIntent`, showing the slashed
  heart from `lastNudgeFailedAt`. No schema.
- **Remove a stranger without deleting the space (M)** — The
  "someone else has joined" card can today only say "unlink". Offer the owner a
  confirmed `removeParticipant`, choosing from the share's participant list
  (names from `userIdentity`) — not "the author of `status-participant`", which
  both participants write. Manual and confirmed only (invariant 9). No schema.
- **Voice-memo transcripts (M)** — On-device Speech under the waveform,
  as the banner body without a caption, and for VoiceOver. Receiver-side
  transcription needs no schema; an encrypted `transcript` field would.
- **Draw on their photo (S)** — Gallery menu "Draw on this" opens the
  composer with the partner's full image (`ensureMedia` first) under
  `DrawingController.render(over:)`; sends a normal photo moment. No schema.
- **Time-capsule moments (M)** — An encrypted `revealAt`: a sealed tile
  with a countdown, the NSE saying "sent you something for <date>", a local
  notification on the day. Client-enforced — fine for a gift, not a secret.
  Batch its redeploy with expiring statuses and super nudge's `burst`.
- **Weekly recap card (S)** — Sundays on Home: hearts, statuses, photos
  and memos this week, from the local stores (nudge totals need a weekly
  baseline in `Snapshot`). No schema.
- **Privacy lock (S–M)** — Optional Face ID gate on launch, app-switcher
  blur, `.privacySensitive()` on the status widgets' text (extends the
  photo-widget item below). No schema.
- **Storage steward (M–L)** — An estimate of the shared space's size from
  locally recorded asset sizes and an explicit, opt-in "make room" that drops
  old full-size media but keeps thumbnail, caption and record. Depends on
  "Delete your own moment" and changes the complete-history promise (copy).
  Optional plaintext `bytes` on `Moment`.
- Also considered: heart variants (adjacent to super nudge; one plaintext Int
  on `Nudge`), an Apple Watch target (heartbeat already scopes it), a Lock
  Screen doodle glyph (legibility unproven). Rejected: Live Activities
  (push-to-start needs a server), location sharing, view-once photos,
  `CKSyncEngine` (owns the change token, against invariant 2).

### From the September 2026 arena review (not picked yet)

Verified in code by the review; ordered by value over cost within each group.

**Copy that promises more than the design does (S, one pass)**
- Terms/site say the developer removes content and "ejects" the sender
  (`TermsView.swift:67-74`, `docs/index.html:354-357`) — no server can. Word it
  as what happens: hidden here at once, Block ends the link, we reply in 24 h.
- `PairingView.privacyNote` says photos are end-to-end encrypted (assets are
  Apple-encrypted; E2E only with Advanced Data Protection). "Your own iCloud"
  is wrong for the joiner (`WelcomeView`, Settings' version footer, `TermsView`,
  site). "Details go to us" / "we're notified" is a `mailto:` draft to send.
- README "complete and recoverable"/"unlimited" history vs the 500-entry index.
  Fix the copy. ("Save memories" now reads the whole zone — October 2026.)

**Re-seat and zone-gone (S)**
- The 120 s zone-gone window is justified by "ten seconds", but a re-seated
  partner is off the share until they re-tap. Show "tap the link once more"
  while `zoneGoneSeenAt` is set; reword `linkEnded` when `lastPairing` is kept;
  pass `rejoining: true` in `acceptShare` for the same zone (#25); clear the
  change tokens *before* erasing media in the wipe; let extensions only stamp
  the sighting.

**Coverage still missing (M)** — `SharedStore`'s static locks still resolve the
real container in tests (lock files only; inject a lock directory); `CloudSync`
itself has no `CKDatabase` seam, so the per-zone fetch error path (#16 of the
October review) and the CloudKit calls behind the pure policies are untested.
(The NSE's branch table and `SyncRunner`'s choice are now `PushBannerPolicy`,
under test.)

**Left from the change review (S each)**
- A replaced zone keeps its zone ID, so a partner rejoining it skips the media
  wipe (`adoptPairing`'s `lastPairing.sameZone`) and re-sends unsent media from
  the old space. Same after an owner unlink and re-invite.
- An anniversary save or delete abandoned at its deadline can land after a
  newer edit (a late delete removes the new date on both phones).
- A successful status publish clears the full-iCloud back-off even if a photo
  still can't fit.
- CI: checksum the downloaded XcodeGen zip; the simulator picker sorts runtime
  names as strings.

**Robustness (S each)**
- Per-record fetch failures are dropped while the token advances
  (`CloudSync+Refresh.swift:163-165`) — fold them into the unreadable hold.
- `GroupFileStore` reads unreadable as absent, so `mutate` could write
  `.empty` over the snapshot after a transient read error.
- Store I/O and `flock` waits run on the main actor from `CloudSync`; now that
  the stores are `Sendable`, drop the `MainActor.run` hops (profile a resync).
- One shared `isBusy` spans nine overlapping operations. (The footer's
  "1 waiting to send" during a first upload is fixed: `Outbox.uploadsInFlight`.)

**UI/UX (S each unless noted)**
- The default-on word filter hides ordinary names ("Dick" → "Partner"): exempt
  names or check them against slurs only.
- Dynamic Type: the 1.35× cap also limits prose (Terms, Welcome, the partner's
  message); mood tiles are fixed-height (M).
- `.secondary` 11 pt captions ("Seen …", timestamps) are ~3.3:1; `mint` on
  cream is 2.2:1 for the "Saved" check.
- Voice Control: "Thinking of you" is labelled "Send a nudge".
- `willPresent` plays banner + sound for every category, `.passive` included.
- Settings: "Report a problem" and "Save memories…" look like the destructive rows.
- Mood picker "Set" is disabled with no hint when the emoji is empty.
- The anniversary prompt stacks on the invite sheet before anyone has joined.
- Receiver-side "quiet nudges for a while" via the NSE's existing `quieten`.
- Localisation readiness (M): ~100 mood labels bypass the catalog and key
  `Mood.id` on English; ". Seen %@" fragment; "a \(noun)"; ternary plurals;
  locale-insensitive `uppercased()`; English `alertBody` (needs new
  subscription IDs); stale catalogs (last committed 2026-09-13).

**Safety and privacy**
- Reports carry no evidence: `report()` deletes the media before the mail, and
  `mailto:` can't attach. In-app composer with the thumbnail snapshotted first (M).
- An owner's unlink wipes the joiner's copies of their *own* sends; offer "save
  what you sent" first — changes invariant 8's wipe scope, needs a decision (M).
- Support is a personal Gmail compiled into the binary: a domain alias.
- The privacy page loads Google Fonts; self-host them.
- Decrypted JSON and media sit in device backups; exclude the re-downloadable
  `Moments/` cache and say so in the policy.
- Optional "hide when locked" (`.privacySensitive()`) for the photo widget.

**Docs and tooling (S)**
- Each invariant: one-line rule + "guarded by: `TestName`" or "unguarded".
- A CI step checking the `AppConfig` IDs against the four entitlements files,
  `project.yml` and `Info.plist` (invariant 12), and a grep for
  `.safeAreaInset(edge: .top)` in `Views/` (invariant 21).
- `make test`/`make build` regenerate the committed project as a side effect.
- Dead code: `PairingView.inviteReady` (unreachable, hosts an unconfirmed
  unlink).

### Known issues on file (September 2026 audit, not yet fixed)

Found by the audit and deliberately left for now; numbers are the audit's.
- #5/#6 A modified partner client can delete or take over your moments on your
  phone (deletions under either role's name; index keyed by id alone), and
  record names are trusted for authorship. Needs a creator check. (M)
- #7 Owner-side block isn't enforced: an offline block leaves the share up,
  Rejoin reconnects to the blocked person, and a blocked ex can join the next
  link. (M)
- #14 A failed account lookup at pairing leaves `userRecordName` nil, which
  disables the different-account guard for good. (S)
- #24 A join that half-fails leaves the join screen over a paired app; #25
  re-accepting the same zone posts "👋 just joined"; #26 the owner's
  `sameZone` check is always true; #27 zone-recovery edge cases (token-expired
  retry skips the second-sighting rule; `unknownItem` counts as zone gone;
  unpair ignores the per-zone result); #42 Rejoin picks the first shared zone.
- #32 The share title carries the owner's name in plaintext
  (`"Red String — <name>"`), contradicting "the names you set are
  encrypted". One line. (S)
- #33 The word filter misses plurals, spaced letters, homoglyphs, leetspeak.
- #34 remainder: the memories archive writes plaintext to iCloud Drive (it's
  an export; say so in the policy). Filtered partner text and long names
  fixed October 2026.
- #36 Plaintext metadata: memo durations, nudge counts, send times, receipt
  times (`kind` must stay plaintext for locked-phone banners).
- #37 Diagnostics' "Copy report" puts participant names/emails on the clipboard.
- #38 A playing memo bleeds into a new recording; closing the composer stops
  other audio; after granting the microphone the sheet must be reopened.
- #41 Privacy manifest: reading the App Group's UserDefaults suite (the
  one-time migration) needs reason `1C8F.1`; only `CA92.1` is declared. (S)
- #43 remainder: in the hours before the start's time of day, the count's
  full-day number is one behind the date-based "months and days" (by design:
  the counter ticks over at the start time).
- #21 remainder: an own second device writing while this phone is locked is
  worded as the partner's (the held record can't be told apart).
- Review notes (September 2026): a new moment found by a background refresh
  goes out passive if an *older* generic/held moment banner is still in
  Notification Centre (stamp the moment id to match exactly); a lock-screen
  heart whose save lands after the 8 s deadline shows as failed although it
  sent (the trade for never showing a failed one as sent).

### Library grouped by day, and search (M)

`StatusHistoryView.byDay` already does the grouping; the moment library is a
flat grid. Sections by day plus a caption/sender search field.

### Smaller UX items on file

- "Report a problem" in Settings is a bare `mailto:` `Link` — a silent no-op
  without Mail; the moment/status report path falls back to the clipboard and
  this one should too.
- The general `noticeMessage` alert is titled "Report copied" in `RootView`
  even though the channel is generic.
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

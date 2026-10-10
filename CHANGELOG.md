# Changelog

What shipped, newest first. Planned work is in [ROADMAP.md](ROADMAP.md).

## Review-fix round (October 2026)

- **Mostly code health; no schema change.** `AppModel` split
  into extensions by concern (`+Pairing`, `+Connectivity`, `+Moderation`,
  `+FreshStart`, `+Archive`, `+Notices`); Home split into value-taking cards
  (`HomeCards`, `HomeControls`, `HomeNotices`) SwiftUI can skip; pairing and
  share calls moved onto `SyncBackend`, with `DemoBackend` mirroring what
  `CloudSync` stamps locally.
- **Sharing:** share lookups fail closed (`existingZoneShare`); every owner
  share call goes through one guard (`ownerPairing()`); the participant list
  is judged by `SharePosture`; share saves are confirmed per record
  (`savedShare`); the Diagnostics sweep runs under the invite-change flag.
- **Stores:** shared-store reads cached by file identity; the status log
  cached and corruption-handled like the moment index (its corruption re-fetches
  the cloud log); `clearPairing` removes corrupt copies of what it clears;
  `Snapshot`'s coding keys checked against its properties.
- **Sync:** batched deletions and media fetches, one snapshot read per
  refresh, no widget reload for an empty refresh; `CKError` partial-failure
  helpers; the status log mark only moves for the current status; an
  anniversary changed mid-send is sent again.
- **Widgets and notifications:** widget content built and moderated once per
  timeline; the photo widget draws the full photo, downsampled
  (`WidgetPhoto`); the NSE passes only banner candidates; the lock-screen
  heart's abandoned-claim release is `NudgeCooldownPolicy`.
- **Moderation:** helpers say when they show a placeholder (`ModeratedText`,
  `ModeratedStatus`); views go through them.
- **Tooling:** XcodeGen pinned in `.xcodegen-version` (`make project` checks
  it); CI builds Debug once for the tests, compiles the UI tests, uploads
  results on failure; tests wait on conditions instead of sleeping.

## Shipped (October 2026)

- **Custom moment camera** — `UIImagePickerController` replaced by an
  AVFoundation camera (`CameraEngine`/`CameraModel`/`CameraView`): 3 s / 10 s
  self-timer, flash (incl. front screen flash), lens buttons from the device's
  real cameras plus a 2× crop (`CameraLensPlan`), pinch zoom, tap to focus,
  quality-prioritised capture in the dark (the multi-frame low-light
  processing apps can get — Night mode itself has no public API; balanced in
  daylight, where it lagged the shutter), and hardware shutters: volume
  buttons and AirPods stem
  (`AVCaptureEventInteraction`, 17.2+), the Camera Control's click plus zoom,
  exposure and timer controls (`AVCaptureControl`, 18+). Device-only: the
  Simulator has no camera, so the UI smoke doesn't reach it. The last camera,
  flash and timer are remembered per device (`SharedStore.cameraSettings`).
  The front camera frames like the system camera: cropped upright, its full
  width when the phone turns sideways or via the expand button.
- **Whole-app review round** — bugs, battery and accessibility fixes from an
  October audit, each with a regression test (invariants 2, 8, 10, 11, 13–16,
  22, 23 carry the rules).
  - **Sync:** a rename's own echo keeps `wordsSince` (it erased the "Seen" line,
    duplicated history and un-hid a reported status); the unreadable give-up
    starts when an extension saw the records first, and an incomplete batch
    never clears the hold (`TokenAdvancePolicy`); unknown moment kinds are kept
    (`Moment.Kind.unsupported`) and store files decode entry by entry
    (`LossyArray`), salvaging unsent sends from a `.corrupt` sidecar; the
    status log mirrors `readFailed`; partner dates are bounded and `Snapshot`
    decodes field by field; zone-level fetch errors are thrown.
  - **Statuses:** `StatusSavePolicy` — a status after a fast clock is no longer
    reported sent when skipped, an unreadable newer server copy isn't
    overwritten, an identical copy isn't re-saved, a status whose log failed
    retries only the log; the partner's copies order by server save time
    (`serverSavedAt`, local only, ties fall back to `updatedAt`); an unpublished
    local status survives the fold; setting or renaming no longer undoes a
    lock-screen heart; a recreated nudge counter is detected by creation date.
  - **Notifications:** the partner leaving is explained (`partnerLeft`, Home's
    notice, the NSE's quiet "left your shared space", never a heart for a
    missing count); unpaired pushes are quiet and stale subscriptions are
    cleaned up (`subscriptionCleanup`, block and the zone-gone verdict too); a
    >500-moment resync doesn't announce old photos; the worded banner is the
    expiry fallback and the attachment is bounded. The branch table is
    `PushBannerPolicy`, under test.
  - **Sends:** no double upload during a refresh (`uploadsInFlight`); CloudKit's
    retry-after is honoured (`SendFailure.throttled`); "Sent to …" for retried
    sends; clipboard copies expire.
  - **Battery:** widget reloads only when drawn fields moved and never fetch
    after a sibling's reload; one shared refresh across widget kinds; the
    account lookup runs alongside the fetch with a shared cache; batched,
    off-main library thumbnails; a cached index with a dictionary merge; one
    launch fetch; debounced receipts; a parallel, cancellable archive.
  - **UI and accessibility:** the heart's "Sending…" and an AA "Sent" state; a
    notifications-off notice; the invite share explains "install first, then
    tap"; VoiceOver announcements; recording pauses on interruption and stops
    only in the background; report/reveal as accessibility actions; a reported
    or filtered status stamps no "Seen" until revealed; editing the date keeps
    its time zone; text styles on the small widget; hidden-preview text;
    AA footers in Settings.
  - **Feature:** milestone reminders (`MilestoneReminderPlan`, opt-in per
    device, each phone's own 9 am).
  - **Tests:** `PushBannerPolicy`, `TokenAdvancePolicy`, `TimelinePlan`, the
    change fetch's keys read from source, and the demo-mode UI smoke with
    `performAccessibilityAudit()` (`make uitest`). No schema change.

- **UX refresh** — from the October design arena's brief (not kept in the repo; IDs refer to it).
  The easter egg has one lock: a 0.8 s hold on the home title (a thread draws
  while held), then tying the fox to the fish (drag, or tap one then the other)
  opens the count, the logo flying into its header; the logo-hold stage and the
  Settings-title secret are gone, the owner's date is a visible "Our date" row
  (EGG-1/2). Home is partner-first with their last heart on the card (the
  sweep on open had erased it), urgent notices above it, a bar backing that
  fades in under the title, and a soft haptic when something lands while it's in front
  — native banners unchanged (HOME-1/2/3, NOT-1 as adjusted). The status picker
  waits for a change before Set (a preset tap counts), shows your words as the
  placeholder, sends words alone with 💬, has a Recent row and counters; an
  emoji-only status shows as the emoji in the app (STA-1/2). Send failures show
  where they happened instead of alerts, only a full iCloud alerts (once per
  back-off), and alerts have specific titles (ERR-1). Settings is regrouped on
  one page with danger last (SET-1). A moment banner or the photo widget opens
  the moment (`AppModel.pendingRoute`, ROUTE-1); the gallery and the
  celebration send a heart back (MOM-1); the footer pill says "Sent to …"
  (SEND-1); a blank canvas draws on first touch, the voice composer shows the
  cap, and Redo and the drawing's trash ask first (COMP-1, VOI-1); the library
  is "Moments" (LIB-1); Terms open with what the app is (TERMS-1); an AA
  contrast pass via `Theme.mutedText`, 44 pt targets, Reduce Motion fades
  (A11Y-1).

- **Fresh start — clear the history, both agreeing.** For a chapter that has
  ended without the link ending: one person asks (Settings → Fresh start), the
  other gets a Home card (no push, no subscription — it rides any refresh like
  `AnniversaryRequest`) and agrees; Save memories is offered first to both,
  skippable behind a confirmation, and an incomplete archive stops before
  anything is asked or agreed. Moments, status logs and read receipts go from
  both phones and the zone; both current statuses, the heart, the link, the
  date and its request stay. The request doesn't expire; the asker can
  withdraw it until the partner's phone commits.
  - **Records.** One `FreshStart` per side (`freshstart-<role>`, encrypted
    `stage`, `epoch`, `clearedBefore`). The epoch is the ask's *server* save
    time — not either phone's clock — so "before the request" means the same
    on both, and the cut on every record is its server `creationDate`. An ask
    is written once, never re-saved, and never queued offline.
  - **Commit, not just agreement.** Agree names the epoch and is final; the
    asker's app commits on seeing it, and only a committed epoch clears. A
    withdraw and a commit are both writes to the asker's own record judged
    against the server copy under a change tag (`FreshStartPolicy.transition`),
    so a withdraw racing the partner's yes can never leave one phone clearing.
    Both asking at once: the later ask converts into agreement to the earlier.
  - **Each side deletes only its own records**, app only, after re-reading
    both records from the server (`CloudSync.clearHistory`): non-atomic
    batches, each confirmed, re-run whole on failure. Never `status-*`/
    `nudge-*` (read as an unlink), never the `FreshStart` record (the lasting
    mark), never the current status's log record. This phone's own copy is
    purged only after its zone half succeeds (`FreshStartPolicy.purge`): the
    zone's server-time classification wins; what the zone doesn't hold is
    judged by its date — except an own send that never reached iCloud, which
    is kept and sent (it's the only copy, and lands after the epoch).
  - **Resurrection closed** by `Snapshot.freshStart.clearedBefore`, moved only
    by a published commit and never back down: ingestion drops older moments
    and logs (before the readability check, so they never hold the token —
    and the commit in the same delta already counts), `requeueMissingUploads`
    leaves older sends alone, and the upload retry never overlaps a clear.
    Our own record written by another account is never taken as our consent.
  - Extensions only fold the records; the NSE rewords a deletion-only moment
    push quietly. Diagnostics shows both records. Tests: `FreshStartPolicyTests`
    (with a two-phone handshake simulation), `FreshStartIngestTests`,
    `FreshStartOutboxTests`. Schema: new type, see README "Shipping it".
  - **Changed from the first design**: the epoch is server time, not the
    asker's clock; a commit step guards the withdraw race; agreement is final;
    withdrawing writes an idle record instead of deleting it (it carries the
    last clear's mark); unsent own sends are kept, not dropped; the current
    status keeps its log entry.
- **Groundwork**: `ZoneClearPlan` (`.freshStart` vs `.unlink`, which now
  takes the `FreshStart` record too) and a complete memories archive read from
  the whole zone (`SyncBackend.archiveZone`, `ArchiveContents`).

## Shipped (September 2026)

- **Arena review fixes** — from a ten-critic review. A new invite no longer
  reuses a zone with someone on its share (known issue #1): `createPairInvite`
  refuses with `existingPairing`, the pairing screen demotes "Create" under
  Rejoin, and replacing deletes the old space only after a confirmation. A full
  iCloud is named (whose storage — the owner's holds both people's sends) and
  slows automatic retries (`SendFailure`). The owner gets a one-time "\<partner\>'s
  in — close the link?" card into the confirmed re-seat, a warning when more
  than one person is on the share, and the close refuses to re-seat a stranger
  (`tooManyOnShare`). `refresh()` holds its guard for the fetch only, a
  mid-fetch request re-runs instead of being dropped, and the status, receipt,
  anniversary and subscription writes have a deadline. Home: the nav bar keeps the system scroll-edge treatment (the
  title no longer draws over content), AA-safe `Theme.accentText` and a deeper
  `warmDeep`, a Lock Screen widget tip (retired once a Lock Screen widget is installed; the
  steps also live in Settings), and the status receipt isn't stamped under a
  sheet. Tooling: CI (drift check, tests, Debug + Release with warnings as
  errors), Pages deploys only on `docs/**`, strict concurrency `complete` at
  zero warnings.
- **Testability** — `CloudSync.apply`'s decisions moved into a pure
  `ParsedDelta` (tested with real `CKRecord` fixtures, `isReadable` included);
  the zone-gone rule into `ZoneGonePolicy` (a future-dated sighting now
  restamps instead of holding off the verdict); `AppModel`'s offline-send loops
  into `Outbox`, tested against a recording `FakeBackend`; the refresh
  coalescing into `RefreshGate`; `GroupFileStore` and `CrossProcessLock` take a
  directory and are tested for real, contention included. `AppModel` takes an
  injectable backend.
- **Notification-extension media** — downloads moved out of `apply` to after
  the token persist (`prefetchMedia` executing a pure `MediaPrefetchPlan`). The
  NSE does no bulk prefetch: only the widget's picture (one thumbnail) and its
  banner's attachment, never a full photo, each bounded. The widget takes the
  partner's three newest photos and doodles, so newer memos can't crowd out the
  picture it draws; the app plans over the index's newest ten (a push's moments
  are usually filed by the NSE first), on its own task so nothing waits on it.
- **Change review fixes** — ten reviewers, two per change group. The new-invite
  refusal fails closed and also covers a leftover zone that only holds records;
  owner share calls check the iCloud account; Rejoin is not offered into a share
  with a blocked person on it (an unreadable share only when nobody is blocked); member counts skip leavers; the close handshake
  refuses a second tap, and Home's prompt waits for the server's word on the
  link; recovery passes coalesce; launch re-sends a receipt retraction; the
  widget tip counts Lock Screen widgets only; text colours are AA-safe in dark
  mode too; CI pins Xcode 26, gates test-target warnings and checks untracked
  project files.
- **Audit fixes (round six)** — from a full-codebase audit. Invite link:
  Settings' close now re-seats a joined partner behind a confirmation (the
  handshake was Diagnostics-only), a failed close retries its reopen and says
  honestly whether it worked (`SyncError.inviteLeftClosed`), and Settings can
  reopen the link. Renames no longer restamp what the words mean
  (`StatusPayload.wordsSince`, local only): reports, celebrations, receipts,
  history and the card's time key on `wordsAt`; the log records exactly the
  statuses it's missing (`Snapshot.myStatusLoggedAt`). Status, nudge and
  anniversary saves are change-tag checked, so the conflict retries run.
  Everything ingested is bounded (invariant 23: `TrustedTime` caps dates to
  the server's clock, text/waveform/count caps), stored future marks heal,
  the moment cap never drops a pending send, and an unreadable index is
  neither overwritten nor pruned against. Locked-phone status pushes no longer
  announce the previous status; the NSE claims nothing once out of time; a
  late or repeated nudge can't break through Focus; "Reply with a status"
  needs Face ID; a moment re-posted over a generic banner is silent. The
  give-up rule counts only unlocked app refreshes; the latest thumbnail is
  re-fetched if its download failed; images decode with a size cap; the
  gallery marks photos seen when shown and memos when played; the anniversary
  prompt waits for open sheets and counts days across daylight saving;
  bootstrap watermarks only move forward; a lock-screen heart that times out
  shows as failed; the widget's backoff returns to hourly after two hours and
  kinds share a fetch. No schema changes. A review of the round fixed its own
  regressions: re-picking the same status no longer reads as a rename; the
  clock allowance is a day, not five minutes (clocks set ahead split history
  and receipts); own records aren't text-capped; the first rename after
  upgrading doesn't log; conflicts retry up to three times, wrapped or bare;
  one extension batch no longer suppresses the widget's next fetch; the
  anniversary prompt's sheet flag can't stick; the invite-close error says the
  partner may need to re-tap; widget retries are 10/20 min for budget; a stuck
  moment floor still blocks old moments.

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
  an encrypted seen-map; receiver publishes via `Outbox.flushReceipts`, sender
  folds it into `Moment.seenByPartnerAt`. Eye badge in the library, "Seen …"
  line in the gallery. **Schema: the `Receipt` record type must exist in
  Production before release** (README → "Shipping it").
- **Waveform scrubbing** — swipe across any playback waveform to seek
  (`ScrubbableWaveform` + `VoicePlayer.seek`); scrubbing an idle memo starts it
  from that point.

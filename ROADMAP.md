# Roadmap

What has shipped is in [CHANGELOG.md](CHANGELOG.md). Re-ranked October 2026 by
impact and feasibility; within each section, the first item is the one to pick.

- **Effort:** S = hours, M = days, L = a week+.
- **Impact:** ★★★ changes how the app feels day to day · ★★ noticeable to most
  pairs · ★ polish, or matters to a few.
- **Research:** 🔬 an open question to settle (with how to probe it) before
  committing · ✓ probed October 2026, findings inline.
- **Schema:** any new CloudKit field or record type needs a Production schema
  deploy (README → "Shipping it"). Batch them: see "The next schema release".

## Read first: how a feature reaches the other phone

Every feature that crosses phones rides one of these carriers, and the carrier
decides how intrusive it is. Choose it before designing anything else.

| Carrier | Push? | Arrives | Good for |
|---|---|---|---|
| `Status` record | Always, visible. The NSE can make it quiet (`.passive`, no sound) but **can't drop it** — no notification-filtering entitlement | Seconds | Things the partner should see now |
| `Nudge` / `Moment` record | Always, visible, with sound | Seconds | Hearts, photos, memos |
| A record type with **no subscription** (like `AnniversaryRequest`, `Receipt`) | Never | At the next refresh anywhere: app open, any other push's NSE pass, or the widget's timeline (hourly when settled, `WidgetReloadPolicy.settled`) | Ambient, no-rush things |
| A new record type with a **silent** (`content-available`) subscription | Invisible; wakes the app in the background when iOS allows | Seconds when allowed; iOS throttles background pushes to about two or three an hour (✓ Apple's "Pushing background updates") and drops them after a force-quit; otherwise the next refresh | Ambient state that's nicer fresh but fine late |
| Local only | — | — | Suggestions, reminders, memories |

Two consequences shape the ideas below:
- **Anything added to `Status` notifies on every change.** A battery slider or
  a "free" toggle on `Status` would leave a quiet notification each time it
  moves. Those belong on a new **`Presence` record** (one per side,
  `presence-<role>`, every field encrypted), which several ideas below share:
  social battery, free to talk, local time, the candle, goodnight together.
  Recommended carrier: a silent subscription, so it's usually fresh, with
  the next refresh as the fallback.
- **"Both of you did X" moments are judged on each phone.** When a phone
  notices the mutual state (in its refresh, or when its own user acts), it
  posts its *own* local notification. Neither phone ever has to push the
  other. The second person to act hears about it at once; the first hears
  when the silent push or their next refresh arrives — fine for "goodnight",
  too slow for anything that must be simultaneous (see "hold hands").
- ✓ **Push facts (October 2026):** CloudKit sends at high priority only when a
  subscription sets `alertBody`, `soundName` or a badge (ours do); APNs is
  best effort, may reorder, and keeps only one notification per app for an
  offline device; CloudKit coalesces and "excludes the device where the change
  originates". No latency figures are published — measure before relying on
  seconds.

## The next schema release

One Production deploy for all of these, in Development first (README →
"Shipping it", steps 2–3; each field's encryption is fixed when it's created):
- **`Presence` record** (new type, silent subscription): `battery`,
  `freeUntil`, `timeZone`, `candleUntil`, `goodnightAt`, `togetherAt`,
  `togetherWhat` — all encrypted.
- `Status`/`StatusLog`: encrypted `expiresAt` (expiring statuses).
- `Nudge`: plaintext `burst` (super nudge).
- `Moment`: encrypted `revealAt` (time capsule, send for the morning), `bpm`
  (heartbeat, if it passes review).
- New no-subscription types as their features are picked: `Whisper`, `Ask`,
  `Letter`, `JarSlip`, `SomedayItem`, `Answer`, `FridgeStroke`.

Older builds ignore fields they don't read; a new moment kind shows as
`Moment.Kind.unsupported` ("update to see this").

---

## Tier 1 — next: high impact, ready to build

### Pause notifications for a while (S) ★★
Per-kind levels shipped in 1.6.1 (`NotificationPreferences`: sound, silent,
list only). Left: a temporary override on top — "quiet everything for an hour"
or "quiet hearts until tonight" (the arena review's "quiet nudges for a
while"). A `pausedUntil` in the same per-device preferences, read by
`level(for:)`, so the NSE and the app's posts honour it with no new path. No
schema.

### Expiring statuses (M) ★★★
Raised independently by all three October reviewers. "In a meeting until 3",
"driving · 30 min": the picker offers "for 1 h / until tonight / until I change
it". After `expiresAt`, the card, widgets and history show it dimmed ("was …"),
and the widget timeline gets an entry at the expiry instant. Receivers decide
locally.
- Schema: encrypted `expiresAt` on `Status` (and `StatusLog`), capped through
  `TrustedTime`, hand-written Codable fallback `nil`. The anchor of the next
  schema release.

### Presence, part 1: social battery and free to talk (S–M) ★★★
The first `Presence` features (see "Read first"), and the best fit for "less
intrusive": each person says how open they are *before* anyone reaches out.
- **Social battery** — one slider, 🔋 full to 🪫 drained, drawn as a ring on
  the partner card and around the emoji on the status widgets. Sets
  expectations ("don't expect much tonight") without words. Silent.
- **Free to talk** — a toggle with a duration (30 min / 1 h / until I turn it
  off) that puts a green dot on the partner's Lock Screen widget. When both are
  on, each phone posts its own quiet "You're both free right now" (judged
  locally, see "Read first"). Nobody has to ask first. Pairs with a "call"
  button on the partner card (`facetime://` or `tel:`, from a number they
  choose to share — design question).
- How: `Presence` record, silent subscription, app and widget read it from
  `Snapshot`. The widget timeline gets an entry where `freeUntil` ends.
- Open question: whether the battery should decay ("charged 6 h ago") or stay
  until changed. Recommendation: stay, show its age.

### Set status from Shortcuts, Focus and Siri, plus a quick-status widget (S–M) ★★★
A parameterised `SetStatusIntent` (an `AppEntity` over presets and Recent) as
App Shortcuts and a `SetFocusFilterIntent` ("Sleep Focus → 😴"), Siri read-back
("What's Sam up to?" through the moderation helpers), and an interactive widget
whose buttons are your recent statuses. Publishes through the existing offline
queue; on failure the widget leaves `myStatusPublished` down for the app's
republish. No schema.
- ✓ Probed: App Intents get about 30 s (an Apple engineer: "30 seconds of CPU
  runtime… network requests… should be fine"), so one CloudKit save fits.
  - **Shortcuts and Siri** run in the app: no new target.
  - **Interactive widget buttons** run in the widget extension and reload its
    timeline when `perform()` returns. iOS may suspend the extension mid-request
    — hold an expiring activity, as `CrossProcessLock` does. On a *locked*
    phone, widget buttons are inactive until the person unlocks, so the
    quick-status widget always saves unlocked (its encrypted fields are safe).
  - **The Focus filter** runs `perform()` only for Focuses the user added the
    filter to, and needs a new **App Intents extension** target to run while the
    app isn't (Apple's sample) — iCloud and App Group entitlements, so invariant
    12 applies. It never learns the Focus's name, only its parameters ("set
    this status", "share that I'm silenced"). iOS 18 had reports of it not
    firing in the background (FB14715113).
- 🔬 Still to probe: the Focus filter extension cold-launched on a **locked**
  phone — it writes a status's *encrypted* fields, and this app already sees
  extensions read encrypted fields as empty while locked; whether the save
  works is unproven. Fallback: queue it in the store and let the app or the
  next unlocked refresh publish it (`myStatusPublished` down).

### Super nudge — escalate when they spam the heart (S–M) ★★
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
- Schema: one plaintext field on `Nudge` (next schema release).

### "Me too" (S) ★★
One tap on the partner card to take their status as your own ("😴 too").
Answering becomes a single tap with nothing to write.
- How: `setStatus` with their emoji and words (moderated: a filtered or
  reported status can't be copied). It's a normal status, so it notifies them
  like any other — that's the reply.
- Optional later: show the two cards as linked ("both sleepy") with a
  plaintext `echoes` field on `Status`; the first version needs no schema.

### One-tap banner replies (S) ★★
Next to today's heart-back and typed reply: chips such as "❤️", "😂", "📞 later"
that set a short status or send a heart from the banner without opening the
app.
- How: more `UNNotificationAction`s on the existing categories
  (`NotificationManager`), handled in `AppDelegate`'s banner-action path,
  which already wakes the app and awaits the send. No schema.
- Limit: iOS shows only a few actions on a long-press; pick three.

### Delete your own moment (S) ★★
The gallery menu exists only for the partner's moments. Own deletion is one
record delete (`moment-<role>-<uuid>`) plus the local `MomentIndex.remove` +
`MomentStore.delete` the deletion mirror already runs on the other phone; the
snapshot's derived fields recompute via `refreshDerived`. Confirm first — it
deletes on both phones. Unblocks "storage steward" and makes "undo" mostly
unnecessary.

---

## Tier 2 — soon: strong, needs one design decision or a small probe

### Presence, part 2: the candle, goodnight together, their local time (S–M each) ★★
Same `Presence` record as part 1; each is a field and a bit of UI.
- **Light a candle** — on a hard day (an exam, a hospital visit, a long shift),
  light a candle that burns on their Lock Screen widget for a few hours and goes
  out on its own. "I'm with you" without needing a reply. A widget timeline of
  a few frames (the flame shortening) up to `candleUntil`. Lighting it should
  reach them promptly; decide whether it rides the silent presence push (may
  arrive late) or also sends a quiet banner ("Sam lit a candle for you") —
  recommendation: a quiet banner, as it's rare and meaningful.
- **Goodnight together** — tap "🌙 goodnight". Once both have (within the same
  evening), each phone posts its own soft "you both said goodnight". No
  streaks, no counters.
- **Their local time** — "11:40 pm for Sam" on the partner card, so you can judge
  the moment before sending. Encrypted `timeZone`, written whenever it changes.
- **Under the same sky** — the widget's background follows *their* sky (dawn,
  day, dusk, night) from that time zone. ✓ No API maps a time zone to
  coordinates or sunrise (`TimeZone` has none; WeatherKit's `SunEvents` needs a
  location), so use their local clock's hours — approximate, honest, no location.

### At the same time (S–M) ★★
"Let's both look at the moon at 9 pm." Each phone posts its own gentle local
notification at that moment: a shared moment across distance, no live
connection.
- How: the invitation rides `Presence` (`togetherAt`, encrypted `togetherWhat`)
  or a small no-subscription record; whichever phone sees it schedules its own
  local notification, the sender's at once. Times in the past or more than a
  week out are refused.
- Limit: a silent push can arrive late, so the picker asks for at least an
  hour's notice, or the invitation also sends a quiet banner.
- 🔬 Shared with "send for the morning": scheduling the local notification from
  the NSE needs a prototype; the app scheduling it on its next run is the
  fallback (fine with an hour's notice).

### A gentle ask (S) ★★
"Would love an update": no buzz, just a small "?" on their widget and partner
card until they next set a status.
- How: an `Ask` record (no subscription), the same shape as
  `AnniversaryRequest` — participant or owner writes their own, the other side
  shows it until a status set after it. Arrives at their next refresh, which is
  the point.

### "Sam peeked" (S) ★★
Your widget quietly shows "💭 Sam looked at your photo · 3:12 pm" or "saw your
status". Looking becomes a message, with no notification.
- How: the data already exists — `Moment.seenByPartnerAt` and
  `Snapshot.myStatusSeenByPartner` from read receipts. Mostly widget layout
  (which line wins: your status or the peek).
- Limits: receipts have no subscription, so a peek shows at the next refresh
  (hourly at worst); only while both have read receipts on.

### "Open when…" letters (M) ★★
Notes written ahead ("open when you can't sleep", "open when you miss me")
that stay sealed in the other person's app until *they* choose to open one —
the least intrusive message there is.
- How: a `Letter` record (no subscription; encrypted `prompt`, `body`, optional
  media later). A "Letters" shelf in the app; opening one stamps the receipt so
  the writer sees "opened". Client-enforced seal, fine for this.
- Design: can a letter be edited or withdrawn before it's opened? Recommendation:
  yes, the writer owns the record.

### Whisper — a send that doesn't buzz (S–M) ★★
A note, photo or memo marked "no rush". It never pushes; it arrives on the
widget's next refresh or the next app open.
- How: a `Whisper` record type with no subscription, or a "no rush" variant of
  `Moment` whose banner the NSE makes `.passive` (a plaintext flag, as the NSE
  must read it while locked). The second reuses the whole moment pipeline but
  still shows a quiet notification; the first is truly silent. Recommendation:
  the record type, sharing `Moment`'s media handling.

### Time capsule and "send for the morning" (M) ★★
- **Time capsule** — an encrypted `revealAt`: a sealed tile with a countdown,
  the NSE saying "sent you something for <date>", a local notification on the
  day. Client-enforced — fine for a gift, not a secret.
- **Send for the morning** — the same field set to 8 am in the receiver's time
  zone (from `Presence`): it arrives quietly now and chimes then.
- 🔬 Scheduling the later local notification from the NSE: `UNUserNotificationCenter`
  is documented for "your app or app extension" and `add(_:)` from an NSE has
  been used, but Apple neither endorses nor forbids it (another extension type
  failed with Cocoa error 4099). **Probe:** in the NSE, `add` a calendar-trigger
  request before calling the content handler, await it, log the error, and
  check it fires on a locked phone. **Fallback:** the app schedules it on its
  next run, and the banner says "for tomorrow morning" meanwhile.
- Budget: iOS allows 64 pending local notifications per app, shared with
  milestone reminders (up to 12); cap capsules accordingly.

### Statuses that suggest themselves (S) ★★
Recent statuses ranked by time of day and weekday ("☕️" at 8 am, "🚗" at 5:30
pm), on device from the status log, so the most common send is one tap. No
schema.

### On this day (S) ★★
A quiet Home card (and optionally a widget state) for both: the photo you
shared a year ago today. Starts a conversation without either of you having to.
Local only, from `MomentIndex`; respects reported/hidden moments and the fresh
start's `clearedBefore`.

### Warm acknowledgement (S–M) ★★
Double-tap a photo or status for a quiet "💛 loved this" next to "Seen".
- How: one encrypted map in the `Receipt` record (no subscription, no push),
  so it avoids what sank reactions in September (their own subscription and
  removal pushes nobody could suppress).
- Design: one gesture, one reaction — no emoji picker.

### Draw on their photo (S) ★★
Gallery menu "Draw on this" opens the composer with the partner's full image
(`ensureMedia` first) under `DrawingController.render(over:)`; sends a normal
photo moment. No schema.

### Control Center / Action button heart (S) ★★
A `ControlWidget` (iOS 18, `@available`-gated) over `SendNudgeIntent`, showing
the slashed heart from `lastNudgeFailedAt`. No schema.
- ✓ Probed: runs in the widget extension like `SendNudgeIntent` (about 30 s);
  `StaticControlConfiguration` with a value provider reads the App Group, so the
  slashed heart works. Controls can't be reloaded by a push without our own
  server, so the app and NSE call `ControlCenter.shared.reloadControls(ofKind:)`
  after a heart's outcome. `privacySensitive()` hides state while locked.

### Library grouped by day, and search (M) ★★
`StatusHistoryView.byDay` already does the grouping; the moment library is a
flat grid. Sections by day plus a caption/sender search field.

### Status history: report from the sheet, and live refresh (S) ★
`StatusHistoryView` loads once (`.task`) and offers no report action; a status
that lands while it's open doesn't appear, and reporting means backing out to
the home card. Reload on `pairingDidChange`, add "Report…" to partner rows
(reuses `reportPartnerStatus` for the current one; older entries need the
report to carry the entry's `at`).

### Send the queue while the app is suspended (M) ★★ — open question
Offline sends go on the reconnect refresh, but `NWPathMonitor` only runs
while the app does: send offline, lock the phone, regain signal, and nothing
leaves until the app is next opened. Options: a `BGAppRefreshTask` scheduled
on backgrounding whenever `pendingSendCount > 0` (needs the `fetch`
background mode and `BGTaskSchedulerPermittedIdentifiers`; iOS runs it at
its own discretion, often within the hour for an app used daily, never
guaranteed), or a `BGProcessingTask` with `requiresNetworkConnectivity`
(runs later still, usually idle/charging). Either runs `refresh()` + the
recovery pass under the existing upload protection. Long-lived CloudKit
operations don't solve this — they don't wait for a connection — though
moment uploads already under way are long-lived, so one in progress
finishes in the background.

### Moments on weak signal — next steps (M each) ★★
Uploads give up only when stuck, run long-lived, and retry smallest first
(October 2026). Not picked yet:
- **Thumbnail first.** Save the moment with only its ~50 KB thumbnail so the
  partner sees it at once, then add the full photo as an update of the same
  record. Needs a receiving-side "full photo still on its way" state (gallery,
  widget, `MediaPrefetchPlan`), a re-fetch once the photo lands, and a check
  that `requeueMissingUploads` and the fresh start's purge treat a
  thumbnail-only record as sent. The update fires the subscription again;
  `claimMomentBanner` already keeps that quiet.
- **Smaller photos on a poor network.** Encode at ~1280 px when the path is
  constrained (Low Data Mode) or recent sends failed — roughly 3–4× smaller —
  at the cost of permanent quality unless paired with an upgrade later.

### Finer detail in doodles: pinch to zoom (S–M) ★★
A fingertip covers too much of a 362 pt canvas for small writing. `PKCanvasView`
is a scroll view with zoom built in: two fingers zoom/pan, one draws; the
2048 px export has ~5.7× headroom. Two traps: the photo must move *inside* the
canvas's content so it zooms with the strokes, and `DrawingController.render`
exports `canvas.bounds` — under zoom that's the visible region, so export the
fixed content square instead or strokes land misaligned. Replaces the
`SheetDragBlocker` (the canvas's own two-finger gestures then win). After,
trace strokes over a grid photo and measure the sent JPEG in the App Group's
`Moments/` — that file is exactly what the partner downloads. (Other doodle
options are in Tier 3.) Checked September 2026: strokes already reach the
partner pixel-aligned with the photo.

### Privacy lock (S–M) ★★
Optional Face ID gate on launch, app-switcher blur, `.privacySensitive()` on the
status widgets' text and an optional "hide when locked" for the photo widget.
No schema.

---

## Tier 3 — later: bigger builds, or narrower impact

### Countdown status (M–L) ★★
A status that counts down to a date — "see you in 12 days" — on the other
phone, with a celebration on the day; also the long-requested shared countdown
Lock Screen widget. Shelved from the celebration round (October 2026); design
to come. Likely an encrypted `countdownTo` on `Status` (next schema release).

### Weekly recap card (S) ★★
Sundays on Home: hearts, statuses, photos and memos this week, from the local
stores (nudge totals need a weekly baseline in `Snapshot`). No schema. Keep it
warm, not a scoreboard — no comparisons between the two of you.

### Daily question (M) ★★
One gentle prompt a day ("Best bit of today?"); each answer stays sealed until
both have answered. A reason to write something without starting a
conversation. `Answer` records (no subscription; encrypted), prompts bundled
locally and picked by date so both phones agree. Client-enforced seal.

### Tap a rhythm (M) ★★
Tap a pattern on the heart; their phone plays it back as haptics
(Digital Touch-style) — wordless and more personal than a heart. Recording tap
timings and playing a `CHHapticPattern` in the app is straightforward: a new
moment kind (or an encrypted pattern on `Nudge`), played when they open it.
- ✓ A notification can't carry a haptic: `UNNotificationSound` is the only
  sensory payload, and the vibration is the user's setting. So the banner gets
  the standard buzz and the rhythm plays when the partner opens it in the app.
- 🔬 Playing it from the expanded notification needs a new Notification Content
  Extension target, and Apple doesn't document Core Haptics there (the engine
  stops when backgrounded and system haptics can override it). **Probe:** a
  content extension starting a `CHHapticEngine` from an interactive button,
  locked and unlocked. Ship the in-app version first.

### The jar (S–M) ★★
Each of you drops in small slips over time ("the way you laugh at your own
jokes"); the other draws one at random whenever they like. `JarSlip` records,
no subscription; drawing stamps the receipt so the writer can see it was read.

### The fridge door (M–L) ★★
One shared doodle canvas on both home-screen widgets, added to whenever, no
notifications. Each side's strokes in its own `FridgeStroke` record so they
never conflict. Widget render cost (PencilKit drawing to an image per
timeline) and a "wipe the door" ritual need design.

### Song of the moment (M) ★★
Share what you're listening to: album art on their widget, a tap plays it in
Apple Music. A new moment kind carrying the catalog ID.
- ✓ Probed: enable the MusicKit App Service on the App ID (automatic developer
  token) and `NSAppleMusicUsageDescription`; catalog search works without an
  Apple Music subscription (iOS 15+) but needs the sender's MusicKit consent
  and an Apple ID. Store the catalog ID *plus* title, artist, artwork URL and
  `Song.url`, and download the artwork into the App Group like other media —
  then the receiver needs no MusicKit and the widget draws a plain image. The
  current song is readable only from Apple Music (`SystemMusicPlayer`), not
  Spotify; the system music picker is iOS 27+.
- 🔬 Still to probe: whether catalog artwork URLs stay valid on the other phone,
  and what a non-subscriber sees opening the link. **App Review 4.5.2(ii):**
  cover art only "in connection with music playback" — label it "Listen in
  Apple Music" and follow the Apple Music identity guidelines.

### Voice-memo transcripts (M) ★★
On-device Speech under the waveform, as the banner body without a caption, and
for VoiceOver. Receiver-side transcription needs no schema; an encrypted
`transcript` field would.

### Someday list (M) ★
A shared list of things to do together; adding to it is a low-key "I want
time with you". Each item is its author's `SomedayItem` record; ticking off the
partner's item needs a `done` marker in your own record (each side writes only
its own records). Silent adds.

### Soundscape (S) ★
Ten seconds of where you are (rain, a café, the sea), no talking: shares the
moment without performing for a memo. A voice memo with a "just listen"
presentation and a loop; a new moment kind or an encrypted flag.

### Remove a stranger without deleting the space (M) ★
The "someone else has joined" card can today only say "unlink". Offer the owner
a confirmed `removeParticipant`, choosing from the share's participant list
(names from `userIdentity`) — not "the author of `status-participant`", which
both participants write. Manual and confirmed only (invariant 9). No schema.

### Storage steward (M–L) ★
An estimate of the shared space's size from locally recorded asset sizes and an
explicit, opt-in "make room" that drops old full-size media but keeps thumbnail,
caption and record. Depends on "Delete your own moment" and changes the
complete-history promise (copy). Optional plaintext `bytes` on `Moment`.

### Alternate app icons (S) ★
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
- Per device, not synced. No schema.

### Scheduled Summary friendly (S) ★
`relevanceScore` and steady thread IDs from the NSE, plus a Settings line
saying the app can go in Scheduled Summary.
- ✓ A weak lever: `relevanceScore` only orders this app's notifications within
  a summary (developers report it's often ignored); an app can *read* whether
  it's scheduled (`scheduledDeliverySetting`) but not change it; `.passive`
  never escapes a summary. Worth it only as a Settings hint when
  `scheduledDeliverySetting` is on.

### Undo for five seconds (S) ★
Hold a moment's upload behind an "Undo" toast. Mostly superseded by "Delete
your own moment"; worth it only if people send by accident.

### Camera follow-ups (S each, except where noted) ★
- **Lock Screen camera (M–L):** a `LockedCameraCapture` extension (iOS 18)
  plus a Lock Screen/Control Center control, so the Camera Control or a lock
  screen button opens straight into a moment. New target, entitlements and a
  hand-off of the captured photo to the app on unlock.
- **Back-camera timer cue:** blink the torch through the countdown, like the
  system camera, for a phone propped up facing away.
- **Night mode:** revisit each WWDC; no third-party API as of iOS 26.

### Finer detail in doodles: the other options (S–M each) ★
After pinch to zoom (Tier 2), roughly in order of value:
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

---

## Tier 4 — research first: promising, feasibility unproven

### Their Focus on the partner card (S–M) ★★ 🔬
"Notifications silenced" next to their local time, like Messages, so you know
before you send. Published into `Presence`.
- ✓ Probed: `INFocusStatusCenter` reports only `isFocused` (no name), and is
  built for exactly this sharing ("communicate to others that the user is
  focused or not" — an Apple engineer). It needs the Communication
  Notifications capability, notification permission,
  `NSFocusStatusUsageDescription`, the user's "Share Focus Status" setting, and
  a **SiriKit Intents extension** (a fourth target) handling
  `INShareFocusStatusIntent` to hear changes in the background.
- **Cheaper route (recommended):** reuse the Focus filter from "Set status from
  Shortcuts, Focus and Siri" — a "share that I'm silenced" parameter writes
  `Presence` when the Focus turns on or off. Same App Intents extension, no
  Communication Notifications capability, and the user picks which Focuses
  share. 🔬 Whether App Review allows the Communication Notifications
  capability for a non-messaging app is unknown — another reason to prefer the
  filter.

### Hold hands (M) ★★★ 🔬
Both press and hold the heart within the same short window, and both phones
give a long, soft vibration: "you're holding hands". It only happens when both
reach out, so nobody is interrupted.
- ✓/🔬 Probed: our pushes go at high priority (they carry `alertBody`), but
  Apple publishes no latency figures; APNs is best effort and CloudKit
  coalesces. So **judge the window by server time, not arrival**: each press is
  a record (on `Nudge`, so it pushes visibly); the second presser's NSE sees
  the first press's `modificationDate` within N seconds and fires at once; the
  first presser waits only on the second's push. The buzz is the normal alert
  vibration (no custom pattern, see "tap a rhythm"); `.timeSensitive` to break
  through Focus. **Probe:** measure save-to-NSE time on two phones across
  Wi-Fi/cellular, locked, Low Power Mode and Focus before choosing N.

### Wake up to their voice (M) ★★ 🔬
Record a "good morning" the partner can choose to set as tomorrow's alarm sound.
- ✓ Probed, feasible with caveats (iOS 26+ only): AlarmKit plays a named sound
  from the app bundle or the app's *own* `Library/Sounds` (not the App Group,
  so the memo is copied and converted there), under 30 s, `.caf` safest. It
  breaks through Silent mode and Focus. Needs `NSAlarmKitUsageDescription` and
  the receiver's per-app permission; the receiver chooses to set the alarm.
- 🔬 Risky: Apple acknowledged a custom-sound bug ("being fixed in iOS 26.1"),
  and developers still report `Library/Sounds` files falling back to the
  default sound in 2026; no confirmed success for a runtime file. **Probe:** a
  runtime-written 20 s `.caf` in `Library/Sounds`, scheduled from the app, on
  the current iOS. Frame it as an alarm the receiver sets, never as a way to
  ping them (App Review would read that as misuse).

### Record a memo from the Action button or Control Center (M–L) ★★ 🔬
Make a voice memo as quick as the heart.
- ✓/🔬 Probed, unclear: `AudioRecordingIntent` must start a Live Activity and keep
  it running while recording, which an intent may start locally
  (`LiveActivityIntent`, no push). But developers report starting from the
  Action button or a Shortcut fails with "Target is not foreground", and
  Apple has long said background recording isn't generally allowed. **Probe:**
  an intent conforming to both, in the app target, with the microphone already
  granted and the `audio` background mode, fired from a control and the Action
  button with the app killed. If it fails, the control can only open the app
  straight into the recorder — still one tap fewer than today.

### Heartbeat moment (M) ★★ 🔬
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
- **🔬 App Review risk — decide before building.** Guideline 5.1.3 says HealthKit
  apps "may not store personal health information in iCloud"; an encrypted
  BPM in a CloudKit record is arguably that. Defence: the field is encrypted
  like every other user word, and the review notes describe it as a tempo for
  a haptic pattern, not health data. If that's not acceptable, the fallback is
  "tap a rhythm" above, without HealthKit.
- **Later:** a live session (watchOS target running a workout-style session
  for 1 Hz readings → WatchConnectivity → an ephemeral CloudKit record,
  deleted when the session ends) on top of the same "feel" screen; and if the
  partner also wears a watch, an extended runtime (mindfulness) session can
  tap the wrist with the screen off. Both need both people present at once.

---

## Correctness and robustness — ranked

Ranked by harm: data loss and trust first. Numbers like #5 are the September
2026 audit's.

1. **#5/#6 A modified partner client can delete or take over your moments** on
   your phone (deletions under either role's name; index keyed by id alone),
   and record names are trusted for authorship. Needs a creator check. (M)
2. **#7 Owner-side block isn't enforced**: an offline block leaves the share
   up, Rejoin reconnects to the blocked person, and a blocked ex can join the
   next link. (M) Includes **"an offline block should still remember the
   partner"**: `recordBlockedPartner` needs the share's participant list from
   the network, so an owner who blocks offline records nobody; cache the
   participant record names on each successful refresh (or `shareCheck()`). (S)
3. **Statuses set while offline only log the last one** (S). Set A then B
   offline: the reconnect republishes `mine` (B) and logs B, so A stays in this
   phone's `StatusHistoryLog` but never gets a `StatusLog` record — the
   partner's history skips it and a reinstall loses it. Fix: a local-only
   "unlogged" mark on own `StatusHistoryEntry`s and a capped republish of their
   `StatusLog` records.
4. **#14 A failed account lookup at pairing** leaves `userRecordName` nil, which
   disables the different-account guard for good. (S)
5. **An anniversary save or delete abandoned at its deadline** can land after a
   newer edit (a late delete removes the new date on both phones). (S)
6. **A replaced zone keeps its zone ID**, so a partner rejoining it skips the
   media wipe (`adoptPairing`'s `lastPairing.sameZone`) and re-sends unsent
   media from the old space. Same after an owner unlink and re-invite. (S)
7. **Re-seat and zone-gone** (S): the 120 s zone-gone window is justified by
   "ten seconds", but a re-seated partner is off the share until they re-tap.
   Show "tap the link once more" while `zoneGoneSeenAt` is set; reword
   `linkEnded` when `lastPairing` is kept; pass `rejoining: true` in
   `acceptShare` for the same zone (#25); clear the change tokens *before*
   erasing media in the wipe; let extensions only stamp the sighting.
8. **Pairing edge cases** (S–M): #24 a join that half-fails leaves the join
    screen over a paired app; #25 re-accepting the same zone posts "👋 just
    joined"; #26 the owner's `sameZone` check is always true; #27 zone-recovery
    edge cases (token-expired retry skips the second-sighting rule;
    `unknownItem` counts as zone gone; unpair ignores the per-zone result); #42
    Rejoin picks the first shared zone.
9. **A successful status publish clears the full-iCloud back-off** even if a
    photo still can't fit. (S)
10. **Store I/O and `flock` waits run on the main actor** from `CloudSync`; now
    that the stores are `Sendable`, drop the `MainActor.run` hops (profile a
    resync). (S)
11. **One shared `isBusy` spans nine overlapping operations.** (S)
12. **The lock-screen heart's account lookup** still precedes its write when the
    shared cache is stale (`sendNudge` → `requirePairing`); running it alongside
    the record fetch needs a `saveNudge` restructure. The app's own refresh can
    still request two widget reloads (apply, then the media prefetch's). (S)
13. **Review notes (September 2026):** a new moment found by a background
    refresh goes out passive if an *older* generic/held moment banner is still
    in Notification Centre (stamp the moment id to match exactly); a
    lock-screen heart whose save lands after the 8 s deadline shows as failed
    although it sent (the trade for never showing a failed one as sent). (S)
14. **The status read receipt** is forward-only by the words' date; after a
    partner's clock ran ahead, a later status with an earlier stamp isn't
    stamped "seen" until the stored stamp is in the past (rare; would need a
    local-only order key on `StatusSeen`). (S)
15. **Fresh start follow-ups** (shipped October 2026; left on file):
    - Verify on the live service, as for the invite handshake: that
      `lastModifiedUserRecordID` names this account (`__defaultOwner__` or its
      own record name) on both databases, so a second device trusts its own
      record. If it doesn't, a second device with an old index still filters
      (the partner's half and `clearedBefore` from the agreement), but won't
      purge.
    - A partner who never opens the app again leaves their half in the zone
      (and in the owner's storage). Each phone hides it; deleting the other
      side's records would undo the creator-check direction (#5/#6). Unlink
      settles it.
    - The asker's archive is taken just before the ask lands: a send in that
      window (an archive's length, normally seconds) is cleared without being
      in the asker's copy — it is in the agreer's, taken after the epoch.
    - A moment push that only carried deletions is reworded quietly by the NSE,
      never dropped (no filtering entitlement).
    - An older build on a second device of either person neither filters nor
      guards the requeue; after a full resync it could re-send cleared moments.
    - `requeueMissingUploads` judges a cleared send by its client `sentAt`, not
      the server time the cut uses: a second device whose clock ran ahead of
      the ask by more than the gap to a send could re-queue that one send after
      a full resync. The index would need each moment's server creation time.
    - Nothing clears until the asker's phone commits, and then this phone's own
      zone pass must finish before its copy is purged: Home and the widget keep
      the history until then (the sheet says "waiting"; a failing pass gets its
      own card). Extensions never purge.
    - Asks need a connection (an ask queued offline would move the epoch); the
      sheet says so rather than queueing.
16. **#21 remainder:** an own second device writing while this phone is locked
    is worded as the partner's (the held record can't be told apart). (—)
17. **CloudKit overhead leftovers** (S each): widget media in parallel
    (`prefetchMedia` fetches thumbnails, then the full photo, one after the
    other); a longer account cache in extensions (the NSE re-looks-up the user
    record once `accountCacheLifetime`, 5 min, passes — it overlaps the fetch, so
    this saves a request, not time).
18. **Coverage still missing (M):** `SharedStore`'s static locks still resolve
    the real container in tests (lock files only; inject a lock directory);
    `CloudSync` itself has no `CKDatabase` seam, so the per-zone fetch error
    path (#16 of the October review) and the CloudKit calls behind the pure
    policies are untested.

## Privacy, safety and App Review — ranked

1. **Decrypted JSON and media sit in device backups**: exclude the
   re-downloadable `Moments/` cache and say so in the policy. (S)
2. **Support is a personal Gmail** compiled into the binary: use a domain
   alias. (S)
3. **The privacy page loads Google Fonts**: self-host them. (S)
4. **Reports carry no evidence**: `report()` deletes the media before the mail,
   and `mailto:` can't attach. An in-app composer with the thumbnail
   snapshotted first. (M)
5. **An owner's unlink wipes the joiner's copies of their *own* sends**: offer
   "save what you sent" first — changes invariant 8's wipe scope, needs a
   decision. (M)
6. **#37 Diagnostics' "Copy report"** puts participant names/emails on the
    clipboard. (S)
7. **#36 Plaintext metadata**: memo durations, nudge counts, send times,
    receipt times (`kind` must stay plaintext for locked-phone banners). (—)
8. **#34 remainder**: the memories archive writes plaintext to iCloud Drive
    (it's an export; say so in the policy). (S)
9. **#33 The word filter misses** plurals, spaced letters, homoglyphs,
    leetspeak. (M)

## Polish, accessibility and copy — ranked

1. **Widgets** (S each): emoji-only statuses still print "no message"
   (STA-1's widget half); **WID-2** status age on the status widgets (live
   relative time on systemSmall, a coarse age on the Lock Screen, dimmed past
   12 h); **WID-1** the small status widget's heart shows sent/failed, bigger
   target.
2. **Contrast** (S): `.secondary` 11 pt captions ("Seen …", timestamps) are
   ~3.3:1; `mint` on cream is 2.2:1 for the "Saved" check.
3. **Dynamic Type** (S–M): `Theme.rounded` reads `UIFontMetrics` when a view
   renders and nothing re-renders on a size change (read
   `@Environment(\.dynamicTypeSize)` in a modifier or `@ScaledMetric`, then
   re-enable `.dynamicType` in `DemoSmokeTests`); the 1.35× cap also limits
   prose (Terms, Welcome, the partner's message); mood tiles are fixed-height.
4. **#38 Audio** (S): a playing memo bleeds into a new recording; closing the
   composer stops other audio; after granting the microphone the sheet must be
   reopened.
5. **Small UX fixes** (S each):
   - Mood picker "Set" is disabled with no hint when the emoji is empty.
   - Settings: "Report a problem" and "Save memories…" look like the
     destructive rows; "Report a problem" is a bare `mailto:` `Link` — a silent
     no-op without Mail; fall back to the clipboard like the report path.
   - The general `noticeMessage` alert is titled "Report copied" in `RootView`
     even though the channel is generic.
   - Voice Control: "Thinking of you" is labelled "Send a nudge".
   - Siri's "Send a nudge" while unpaired returns success silently
     (`SendNudgeIntent` swallows the error); a spoken dialog would be kinder.
   - The anniversary prompt stacks on the invite sheet before anyone has joined.
6. **FIRST-1** (S–M, from the October UX brief): the owner's first run one
   interruption at a time — the notification prompt after the link sheet, no
   date sheet before anyone has joined (a Home card once they have), and a
   "Waiting for your partner" card with the link. Not yet: the owner isn't
   ready to change first run.
7. **"Invite again" from the partner-left card** opens Settings (a new link
   needs the unlink first); a one-tap unlink-and-reinvite would need the unlink
   confirmation hosted on Home. (S)
8. **App Store link in the invite message** once the app's ID is known
   (`AppConfig.appStoreURL`). (S)
9. **Localisation readiness** (M): ~100 mood labels bypass the catalog and key
    `Mood.id` on English; ". Seen %@" fragment; "a \(noun)"; ternary plurals;
    locale-insensitive `uppercased()`; English `alertBody` (needs new
    subscription IDs); stale catalogs (last committed 2026-09-13).
10. **App tint** is `Theme.accentText` (AA crimson for text) app-wide, which
    also darkens toggle tracks and date-picker selection; revert the one line
    in `RedStringApp` if the brighter crimson is preferred there.
11. **UI audit exclusions** for screenshot-checked misreads (wrapped small
    text, the composer's "Camera", navigation-bar glass buttons): re-check on
    each new iOS/Xcode and drop the ones the audit stops raising.
12. **#43 remainder** (by design): in the hours before the start's time of day,
    the count's full-day number is one behind the date-based "months and days"
    (the counter ticks over at the start time).

## Docs and tooling (S each)

- Each invariant: one-line rule + "guarded by: `TestName`" or "unguarded".
- A CI step checking the `AppConfig` IDs against the four entitlements files,
  `project.yml` and `Info.plist` (invariant 12), and a grep for
  `.safeAreaInset(edge: .top)` in `Views/` (invariant 21).
- `make test`/`make build` regenerate the committed project as a side effect.
- CI: checksum the downloaded XcodeGen zip; the simulator picker sorts runtime
  names as strings.
- Dead code: `PairingView.inviteReady` (unreachable, hosts an unconfirmed
  unlink).

## Parked, considered and rejected

- **Reactions on a moment** (needs a `Reaction` record type + subscription).
  Built and removed in September 2026 — the UI never felt right; the sync
  design (one `reaction-<role>-<momentID>` record per person per moment,
  encrypted emoji, own subscription, removal pushes that can't be suppressed)
  is in the git history. The warm acknowledgement (Tier 2) is the receipt-based
  replacement.
- **Also considered:** heart variants (adjacent to super nudge; one plaintext
  Int on `Nudge`), an Apple Watch target (heartbeat already scopes it), a Lock
  Screen doodle glyph (legibility unproven).
- **Thumbnail inside the NSE's change fetch** — would save the banner a round
  trip, but puts media before the token (against invariant 2). Not recommended.
- **Old `StatusLog` entries** logged before the cloud log existed are local-only
  and don't survive a reinstall (documented; nothing to do unless it matters).
- **Rejected:** Live Activities started remotely (push-to-start needs a server),
  location sharing, view-once photos, `CKSyncEngine` (owns the change token,
  against invariant 2).

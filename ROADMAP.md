# Roadmap

Effort: S = hours, M = days, L = a week+. Any CloudKit field/record-type
addition requires re-deploying the schema to Production (README → "Shipping it").

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

### Status history phase 2 — durable log (M)

One CloudKit `StatusLog` record per status (like moments) if recover-on-reinstall
matters. Costs a record per status change; cap with periodic deletion. No new
subscription — entries ride the existing refresh.

### Also on file (from README "Possible improvements")

- Reactions on a moment (needs a `Reaction` record type + subscription).
- Shared countdown lock-screen widget.
- Status read receipts ("Seen 2h ago" under your own status) — the `Receipt`
  record already has room for a `statusSeenAt` field.

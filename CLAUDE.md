# Red String — agent guide

Two-person iCloud status app (iOS 17+, SwiftUI). One partner sets a status/nudge/photo/doodle/voice memo; it appears on the other's lock screen. No server: everything travels through CloudKit (a zone-wide `CKShare`), human-readable fields end-to-end encrypted via `encryptedValues`. Three targets: app, widget extension, notification service extension — all compile `Sources/Shared/`.

`README.md` is the deep reference (design rationale, pairing/share security model, shipping/CloudKit-schema steps, demo mode). Read the relevant README section before changing sync, pairing, or notification behaviour. `ROADMAP.md` lists planned features. This file is the quick map + the invariants that must not break.

Comment style: comments are deliberately lean — one or two lines carrying only the non-obvious constraint or "why". Don't add narrative comments, restate code, or document history; match the existing density.

## Build & run

- `RedString.xcodeproj` is **generated** from `project.yml` by XcodeGen (`make project`) but also **committed** (Xcode Cloud needs it). After adding/renaming files: `make project`, commit the regenerated project too. Never edit project settings in Xcode's UI — they're overwritten.
- `make build` = unsigned compile check (do not launch the product). `make run` = signed build + launch in Simulator. `make device`, `make archive` per README.
- Demo mode for screenshots/UI work: launch with `REDSTRING_DEMO=1` (Debug only) — stub backend + `DemoSeeder` content, no iCloud needed.
- No test target exists.

## Architecture (data flow)

```
UI (Views/) → AppModel (@MainActor, @Observable)
            → Backend.current (SyncBackend protocol: CloudSync actor, or DemoBackend)
            → CloudKit custom zone "CoupleZone", zone-wide CKShare

SharedStore (App Group, file-backed KV via GroupFileStore)  ← app / widget / NSE all read+write
  ├─ Snapshot        widget-renderable cache: both statuses, nudge watermarks, latest moments
  ├─ PairingInfo     role (owner/participant) + zone coords + account userRecordName
  └─ change tokens   per-database CKServerChangeToken

MomentIndex   moments-index.json in App Group — full history metadata (cap 500)
MomentStore   media files in App Group /Moments — JPEG full+thumb, .m4a (cache cap 60 newest;
              pending-upload media is never pruned)
StatusHistoryLog  status-history.json — local rolling log of both sides' statuses (cap 100)
SyncRunner    refresh → decide what to announce → NotificationManager (local notifications)
NotificationService  enriches CloudKit pushes: refreshes, decrypts, rewrites banner, reloads widgets
```

Key types: `StatusPayload` (one per partner, fixed record names `status-owner`/`status-participant`), `Nudge` (own record type so its push can be visible+sound), `Moment` (one record per item, name `moment-<role>-<uuid>`, kept forever — that's what makes history recoverable), `Receipt` (one per side, `receipt-<role>`: encrypted seen-map for read receipts, no subscription — arrives with any refresh). `PairRole` derives all record names; neither device ever needs the other's CloudKit user ID.

## Invariants — do not break

1. **Cross-process locking.** App, widget, and NSE run concurrently on the same triggers. Every read-modify-write of `Snapshot` goes through `SharedStore.mutate` (flock-based `CrossProcessLock`); `MomentIndex` locks likewise. Check-and-claim decisions (announce a nudge/moment, rewrite a banner) must happen *inside* one `mutate`.
2. **Apply before token.** `CloudSync.refresh` folds records into local state *before* persisting the change token. Reversing it loses records forever when the NSE is killed on deadline.
3. **Shared state lives in files, not UserDefaults.** `UserDefaults(suiteName:)` proved unreliable as an App Group channel (see `GroupState.swift`). Widget↔app data goes through `GroupFileStore` / files.
4. **Encryption boundaries.** Text fields (`emoji`, `message`, `displayName`, `caption`, `senderName`, `waveform`, `isCelebration`) go through `record.encryptedValues`. `CKAsset`s are encrypted by CloudKit automatically and must NOT go through `encryptedValues`. Adding a plaintext field that carries user words is a privacy regression.
5. **Hand-written Codable.** `Snapshot`, `StatusPayload`, `Moment` decode with `decodeIfPresent` + fallbacks so old on-disk data survives new fields. New persisted fields must follow that pattern (and consider what the fallback means for legacy data).
6. **Widgets reload via `SharedStore.reloadWidgets()`** after any snapshot/media change — but never from inside the widget process (guarded by `isRunningInWidgetExtension`).
7. **Cooldown claims before network.** `CloudSync.sendNudge` claims the cooldown inside the lock before the network call; a failure releases it and stamps `lastNudgeFailedAt` (the lock-screen heart's only error channel).
8. **Unlink is cloud-first.** `unpair()` must succeed before local state is cleared; `forceLocalReset` is the explicit escape hatch. "Zone gone" under a *different* iCloud account must never wipe local state (`SyncError.differentAccount`).
9. **Invite close is manual-only, and dangerous.** The share URL is a bearer token, but promoting a link-joined (public) partner to private evicted them from the share in Production (2026-09) — the atomic close+add landed with the partner surviving as neither. Auto-close (`closeInviteIfPartnerJoined`) is disabled; only the Diagnostics button runs `lockPairing`, whose promote-and-close save must stay a single atomic modify and whose failure path reopens the link. Do not re-enable auto-close (or run the promote from any passive path) without a conversion proven to preserve membership.
10. **Announcement dedup watermarks** live in `Snapshot`: `lastSeenPartnerNudgeCount`, `notifiedMomentIDs`/`lastNotifiedMomentID`, `lastAnnouncedPartnerStatusAt`, `lastCelebratedAt`. The NSE and app both advance them; nudge watermark moves with `max()`, never assignment.
11. **Offline sends recover, never silently drop.** Statuses: `Snapshot.myStatusPublished` + `republishStatusIfNeeded()`. Moments: `Moment.uploaded` + `retryPendingUploads()`. Both re-run safely (fixed record names / overwrite semantics). Media is written locally before any network call.
12. **`AppConfig` IDs must stay in lockstep** with the three entitlements files, `project.yml`, and `Info.plist` `NSUbiquitousContainers`.
13. **Read receipts are double-gated and sticky.** `readReceiptsEnabled` gates both publishing and display; `Snapshot.receiptsDirty` + `flushReceiptsIfNeeded()` is the retry loop (same shape as `myStatusPublished`), re-armed once per launch to heal misses; `MomentIndex.applyPartnerReceipts` never un-sees, and `MomentIndex.insert` keeps every local-only field (`seen`, `seenAt`, `seenByPartnerAt`, `uploaded`) sticky — a moment rebuilt from a CloudKit re-delivery carries none of them. Receipts fold into the index *after* a delta's moments are inserted. Disabling publishes an empty map.
14. **Status history is local-only and dedups by `(fromMe, updatedAt)`.** Written from `AppModel.setStatus` (own) and `CloudSync.apply` (both, any process); gaps are by design — never assume it's complete, and never sync it without a schema plan.
    **Persisted dates are whole seconds.** All App Group JSON encodes ISO-8601, which drops fractional seconds — a fractional `Date` never equals its own stored copy. `StatusPayload.updatedAt` is therefore truncated at creation (`AppModel.statusTimestamp`) and at CloudKit ingestion (`CloudSync.payload(from:)`); any new date used in an equality/watermark check must follow suit.
15. **Corrupt store files are preserved, not overwritten.** `SharedStore.decode`, `MomentIndex`, and `StatusHistoryLog` move unreadable bytes to a `.corrupt` sidecar before falling back to empty; the moment index also clears change tokens so CloudKit rebuilds it. Keep that pattern for any new persisted file.
16. **Publish-success flags must verify currency.** `markStatusPublished(payload)` only flips `myStatusPublished` if the payload is still the current status — a late-finishing publish must not mark a newer offline edit delivered.
17. **Scrub gestures need `.highPriorityGesture`** (`ScrubbableWaveform`): a plain `.gesture` loses to the gallery's paging TabView, and waveforms must not be wrapped in a `Button` (see `VoiceMemoRow`).
18. **Pin vertical-ScrollView content with `.containerRelativeFrame(.horizontal)`** (see `HomeView`). A child with a wide *ideal* size — a long single-line `Text` — can inflate the scrollable content's horizontal extent on some OS builds, letting the whole screen pan sideways; prefer `.fixedSize(horizontal: false, vertical: true)` on wrapping text too. (`WaveformBars` is safe: it condenses to what fits and never reports more than its measured width.)

## File map (one line each)

Shared/
- `AppConfig.swift` — all identifiers + tunables (cooldowns, cache limits, memo max length).
- `Theme.swift` — colors, card/button styles. `Waveform.swift` — level condensing for memo waveforms.
- `Models/StatusPayload.swift` — `StatusPayload`, `PairRole`, `PairingInfo`, `Snapshot` (the widget cache; read its doc comments before adding fields).
- `Models/Moment.swift` — moment metadata + presentation helpers. `Models/Mood.swift` — status presets. `Models/MomentAttachment.swift` — notification attachment factory.
- `Store/SharedStore.swift` — App Group KV + `mutate` + derived-field recompute (`applyDerived`) + `readReceiptsEnabled`. `Store/GroupState.swift` — file-backed store + one-time UserDefaults migration. `Store/CrossProcessLock.swift` — flock wrapper. `Store/MomentIndex.swift` — history JSON, seen/uploaded/receipt merging. `Store/MomentStore.swift` — media files, thumbnail cache (evicted on delete), prune (5-min grace; spares pending uploads via caller's keep-set). `Store/StatusHistoryLog.swift` — local status log.
- `Cloud/CloudSync.swift` — the CloudKit actor: pairing/share lifecycle, publish/refresh/nudge/moment, subscriptions, unpair. Largest and most safety-critical file.
- `Cloud/SyncBackend.swift` — backend protocol + `RefreshResult` + DEBUG `DemoBackend`. `Cloud/CloudDiagnostics.swift` — Settings→Diagnostics report.

App/
- `RedStringApp.swift` — scene phases, notification-center subscriptions, deep links (`redstring://compose|open`). `AppDelegate.swift` — push registration, scene delegate for share acceptance, `InviteInbox`, `Notification.Name`s.
- `AppModel.swift` — the app's single view model: derived accessors, lifecycle refresh, status/nudge/moment send paths with upload protection, invite management, unlink, archive.
- `SyncRunner.swift` — refresh + announce decisions. `NotificationManager.swift` — local notifications (moment/nudge, stale-nudge wording, generic-banner sweep).
- `MemoryArchive.swift` — exports history to iCloud Drive as plain files + HTML/text index. `DemoSeeder.swift` — DEBUG demo content.
- `Audio/VoiceRecorder.swift`, `Audio/VoicePlayer.swift` — AVFoundation record/playback.
- `Views/` — SwiftUI screens: `RootView` (routing: welcome→pairing→home), `HomeView` (status card → status history, nudge, moment card, memo row; composer deep-link queueing), `SettingsView` (name, notifications, read-receipts toggle, invite, archive, unlink, diagnostics), `WelcomeView`/`PairingView`/`InviteLinkView` (onboarding + invite), `MoodPickerView` (status presets + celebration), `MomentComposerView`+`DrawingCanvas`+`CameraPicker` (photo/doodle), `VoiceMemoComposerView`+`VoiceMomentViews`+`ScrubbableWaveform` (memos + swipe-to-seek), `MomentLibraryView`/`MomentGalleryView` (history grid/pager, direction filter, seen badges), `HistoryFilter` (shared filter enum+picker), `StatusHistoryView` (status log sheet), `CelebrationOverlay`, `PinchToZoom`, `ShareSheet`, `DiagnosticsView`.

Widget/
- `RedStringWidgetBundle.swift` — bundle. `StatusWidget.swift`+`WidgetViews.swift` — status widget (accessory families + systemSmall). `MomentWidget.swift` — photo widget (systemSmall/Medium/Large, memo badge, compose deep link). `StatusProvider.swift` — shared timeline provider (hourly refresh, 8s CloudKit timeout, cooldown flip-back entries). `SendNudgeIntent.swift` — lock-screen heart AppIntent.

NotificationService/
- `NotificationService.swift` — push enrichment; dispatches on `subscriptionID` (never on sync delta), claims banners under the cross-process lock.

docs/ — GitHub Pages marketing site (`index.html`), deployed by `.github/workflows/static.yml`. Unrelated to the app binary.

## CloudKit schema gotchas (summary — full detail in README "Shipping it")

- Production auto-creates nothing: deploy schema after Development use, and `cloudkit.share` only enters the schema when a share is actually saved in a Debug device build. The `Receipt` type likewise only appears after a Debug device has published one (toggle read receipts on and view a received moment) — deploy it before shipping the read-receipts build.
- Field encryption is fixed at creation; the CloudKit environment (Dev vs Prod) is decided by code signing, and mixed-environment devices can't see each other (looks like a broken pairing — see `CloudDiagnostics`).
- Subscriptions: `status-alerts` (visible, silent-sound), `nudge-alerts`, `moment-alerts` (both visible + sound + mutable content); legacy `status-changes` is deleted on sight.

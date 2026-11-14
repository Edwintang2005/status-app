# Red String — agent guide

Two-person iCloud status app (iOS 17+, SwiftUI). One partner sets a status/nudge/photo/doodle/voice memo; it appears on the other's lock screen. No server: everything travels through CloudKit (a zone-wide `CKShare`), human-readable fields end-to-end encrypted via `encryptedValues`. Five shipping targets (app, widget, notification service, notification content, share extension) plus a unit-test bundle — all compile `Sources/Shared/`.

This file is the map. The detail is in `Documentation/`: each invariant in full (`invariants/NN-*.md` — **read the one you're touching first**), the file-by-file map (`FILE-MAP.md`), build/test/CI notes (`BUILD-AND-TEST.md`), design rationale (`DESIGN.md`), shipping and the CloudKit schema (`SHIPPING.md`), rejected ideas (`DECISIONS.md`). `ROADMAP.md` is planned work, `CHANGELOG.md` what shipped.

Comment style: lean — one or two lines carrying only the non-obvious constraint or "why". No narrative comments, no restating code, no history; match the existing density.

## Build & run

- `RedString.xcodeproj` is generated from `project.yml` but **committed**: after adding/renaming files, `make project` and commit the project too. Never edit settings in Xcode's UI. XcodeGen is pinned (`.xcodegen-version`).
- `make build` is an unsigned compile check (never launch it: it traps on the App Group). `make test` runs the unit tests over `Sources/Shared/` with no host app. `make uitest SIM=…` / `make uitest-narrow` run the signed demo-mode UI smoke (CI only compiles it). Demo mode: `REDSTRING_DEMO=1`, Debug only.
- CI: unsigned Debug `build-for-testing` with warnings as errors, then the unit tests; an unsigned Release build beside it. Strict concurrency `complete`: zero warnings in every target. CI's Xcode can be older than yours — a local pass isn't proof.
- Tests: stores take an injected URL, directory or `UserDefaults` suite — **never a `.shared` singleton in a test** (the host-less bundle writes the installed app's real container). Keep decisions in pure types (`ParsedDelta`, `PushBannerPolicy`, `Outbox`, `SyncCoordinator`, …) so they're testable; `CloudSyncSeamTests` drives `CloudSync` over `FakeCloudDatabase`. Wait on conditions (`waitUntil`), never sleep.
- User-facing text: `Text` literals, `String(localized:)` elsewhere. Icon-only controls carry an `accessibilityLabel`; headlines use `Theme.rounded`.

## Architecture

```
UI (Views/) → AppModel (@MainActor, @Observable)
            → Backend.current (AppBackend = SyncBackend & PairingBackend: CloudSync actor, or DemoBackend)
            → CloudKit custom zone "CoupleZone", zone-wide CKShare
SharedStore (App Group, file-backed KV)  ← every process reads + writes: Snapshot, PairingInfo, change tokens
MomentIndex / MomentStore / StatusHistoryLog   history metadata (cap 5,000) / media files / both sides' statuses
SyncCoordinator → SyncRunner (refresh → announce)        NotificationService (rewords pushes, reloads widgets)
```

Records (`PairRole` derives every per-side name): `status-<role>`, `statuslog-<role>-<seconds>`, `nudge-<role>`, `moment-<role>-<uuid>`, `receipt-<role>`, `anniversary`, `anniversary-request`, `freshstart-<role>`; the last four have no subscription.

## Invariants — do not break

Each: the rule · where · guarded by. Full text, with the why: `Documentation/invariants/NN-*.md`.

1. **Cross-process locking.** Every read-modify-write of `Snapshot` goes through `SharedStore.mutate`; check-and-claim inside one `mutate`. Index and status log lock likewise. · `testLockSerialisesReadModifyWrites`, `testConcurrentPushesNeverTakeTheSameMoment`.
2. **Apply before token, media after both; what couldn't be read is owed.** Records filed, then the token (compare-and-swap), then media; unreadable records are owed and retried by ID, never pin the delta. · `CloudSyncSeamTests`, `TokenAdvancePolicyTests`, `testAnUnreadableRecordIsOwedAndTheTokenMovesOn`.
3. **Shared state lives in files, not UserDefaults.** Caches key on the file's identity. · `GroupStoreTests`.
4. **Encryption boundaries.** User words and behaviour go through `encryptedValues`; only names, kinds, dates and counts are plaintext; assets never through `encryptedValues`. · unguarded (review every new field).
5. **Hand-written Codable.** Persisted types decode with fallbacks so old data survives. · `SnapshotCodableTests`, `ModelCodableTests`, `ForwardCompatTests`.
6. **Widgets reload through `SharedStore`, only when something drawn moved,** never from the widget process; the NSE holds reloads to one per push. · `WidgetReloadPolicyTests`, `testAnUnchangedMutateLeavesTheFileAndTheWidgetsAlone`, `testAHeldProcessAbsorbsReloadsUntilTheHoldEnds`.
7. **The heart's cooldown is claimed before the network** (`Snapshot.claimNudgeCooldown`), released only for a tap that never reached iCloud. · `NudgeCooldownPolicyTests`.
8. **Unlink is cloud-first;** "zone gone" needs a second sighting and the same account; a new invite never reuses an occupied zone. · `CloudSyncSeamTests` (zone gone, unlink mid-fetch), `SharePostureTests`.
9. **Closing the invite link is a manual two-step handshake;** never automatic, never evicts a stranger with the partner. · `SharePostureTests`; the handshake itself only on devices.
10. **Every banner is a claim, deduped by `Snapshot` watermarks;** moments are owed, not reconstructed; unread pushes keep CloudKit's words at full volume; the receiver's preferences cap last. · `AnnouncementPolicyTests`, `PushBannerPolicyTests`, `PushBannerBypassTests`, `BannerUpkeepPolicyTests`.
11. **Offline sends recover, never silently drop;** every send goes through `Outbox`; failures are classified (`SendFailure`). · `OutboxTests`, `UploadPolicyTests`, `SendFailureTests`.
12. **`AppConfig` IDs match** the six entitlements files, `project.yml` and `Info.plist`. · unguarded.
13. **Read receipts are double-gated and sticky;** claimed before the call, settled only by a confirmed write; never un-see. · `testReceiptsAreClaimedBeforeTheCallAndReDirtiedOnFailure`, `testPartnerReceiptsApplyOnlyToOwnMomentsAndNeverUnsee`.
14. **Status history dedups by `(fromMe, wordsAt)`; persisted dates are whole seconds.** · `StatusHistoryLogTests`, `StatusOrderingTests`.
15. **Corrupt store files are preserved, not overwritten; unreadable isn't corrupt or empty.** · `testCorruptFileIsPreservedNotOverwritten`, `testAFileHealedBeforeTheLockedRereadIsKept`, `testAnUnreadablePairingIsNotUnpaired`.
16. **Publish-success flags verify currency;** conflicting saves refetch and retry. · `StatusOrderingTests`, `testAnUnloggedFirstStatusStaysOwedAcrossARelaunch`.
17. **Scrub gestures need `.highPriorityGesture`;** never a waveform inside a `Button`. · unguarded.
18. **Pin vertical-ScrollView content with `.containerRelativeFrame(.horizontal)`.** · UI smoke's `assertFitsScreen`.
19. **Never hold a shared-container file lock without a suspension guard.** · unguarded.
20. **Moderation is local and sticky;** partner text reaches the screen only through `Moderation.swift`'s helpers, each passed the filter switch once per surface. · `ModerationTests`, `ModeratedTextTests`.
21. **No `.safeAreaInset(edge: .top)` over a scrolling list in a `NavigationStack`.** · UI smoke's launch-hang guard.
22. **A save is confirmed by the record's own result,** every `modifyRecords` (zone deletes and subscription saves included); calls are bounded. · `SaveConfirmationTests`, `testAZoneDeletionIsConfirmedByItsOwnResult`.
23. **Nothing from the shared zone is trusted:** dates bounded by server time, partner text capped, counts clamped. · `IngestTests`, `testPlausibleCapsFutureAndPreEpochDates`, `testNudgeCountIsClamped`.
24. **A fresh start clears only with both committed,** each side its own records, by server time. · `FreshStartPolicyTests`, `FreshStartIngestTests`, `FreshStartOutboxTests`.
25. **UIKit delegate callbacks with a completion run on the main actor,** never `nonisolated async`. · unguarded.

## Where things are

`Sources/Shared/` (every target): `Cloud/` (`CloudSync` and one extension per concern; pure rules beside it), `Store/` (`SharedStore` and its `+Widgets`/`+Unreadable`/`+Diagnostics`, `MomentIndex`, `MomentStore`, `StatusHistoryLog`, `Outbox`), `Models/`, the policies (`AnnouncementPolicy`, `PushBannerPolicy`, `BannerUpkeep*`, `SyncCoordinator`, `SyncRunner`, …). `Sources/App/` (`AppModel` and its extensions, `Views/`, `Camera/`, `Audio/`), `Widget/`, `NotificationService/`, `NotificationContent/`, `Share/`. Every file and what it owns: `Documentation/FILE-MAP.md`. CloudKit schema gotchas (deploy before Production, encryption fixed at creation, a second device on your account is you): `Documentation/SHIPPING.md`.

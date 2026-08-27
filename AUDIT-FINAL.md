# Final pre-submission audit — 27 Aug 2026 (late)

A second full-codebase audit over the fixed tree (two independent passes:
sync/store layer, and views/widgets/extensions/config). Every fix from the
first round was re-verified in place; the Release binary was checked to
contain no demo-mode or diagnostics code; privacy manifests, entitlements and
Info.plists all verified submission-ready.

## Residual findings — all fixed the same evening

1. **`unpair()` under the wrong iCloud account** treated "zone not found" as
   successful cloud cleanup and wiped local state while everything sat intact
   in the other account's iCloud — the one zone-gone path the new account
   guard had missed. Now throws `differentAccount` instead
   ([CloudSync.swift](Sources/Shared/Cloud/CloudSync.swift) `unpair`).
2. **A refresh racing an unlink** could write `isPaired = true` and the
   ex-partner's status back onto the freshly wiped snapshot. `apply`'s mutate
   now re-checks the pairing key under the snapshot lock.
3. **The nudge cooldown check-then-claim wasn't atomic across processes**
   (app button vs lock-screen widget intent) — both could pass a stale read
   and send two nudges. Check and claim now happen inside one locked `mutate`.
4. **"Delete everything and start over" resurrected the user's name**:
   Settings' `onDisappear` commit wrote the stale draft back onto the wiped
   model. The commit is now gated on `model.hasName`
   ([SettingsView.swift](Sources/App/Views/SettingsView.swift) `commitName`).
5. **The nudge widget's cooldown-expiry timeline entry still drew a
   checkmark** — WidgetKit renders every entry at delivery time, so the
   wall-clock comparison saw "inside cooldown" for both entries.
   `recentlySent` now measures from `entry.date`
   ([WidgetViews.swift](Sources/Widget/WidgetViews.swift)).
6. **VoicePlayer leaked its two NotificationCenter observers** per instance
   (one per screen presentation, for the process lifetime). Tokens are kept
   and removed in `deinit`.
7. **`removeGenericBanners` swept unenriched *status* banners** that nothing
   was going to re-state, trimming the visible status history. It now matches
   only the wording it supersedes, via the shared `CloudSync.GenericAlert`
   constants.
8. **The extension's un-announced-moment fallback broke at three or more
   rapid moments** (newest caption on two banners, oldest never shown, and
   the single-id watermark could move backwards). Replaced with
   `Snapshot.notifiedMomentIDs`, a bounded announced-ids set used by both the
   app and the extension.

## Also in this round

- **Lock-screen status widget alignment**: the two columns are now
  top-anchored, so a long status wraps below its emoji instead of pushing it
  out of line with the partner's
  ([WidgetViews.swift](Sources/Widget/WidgetViews.swift) `rectangular`).
- **Documentation pass**: README brought fully current (voice memos, layout
  tree, both required-reason APIs, account-switch behaviour, demo mode, push
  table); stale silent-push comments in NotificationManager, AppDelegate and
  SyncRunner rewritten.

Both configurations build; runtime re-verified on the simulator (home,
composer, mood picker, lock-screen widget). The repeated "app crashed" during
verification was an unsigned `make build` artifact being installed — a build
pipeline trap, not an app bug (see README: `make build` output must not be
launched; run `xcodebuild clean` before building for install after using it).

# Red String

A private lock screen status app for two people. Your partner sets a status;
it appears on your lock screen. You tap a heart; their phone buzzes.

No accounts, no servers, no ads. Everything travels through iCloud — the
shared space lives in the account of whoever sent the invite — with the text
fields end-to-end encrypted.

<!-- Built as an alternative to Widgetable: same core idea, none of the ads. -->

## What it does

| | |
|---|---|
| **Status** | An emoji plus a short message — `🥰 missing you`, `😴 sleeping`. Two taps from a preset, or type your own. |
| **Heart** | A heart on your lock screen. Tapping it makes their phone show *"Sam sent you a heart ❤️"*. |
| **Photos & doodles** | Snap a photo, draw a doodle, or scribble over a photo, and it lands on their home screen widget. Pick the paper colour for a doodle. Or share one photo from any app's share sheet. A photo carries where it was taken (see "Where a photo was taken" in [DESIGN](Documentation/DESIGN.md)). |
| **Voice memos** | Up to 4 minutes (`AppConfig.voiceMemoMaxDuration`), with a live waveform while recording. Playable from the expanded notification without opening the app; a badge on the photo widget says one is waiting. Swipe across any playback waveform to scrub. |
| **History** | Every photo, doodle and memo is kept. Browse the lot in the library — filterable by *from them* / *from me* and by type — save any to Photos, and get it all back on a new phone. |
| **Status history** | A log of both sides' statuses, grouped by day, behind a tap on the partner card. Every change is its own CloudKit record, so it comes back on a new phone — see "Status history" in [DESIGN](Documentation/DESIGN.md). |
| **Read receipts** | On by default, with a per-side switch in Settings. Each side shares which moments it has seen; your own sends wear an eye badge in the library and a "Seen …" line in the gallery. Your own status gets the same line once they've had it on screen. |
| **Names** | You set your own name; they set theirs. Whatever they call themselves is what you see — there's no renaming other people. |

Widgets:

- **Their status** — `accessoryRectangular`, `accessoryCircular`,
  `accessoryInline` for the lock screen, plus `systemSmall` for the home screen.
- **Nudge** — a circular lock screen widget that is just a heart button.
- **Their photo** — `systemSmall` / `systemMedium` / `systemLarge` on the home
  screen, showing the last photo or doodle they sent, with a badge when a
  voice memo is waiting. "Hide from widget" in the gallery takes that one off
  (the one before shows instead) on this phone only, until their next
  picture arrives.

The photo widget is home screen only, and drawing happens in the app rather
than on the widget. Both are platform limits, not omissions: lock screen
accessory widgets are rendered monochrome at a couple of hundred points across,
and a widget can host a `Button` or a `Link` but not a drawing canvas. The
medium and large photo widgets carry a compose shortcut that opens straight
into the canvas.

## Requirements

- **Xcode 26** (the code uses iOS 26 APIs behind `#available`; CI builds with `^26.0`), iOS 17+ on both phones (interactive widgets need 17).
- **XcodeGen at the version in `.xcodegen-version`.** `make project` refuses any other (another version can write a different project, which fails CI's drift check); install it from the [XcodeGen releases](https://github.com/yonaskolb/XcodeGen/releases), as CI does.
- **A paid Apple Developer account ($99/yr).** Not optional: CloudKit, push
  notifications and App Groups are all unavailable under free provisioning.
- Both phones signed into iCloud.

## Setup

```bash
make project
open RedString.xcodeproj
```

Then, once:

1. **Set your team in [project.yml](project.yml)**, not in Xcode's Signing &
   Capabilities tab. The `.xcodeproj` is generated, so `make project`
   overwrites anything the UI set — setting it in the spec is the only place it
   survives. Then re-run `make project`.
2. **Change the bundle IDs** if `com.edwintang.redstring` isn't yours. Four
   places must agree:
   - `PRODUCT_BUNDLE_IDENTIFIER` in [project.yml](project.yml) (all seven targets, both test bundles included)
   - the identifiers in [Sources/Shared/AppConfig.swift](Sources/Shared/AppConfig.swift)
   - the container and group IDs in all six `.entitlements` files
   - the `NSUbiquitousContainers` key in
     [Info.plist](Sources/App/Resources/Info.plist)
3. **Create the CloudKit container** — Xcode does this for you the first time
   you build with the iCloud capability enabled.
4. Build and run on both phones.

There is no offline or unsigned path. The app↔widget channel is a file in the
App Group container, so a build without that entitlement traps at launch on
`GroupFileStore`'s `assertionFailure` in Debug, and in Release quietly comes up
with nowhere to store anything. App Groups, CloudKit and push all need the paid
team. `make build` is a compile check only; `make run` signs first.

`make project` regenerates `RedString.xcodeproj` from `project.yml`; anything
changed in Xcode's UI is lost on the next regeneration. The generated project
**is committed** — unusual for XcodeGen, but Xcode Cloud builds from a plain
clone and fails without it — so after adding or renaming files, commit the
regenerated project with the source change (only `xcuserdata` is ignored).

## Documentation

- [Documentation/DESIGN.md](Documentation/DESIGN.md) — how it works and why:
  pairing and the share's security model, notifications, offline sends, Home,
  photos and doodles, history, the fresh start, costs, known limitations.
- [Documentation/SHIPPING.md](Documentation/SHIPPING.md) — the CloudKit schema
  steps and the order to ship in.
- [CLAUDE.md](CLAUDE.md) — the code map and the invariants that must not break;
  each one in full under [Documentation/invariants/](Documentation/invariants/).
- [ROADMAP.md](ROADMAP.md) — planned work, ranked;
  [Documentation/DECISIONS.md](Documentation/DECISIONS.md) — what was
  considered and rejected.
- [CHANGELOG.md](CHANGELOG.md) — what shipped.

## Layout

```
Sources/Shared/        compiled into every target, the test bundle included
Sources/App/           the app: AppModel, views, camera, audio, notifications
Sources/Widget/        status, photo and heart widgets
Sources/NotificationService/   push enrichment
Sources/NotificationContent/   the expanded (long-pressed) banner
Sources/Share/         the share sheet's "Red String": one photo, captioned and sent
Tests/                 RedStringTests (no host app) and RedStringUITests
```

The file-by-file map lives in [Documentation/FILE-MAP.md](Documentation/FILE-MAP.md).

Each target's `Resources/` also carries a `Localizable.xcstrings` (an Xcode IDE
build fills it from SwiftUI text and `String(localized:)` — xcodebuild doesn't
write it back; English only so far, but every user-facing string goes through
it) and a `PrivacyInfo.xcprivacy`, required for App Store submission. Red String
declares no tracking and no collected data; the required-reason APIs are the
App Group defaults suite (1C8F.1, and CA92.1 in the app), the file timestamps
`MomentStore.prune` reads inside the app's own container (C617.1), and, in the
app, the active keyboards the status picker's emoji field checks (54BD.1).

## Commands

| | |
|---|---|
| `make project` | regenerate the Xcode project from `project.yml` |
| `make build` | compile check for the Simulator (unsigned — don't launch it) |
| `make test` | unit tests over `Sources/Shared` (unsigned; no host app or App Group needed) |
| `make uitest` | demo-mode UI smoke with `performAccessibilityAudit()` on Home and every main sheet, plus a check that nothing hangs past the screen's sides (signed, like `make run`; CI compiles it but can't run it — about three minutes) |
| `make uitest-narrow` | the same on an iPhone SE (3rd generation), the narrowest phone iOS 17 runs on (375 pt), created on first use; Display Zoom (320 pt) can't be scripted, so check it by hand |
| `make run` | build signed, install and launch on the Simulator |
| `make device` | build signed and install the Debug config on a connected iPhone — the only route to the CloudKit Development schema |
| `make archive` | archive the Release config for TestFlight / the App Store |
| `make clean` | |

## Demo mode (screenshots and previews)

Debug builds accept `REDSTRING_DEMO=1` in the launch environment:

```bash
SIMCTL_CHILD_REDSTRING_DEMO=1 xcrun simctl launch booted com.edwintang.redstring
```

`DemoMode` swaps CloudKit for a stub backend where everything instantly
succeeds, and `DemoSeeder` reseeds the real App Group store on every launch
with a fixed Alex/Sam pairing — statuses, doodles, photos and a playable
voice memo — so the whole app (widgets included) can be driven on a Simulator
with no iCloud account. It is `#if DEBUG` and environment-gated; a Release
build contains none of it. The App Store screenshots and previews were made
this way. Add `SIMCTL_CHILD_REDSTRING_DEMO_BULK=1` for weeks of older moments
and statuses below that set, so the library and status history scroll.

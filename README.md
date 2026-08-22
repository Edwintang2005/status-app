# Tether

A private lock screen status app for two people. Your partner sets a status;
it appears on your lock screen. You tap a heart; their phone buzzes.

No accounts, no servers, no ads. Everything travels through your own iCloud,
with the text fields end-to-end encrypted.

<!-- Built as an alternative to Widgetable: same core idea, none of the ads. -->

## What it does

| | |
|---|---|
| **Status** | An emoji plus a short message — `🥰 missing you`, `😴 sleeping`. Two taps from a preset, or type your own. |
| **Nudge** | A heart on your lock screen. Tapping it makes their phone show *"Sam is thinking of you 💭"*. |
| **Nicknames** | What you call them is stored on *your* phone only. They never see it, and it overrides whatever they call themselves. |

Widgets: `accessoryRectangular`, `accessoryCircular` and `accessoryInline` for
the lock screen, a `systemSmall` for the home screen, plus a dedicated
circular **Nudge** widget that is just a heart button.

## Requirements

- **Xcode 16 or later**, iOS 17+ on both phones (interactive widgets need 17).
- **A paid Apple Developer account ($99/yr).** Not optional: CloudKit, push
  notifications and App Groups are all unavailable under free provisioning.
- Both phones signed into iCloud.

## Setup

```bash
brew install xcodegen
make project
open Tether.xcodeproj
```

Then, once:

1. **Pick your team.** Select both the `Tether` and `TetherWidgetExtension`
   targets → Signing & Capabilities → choose your team. Or set
   `DEVELOPMENT_TEAM` in [project.yml](project.yml) and re-run `make project`.
2. **Change the bundle IDs** if `com.edwintang.tether` isn't yours. Three
   places must agree:
   - `PRODUCT_BUNDLE_IDENTIFIER` in [project.yml](project.yml) (both targets)
   - the identifiers in [Sources/Shared/AppConfig.swift](Sources/Shared/AppConfig.swift)
   - the container and group IDs in both `.entitlements` files
3. **Create the CloudKit container** — Xcode does this for you the first time
   you build with the iCloud capability enabled.
4. Build and run on both phones.

`make project` regenerates `Tether.xcodeproj` from `project.yml`; the
`.xcodeproj` is gitignored on purpose, so add new files to the folder and
re-run it rather than editing project settings by hand.

### Trying the UI without a developer account

```bash
make preview
```

Compiles CloudKit out (`TETHER_NO_CLOUDKIT`) so the app runs unsigned in the
Simulator. You can see every screen; pairing will not work.

## Pairing

One of you creates an invite link and sends it over iMessage. The other taps
it. That's the entire setup — no codes, no email addresses, no sign-up.

Under the hood this is a **zone-wide `CKShare`**. Whoever pairs first owns a
custom zone in their private database and shares the whole zone; the other side
accepts, and the zone shows up in their shared database. Both can then write
into it.

The invite link is created with `publicPermission = .readWrite`, so anyone
holding the link could join. Once your partner is in, use **Settings → Close
the invite link** to revoke that, so a forwarded screenshot can't add a third
person.

## How it stays current

Each side writes exactly one record, named after its role (`status-owner` /
`status-participant`), so neither phone ever needs to know the other's iCloud
user ID and the two can never write conflicting records.

Updates reach the widget by three independent paths, because no single one is
reliable enough on its own:

1. **Silent push.** A `CKDatabaseSubscription` fires whenever the shared zone
   changes. The app wakes, fetches, writes the snapshot to the App Group and
   reloads the widget. This subscription is deliberately silent
   (`shouldSendContentAvailable`) — a banner per status change would be
   unbearable — which does mean iOS throttles it and drops it entirely while
   the app is force-quit. Paths 2 and 3 are the backstop.

   Note that a database subscription is only silent *because* we leave
   `alertBody`/`soundName`/`shouldBadge` unset; setting any of them makes
   CloudKit deliver a visible, higher-priority push. See *Possible
   improvements*.
2. **Foreground refresh**, whenever the app becomes active.
3. **The widget's own fetch**, on its 30-minute timeline refresh, with an 8s
   timeout and the cached snapshot as fallback.

Nudges are a counter on your own status record rather than a separate record
type. The other side notices the number went up and raises a notification —
which makes delivery idempotent, so a record fetched twice can't buzz twice.

## Possible improvements

**Deliver nudges as a real alert push.** Today a nudge is a counter on your
status record: the silent push wakes the app, which raises a *local*
notification. That inherits every silent-push weakness — throttled, and dead
while the app is force-quit.

`CKDatabaseSubscription` has a `recordType` property, so the two concerns can be
split into two subscriptions against the same database:

| record type | notificationInfo | behaviour |
|---|---|---|
| `Status` | `shouldSendContentAvailable` | silent; refreshes the widget |
| `Nudge` | `alertBody` + `soundName` | visible, higher priority, delivered by APNs without waking the app |

That makes nudges reliable even when the app is force-quit, with no server. It
needs `Nudge` restored as its own record type rather than a counter.

One trade-off: CloudKit's server composes the alert text and cannot read
`encryptedValues`, so personalising it to *"Sam is thinking of you"* requires
the sender's name in an unencrypted field on the `Nudge` record. A generic
*"💭 Thinking of you"* keeps everything encrypted.

## Known limitations

- **Lock screen widgets are monochrome.** iOS renders accessory widgets in a
  vibrant, desaturated style; emoji become white silhouettes. Every layout
  therefore pairs the emoji with words rather than relying on colour.
- **Silent pushes are throttled by iOS** and stop entirely if the app is
  force-quit. The widget's own periodic fetch is the backstop.
- **Before a TestFlight or App Store build**, change `aps-environment` in
  [Tether.entitlements](Sources/App/Resources/Tether.entitlements) from
  `development` to `production`, and deploy the CloudKit schema to Production
  from the CloudKit Console. The dev environment creates the schema for you on
  first save; production does not.

## Layout

```
Sources/
  Shared/      compiled into BOTH targets
    AppConfig.swift        the four IDs that must match the entitlements
    Theme.swift            colours, cards, buttons
    Models/                Mood, StatusPayload, PairingInfo, Snapshot
    Store/SharedStore.swift  App Group cache — the app↔widget channel
    Cloud/CloudSync.swift    all CloudKit: sharing, records, subscriptions
  App/
    TetherApp.swift, AppDelegate.swift   push registration, share acceptance
    AppModel.swift, SyncRunner.swift     state and the refresh→notify path
    Views/
  Widget/
    StatusWidget.swift, WidgetViews.swift, StatusProvider.swift
    SendNudgeIntent.swift                the lock screen heart
```

## Commands

| | |
|---|---|
| `make project` | regenerate the Xcode project from `project.yml` |
| `make build` | build for the Simulator |
| `make run` | build, install and launch |
| `make preview` | build without CloudKit, unsigned |
| `make clean` | |

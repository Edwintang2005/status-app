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
| **Photos & doodles** | Snap a photo, draw a doodle, or scribble over a photo, and it lands on their home screen widget. Swipe back through the last 30 in the app, and save any to Photos. |
| **Nicknames** | What you call them is stored on *your* phone only. They never see it, and it overrides whatever they call themselves. |

Widgets:

- **Their status** — `accessoryRectangular`, `accessoryCircular`,
  `accessoryInline` for the lock screen, plus `systemSmall` for the home screen.
- **Nudge** — a circular lock screen widget that is just a heart button.
- **Their photo** — `systemSmall` / `systemMedium` / `systemLarge` on the home
  screen, showing the last photo or doodle they sent.

The photo widget is home screen only, and drawing happens in the app rather
than on the widget. Both are platform limits, not omissions: lock screen
accessory widgets are rendered monochrome at a couple of hundred points across,
and a widget can host a `Button` or a `Link` but not a drawing canvas. The
medium and large photo widgets carry a compose shortcut that opens straight
into the canvas.

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

## Running it without an Apple Developer account

```bash
make local
```

A **fully working build with no iCloud at all**, for playing with the app
before paying for anything. It pairs you with a fictional partner you drive
yourself from **Settings → Demo controls**: set their status, make them nudge
you, send yourself photos and doodles. Statuses, images, notifications and
**real widgets** all work — the only thing missing is the network.

Simulator only, and worth knowing why. Xcode strips entitlements when it can't
produce a provisioning profile, so `make local` re-applies the App Group by
hand with `codesign` afterwards. The Simulator honours an App Group entitlement
without a provisioning profile, which is what lets the widget share data with
the app; a real device would reject the ad-hoc signature. Personal (free) teams
can't use App Groups at all, so on real hardware the widget genuinely needs the
paid account.

Internally this is the `TETHER_LOCAL_MODE` compile flag, which swaps
`Backend.current` from `CloudSync` to `LocalSync`. Both conform to
`SyncBackend`, so every screen above the backend is identical in the two
builds — the demo isn't a mock of the app, it *is* the app.

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

### Battery

The widgets carry **no timestamps and no live-updating text**, so nothing on
them ticks. Worth knowing for future changes though: `Text(date, style:
.relative)` in a widget is drawn by the system's rendering layer and does *not*
re-run the timeline — it looks like a per-second update but costs no process
launches. The only thing that actually spends battery is the timeline policy
below, which is why it's an hour rather than a minute.

In the app, the nudge cooldown owns a one-second countdown that runs **only
during the sixty seconds after a nudge**, scoped to the button so it doesn't
invalidate the screen.

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
3. **The widget's own fetch**, on its hourly timeline refresh, with an 8s
   timeout and the cached snapshot as fallback. This is the only battery cost
   in the widget: one process launch and one CloudKit round trip per tick. It's
   a backstop for dropped pushes, not the primary path, so it's deliberately
   lazy — `StatusProvider.refreshInterval` if you want it keener.

Nudges are a counter on your own status record rather than a separate record
type. The other side notices the number went up and raises a notification —
which makes delivery idempotent, so a record fetched twice can't buzz twice.

## Photos and doodles

### Where they're stored, and what it costs

**On the phone:** two JPEGs per moment in the App Group container — a 1280px
copy for the app and a 512px one for the widget — capped at the most recent 30,
with older image files deleted as they fall off the end. Doodles measure around
30 KB + 12 KB each; camera photos run larger, roughly 200–400 KB. So the cap
works out at **a few MB, and single-digit MB worst case**. It cannot grow
without bound.

**In iCloud:** almost nothing, and it does not accumulate. Each person has
exactly **one moment slot** on the server (`moment-owner` /
`moment-participant`), overwritten on every send — so the container holds four
image files total, under about 1.5 MB between the two of you, forever. Your
iCloud quota won't notice.

### Why one slot

It avoids `CKQuery` entirely. Queries need indexes configured by hand in the
CloudKit Console, whereas a fixed record name can just be fetched. The
**trade-off is real**: if your partner sends two photos before your phone syncs
even once, the first is gone from the server and you'll never see it. In
practice a sync happens on every silent push and every app open, so this needs
two sends inside one quiet window.

If you'd rather never miss one, the fix is a small **ring of N slots**
(`moment-owner-0…4`) written round-robin, with the receiver checking all of
them. It's a contained change to `CloudSync` and would raise iCloud usage to
maybe 5 MB. Worth doing once the CloudKit path is actually being tested.

### Mechanics

Every refresh fetches the moment slot with `desiredKeys` limited to the id, and
only downloads the image when that id is one this device hasn't stored. Two
sizes are written per moment: a full copy for the app and a ~512px one for the
widget, because widget extensions have a hard memory ceiling and decoding a
full-resolution photo there is the quickest way to get jetsammed.

Images travel as `CKAsset`s, which **CloudKit encrypts by default** — they must
*not* be put through `encryptedValues`, which rejects them. The caption and
sender name are explicitly encrypted alongside.

Drawing is PencilKit (`PKCanvasView`) with a small custom palette rather than
`PKToolPicker`, which docks itself to the window and fights with sheets on
iPhone. The canvas is square because the widget is square — composing in the
destination's shape means nothing gets unexpectedly cropped later. Strokes are
rasterised at export resolution, not upscaled from the on-screen canvas.

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
    AppConfig.swift          the IDs that must match the entitlements
    Theme.swift              colours, cards, buttons
    Models/                  Mood, StatusPayload, PairingInfo, Snapshot, Moment
    Store/SharedStore.swift  App Group cache — the app↔widget channel
    Store/MomentStore.swift  image files in the App Group, full + thumb
    Cloud/SyncBackend.swift  the protocol both backends implement
    Cloud/CloudSync.swift    CloudKit: sharing, records, assets, subscriptions
    Cloud/LocalSync.swift    the no-network demo partner
  App/
    TetherApp.swift, AppDelegate.swift   push registration, share acceptance
    AppModel.swift, SyncRunner.swift     state and the refresh→notify path
    Views/
      HomeView, PairingView, SettingsView, MoodPickerView
      MomentComposerView                 photo + doodle composer
      DrawingCanvas.swift                PencilKit canvas and palette
      CameraPicker.swift                 UIImagePickerController wrapper
  Widget/
    StatusWidget.swift, WidgetViews.swift, StatusProvider.swift
    MomentWidget.swift                   the photo/doodle widget
    SendNudgeIntent.swift                the lock screen heart
Config/
  Local.entitlements                     App Group only, for `make local`
```

## Commands

| | |
|---|---|
| `make project` | regenerate the Xcode project from `project.yml` |
| `make build` | build for the Simulator |
| `make run` | build, install and launch |
| `make local` | build, sign and run the no-iCloud demo (Simulator only) |
| `make clean` | |

# Red String

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
| **Photos & doodles** | Snap a photo, draw a doodle, or scribble over a photo, and it lands on their home screen widget. Pick the paper colour for a doodle. |
| **History** | Every photo and doodle is kept. Browse the lot in the library, save any to Photos, and get it all back on a new phone. |
| **Names** | You set your own name; they set theirs. Whatever they call themselves is what you see — there's no renaming other people. |

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
open RedString.xcodeproj
```

Then, once:

1. **Set your team in [project.yml](project.yml)**, not in Xcode's Signing &
   Capabilities tab. The `.xcodeproj` is generated, so `make project`
   overwrites anything the UI set — setting it in the spec is the only place it
   survives. Then re-run `make project`.
2. **Change the bundle IDs** if `com.edwintang.redstring` isn't yours. Four
   places must agree:
   - `PRODUCT_BUNDLE_IDENTIFIER` in [project.yml](project.yml) (all three targets)
   - the identifiers in [Sources/Shared/AppConfig.swift](Sources/Shared/AppConfig.swift)
   - the container and group IDs in all four `.entitlements` files
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

`make project` regenerates `RedString.xcodeproj` from `project.yml`. Add new
files to the folder and re-run it rather than editing project settings by hand
— anything changed in Xcode's UI is lost on the next regeneration.

The generated `.xcodeproj` **is committed**, which is unusual for an XcodeGen
project. Xcode Cloud builds from a plain clone of the repository and fails with
*"RedString.xcodeproj does not exist at the root of the repository"* if it
isn't there. So after adding or renaming files: `make project`, then commit the
regenerated project alongside the source change. Only `xcuserdata` inside the
bundle is ignored.

## Pairing

One of you creates an invite link and sends it over iMessage. The other taps
it. That's the entire setup — no codes, no email addresses, no sign-up.

Under the hood this is a **zone-wide `CKShare`**. Whoever pairs first owns a
custom zone in their private database and shares the whole zone; the other side
accepts, and the zone shows up in their shared database. Both can then write
into it.

### The invite link closes itself

The link is created with `publicPermission = .readWrite`, which makes it a
**bearer token**: whoever holds the URL can join, not just the person you sent
it to. That matters more than it first looks, because a device joining with no
change token is handed the *entire zone* — every photo, drawing and voice memo
ever sent, not just what happens next.

So the app revokes it rather than the user. On the owner's next refresh after
the partner has joined, `closeInviteIfPartnerJoined()` sets the share's
`publicPermission` to `.none`. The proof it waits for is a `status-participant`
record existing — only a share participant can write one — so it costs no extra
fetch, and the single round trip to revoke happens once per pairing. A
forwarded screenshot is then worthless.

**Settings → Close the invite link** is still there for closing it *early*,
before anyone joins, if you sent it to the wrong person; once closed the row
reads "Invite link — Closed" instead. The local `inviteClosed` flag only stops
a settled pairing re-checking the server; the share's own permission is the
truth. Creating a genuinely new invite reopens the share and re-arms the
auto-close.

Two things this deliberately does **not** claim to protect against: the window
between your partner joining and the owner's next refresh (small, and a silent
push usually closes it within seconds), and anyone with access to the owner's
unlocked phone.

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

### Three subscriptions, deliberately different

`CKDatabaseSubscription` can filter by record type, and the payload it sends
decides how much of the system wakes up. That's why nudges and moments are
their own record types rather than fields on `Status`:

| Record type | Payload | What happens |
|---|---|---|
| `Status` | `shouldSendContentAvailable` | **Silent.** Wakes the app to refresh the widget. Nobody wants a banner because their partner started cooking. |
| `Nudge` | `alertBody` + sound + `shouldSendMutableContent` | **Visible.** APNs displays it whether or not the app is running. |
| `Moment` | `alertBody` + sound + `shouldSendMutableContent` | **Visible**, and the image is attached by the service extension. |

Setting `alertBody` is what makes CloudKit send at normal priority as a
displayed alert rather than a throttled background wake — which is what makes
nudges and photos **survive a force-quit**, with no server anywhere.

### The notification service extension

`shouldSendMutableContent` sets `mutable-content: 1`, which hands the push to
[RedStringNotificationService](Sources/NotificationService/NotificationService.swift)
for about thirty seconds before the user sees anything. It is often the only
part of the app that runs at all.

In that window it fetches the change from CloudKit, **decrypts it on-device**,
writes it into the App Group, reloads the widget, and replaces CloudKit's
wording with the real caption and name.

That last part is the reason it exists. CloudKit composes alert text
server-side and cannot read `encryptedValues`, so the subscription's own copy
has to stay generic — *"Sent you something 📷"*. Rather than store names and
captions in the clear just to personalise a push, the extension decrypts
locally and rewrites it. Nothing readable ever reaches Apple's servers, and the
notification still says *"Sam — morning ☕️"* with the photo attached.

It also marks the event as seen in the shared snapshot, so the app doesn't
raise a duplicate local notification the next time it refreshes.

### The remaining paths

Status changes stay silent by design, so the widget still relies on:

1. **The silent push**, when iOS grants the app a background wake. Throttled,
   and skipped entirely while the app is force-quit.
2. **Foreground refresh**, whenever the app becomes active.
3. **The widget's own fetch**, on its hourly timeline refresh, with an 8s
   timeout and the cached snapshot as fallback. This is the only battery cost
   in the widget: one process launch and one CloudKit round trip per tick.
   `StatusProvider.refreshInterval` if you want it keener.

A nudge or a moment arriving also runs a full refresh in the extension, so in
practice status tends to ride along with them.

## Photos and doodles

### Two ways in: what's waiting, and everything

The home card is for **what's waiting**. Tapping it opens a carousel of the
moments you haven't looked at yet, newest first — the same one the card is
previewing, so tapping a picture opens that picture. Once you're caught up it
falls back to just the most recent, rather than replaying the archive.

**Everything else lives in the library**, behind the photo button in the top
left: a grid of the full history, unseen ones marked with a dot, your own sends
flagged with a small arrow. Tap any of them to open the pager over the whole
history.

`Moment.seen` is local-only and never written to CloudKit — "seen" means seen
*on this device*, and your own sends count as seen the moment you make them.
Note that it's a different thing from `Snapshot.lastNotifiedMomentID`, which
only stops a notification firing twice.

One subtlety worth knowing if you touch this: the carousel's list is **captured
when it opens**. Reading the unseen set live would shrink the list underneath
the user, because paging marks each one seen as it appears.

### Whose name shows

**A name belongs to the person it names.** You set yours in Settings, they set
theirs on their phone, and there is no way to rename anyone else — no nickname
override anywhere in the app.

Two sources, for two different things:

- **Moments** display `Moment.senderName`, captured at send time from the
  sender's own `displayName`. That means an old photo keeps the name they were
  using when they sent it, which is the honest thing for a historical record to
  do. Notifications for a moment use the same field.
- **Everything live** — the status card, the widget, a nudge — uses
  `Snapshot.partnerDisplayName`, which is simply their current
  `Status.displayName`, or "Partner" if they haven't set one.

Changing your own name republishes your `Status` record immediately, so your
partner sees it on their next sync. It does not rewrite anything you've already
sent.

### History, and where it lives

Every moment is its own CloudKit record, kept indefinitely. Nothing is
overwritten and nothing expires, so the history is **complete and recoverable**
— sign in on a new phone and the whole thing comes back.

Syncing uses `CKFetchRecordZoneChangesOperation` with a stored server change
token rather than fetching known record names. Three things fall out of that:

- **No `CKQuery`, so no indexes** to configure in the CloudKit Console. Change
  tracking is index-free by design.
- **A device with no token gets the entire zone**, which is exactly what a
  fresh install needs. Recovery isn't a special path; it's the ordinary one
  with an empty starting point.
- Deletions propagate, so removing a moment later is a one-line change.

### What it costs

**In iCloud:** roughly **270 KB per moment** (a 1280px copy plus a 512px
thumbnail), and it accumulates. A thousand moments is around 270 MB against
your iCloud quota — real, but comfortable inside the free 5 GB, and it only
grows as fast as you actually send things.

**On the phone:** bounded, and much smaller. The device keeps
metadata for the last `AppConfig.momentHistoryLimit` (500) entries — a few
hundred bytes each, so well under 100 KB — but image files only for the
`momentImageCacheLimit` (60) most recent, around 16 MB. Scroll further back in
the gallery and the image is **fetched from CloudKit on demand**, with a
spinner while it lands.

That split is what lets the history be unlimited without the phone carrying
every photo you've ever exchanged. The index is a JSON file in the App Group
rather than part of `Snapshot`, because the widget decodes the snapshot on
every render and has no business parsing hundreds of history entries.

### Mechanics

Change fetches use `desiredKeys` to exclude the two `CKAsset` fields, so a
sync — including the big first one after a reinstall — moves only metadata.
Images for the ten newest arrivals are pulled straight after; everything older
waits until you look at it.

Images travel as `CKAsset`s, which **CloudKit encrypts by default** — they must
*not* be put through `encryptedValues`, which rejects them. The caption and
sender name are explicitly encrypted alongside.

Anywhere a photo is shown in a square — the composer, the home card, the
library grid — it goes through `SquareFill`. `Image.resizable().scaledToFill()`
reports the size it needs *in order to fill*, so as a plain child it drags its
parent out to that size and a later `.aspectRatio(1, contentMode: .fit)` can't
pull it back. `SquareFill` sizes from a `Color.clear` (no intrinsic size) and
hangs the image in an `overlay`, which reverses the negotiation: the box
decides, the content fits. Use it rather than reinventing the frame.

Drawing is PencilKit (`PKCanvasView`) with a small custom palette rather than
`PKToolPicker`, which docks itself to the window and fights with sheets on
iPhone. Doodles with no photo behind them get a **backdrop colour**; choosing
the dark one flips black ink to white so you can't end up drawing
black-on-black. The canvas is square because the widget is square — composing
in the destination's shape means nothing gets unexpectedly cropped later.
Strokes are rasterised at export resolution, not upscaled from the on-screen
canvas.

## Possible improvements

- **Reactions on a moment** — a heart or a quick emoji back, without composing
  a whole reply. Would need a small `Reaction` record type and a fourth
  subscription.
- **Status history** — the app keeps only the current status. Keeping a rolling
  log would make "you were asleep when I sent that" legible.
- **A shared countdown** to the next time you're in the same place, as a
  dedicated lock screen widget.

## Known limitations

- **Lock screen widgets are monochrome.** iOS renders accessory widgets in a
  vibrant, desaturated style; emoji become white silhouettes. Every layout
  therefore pairs the emoji with words rather than relying on colour.
- **Status updates are silent, so they can lag.** Nudges and photos arrive as
  real alerts and survive a force-quit; a plain status change relies on a
  throttled background wake, and won't reach a force-quit phone until something
  else wakes the app. The widget's hourly fetch is the backstop.
- **The first sync after a reinstall pulls the whole zone.** Metadata only, so
  it's quick, but the images arrive gradually — the ten newest immediately and
  the rest as you scroll back. Expect placeholders in the gallery for a while
  on a fresh phone.
- **The service extension has ~30 seconds and a small memory ceiling.** If the
  CloudKit fetch is slow it falls back to CloudKit's generic wording rather
  than showing nothing — you'd see *"Sent you something 📷"* instead of the
  caption, and the app fills in the detail on next launch.

## Shipping it

Everything below is already wired up; this is the order to do it in.

1. **Set your team** — `DEVELOPMENT_TEAM` in [project.yml](project.yml),
   then `make project`. All three targets (`RedString`,
   `RedStringWidgetExtension`, `RedStringNotificationService`) inherit it from
   the project level.
2. **Run once on a device** with a Debug build. That creates the CloudKit
   *Development* schema automatically — record types `Status`, `Nudge` and
   `Moment` with their fields — the first time each record is saved. Pair, set
   a status, send a nudge and send a photo, so every type and field actually
   gets created.

   **Tapping "Create a link" is part of this step, not an optional extra.**
   Zone sharing needs a system record type, `cloudkit.share`, and CloudKit only
   adds it to the Development schema the first time a `CKShare` is actually
   saved. Deploy before you have ever created an invite and Production is left
   without it — the *first* thing a new user does then fails with
   `Cannot create new type cloudkit.share in production schema`. You cannot add
   the type by hand in the Console; you have to create a share in Development
   and deploy again.
3. **Deploy the schema to Production** in the CloudKit Console
   (*Schema → Deploy Schema Changes*). Production does **not** auto-create
   anything, so an App Store build against an undeployed schema fails on every
   write. Re-deploy whenever you add a field. Confirm afterwards by switching
   the Console to *Production* and checking that `Status`, `Nudge`, `Moment`
   **and `cloudkit.share`** are all listed under Record Types.
4. **Archive** with `make archive` (or Xcode's *Product → Archive*). The
   Release configuration already points at
   [RedString-Release.entitlements](Sources/App/Resources/RedString-Release.entitlements),
   which sets `aps-environment` to `production`; Debug uses the `development`
   file. This is per-configuration in `project.yml`, so there's nothing to
   remember at archive time.
5. **Check the app icon.**
   [icon-1024.png](Sources/App/Resources/AppIcon.xcassets/AppIcon.appiconset/icon-1024.png)
   is still the two-ring artwork drawn for the old name. It's a valid icon and
   will pass review, but it's off-brand now — replace it with a 1024×1024
   **opaque** PNG (no alpha channel; the App Store rejects transparency).

Two things to know about the CloudKit schema:

- **Encryption is fixed at field creation.** CloudKit won't let you encrypt a
  field that already exists unencrypted. If you experimented with an earlier
  build and the dev schema has the wrong shape, reset the Development
  environment in the Console before running again.
- **Subscriptions must be created in Development first**, then promoted — the
  app registers them on launch and after pairing, so this happens on its own
  as long as step 2 was done in Debug.

## Layout

```
Sources/
  Shared/      compiled into BOTH targets
    AppConfig.swift          the IDs that must match the entitlements
    Theme.swift              colours, cards, buttons
    Models/                  Mood, StatusPayload, PairingInfo, Snapshot, Moment
    Store/SharedStore.swift  App Group cache — the app↔widget channel
    Store/MomentStore.swift  image files in the App Group, full + thumb
    Store/MomentIndex.swift  the durable history list, kept out of the snapshot
    Cloud/SyncBackend.swift  the sync surface the UI depends on
    Cloud/CloudSync.swift    CloudKit: sharing, records, assets, subscriptions
  App/
    RedStringApp.swift, AppDelegate.swift   push registration, share acceptance
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
  NotificationService/
    NotificationService.swift            enriches pushes; runs when the app can't

Each target's Resources/ also carries a PrivacyInfo.xcprivacy — required for
App Store submission. Red String declares no tracking and no collected data;
the one required-reason API is the App Group defaults suite (CA92.1).
```

## Commands

| | |
|---|---|
| `make project` | regenerate the Xcode project from `project.yml` |
| `make build` | compile check for the Simulator (unsigned — don't launch it) |
| `make run` | build signed, install and launch on the Simulator |
| `make archive` | archive the Release config for TestFlight / the App Store |
| `make clean` | |

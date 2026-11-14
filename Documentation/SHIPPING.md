# Shipping it

Getting a build to TestFlight and the App Store, and the CloudKit schema steps
that have to come first.

Everything below is already wired up; this is the order to do it in.

1. **Set your team** — `DEVELOPMENT_TEAM` in [project.yml](../project.yml),
   then `make project`. The shipping targets (`RedString`,
   `RedStringWidgetExtension`, `RedStringNotificationService`) inherit it from
   the project level.
2. **Run once on a device** with a Debug build. That creates the CloudKit
   *Development* schema automatically — record types `Status`, `StatusLog`,
   `Nudge`, `Moment`, `Receipt` and `Anniversary` with their fields — the first
   time each record is saved. Pair, set a status (which also writes a
   `StatusLog`), set a celebration status from the picker (🎂 *happy birthday*
   or any other — it writes `celebrationStyle`), send a nudge, send a photo, **turn on read receipts + view a
   received moment with the home screen in front** (which publishes a `Receipt`
   record with both the seen-map and the status-receipt fields), **and answer
   the "when did you begin?" prompt as the owner** (the `Anniversary` record),
   so every type and field actually gets created.

   As the participant, also tap **"Ask … to set it"** on the count screen once
   (the `AnniversaryRequest` record).

   Then run **one complete fresh start** between the two Debug devices (Settings
   → Fresh start: ask on one, agree on the other, and open the app on both until
   each has cleared). The `FreshStart` record only gets all three fields —
   `stage`, `epoch` (from the agreement and commit) and `clearedBefore` (from
   the completion) — over a full round, and each field's encryption is fixed
   when it's created. While you're there, check Diagnostics on both phones
   shows the round finished (`Fresh start:` line): the consent check reads
   `lastModifiedUserRecordID` and assumes your own writes come back as
   `__defaultOwner__` or your account's record name in both databases — a
   clear refused with "doesn't show the fresh start agreed" means that
   assumption is wrong on the live service.

   **Tapping "Create invite link" is part of this step, not an optional extra.**
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
   the Console to *Production* and checking that `Status`, `StatusLog`,
   `Nudge`, `Moment`, `Receipt`, `Anniversary`, `AnniversaryRequest`,
   `FreshStart` **and `cloudkit.share`** are all listed under Record Types.
4. **Archive** with `make archive` (or Xcode's *Product → Archive*). The
   Release configuration already points at
   [RedString-Release.entitlements](../Sources/App/Resources/RedString-Release.entitlements),
   which sets `aps-environment` to `production`; Debug uses the `development`
   file. This is per-configuration in `project.yml`, so there's nothing to
   remember at archive time.
5. **Check the app icon.**
   [icon-1024.png](../Sources/App/Resources/AppIcon.xcassets/AppIcon.appiconset/icon-1024.png)
   is the fox, fish and red rope infinity logo in the current palette, an
   opaque 1024×1024 PNG. Any replacement must stay **opaque** (no alpha
   channel; the App Store rejects transparency).

Two things to know about the CloudKit schema:

- **Encryption is fixed at field creation.** CloudKit won't let you encrypt a
  field that already exists unencrypted. If you experimented with an earlier
  build and the dev schema has the wrong shape, reset the Development
  environment in the Console before running again.
- **Subscriptions must be created in Development first**, then promoted — the
  app registers them after pairing and re-checks them once a day at launch, so this happens on its own
  as long as step 2 was done in Debug.

## Schema gotchas, in short

- Production auto-creates nothing; deploy after Development use. `cloudkit.share` enters the schema only when a Debug device build saves a share; `Receipt`, `StatusLog`, `Anniversary`, `AnniversaryRequest` only once one is saved (`statusSeenAt`/`statusSeenFor` once a status has been on screen; `Status.celebrationStyle` once a celebration preset is sent); `FreshStart` gets every field only from a complete two-device round.
- Field encryption is fixed at creation. Code signing picks the environment (Dev vs Prod); mixed-environment devices can't see each other — looks like a broken pairing (`CloudDiagnostics`).
- **A second device on the same iCloud account** (a Simulator signed in as you) is the same CloudKit user and `PairRole`: it writes *your* records and fires *your* subscriptions. Its writes show as your own, never the partner's; the NSE words its pushes "from another device" (invariant 10).
- Subscriptions: `status-alerts` (visible; registered silent — the NSE adds the sound), `nudge-alerts`, `moment-alerts` (visible + sound + mutable content); legacy `status-changes` is deleted on sight.

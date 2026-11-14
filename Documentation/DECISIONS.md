# Decisions

Ideas that were built and removed, left as they are on purpose, or rejected,
and why. Moved out of [ROADMAP.md](../ROADMAP.md), which lists only work still
to do. Read this before proposing one of them again.

## Parked, considered and rejected

- **Reactions on a moment** (needs a `Reaction` record type + subscription).
  Built and removed in September 2026 — the UI never felt right; the sync
  design (one `reaction-<role>-<momentID>` record per person per moment,
  encrypted emoji, own subscription, removal pushes that can't be suppressed)
  is in the git history. The warm acknowledgement (Tier 2) is the receipt-based
  replacement.
- **Also considered:** heart variants (adjacent to super nudge; one plaintext
  Int on `Nudge`), a Lock Screen doodle glyph (legibility unproven). The Apple
  Watch is now a Tier 4 item.
- **CarPlay (iOS 26) — left as is, October 2026.** CarPlay offers every
  `systemSmall` widget (Statuses, Their photo) with no CarPlay app; whether one
  goes in a car is the user's choice, so neither is `.disfavoredLocations`-ed.
  Tapping one in the car does nothing, as intended.
- **Thumbnail inside the NSE's change fetch** — would save the banner a round
  trip, but puts media before the token (against invariant 2). Not recommended.
- **Old `StatusLog` entries** logged before the cloud log existed are local-only
  and don't survive a reinstall (documented; nothing to do unless it matters).
- **Rejected:** Live Activities started remotely (push-to-start needs a server),
  location sharing, view-once photos, `CKSyncEngine` (owns the change token,
  against invariant 2).


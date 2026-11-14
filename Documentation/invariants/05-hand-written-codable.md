# Invariant 5: Hand-written Codable

Read before touching `Snapshot`, `StatusPayload`, `Moment`, `PairingInfo`, any persisted type.

**Hand-written Codable.** `Snapshot`, `StatusPayload`, `Moment`, `PairingInfo` (only the zone's role and names required — a `nil` pairing reads as unlinked) decode with `decodeIfPresent` + fallbacks so old data survives; new persisted fields follow suit (mind what the fallback means for legacy data). `Snapshot.CodingKeys` is `CaseIterable`, checked against the stored properties by `SnapshotCodableTests`; `Snapshot()` builds the defaults.

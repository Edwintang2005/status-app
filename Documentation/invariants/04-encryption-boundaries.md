# Invariant 4: Encryption boundaries

Read before touching any record field, `CloudSync` record writers, `PhotoLocation`.

**Encryption boundaries.** Text and behavioural fields (`emoji`, `message`, `displayName`, `caption`, `senderName`, `waveform`, `isCelebration`/`celebrationStyle`, `seenMap`/`statusSeenAt`/`statusSeenFor`, `startsAt`/`timeZone`, `requestedAt`, the fresh start's fields) go through `record.encryptedValues`. Plaintext by design: record names, moment `kind`/`sentAt`/`duration`/`momentID`, nudge `count`/`sentAt`, `updatedAt` (locked-phone banners need `kind`). `CKAsset`s, encrypted by CloudKit, must NOT go through `encryptedValues`; a photo's place rides inside its full-size asset (`PhotoLocation`), never as a field. Plaintext user words are a privacy regression.

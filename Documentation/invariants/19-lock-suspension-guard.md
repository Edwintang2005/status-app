# Invariant 19: Never hold a shared-container file lock without a suspension guard

Read before touching `CrossProcessLock`, `withUploadProtection`.

**Never hold a shared-container file lock without a suspension guard** (suspended mid-`flock` = `0xdead10cc`). `CrossProcessLock.withLock` holds a `performExpiringActivity` assertion; paths that end a background task (`withUploadProtection`) do post-await bookkeeping *inside* the protected closure.

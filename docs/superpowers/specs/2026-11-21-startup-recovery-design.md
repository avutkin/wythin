# Data-preserving startup recovery

The user reports build 159 repeatedly crashes before opening and has explicitly asked us to proceed without requesting crash logs. The exact device exception remains unavailable. This change addresses two confirmed unsafe startup paths, not a proven diagnosis of that device: forced container reopening after any error, and synchronous main-context history fetches during foreground activation.

## Approach

Keep the current schema and chart gap behavior. Open the disk store off the main actor. A throwing open must leave the existing store and sidecars in place, report a recoverable state, and permit a single retry; never substitute an empty store. Start loading from App initialization so Bluetooth/background URL-session restoration does not depend on a SwiftUI view appearing. Start AppEnvironment and Health services exactly once after the store succeeds. A lightweight opening/error screen exists before those services. Existing recordings remain inaccessible until their store can be opened, rather than being represented as an empty history.

Use one coalesced background history read for launch/foreground. Fetch and map SwiftData records on its own background context; publish only value snapshots. Merge with concurrently arriving live points by timestamp, retaining live points on duplicates and the newest 43,200 observations. Discard stale in-flight results after explicit cloud restore/timezone invalidation. Recording and upload behavior otherwise remains unchanged.

Alternatives considered: reverting 159 charts has no reproduced causal evidence and loses the requested gap fix; continuing to require a device report is unavailable by user instruction. A broad crash-loop safe mode is deferred because an unclean background exit must not disable recording.

## Verification and limits

Tests cover a failed open without file relocation, repeated failure/retry/success, concurrent starts, background initiation without a view, responsive main actor during a blocking read, overlapping snapshots/live arrivals, bounded ordering, and stale-result invalidation. Keep the existing chart rendering diagnostic. Full signed simulator suite and independent review precede release through tools/ship.sh. No claim that physical-device startup or overnight Polar reliability is confirmed by simulator tests.

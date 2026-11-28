# Memory pressure during recording

User instruction: record the identified errors and fix them. Continue the existing recording-resilience work; preserving measurements and existing anchor semantics is the priority. KT's termination reason is still unknown: received reports include short background launch spans and no memory-warning/termination events, but no system crash/jetsam report.

## Confirmed code defects and chosen approach

1. AnchorBackfill reads the entire 60-day baseline into HRVSample objects, maps a second representation, then groups the complete history. Replace it with one calendar day at a time, enumerating SwiftData in batches into plain snapshots. Keep the detector and version 3 unchanged. Store at most 60 small candidate readings before one atomic save; no edits until all required reads succeed. Bound a pathological day at 60,000 snapshots: exceeding the bound is a reported failure, never a truncated successful result. Preserve original samples and anchors on failure/cancellation. A normal 25-hour day at two-second cadence is 45,000 samples.
2. Detached backfill continues after its foreground owner is canceled. Forward cancellation into the worker and check it during enumeration, between days and before mutation/save. Use a fresh read context for each day; the small write context has autosave disabled and rolls back on failure. Snapshot calendar/timezone for the pass; abandon if the zone changes before commit. Multi-day baseline warm-up likewise scopes its read context per day and propagates fetch failures instead of caching them as empty data.
3. The memory-warning handler currently only logs. Suspend optional foreground preparation until a real background→foreground transition; drain its canceled task before another attempt. Do not stop BLE, metric recording, upload or the recording-owned tick history. Display updates remain live. A warning is not a request to delete stored data or invalidate persistent caches.
4. Current automatic diagnostics do not measure RAM. Add a local-only, rate-limited memory log at most once per minute plus warnings, using physical footprint and advisory available memory. Track the peak of observed samples, not an asserted OS lifetime peak. Reuse the existing bounded diagnostic log/export; no wire schema change, signal values, identifiers, production mutations or new upload.

## Alternatives

Only moving the whole fetch to another queue leaves the memory spike intact. A full streaming rewrite of AnchorDetector would reduce memory further but changes a validated algorithm unnecessarily. Chosen bounded daily replay retains current detector behavior and is independently testable. This implementation choice is the executor's under the user's instruction to fix the confirmed risks.

## Verification

Regression tests must show day isolation, release/bounds, preservation of anchors for unreadable/missing days, no writes or completed flag after cancellation, and successful retry. Existing detector/backfill fixtures must remain green. Pressure tests must show no immediate restart loop and retry after foreground transition. Memory sampling tests cover rate limiting, clock rollback, forced warning and unavailable readings. Run the complete WythinTests suite and independent final review. Simulator results do not prove the cause of KT's termination or 24-hour physical-device uptime.

# Apple Health launch watchdog fix

**User report:** Wythin stops opening after installing build 165.

**Evidence:** Device crash `Wythin-2026-11-27-205919.ips`, version 1.1 (165), UUID `C272191D-A947-376A-9FAE-1920F3D6A709`. iOS terminated it with `0x8BADF00D`, process-exit watchdog, after it failed to terminate gracefully for five seconds. Main thread waits in `NSManagedObjectContext.performBlockAndWait` while submitting SwiftData actor work. Symbolicated worker stack: `HealthSyncCoordinator.synchronize` → `HealthRepository.applyWorkouts` → `removeWorkoutData` → `HealthCoding.decoder` → ISO8601 parsing. The raw report stays in `/private/tmp/wythin-launch-165.ips`, outside git.

**Design:** Keep Health work serial and off the UI thread even when its queue is busy. Avoid repeatedly decoding every saved sample for HealthKit deletion IDs, particularly unknown/already removed workouts. Preserve transactional tombstones, anchors, outbox updates and shared measurements. No deletion/reset of the user's database, no schema changes, and no Garmin changes.

- [x] Reproduce expensive unknown deletions and blocked MainActor scheduling with focused tests.
- [x] Fix the demonstrated bottlenecks and verify shared-sample deletion, replay and cloud restore.
- [x] Independent review, full WythinTests and Release launch verification.
- [x] Merge and release using `tools/ship.sh`; verify external TestFlight status.

## Verification evidence

- Both original regressions failed at runtime: unknown deletions took 4.230 s; MainActor probe stalled 1.057 s (`/private/tmp/wythin-launch-red.log`).
- Initial executor/cleanup change passed all 18 repository tests.
- Broader suite exposed default localized string sorting incompatible with keyset comparison (28 samples skipped); explicit lexical sorting now matches the cursor predicate.
- Review found cloud samples may reference absent workouts. Added a regression and observed two failures; the final cleanup scans memberships for all deletion IDs, with an empty-ID fast path.
- Reviewer independently checked executor CRUD under Core Data concurrency assertions in macOS probes. No confinement failure found.

- Final HealthRepository suite: 20 tests passed (`/private/tmp/wythin-launch-health-final.log`).
- Independent review approved the corrected all-ID membership scan and lexical pagination; no remaining actionable findings.
- Final full WythinTests: 2043 executed, 2 existing opt-in background-upload tests skipped, 0 failures (`/private/tmp/wythin-launch-full-final.log`).
- Release simulator build succeeded (`/private/tmp/wythin-launch-release-fixed.log`). The app launched on a clean iPhone 17 Pro Max simulator, stayed running, terminated gracefully in 0.201 s, and relaunched successfully. The relaunched process remained alive during release upload. The fixed build has not yet been verified on the reporting user's physical iPhone.
- Fix merged as `da70097`; the official ship pipeline repeated the full suite with 2043 tests, 2 existing opt-in skips, 0 failures (`/private/tmp/wythin-ship-tests.log`) and recorded build 166 as `e3624ac`.

## Release evidence

- `tools/ship.sh testflight` finished successfully: archive/export succeeded, build 166 processed as `VALID`, export compliance set.
- Build 1.1 (166), App Store Connect ID `145ec927-2052-4199-a1c6-e4a3555c2a09`, assigned to External Testers and submitted for beta review.
- Fresh App Store Connect verification on 2026-11-28 UTC: external and internal states both `IN_BETA_TESTING`, `expired: false`, external group assignment present, automatic tester notifications enabled.
- Public link is enabled without a tester-count limit: https://testflight.apple.com/join/7c7b68t1. Existing public-link testers can update to build 166.

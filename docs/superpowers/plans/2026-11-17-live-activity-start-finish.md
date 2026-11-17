# Live activity: Start Now → Finish

## Requested behavior

Start Now begins an open-ended activity in a separate live section. Show an elapsed timer and current sensor metrics until the user explicitly taps Finish. Only then present the completed interval and session summary in history. Log Past Activity remains the retrospective flow.

## Findings and changes

The persisted live model already supports `endedAt = nil`, but Activities placed running sessions inside scored history rows. Both action buttons also used the automatic button style in one List row; this is a plausible explanation for Start Now reaching the retrospective form, but an actual tap reproduction was unavailable while the Mac was locked. Apple documents container-dependent behavior for the [automatic button style](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/automatic). Both actions now use explicit plain styles and distinct accessibility IDs.

- Running entries appear in a separate LIVE ACTIVITY section, excluded from day-grouped history.
- The card shows actual elapsed time from the saved start, current pulse, Calm Power, Stress Balance, Breath Rate, Vagal Tone, and a full-width FINISH control. It has no completed score, end time or estimated duration.
- A one-second TimelineView updates the clock independently of incoming measurements. Metric readings must be fresh, from this session, and backed by live RR; stale/pre-session/future readings disappear while the elapsed timer continues.
- The Start Now form only chooses an activity; no end-time or duration controls. It creates an untargeted live entry. Existing optional target data used by other flows remains supported and never stops a session automatically.
- Finish stamps the actual end and moves the entry into history. A repeated Finish cannot change an already saved end time or end a different active lock-screen session.
- Incoming ticks refresh recent completed after-windows. Active cards use current readings directly instead of recomputing a growing session score on every tick.
- Current Apple Health changes from main are preserved. No historical intervals are guessed or rewritten; an incorrectly logged past interval is still editable in history.

## Verification

The repeated-Finish regression failed before the implementation (`/private/tmp/wythin-activity-live-red.xcresult`). The focused activity suites passed **50 tests, zero failures** (`wythin-activity-live-targeted.xcresult`). Tests cover active/history separation, saved open-ended state across a model-context reload, elapsed time without metrics and past a target, stable finish timestamps, fresh/current metric selection and unavailable values. Production card renders at 375-point width were reviewed in both receiving-data and waiting-for-sensor states; labels, values, elapsed time and Finish fit without truncation.

The Mac was locked when attempting the interactive simulator walkthrough; the user was asked to unlock it while implementation continued. Static renders and tests are not a tap-through verification of Start Now → picker → live session → Finish. Full-suite and delivery results will be recorded below.

Final full suite: **1,891 tests, 1 opt-in background transport test skipped, zero failures**, exit 0 (`/private/tmp/wythin-activity-live-full.xcresult`). This includes the current Apple Health tests. `git diff --check` passed. No server changes are required for this activity flow.

## Review and release follow-up

Independent review found that a sensor update arriving between one-second display updates could be compared with an older `TimelineView.Context.date` and briefly be hidden as a future reading. The freshness check now uses wall time; the elapsed display still follows its one-second schedule. Coverage includes a reading arriving between clock ticks. Apple defines [the timeline context date as the scheduled update date](https://developer.apple.com/documentation/swiftui/timelineview/context/date), rather than the time of each observed-data redraw. No other important introduced issues were found in review.

The first release attempt reserved build 153 but failed before upload because the cached signing profile did not include the new HealthKit capabilities from main. `ship.sh` supplied the existing App Store Connect key to export but not archive; the archive command now receives the same authentication arguments so automatic provisioning can refresh the profile. The retry reached compilation with provisioning resolved. Build 154 was stopped before upload to include the review correction above. Neither 153 nor 154 was released to testers.

After the review correction, the full suite passed again: **1,891 tests, 1 opt-in skip, zero failures**, exit 0 (`/private/tmp/wythin-activity-live-reviewed.xcresult`). The reviewer confirmed the timing finding resolved with no further blocking findings. A second simulator access attempt still reported the Mac locked; interactive tap-through remains unverified.

## Delivered

**TestFlight 1.1 (156)** was archived and uploaded through `tools/ship.sh testflight` from release commit `9999412`. Its release suite again passed 1,891 tests with one opt-in skip and zero failures. App Store Connect reports processing `VALID`, export compliance `usesNonExemptEncryption = false`, and beta review `APPROVED`. English and Russian test notes were saved and read back. Build ID `99818993-2fc7-4c9b-bbf8-b314cd3fdd4a` is present in both the Internal and External Testers group relationships; the existing [TestFlight invitation](https://testflight.apple.com/join/7c7b68t1) is unchanged.

Build 155 passed archive but Apple rejected its upload with error 90683: the Apple Health integration on main lacked `NSHealthUpdateUsageDescription`. Build 156 adds the required purpose string, accurately stating that Wythin only reads permitted Health data. `HealthKitSource` still requests `toShare: []`; no write permission was added. Both Health purpose strings were verified in the final archived app.

After Apple accepted 156, the script's processing poll stopped on an empty/non-JSON API response. Processing, compliance, review, and group assignment were completed and verified through the App Store Connect API. The documented `POST /v1/builds/{id}/relationships/betaGroups` assignment returned 204; membership was verified using the app-filtered beta-groups listing with included builds. Direct group/detail lookups returned intermittent 404s and were not used as availability evidence.

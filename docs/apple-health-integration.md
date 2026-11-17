# Apple Health integration

The implementation lives in the isolated `codex/apple-health-integration` branch.
It adds a native iPhone HealthKit reader, separate local storage, a cloud API,
and imported activities in the existing journal. No server can read a person's
Apple Health store directly: the authorized iPhone reads it and optionally
uploads to Wythin. Apple Watch workouts arrive through Health on that iPhone.

## Using the integration

1. Open **Settings → Apple Health → Connect Apple Health** on a signed iPhone build.
2. Choose the Health data Wythin can read in Apple's permission sheet. Wythin
   imports every accessible saved workout type and resumes historical imports.
3. Open an imported journal entry to see its source, active/elapsed duration,
   measurements, and statistics for **5 minutes before**, **during**, and
   **10 minutes after**. Available metrics include heart rate, SDNN, steps,
   active energy, and walking/running/cycling/swimming distance.
4. Cloud storage requires the separate Health cloud confirmation and the
   app-wide cloud switch. The confirmation names the configured server.

No measurement is inferred from an empty Health query. Permission denial is
indistinguishable from inaccessible data for some HealthKit reads. Source
series remain separate; sparse observations do not become continuous coverage.
SDNN is never converted into Polar RMSSD or written into Polar sample tables.
Heart-rate recovery is shown only with close supporting observations.

An overlapping completed manual exercise can be explicitly linked from the
imported detail screen. Both entries and notes remain intact. These ID-only
links are local to the device. Workout titles and notes use the Health API;
the legacy activity uploader and automatic AI analysis exclude Health imports.

## Synchronization and deletion

HealthKit observers are registered at launch after a previous connection.
Foreground resumes history and queued work; background delivery follows iOS
scheduling and is not an instant-delivery guarantee. Anchors and the outbox
commit with data. Frozen upload batches retry with the same IDs and bytes.
Long quantity series publish only after their ordered parts and digest commit.

Disconnect stops further import and keeps saved history. Disabling Health
cloud keeps local data and pauses server consent. **Delete imported data**
removes imported local data and queues durable cloud deletion if offline.
The general **Delete my cloud data** action includes the independent Health
archive but retains local Health history; renewed Health cloud consent rebuilds
its upload snapshot. Epochs, a local generation, and tombstones prevent old
responses from resurrecting deleted records.

Cloud ownership uses a separate installation credential in Keychain, not a
caller-selected user ID or the legacy API key. A retained credential supports
same-installation restore after reinstall. Losing that credential means a new
empty archive; cross-device account linking is outside this version. Restore
keeps saved annotations and analysis even when current Health reads are empty.

## Development and verification

See [Health API](health-api.md) for endpoints, authentication, payloads,
pagination, limits, and PostgreSQL test setup. The approved design is in
[the integration spec](superpowers/specs/2026-11-15-apple-health-integration-design.md).

The iOS target includes HealthKit and background-delivery entitlements and a
read-purpose description. A valid signing profile with the capability is
required for a real device. No production server, device installation,
App Store submission, or deployment is performed by this implementation.

Automated tests use synthetic measurements, a disposable PostgreSQL database,
and the iOS simulator. Coverage includes replay/rollback, series publication,
source isolation, permission/consent gates, deletion races, reinstall restore,
the persisted pre-change ActivityLog schema, and an actual Swift-generated JSON
batch ingested and restored through PostgreSQL. Existing manual and sleep rows
are checked through migration and another reopen.

Before release, test on a signed iPhone with Watch data: selectively grant and
deny types; import an old workout and a new Watch workout; lock/unlock and
background the app; add/delete a measurement; delete a workout in Health;
interrupt uploads; turn cloud off during a sync; finish an offline deletion;
reinstall with retained Keychain credential; and inspect a long workout with
gaps and multiple sources. These device behaviors cannot be proven by simulator
tests. Shipping must use the repository's `tools/ship.sh` workflow after merge.

### Verified on 2026-11-16

- Full WythinTests: **1,754 passed**, no failures or skips, iPhone 17 Pro
  simulator / iOS 26.5, Xcode 26.6, signing disabled.
- Full server suite: **201 passed** against disposable PostgreSQL on port
  56467, including the exact Swift-generated series/analysis/annotation batch.
- `git diff --check` and plist/project syntax checks passed.
- Independent code review findings were fixed and rechecked. Tests cover
  overlapping notifications, global consent withdrawal between requests,
  deletion during restore, reused server epochs, successive analysis revisions,
  empty Health reads, oversized annotations, and legacy disk-store migration.
- Signed-device HealthKit permissions, background delivery, and Keychain
  persistence remain device acceptance checks. Cloud-consent tests inject a
  credential store because the simulator test app is unsigned.

The feature remains local to its branch; it has not been deployed or installed
on a phone. Existing unrelated Swift 6 isolation and duplicate MetricNamingTests
project warnings remain in the baseline.

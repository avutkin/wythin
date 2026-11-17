# Apple Health API v1

This archive belongs to one Wythin installation. It is separate from legacy
users, activities, PATs, the admin dashboard, MCP, and AI processing. All values
below are synthetic. Production clients must use HTTPS.

## Enrollment and consent

`POST /v1/health/installations` with `{}` returns HTTP 201:

```json
{"installation_id":"0c631bd9-faa0-46e5-a018-3b3af7d2ee95","credential":"whi_<43 URL-safe characters>"}
```

The server generates both identifiers. Caller-selected owner IDs, extra body
fields, and legacy credentials are rejected. The credential contains 256 random
bits; only its SHA-256 hash is stored. Save it in Keychain with
`AfterFirstUnlockThisDeviceOnly`. It is returned once. Losing it loses access to
this server archive; a new enrollment creates a separate empty archive.
Enrollment allows 120 requests per hour per directly connected peer IP across
workers. A reverse proxy must supply trusted client addressing through the ASGI
server's configured proxy trust; arbitrary forwarded headers are not read here.
Unconnected enrollments older than 24 hours are removed during enrollment.

Every other endpoint requires `Authorization: Bearer whi_…`, even when `API_KEY`
is unset. `X-User-ID`, `X-API-Key`, and `/v1/tokens` credentials confer no Health
access. `POST /v1/health/apple-health/connections`:

```json
{"stream_id":"c514452d-3321-4734-977f-509093244bc8","cloud_consent":true,"consent_version":"1"}
```

Response includes `connection_id`, `connection_epoch`, `stream_id`,
`expected_sequence` (initially 1), `server_revision`, `cloud_consent`,
`consent_version`, `state` (`active` or `paused`), and
`limits: {"max_changes":200,"max_body_bytes":2097152}`.

`GET /v1/health/apple-health/status` returns the same metadata plus `last_ack_at`.
`PATCH /v1/health/apple-health/connections/{connection_id}` with
`{"cloud_consent":false}` pauses ingestion while preserving stored data.
Resumption requires `cloud_consent:true` and a nonempty `consent_version`.

## Ordered ingestion

`POST /v1/health/apple-health/batches` accepts at most 200 changes and 2 MiB of
actual JSON bytes, including chunked request bodies:

```json
{
  "schema_version":1,
  "connection_id":"5fce69c6-096d-44e4-b5df-b5c0d2082185",
  "connection_epoch":1,
  "batch_id":"883a23d4-2cad-45eb-854f-9a26d1ae8755",
  "stream_id":"c514452d-3321-4734-977f-509093244bc8",
  "sequence":1,
  "changes":[{
    "operation_id":"492c3ed1-cd69-43ac-888f-5120730231ee",
    "operation":"upsert_workout",
    "external_id":"e9829cef-3b48-4285-bf10-fdcb4e8d2d44",
    "workout":{
      "activity_code":37,
      "activity_name":"Running",
      "started_at":"2026-11-15T15:30:00Z",
      "ended_at":"2026-11-15T16:10:00Z",
      "active_duration_seconds":2400,
      "timezone":"America/Los_Angeles",
      "source":{"bundle_identifier":"example.synthetic.recorder","name":"Synthetic recorder"},
      "user_entered":false,
      "events":[],
      "segments":[]
    }
  }]
}
```

The acknowledgement is stored transactionally with all changes:

```json
{
  "batch_id":"883a23d4-2cad-45eb-854f-9a26d1ae8755",
  "sequence":1,
  "server_revision":1,
  "connection_epoch":1,
  "expected_sequence":2,
  "workout_mappings":[{"external_id":"e9829cef-3b48-4285-bf10-fdcb4e8d2d44","activity_id":"0476b713-02cc-452a-b0be-91742e9998d8"}],
  "results":[{"operation_id":"492c3ed1-cd69-43ac-888f-5120730231ee","status":"applied"}]
}
```

Retry the immutable batch after network failure. An identical accepted batch
returns its original acknowledgement, including during pause. Reusing its ID
or sequence with different content returns 409. An operation ID replayed in a
new valid batch is `replayed`; different content is a conflict. Future sequence,
wrong stream, and old epoch return 409. No partial batch is committed.

Operations are `upsert_workout`, `delete_workout`, `upsert_sample`,
`delete_sample`, `upsert_analysis`, `update_annotation`, `begin_series`,
`series_part`, and `commit_series`. Every change includes `operation_id`,
`operation`, `external_id` and exactly its operation's payload, except deletes,
which have no payload.

Workout optional fields are `activity_name`, `timezone`, `energy_kcal`,
`distance_meters`, `user_entered`, `events:[{kind,started_at,ended_at}]`, and
`segments:[{activity_code,started_at,ended_at}]`. Activity codes are preserved,
including unknown future codes. Duration must be nonnegative and at most
elapsed time plus one second for timestamp rounding; there is no three-hour cap.
Timestamps require a timezone, and all intervals must be chronological.

A sample payload is:

```json
{
  "metric":"heart_rate","value":123,"unit":"count/min",
  "started_at":"2026-11-15T16:00:00Z","ended_at":"2026-11-15T16:00:00Z",
  "source":{"bundle_identifier":"example.synthetic.recorder","name":"Synthetic recorder"},
  "representation":"point","parent_id":null,
  "workout_ids":["e9829cef-3b48-4285-bf10-fdcb4e8d2d44"]
}
```

Allowed metric/unit pairs are `heart_rate:count/min`, `hrv_sdnn:ms`,
`active_energy:kcal`, `distance_walking_running:m`, `distance_cycling:m`,
`distance_swimming:m`, and `step_count:count`. Values must be finite and
nonnegative. Representations are `point`, `interval`, and `series`.
Sources contain bounded `bundle_identifier`, `name`, optional `version`, and
optional descriptive `device_name`, `device_model`, `software_version`.
Arbitrary HealthKit metadata and device serial numbers are not accepted.

## Series publication

All three series operations use the parent HealthKit UUID as `external_id`.
`begin_series` carries:

```json
{"series":{"generation":"ec110398-30ca-4291-bbfa-e8cb506b7efa","expected_parts":2,"digest":"<64 lowercase hexadecimal SHA-256 characters>"}}
```

`series_part` carries:

```json
{"series":{"generation":"ec110398-30ca-4291-bbfa-e8cb506b7efa","part_index":0,"samples":[{"external_id":"502a4d43-4487-4f1f-9877-6026d5768fc1","metric":"heart_rate","value":123,"unit":"count/min","started_at":"2026-11-15T16:00:00Z","ended_at":"2026-11-15T16:00:00Z","source":{"bundle_identifier":"example.synthetic.recorder","name":"Synthetic recorder"},"representation":"series","parent_id":"0d63a27e-61d5-4ef4-bc65-49458ab493b0","workout_ids":["e9829cef-3b48-4285-bf10-fdcb4e8d2d44"]}]}}
```

`commit_series` carries only `series:{generation}`. The digest is SHA-256 of
UTF-8 lowercase child UUIDs joined by newline, with **no trailing newline**.
Order is ascending part index, then array order within each part. It verifies
the manifest; immutable operation and batch hashes also bind complete sample
content. Parts allow at most 1,000 children each and must have distinct UUIDs.
`parent_id` of every child must equal the change's `external_id`.

Staged children are invisible until complete commit. Publishing a series
uses the series operations; direct `upsert_sample` of a child with `parent_id`
is rejected unless the object is already tombstoned (`ignored_deleted`).
Beginning a replacement
marks the published generation and affected analysis stale. Commit replaces
the old generation atomically. Deleting a parent deletes published and staged
children. Tombstones are terminal within an epoch, including deletes received
before data; later writes return `ignored_deleted` so the queue can advance.

## Analysis and annotations

`update_annotation` carries `annotation:{title,notes}`; either may be null.
Workout refreshes preserve this overlay. `upsert_analysis` carries:

```json
{"analysis":{"algorithm_version":1,"input_revision":12,"computed_at":"2026-11-15T16:25:00Z","status":"partial","statistics":[],"hrr60":null,"hrr_source":null}}
```

Statistics have `window` (`before`, `during`, `after`), `metric`, `source`,
`method`, `count`, optional `mean`, `minimum`, `maximum`, `total`, `first_at`,
`last_at`, and nonnegative `observed_seconds`, `boundary_samples_omitted`.
`hrr_source` is the source bundle identifier. Analysis status is `pending`,
`available`, `partial`, or `no_data`. The server stores client results with
`computed_by:"client"` and `stale:false`; it does not independently calculate
or certify them. Sample changes invalidate linked and overlapping workout
windows (five minutes before through ten minutes after), regardless of age.

## Restore and purge

`GET /v1/health/activities?limit=100&cursor=…` returns
`{items,next_cursor,has_more,connection_epoch}`. A page is an ordered durable
change feed, so a workout may appear more than once at increasing revisions.
Each item contains `external_id`, canonical `activity_id`, `workout`,
`analysis`, `annotation`, `deleted`, and `server_revision`. Tombstones have
`deleted:true` and null payloads. The opaque signed cursor is bound to owner
and epoch; even an empty page returns a cursor suitable for future changes.
Save the page locally before advancing it and continue while `has_more`.
Pages also stop at 1.8 MiB of serialized JSON. The combined workout, analysis,
and annotation snapshot is limited to 1 MiB; an upload exceeding this limit
returns 422 and rolls back its entire batch.

`GET /v1/health/activities/{id}?include=series,analysis` accepts either the
canonical activity ID or the external workout UUID, scoped to the credential.
It returns the item plus flat `samples`, each containing `external_id`, the
sample fields above, and a `stale` flag for superseded published generations.
Samples are paginated: `sample_limit` defaults to 500 (maximum 1,000); pass
`samples_cursor` from `next_samples_cursor` until the latter is null. Pages
also obey the 1.8 MiB byte budget. The signed cursor is bound to owner, epoch,
workout, and revision. If the workout changes between pages, the server returns
409 `samples_revision_mismatch`; restart its detail restore and publish the
complete replacement locally only after every page is saved. Detail responses
include `connection_epoch`.

`DELETE /v1/health/apple-health/data?connection_epoch=1` deletes source data,
snapshots, staging, operation and batch ledgers, and change-feed history. It
returns `{connection_id,connection_epoch:2,expected_sequence:1,cloud_consent:false}`.
Retrying the same purge returns the same result. Old uploads and cursors are
rejected, including previously accepted batches. Reconnect requires explicit
new consent; a new stream may be registered after purge. Retain the credential
and durable purge job while offline until deletion is acknowledged.
If enrollment succeeded but the first connection did not, purge still succeeds:
the empty namespace records a paused connection at requested epoch + 1 and a
stable retry receipt, without recording cloud consent. A later connection
requires consent normally. This also handles local-only deletion epochs before
the first successful server connection.

Errors: 401 invalid credential; 403 missing/paused consent; 404 foreign/missing
resource; 409 ordering, epoch, dependency or immutable-content conflict; 413
body size; 422 validation; 429 enrollment limit. Conflict `detail` has a `code`
and includes `expected_sequence` or `connection_epoch` where relevant.
Validation errors return a generic message without echoing health payloads or
credentials, including malformed requests containing non-finite JSON values.

## Verification

Run against a disposable PostgreSQL cluster, never production:

```sh
DATABASE_URL=postgresql://localhost:56467/postgres python -m pytest server/tests/test_health.py server/tests/test_health_postgres.py -q
```

Tests exercise real transaction rollback, concurrent retries, tenant isolation,
durable cursor/tombstone pagination, staged publication, parent deletion,
consent, purge, and annotation preservation. Simulator/server tests cannot
verify physical HealthKit authorization or background delivery. On a signed
iPhone, record a Watch workout, wait for its arrival in Health, verify import
in foreground and after background/unlock, deny selected data types, retry
offline uploads, and complete an offline purge after connectivity returns.

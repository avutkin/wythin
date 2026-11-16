# Full Polar archive: protocol and Hetzner rollout

Updated 2026-11-15. **Prepared, not activated.** No storage has been purchased
by this change. `RawArchiveFeature.isAvailable` remains false until the live
storage, backup restore and physical recording checks below pass.

## Target and budget

Production: `pulsar-api`, Hetzner server ID `154618769`, Helsinki `hel1-dc2`,
SSH `root@77.42.73.250`, service `pulsar-api.service`, user `pulsar`, checkout
`/opt/pulsar`, environment `/opt/pulsar/server/deploy/.env`.
Live preflight 2026-11-15: 2 vCPU, about 4 GB RAM, 38 GB system disk with 30 GB
free; no archive configuration. Do not place the archive on this system disk.

For up to 100 continuously recording participants, provision a **private Object
Storage bucket in HEL1**, suggested name `wythin-raw-154618769-hel1`, after
checking for an existing resource in the correct project. Use an **unversioned
bucket with no object lock**: the current deletion implementation removes live
objects; it is not a version-history purger. No public ACL or public URL.

Public prices checked 2026-11-15, excluding VAT, processing and overages:

| Resource | Monthly estimate | Purpose |
|---|---:|---|
| Object Storage base, including 1 TB | EUR 6.49 | Primary exact archive |
| BX11 Storage Box, 1 TB | EUR 3.20 | Independent encrypted backup |
| Combined base | EUR 9.69 | Whole cohort, not per participant |

Confirm the authenticated quote before purchase. A 1 TB block Volume at about
EUR 57.20/month is **not** the budget-equivalent replacement. Primary object
storage grows beyond the included TB with usage charges; the 1 TB backup does
not have unlimited room. At the conservative 10 GB/person/month estimate,
100 people fill 1 TB with no reserve. Alert at 70%, act before 85%, and revise
from real overnight recordings before admitting 100 continuous wearers.

Sources: [Object Storage pricing](https://www.hetzner.com/storage/object-storage/),
[Storage Box pricing](https://www.hetzner.com/storage/storage-box/),
[Volume overview](https://docs.hetzner.com/cloud/volumes/overview/).

## What is stored

- Exact Polar H10 notifications: ECG, ACC XYZ, Heart Rate and original RR ticks.
- One JSONL record per notification: UUID, stream, receipt time (Apple reference
  epoch, seconds since 2001-01-01 UTC), optional device nanosecond timestamp,
  base64 notification payload. The phone does not filter raw packets.
- A chunk is sealed after approximately 60 seconds or 1 MB. Server maximum is
  1,500,000 uncompressed bytes. Lossless gzip only; SHA-256 covers the original
  JSONL bytes. ACK includes SHA-256 and byte count; only verified ACK permits
  removal from the phone's pending queue.
- PostgreSQL `raw_chunks` is the owner-scoped integrity manifest. It records the
  storage backend so existing filesystem chunks remain readable after changing
  the active upload backend. Never remove an old backend before migration and
  integrity verification.
- S3 keys are `raw/v1/<user UUID>/<chunk UUID>/<SHA-256>.jsonl.gz`.
  Content addressing prevents a retried request overwriting different bytes.
  Per-user database locks serialize ingest, deletion, consent and processing.
- No GPS. ACC retains the signal needed to examine motion and orientation. A
  direction in sensor coordinates is not a calibrated body-position label.

## Encryption and configuration

Hetzner Object Storage has no default at-rest encryption. This adapter requires
SSE-C with a 32-byte key and HTTPS; no unencrypted fallback. Keep encryption and
access keys in protected server configuration, and keep a separate recovery
copy of the encryption key. Losing it loses the archive. Key rotation requires
an explicit migration; simply replacing the key makes old objects unreadable.
See [Hetzner supported actions](https://docs.hetzner.com/storage/object-storage/supported-actions/)
and [encryption FAQ](https://docs.hetzner.com/storage/object-storage/faq/general/).

Configure these variables through the operator's secret-management flow; do not
paste credentials in chat or commit them:

```text
RAW_ARCHIVE_BACKEND=s3
RAW_S3_ENDPOINT=https://hel1.your-objectstorage.com
RAW_S3_REGION=hel1
RAW_S3_BUCKET=<verified private bucket>
RAW_S3_ACCESS_KEY=<project credential>
RAW_S3_SECRET_KEY=<project credential>
RAW_S3_ENCRYPTION_KEY=<base64 of 32 random bytes>
```

For a filesystem archive, keep `RAW_ARCHIVE_BACKEND=filesystem`, configure an
existing `RAW_ARCHIVE_ROOT` mount, and retain `RAW_ARCHIVE_REQUIRE_MOUNT=1`.
`RAW_ARCHIVE_REQUIRE_MOUNT=0` is for isolated tests, not production.

## Acceptance and withdrawal

New raw capture requires the explicit disclosure `raw-v1-2026-11-15`; a missing
answer or a historical toggle is not acceptance. All three streams become
active together after acceptance. New programme onboarding cannot finish when
raw acceptance is declined (once rollout is enabled). Existing participants
receive a separate notice and retain their previous opt-outs.

`GET/PUT /v1/raw/consent` uses a revision comparison. Every change creates an
append-only event and a new upload token. Uploads carry
`X-Archive-Consent-Token`; disabled or stale tokens are rejected. The settings
switch stops new raw capture and cancels queued URLSession tasks locally; the
server pause takes effect after the revocation request reaches it. When offline,
the UI reports that confirmation is pending. An old background upload cannot
silently re-enable a later refusal. Existing local chunks are retained until
acknowledged or deliberately erased; turning transmission off is not deletion.

Team access and external-AI sharing are separate existing settings. Their final
onboarding requirements are pending the product owner's answer; **this rollout
must not silently turn those flags on, or claim new team-access enforcement**.
The archive worker sends no signals to OpenAI or any other LLM. The owner's
bearer-scoped export remains separate from team-sharing preferences.

## Daily processing

Install the prepared units after code/schema deployment, dependency install,
and successful storage verification:

```sh
sudo install -m 644 server/deploy/wythin-raw-analysis.service /etc/systemd/system/
sudo install -m 644 server/deploy/wythin-raw-analysis.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wythin-raw-analysis.timer
```

The timer runs daily at 03:00 UTC with up to 15 minutes jitter and catches up
missed runs. It invokes `python -m server.raw_worker`. The worker processes new
chunks, including late uploads, in batches of 200, with a six-hour time budget.
Results are idempotent by owner/chunk/algorithm version and reference the source
SHA-256. It does not process owners who have withdrawn archive consent. Failed
chunks retain an error code and retry after one day; corruption is never marked
successful. Monitor a failed service or `time_budget_reached` as actionable.

`signal-audit-v1` records exact RR ticks with packet receipt times, contact and
invalid-interval counts, descriptive RR statistics, ECG count/range/constant
packets, ACC axis means/scatter/gravity direction. It breaks successive-RR
calculations across receipt gaps, off-body intervals and implausible values.
These are per-chunk descriptive results, not validated NN/arrhythmia analysis,
not clinical autonomic diagnoses and not attention/mood/cognition scores.

Owner access: `GET /v1/me/raw/chunks`, exact chunk download, and
`GET /v1/me/raw/chunks/{id}/analysis`, all with the owner's bearer token.
A future algorithm can replay exact sources. Algorithm versions must change
when semantics change. Do not average per-chunk RMSSD into a daily RMSSD.

A local synthetic one-minute benchmark took about 0.017 CPU seconds, excluding
network/DB. This is **not** a production capacity guarantee. Measure actual
recording size, worker runtime and API latency on the 2-vCPU server. Start with
one worker; keep it at low scheduling priority and scale only from measurement.

## Backup, retention and release checklist

1. Purchase and verify the private bucket and independent Storage Box in the
   authenticated account. Configure an encrypted backup of raw objects **and**
   PostgreSQL (including RR results, manifests, consent events and context).
   The backup transfer/schedule is not configured by this commit. Keep recovery
   keys separate. Primary replication is not a recoverable independent backup.
2. Upload a synthetic ECG/ACC/HR chunk; download with the owner's bearer token
   and verify exact SHA-256. A different owner must receive 404. Verify private
   ACL, SSE-C, unversioned bucket, unavailable-storage rejection, revoked-token
   rejection and retry after a timed-out upload.
3. Restore the synthetic object and its manifest from the independent backup;
   verify original SHA-256. Record backup destination, restore evidence and
   operator alert destination before enabling capture.
4. Full streams target a 30-day working window. **Age-based deletion is not
   enabled.** First prove preservation and restore of exact RR, quality/context,
   minute/day summaries and selected raw segments (including random controls,
   not just positive responses). Only then implement/activate compaction. Until
   then the archive keeps growing and must be budgeted accordingly.
5. Verify withdrawal and owner deletion in primary storage; define and implement
   deletion/expiry in backups before promising a retention deadline to people.
6. Run all server tests and full WythinTests. Resolve team/AI onboarding wording.
   Set the release availability flag only after the infrastructure checks;
   merge through the normal review flow and ship only via `tools/ship.sh`.
7. Do a physical overnight H10 recording: background/screen lock, interruptions,
   reconnection, byte-complete upload, no doubled intervals, battery, storage and
   queue recovery. A simulator test cannot substitute for this. Start a limited
   pilot, then widen to 100 after capacity and backup evidence.

Current blockers: authenticated Hetzner console is at its login screen;
no new bucket/backup/keys exist, no live restore or overnight test has run, and
the team/AI onboarding choice is unanswered. No billable resource or production
configuration was changed during preparation.

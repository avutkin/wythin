# Backup review and verification record

An independent read-only reviewer inspected the backup implementation and tests
on this branch. No Critical finding; one P1 and two P2 findings were resolved.

| Finding | Resolution and evidence |
|---|---|
| P1: listing paths did not establish integrity of captured bytes before completion | Newly captured/changed raw objects are restored from the backup and checked against the manifest's original SHA-256/length. The captured dump and manifest are restored and hashed too. A regression failed before this check; a live corrupted synthetic S3 object was rejected without advancing the last-success marker. |
| P2: manifests and snapshot listings grew without a memory bound | PostgreSQL cursor → JSONL manifest, streaming restic JSONL and a disk-backed SQLite verification ledger. A 1,000,000-entry benchmark used 61.3 MiB peak memory, 7.72 seconds locally. This does not establish archive throughput. |
| P2: retention could remove the last published recovery point before a later failure | Publish the new verified marker atomically before cleanup and exclude both current and previous snapshots from pruning. Regression proves protection after a long gap. Cleanup failure remains an unsuccessful service result with retention pending. |

After that review, verification was changed to bounded restore batches (up to
1,000 files / approximately 128 MiB) so it does not launch one SFTP/restic process
per raw chunk. New count/byte-bound and corruption tests failed before the
batch implementation, then passed. The live successful fixture backup and
corrupt-source rejection were repeated using this final path.

Live integration exposed two environment issues: the existing AppArmor FUSE
profile permits `/mnt` rather than the initially selected `/var/lib` mount,
and distribution rclone 1.60.1 returned xattr errors. The mount moved into a
private `/mnt` directory without changing AppArmor; official rclone 1.76.0 was
installed after PGP signature and SHA-256 verification. Restic exit 3 was never
treated as success. The final hardened systemd service completed successfully.

Verification completed 2026-11-16 UTC / 2026-11-15 local:

- Server suite: **215 passed**, including **17 backup integrity/batching cases**.
  An initial restricted-sandbox run could not connect to the isolated local
  PostgreSQL; rerunning with that network access passed the complete suite.
- Updated legal HTML bundle: **26 ClientProfileTests passed**, zero failures.
- Synthetic raw payload: exact 77-byte restore, matching SHA-256; real isolated
  database import verified both marker and manifest row.
- Production dump: 71,841,457 bytes restored into an isolated PostgreSQL with
  10 public tables, zero current raw chunks. Exact dump SHA-256 matched. No
  production database overwrite occurred; the API remained active.
- Full restic repository data read passed. Eight disposable synthetic snapshots
  were then removed, followed by a successful repository check. Synthetic source
  records, test databases and scratch restores were removed.
- The independent encrypted recovery bundle was decrypted with the owner's
  local key without a plaintext file. Server-side secrets remain root-only.
- Daily timer enabled and active. First observed next run:
  **2026-11-17 02:09:27 UTC** (02:00 UTC plus random delay).

Operational procedures and exact snapshot evidence are in
`server/deploy/BACKUP_RECOVERY.md`. This completes the authorized backup setup;
it does not activate app/API raw capture or daily signal analysis. Primary
compaction, subject-level backup erasure, deletion/consent reconciliation,
external failure alerts, physical overnight testing and full-cohort throughput
remain explicit rollout requirements, not claims of this backup verification.

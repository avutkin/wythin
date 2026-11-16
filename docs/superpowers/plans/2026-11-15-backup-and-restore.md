# Encrypted backup and restore implementation plan

> Execute inline using superpowers:executing-plans. The user explicitly authorized internal-only SSH and configured backups with a restore test.

**Goal:** Run daily encrypted backups to the existing Falkenstein Storage Box and prove recovery without modifying production records.

**Architecture:** Restic over SSH/SFTP, with a pinned Hetzner host key and a dedicated server key. A read-only rclone mount exposes SSE-C objects without mirroring the growing archive onto the small system disk. PostgreSQL dump and raw manifest use one exported database snapshot. Completed backups are validated against that manifest. An age-encrypted recovery bundle can be decrypted using the owner's existing SSH key, kept off the server.

**Tech stack:** Ubuntu packages restic/fuse3/age, signed official rclone 1.76.0, Python, asyncpg, systemd, PostgreSQL.

**Spec:** User authorization in this chat and `server/deploy/RAW_ARCHIVE_HETZNER.md`.

## Constraints and decisions

- SSH Support on; External Reachability, SMB and WebDAV off.
- No production API/app deployment or raw capture activation.
- Daily backup at 02:00 UTC, up to 15 minutes jitter; no overlapping runs.
- Encrypt backup contents and filenames. Store credentials root-only outside git.
- Prune managed snapshots older than 30 days, protecting current and previous successes. Outages/protected snapshots can extend retention; this is not a subject-level deletion guarantee. Do not delete primary records. Failed or incomplete backups do not trigger retention cleanup or advance the success marker.
- Do not allow an unavailable source/mount to be treated as an empty successful backup. Validate the dump and every manifest entry in the captured snapshot.
- Restore into an isolated directory/database, never over production. Recovery to production remains an operator action with deletion/consent reconciliation.
- Preserve owner access while adding the server key. The private owner key never leaves the local machine.
- Restic was selected for encrypted incremental snapshots and integrity checks. A daily tar stream would reread the entire growing archive; a local mirror would exceed the 38 GB system disk.

## Tasks

- [x] Enable approved internal SSH; verify console settings and pinned host identity.
- [x] Install trusted backup tools; register a dedicated server key and verify unattended access.
- [x] Write failing tests for manifest path validation, missing/corrupt restored objects, and failure propagation; implement the backup/verification helpers and runner.
- [x] Generate root-only configuration and an encrypted recovery bundle. Prove the bundle is decryptable with the owner's local key without emitting secrets.
- [x] Back up synthetic raw data and an isolated test database, restore both from Storage Box, and verify bytes and database records. Reject damaged/missing data in tests.
- [x] Run the production backup, verify a restored database in isolation, enable the daily timer, and confirm its next run and success marker.
- [x] Review changes, run appropriate tests, update runbook and prepare the draft PR update with evidence and remaining rollout limits.

## Review focus

- An unreachable bucket, failed dump, skipped file or nonzero restic exit must fail the job.
- A snapshot must contain every manifest-referenced object with the expected source identity; corrupt restored payloads must fail SHA-256 validation.
- A missing backup password, host pin or recovery bundle must not silently weaken encryption or authentication.
- Interrupted jobs must unmount temporary sources and retain a useful failure status without deleting the last good backup.
- Server loss must not make the only encryption key unrecoverable; recovery secrets must not enter logs or git.

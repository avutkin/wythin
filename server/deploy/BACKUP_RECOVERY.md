# Encrypted backup operations and recovery

This backup service is separate from the application/API rollout. It does not
activate ECG/RR/ACC recording, alter user choices or run signal analysis.

## Installed layout

- Code and isolated Python environment: `/opt/wythin-backup`.
- Root-only configuration: `/etc/wythin/backup/settings.json` (mode 0600).
- Restic password, dedicated SSH key, pinned host key, S3/SSE-C rclone config
  and encrypted recovery bundle: `/etc/wythin/backup/`, mode 0700.
- Working state, verification ledger and success/restore evidence:
  `/var/lib/wythin-backup`, mode 0700.
- Read-only S3 mount and disposable database staging: `/mnt/wythin-backup`,
  mode 0700. This path is permitted by Ubuntu's existing FUSE AppArmor policy;
  that policy was not weakened.
- Destination: encrypted restic repository `wythin-restic` on the independent
  Falkenstein Storage Box. The primary bucket and API server are in Helsinki.
- Tools verified on the server: restic 0.18.1, rclone 1.76.0, fuse3, age 1.2.1,
  PostgreSQL client, asyncpg and python-dotenv. The old distribution rclone
  1.60.1 returned FUSE xattr errors; do not substitute it. The official 1.76.0
  ZIP was checked against its signed SHA-256 manifest before installation at
  `/usr/local/bin/rclone`; the signing fingerprint was
  `FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA`.

Storage Box SSH is enabled on port 23. External Reachability, SMB and WebDAV
are disabled. The dedicated server public key is restricted to the server's
IPv4 address and uses OpenSSH `restrict`; existing owner access was preserved.
The configured SSH command forces IPv4, pins the provider host key, uses
BatchMode and never accepts a changed host key automatically. Hetzner's
internal-only setting means reachability from its network, not a private
network exclusive to this project; key authentication still applies.

## Daily run and integrity

`wythin-backup.timer` schedules 02:00 UTC plus up to 15 minutes jitter.
Persistent catch-up is enabled. A file lock prevents overlapping managed runs.
The service runs at low CPU/I/O priority, limited to one CPU and 2 GB RAM.

Each run:

1. Checks primary S3 access and the existing encrypted backup repository.
2. Uses one exported repeatable-read PostgreSQL snapshot for `pg_dump` and
   the raw-object manifest. The dump includes application records, RR results,
   manifests, consent events and context actually present in the database.
3. Backs up the dump, hashed manifest, protected configuration and exact S3
   objects through a read-only FUSE mount. It does not mirror a terabyte onto
   the small system disk. Missing/unsupported objects or any nonzero restic
   backup result, including exit 3, fail the job.
4. Streams the captured snapshot's listing into a disk-backed verification
   ledger and checks every manifest path. Newly captured or changed raw
   objects are restored in batches of at most 1,000 files / approximately
   128 MiB uncompressed, then checked against original SHA-256 and byte count.
   Cached verification is reused only for content unchanged from the previous
   verified snapshot, using restic's content diff, not file size/mtime alone.
5. Restores and hashes the captured database dump and manifests; checks the
   dump's archive directory. Runs restic repository checks with a 5% data
   sample. The daily run does not import a second live PostgreSQL database.
6. Marks the snapshot complete and atomically records `last-success.json`.
   Prunes this host's managed snapshots older than 30 days, keeping both the
   current and previous successful snapshot. Failed validation does not move
   the success marker or start pruning. A prune failure leaves the new verified
   copy available with retention marked pending and fails the service.

The 30-day cleanup is an operational target, not a guaranteed deletion deadline:
the two protected snapshots and an outage can retain data longer. It is not
primary raw compaction, subject-level backup erasure or a consent-reconciliation
implementation. Those remain prerequisites for the broader archive release.

Monitor the service and age of the last successful run:

```sh
systemctl list-timers wythin-backup.timer
systemctl show wythin-backup.service -p Result -p ExecMainStatus
cat /var/lib/wythin-backup/last-success.json
journalctl -u wythin-backup.service --since yesterday
```

Detailed failed-command output is retained only in the root-only work directory;
it may contain record paths. Do not publish it. A failed job is visible through
systemd and a stale success timestamp. External failure/capacity notifications
are not configured; establish an operator destination before unattended cohort
rollout. The 1 TB Storage Box includes metadata, database copies and retained
versions: a 1 TB primary archive cannot safely be assumed to fit with no margin.

## Recovery without the original server

`wythin-recovery.age` is stored outside the restic repository on the Storage Box.
It contains the restic password, archive encryption/access configuration,
dedicated server SSH key, pinned host key, application configuration and backup
settings. It is encrypted to the owner's existing Ed25519 SSH public key. The
owner's private key remains off the server; preserve a separate recoverable copy
of that key. This avoids putting the only recovery password inside the repository
it unlocks. Refresh and re-test the encrypted bundle after credential rotation
or material configuration changes.

1. From a trusted owner machine, retrieve the encrypted bundle using the owner's
   existing Storage Box access through a Hetzner jump host. With external access
   disabled, a replacement/recovery host must also be inside Hetzner. Do not
   enable public reachability merely to restore.
2. Decrypt locally with `age --decrypt -i <owner-private-key>`. Use a private
   mode-0700 directory and umask 077 if writing a temporary plaintext file;
   never print the JSON or put it in chat/git. Transfer only required secrets
   to root-only configuration on the recovery server, then remove temporary
   plaintext. The owner's private key need not be transferred.
3. A replacement IP cannot use the old `from=`-restricted server key unchanged.
   Use owner access to register a new restricted server key and pin the verified
   provider host identity. Restore configuration and install the audited backup
   code/dependencies. Do not overwrite an existing live application environment.
4. Select an explicit **complete** snapshot. Restore into a new private path
   with enough disk space for that snapshot; the API's 38 GB system disk is not
   a full-terabyte recovery destination:

   ```sh
   cd /opt/wythin-backup
   .venv/bin/python -m server.backup restore \
     --snapshot <complete-snapshot-id> --target <new-private-restore-directory>
   .venv/bin/python -m server.backup check
   ```

   Restore verifies restic integrity, the dump hash, manifest hash/count, and
   every referenced raw object's uncompressed SHA-256/length. `check` reads all
   repository data; it can take substantial time on a full archive.
5. Import `database.dump` into a **new isolated database** with
   `pg_restore --exit-on-error --no-owner --no-acl`. Verify constraints and
   expected records. The backup CLI never overwrites production PostgreSQL or
   publishes restored objects to S3.
6. Before any production cutover, reconcile deletions, revoked permissions,
   tokens and records created since the snapshot. Validate ownership and access
   controls, restore the archive with its original identities, test reads, then
   perform a separately reviewed cutover. An old backup must not silently
   resurrect withdrawn consent or erased records.

## Verification evidence

Recorded 2026-11-16 UTC / 2026-11-15 America/Los_Angeles:

- A synthetic 77-byte ECG/RR/ACC payload and an isolated database were backed
  up to the Storage Box and restored. Exact raw SHA-256:
  `3b8ec3f0a2898a67c2196b11aa91142ca5637edfd89a400c9f6ae9b3ba168259`.
  A real `pg_restore` into a second isolated database verified both its marker
  row and raw manifest. The original source prefix and both test databases were
  subsequently removed.
- Deliberately replacing only that synthetic object's contents made the backup
  fail integrity validation and preserved the previous success marker. Repeated
  with the bounded batch implementation. The source was repaired in `finally`
  before test cleanup.
- The encrypted recovery bundle was retrieved from the independent Storage Box
  and decrypted with the owner's local key; all required secret fields and
  current settings were verified without writing a plaintext file.
- The first production backup completed through the actual hardened systemd
  service. Snapshot
  `a1ec38a67dfe8232f9ef2d6f1c376f6547000f2dae0c328ae9838052fb7e9544`
  restored a 71,841,457-byte dump into a new isolated PostgreSQL database with
  all 10 public tables and zero raw chunks, matching the currently inactive
  raw archive. Dump SHA-256:
  `0a358e1ac23fc8f489bfa5184d83ad93dd43d82fe37f4203915a14037a8e8ebf`.
  A full repository data read passed. The scratch database and restored files
  were removed; the production API remained active. Evidence is also recorded
  in `/var/lib/wythin-backup/restore-proof.json` on the server.
- A 1,000,000-entry manifest/listing ledger benchmark took 7.72 seconds and
  61.3 MiB peak memory locally. This checks bounded indexing memory, not S3/SFTP
  throughput, a full 1 TB recovery or 100-person daily runtime.
- 215 server tests passed, including 17 backup integrity/batching cases.

Primary references: [Hetzner SSH access](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/),
[restic integrity checks](https://restic.readthedocs.io/en/v0.18.1/045_working_with_repos.html#checking-integrity-and-consistency),
[restic restore](https://restic.readthedocs.io/en/v0.18.1/050_restore.html),
[rclone release verification](https://rclone.org/release_signing/),
[age](https://github.com/FiloSottile/age).

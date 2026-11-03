# Raw Polar archive: Hetzner Volume rollout

Prepared on 2026-11-02. This runbook does **not** create or attach a billable resource. It describes the reviewed change to make after the volume size, monthly cost, and backup destination are approved.

## Verified production target

- Hetzner Cloud server: `pulsar-api`, instance ID `154618769`, location `hel1-dc2` (Helsinki).
- API service: `pulsar-api.service`, user `pulsar`, working directory `/opt/pulsar`, environment file `/opt/pulsar/server/deploy/.env`.
- Only the 38.1 GB system disk is attached; no archive volume exists. The system disk had about 31 GB free at preflight.
- 210 registered accounts; 6 distinct users sent metric data in the previous 30 days, 2 in the previous 7 days. These counts are a sizing signal, not an estimate of future consent or wear time.

## Proposed initial size and cost gate

Create **one 500 GB ext4 Volume** in the same Hetzner project and location as server `154618769`, named `wythin-raw-hel1`, with deletion protection. Hetzner allows online growth but no shrinking, so measure real compressed ingest before increasing it. At 100–200 MB of raw sensor data per active wearer per day, six continuous wearers would produce about 18–36 GB/month before compression and file overhead. A 500 GB starting volume provides room to measure the actual rate and respond to alerts; it is not an indefinite capacity guarantee.

Hetzner bills Volumes hourly with a monthly cap, based on provisioned GB and location. A recent public price listing reports **€0.0572/GB-month**, making 500 GB roughly **€28.60/month before VAT**; confirm the live quote in the Hetzner Console before approving creation. This does not include the independent backup required below. See [Hetzner Volume overview](https://docs.hetzner.com/cloud/volumes/overview/) and [price listing](https://cloudtally.eu/hetzner-cloud-prices).

## Creation step — only after cost approval

In the Hetzner Console, select the project containing server ID `154618769`, then create a 500 GB Volume named `wythin-raw-hel1`, attach it to `pulsar-api`, choose **automatic ext4 formatting and mounting**, and enable deletion protection. Record the new Volume ID. The equivalent official CLI command is:

```bash
hcloud volume create --name wythin-raw-hel1 --size 500 \
  --server 154618769 --format ext4 --automount \
  --enable-protection delete
```

The automatic mount path is `/mnt/HC_Volume_<VOLUME_ID>`. Use that path directly for `RAW_ARCHIVE_ROOT`: the server rejects an ordinary directory when a Volume is absent. Do not copy archive files to `/mnt/wythin-raw` on the system disk. Hetzner documents the [mount path](https://docs.hetzner.com/cloud/volumes/overview/) and [CLI flags](https://github.com/hetznercloud/cli/blob/main/docs/reference/manual/hcloud_volume_create.md).

## Activation step — after the Volume is mounted and backed up

Run these checks on `pulsar-api` before setting the environment variable. Set `VOLUME_ID` to the ID returned by Hetzner:

```bash
set -euo pipefail
VOLUME_ID=REPLACE_WITH_ACTUAL_ID
ARCHIVE_ROOT="/mnt/HC_Volume_${VOLUME_ID}"
findmnt --mountpoint "$ARCHIVE_ROOT"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,MODEL,SERIAL
df -h "$ARCHIVE_ROOT"
sudo chown pulsar:pulsar "$ARCHIVE_ROOT"
sudo chmod 750 "$ARCHIVE_ROOT"
sudo -u pulsar test -w "$ARCHIVE_ROOT"
```

After the raw archive server code is deployed, add the following to `/opt/pulsar/server/deploy/.env` (mode 600, owner `pulsar`), then restart `pulsar-api.service`:

```text
RAW_ARCHIVE_ROOT=/mnt/HC_Volume_REPLACE_WITH_ACTUAL_ID
RAW_ARCHIVE_REQUIRE_MOUNT=1
```

Verify that `findmnt --mountpoint "$ARCHIVE_ROOT"` still succeeds after a reboot, then send a small authenticated test chunk and download it with its owner's bearer token. The server must preserve exact bytes and SHA-256, reject a different user's download, and return 503 when the Volume is unmounted. An upload rejected because the Volume is unavailable stays in the phone's local queue.

## Backup and capacity gates

**Hetzner server Backups and Snapshots exclude attached Volumes; Hetzner does not provide Volume Backups or Snapshots.** Triple replication is not a recoverable backup against accidental deletion or application errors. Arrange an independent encrypted backup of both the Volume files and PostgreSQL `raw_chunks` metadata, test a restore, and monitor backup success before enabling participant raw upload. [Hetzner documentation](https://docs.hetzner.com/cloud/volumes/overview/).

The proposed backup target is a separate **BX11 Storage Box (1 TB) in HEL1**, with encrypted Borg backups and a daily PostgreSQL manifest dump. Hetzner documents [BX11 capacity](https://www.hetzner.com/es/storage/storage-box/bx11/) and [Borg access](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/). This is an additional resource and cost, requires its own approval, and needs a successful test restore. Increase backup capacity as the archive grows. Storage Box snapshots can help with accidental changes but are [not full backups](https://docs.hetzner.com/storage/storage-box/snapshots/).

Alert at **70% capacity** and expand before **85%**. The ingest API already refuses new chunks when less than 1 GB remains, so a full or missing Volume does not silently fill the system disk; clients retain their local queues. Review the actual per-user compressed GB/day after the first week, then revise capacity and price. Hetzner Volumes top out at 10 TB, so an indefinite archive with a larger cohort will eventually need object-storage tiering or another expandable backend. [Hetzner Volume limits](https://docs.hetzner.com/cloud/volumes/faq/).

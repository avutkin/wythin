# Encryption at rest — Postgres on an encrypted Hetzner volume (runbook)

**Goal:** move the Postgres data directory onto a LUKS-encrypted Hetzner Cloud Volume, so the continuous health data (`metric_samples`, sessions, activities) is encrypted on disk. Data in transit is already TLS-protected (Caddy) — this closes the at-rest gap.

**Performance:** LUKS uses AES-NI (present on the CX23), ~2–7% raw disk overhead; negligible for this small, index-served, largely-cached workload. Cost is a one-time ~10–20 min maintenance window (Postgres stopped during the data copy), not ongoing.

**Threat model / key trade-off (decide first):**
- **Keyfile on the root disk (auto-unlock at boot):** the box reboots unattended; protects against a **stolen/decommissioned data volume** (the volume is useless without the key) but NOT against someone who images the whole server. This is the common, pragmatic choice.
- **Passphrase unlock (manual at boot):** stronger (key never on disk) but you must SSH in and unlock after every reboot, and Postgres can't auto-start. Only pick this if you accept manual reboots.

This runbook uses the **keyfile** approach (note where it deviates for passphrase).

---

## 0. Prep
- Take a fresh snapshot/backup of the server in the Hetzner console first. Also dump the DB:
  ```bash
  ssh root@77.42.73.250 'cd /opt/pulsar && DB=$(grep -E "^DATABASE_URL=" server/deploy/.env | cut -d= -f2- | tr -d "\"") && pg_dump "$DB" | gzip > /root/pg-predump.sql.gz && ls -la /root/pg-predump.sql.gz'
  ```
- Note the PG data dir: `ssh root@77.42.73.250 'sudo -u postgres psql -tAc "SHOW data_directory;"'` (call it `$PGDATA`, typically `/var/lib/postgresql/<ver>/main`).

## 1. Create + attach an encrypted-capable volume (Hetzner console)
- Console → Volumes → **Create Volume** (size ≥ 2× current DB; e.g. 10 GB), same location as the server, **do not** let Hetzner auto-format/mount. Attach it to the server.
- It appears as e.g. `/dev/sdb` (confirm: `lsblk`).

## 2. LUKS-format + open
```bash
apt-get update && apt-get install -y cryptsetup
# Keyfile (root-stored) approach:
dd if=/dev/urandom of=/root/pg_luks.key bs=512 count=8 && chmod 400 /root/pg_luks.key
cryptsetup luksFormat --type luks2 /dev/sdb /root/pg_luks.key
cryptsetup open --key-file /root/pg_luks.key /dev/sdb pgcrypt
mkfs.ext4 /dev/mapper/pgcrypt
mkdir -p /mnt/pgdata && mount /dev/mapper/pgcrypt /mnt/pgdata
# (passphrase variant: omit --key-file; `cryptsetup luksFormat /dev/sdb` then `cryptsetup open /dev/sdb pgcrypt`, entering a passphrase)
```

## 3. Move the data (Postgres stopped — start of the window)
```bash
systemctl stop pulsar-api          # stop the API first so it isn't writing
systemctl stop postgresql
rsync -aHAX --info=progress2 "$PGDATA"/ /mnt/pgdata/
chown -R postgres:postgres /mnt/pgdata
# Point Postgres at the new location: either bind-mount over $PGDATA, or set data_directory.
# Cleanest: mount the encrypted fs at the original path.
umount /mnt/pgdata
mv "$PGDATA" "${PGDATA}.old"
mkdir -p "$PGDATA" && mount /dev/mapper/pgcrypt "$PGDATA"
chown postgres:postgres "$PGDATA"
```

## 4. Auto-unlock + auto-mount at boot (keyfile approach)
```bash
# /etc/crypttab: open the LUKS device at boot using the keyfile
echo "pgcrypt /dev/sdb /root/pg_luks.key luks" >> /etc/crypttab
# /etc/fstab: mount it at $PGDATA AFTER it's unlocked (nofail so a missing key never bricks boot)
echo "/dev/mapper/pgcrypt $PGDATA ext4 defaults,nofail 0 2" >> /etc/fstab
# (passphrase variant: leave crypttab keyfile as 'none' and unlock manually each boot; postgres won't auto-start until mounted)
```

## 5. Restart + verify (end of the window)
```bash
systemctl start postgresql && sleep 3
sudo -u postgres psql -tAc "SHOW data_directory;"    # should be $PGDATA (now on the encrypted fs)
systemctl start pulsar-api && sleep 3
curl -sf https://api.77.42.73.250.sslip.io/health
# sanity: row counts intact
DB=$(grep -E "^DATABASE_URL=" /opt/pulsar/server/deploy/.env | cut -d= -f2- | tr -d '"')
psql "$DB" -c "SELECT count(*) FROM metric_samples;"
```

## 6. Reboot test + cleanup
- `reboot`, then confirm the volume auto-unlocked and Postgres came up (keyfile approach): `curl -sf .../health`.
- Only after you've confirmed everything works and taken a backup: remove the old copy `rm -rf "${PGDATA}.old"`.
- Store a copy of `/root/pg_luks.key` somewhere safe **off the server** (losing it = losing the data). Consider it a secret alongside your other keys.

## Notes
- This protects the **data volume** at rest. The OS root disk (which holds the keyfile) is not encrypted — acceptable for the "stolen/decommissioned volume" threat; use the passphrase variant if you need to defend against full-server imaging.
- No app or schema change; `DATABASE_URL` is unchanged (Postgres just lives on an encrypted fs now).
- Roll back: stop services, `mount` the `${PGDATA}.old` back / restore the `pg-predump`, revert `fstab`/`crypttab`.

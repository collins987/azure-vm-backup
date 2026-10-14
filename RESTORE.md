# RESTORE RUNBOOK

How to restore an n8n deployment from a `VM-Restore-Point-YYYYMMDD-HHmmss`
folder produced by `backup-n8n-vm-full.cmd`.

**Priority order:** verify the backup → prepare target VM → restore host
files → load images → restore volumes → start services → verify n8n
credentials decryptable.

---

## 1. Verify the backup before you touch any VM

Run the offline validator from Windows. It does not need network access
and does not touch any VM.

```powershell
.\backup-n8n-vm-full.cmd -ValidateBackup "C:\path\to\VM-Restore-Point-20261014-100000"
```

Expected output ends with `VALIDATION PASSED.` and exit code 0.

What it checks:
- Every file listed in `SHA256SUMS` is present and its SHA-256 matches.
- `host-files.tar.gz` and each `volumes/*.tar.gz` pass `tar -tzf`.
- `docker-images-all.tar.gz` passes `tar -tzf` and contains `manifest.json`.
- `database-dumps/postgres17-all-databases.sql` has the `pg_dumpall` header.
- `manifest.json`'s artifact list matches what's on disk.

Do **not** proceed to a restore if validation fails — the backup is not
trustworthy. Pick an older verified backup instead.

---

## 2. Prepare the target VM

Target: an Ubuntu VM with:

- Docker Engine installed and running
- OpenSSH access from your Windows laptop under a user with `sudo`
- Enough free disk for the uncompressed data (check `BACKUP-INFO.txt`
  and `manifest.json` for sizes)
- The same major Docker version as the source VM (older minor is fine)

Copy the backup folder up:

```powershell
scp -r "C:\path\to\VM-Restore-Point-20261014-100000" user@newvm:/tmp/
```

---

## 3. Restore host files first

```bash
cd /tmp/VM-Restore-Point-20261014-100000
sudo tar --numeric-owner --xattrs --acls -xzpf host-files.tar.gz -C /
```

This restores:

- `/opt/n8n-docker-caddy` (Compose stack, `.env` **including N8N_ENCRYPTION_KEY**, Caddy config, local_files)
- `/home/n8nuser/firecrawl`, `/home/n8nuser/tgbot`
- `/home/n8nuser/.config/rclone` (if present on source)
- `/etc/docker`, `/etc/containerd`

**Confirm the encryption key is in place before continuing:**

```bash
grep -E '^N8N_ENCRYPTION_KEY=' /opt/n8n-docker-caddy/.env
```

If this prints nothing, stop — restoring the database without the original
encryption key makes stored credentials permanently unreadable.

---

## 4. Load Docker images

```bash
docker load < /tmp/VM-Restore-Point-20261014-100000/docker-images-all.tar.gz
```

Images are deduplicated by immutable ID in the archive. The repo:tag
labels come back on load. `reports/image-id-tag-map.tsv` is the human
reference if you need to re-tag anything manually.

---

## 5. Restore Docker volumes

**Do NOT run `docker compose up -d` before this step.** Compose will
create fresh empty volumes if any are missing, and you'll overwrite them
on the next step for no reason — or worse, start containers against empty
state.

For each `volumes/<name>.tar.gz`:

```bash
VOL=n8n-docker-caddy_postgres_data_17   # replace per file
docker volume create "$VOL"
docker run --rm \
    -v "${VOL}:/target" \
    -v /tmp/VM-Restore-Point-20261014-100000/volumes:/src \
    alpine \
    sh -c "tar -xzpf /src/${VOL}.tar.gz -C /target"
```

The archive filename matches the volume name except for a safe-char
substitution (`[^A-Za-z0-9_.-]` → `_`). Compose project volumes include
the project prefix (e.g. `n8n-docker-caddy_postgres_data_17`).

---

## 6. (Optional) Restore PostgreSQL from the logical dump instead

The raw volume restore above is sufficient and preferred when PG versions
match. The logical dump is a fallback — useful when upgrading PG major
version or recovering a single database.

Bring up only the Postgres container first:

```bash
cd /opt/n8n-docker-caddy
docker compose up -d postgres
# wait for it to be ready
docker exec -it n8n-docker-caddy-postgres-1 pg_isready -U n8n

# then restore
docker exec -i n8n-docker-caddy-postgres-1 psql -U n8n -d postgres \
    < /tmp/VM-Restore-Point-20261014-100000/database-dumps/postgres17-all-databases.sql
```

Per-database `*-custom.dump` files restore with `pg_restore`:

```bash
docker exec -i n8n-docker-caddy-postgres-1 pg_restore -U n8n -d n8n --clean --if-exists \
    < /tmp/VM-Restore-Point-20261014-100000/database-dumps/n8n-custom.dump
```

---

## 7. Start the stack

```bash
cd /opt/n8n-docker-caddy
docker compose up -d
docker compose ps
```

---

## 8. Verify n8n credentials decryptable (critical)

Open n8n in a browser and open any workflow that uses a credential (e.g. a
Postgres node, an API key). Click into the credential — it should show as
decrypted and ready, not as "credential is not decrypted".

If you see a decryption failure:

1. Check `/opt/n8n-docker-caddy/.env` for the original `N8N_ENCRYPTION_KEY`.
2. The restored `.env` MUST contain the key the backup was taken with.
3. If the key is wrong, stop n8n, correct the `.env`, `docker compose up -d`
   again. Do not generate a new key — that cannot recover the old credentials.

---

## 9. Verify other workloads

- Firecrawl: `cd /home/n8nuser/firecrawl && docker compose ps`
- Telegram bot: whatever its launch mechanism is on your VM
- Caddy TLS: check that `https://azuren8n.vcollins.me` serves without a
  cert warning (Caddy auto-renews on start if needed)

---

## Rollback

If any step above goes wrong on a fresh target VM, the source backup is
untouched. Discard the target VM and start over.

If you are restoring in place (same VM as the source — not recommended),
you have no rollback once you've overwritten `/opt/n8n-docker-caddy` or
replaced volume contents. Snapshot the Azure disk first and only then run
the restore.

---

## What the backup does and does not capture

**Captures:**
- Host files under tracked paths (see `reports/host-paths-archived.txt`)
- All Docker images deduplicated by ID
- All Docker volumes (named, anonymous, orphaned)
- PostgreSQL cluster dump + per-DB custom-format dumps
- Container writable-layer snapshots (for forensic reference)
- Docker inspect JSON for every container, image, network, volume
- Last 5000 log lines per container

**Does not capture:**
- The OS, kernel, systemd units, installed packages
- `/var/lib/docker` internals (we use `docker save` instead)
- Running process state (only filesystems, as of the stop/snapshot moment)
- External managed services (any API the VM talks to that lives elsewhere)
- Live client sessions — users will need to re-authenticate

---

## Reference: file layout of a backup folder

```
VM-Restore-Point-YYYYMMDD-HHmmss/
├── BACKUP-INFO.txt            human summary
├── manifest.json              machine-readable manifest (-ValidateBackup reads this)
├── SHA256SUMS                 hash of every file in the folder
├── SHA256SUMS-REMOTE          cross-check copy from the VM
├── host-files.tar.gz          /opt/n8n-docker-caddy etc.
├── docker-images-all.tar.gz   all images, deduplicated by ID
├── volumes/
│   ├── n8n-docker-caddy_postgres_data_17.tar.gz
│   ├── caddy_data.tar.gz
│   └── …                      one per Docker volume
├── database-dumps/
│   ├── postgres17-all-databases.sql
│   └── <dbname>-custom.dump
├── reports/                   docker inspect, lists, env info
└── container-logs/            last 5000 lines per container
```

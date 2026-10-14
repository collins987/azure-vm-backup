FULL VM / DOCKER RESTORE-POINT BACKUP — WINDOWS CMD
=====================================================
Architecture: direct SSH streaming (no large staging files on VM)

FILES
  backup-n8n-vm-full.cmd   Launch this from Windows Explorer or CMD.
  backup-n8n-vm-full.ps1   Drives the backup over SSH from Windows.
  RESTORE.md               Step-by-step restore runbook.
  CLAUDE.md                Context for future automated edits to this repo.
  tests/syntax-check.sh    Static bash-syntax check of the embedded runner.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PREREQUISITES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Windows (required):
  • Windows OpenSSH Client — ssh.exe, scp.exe
      Enable via: Settings → Apps → Optional features → OpenSSH Client
      Minimum: OpenSSH included with Windows 10 1803 / Server 2019
  • Windows tar.exe (built into Windows 10 1803+)
  • PowerShell 5.1 (built in) or PowerShell 7.x (recommended for best binary support)

Ubuntu VM (required, typically already present):
  • Docker Engine and docker CLI
  • bash 4+, tar, gzip, sha256sum, sudo access for n8nuser
  • PostgreSQL client tools inside the Postgres container (pg_dumpall, pg_dump, psql)

Optional (not required):
  • pg_restore.exe on Windows — used to validate custom-format DB dumps locally
    (validation also runs on the VM; Windows-side is a best-effort extra check)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HOW TO RUN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Double-click backup-n8n-vm-full.cmd  (or run it from CMD).
   The .cmd launcher finds backup-n8n-vm-full.ps1 in its own folder,
   so both files must stay together.

2. Accept the SSH host-key prompt if it appears (first run only).
   Do NOT type 'no' — that will abort the backup.

3. Review the disk-space summary printed by the script.
   The script asks: "Type STOP-AND-BACKUP to proceed"
   Type exactly: STOP-AND-BACKUP

4. Keep the window open. The backup runs through 9 phases.
   Each large component (host files, volumes, images) shows live progress.

5. The final output will print the local folder path and a SUCCESS or FAILURE
   message. On success the folder is ready to use for restore.

OPTIONAL PARAMETER OVERRIDES (pass after the .cmd filename):
  backup-n8n-vm-full.cmd -SshHost 1.2.3.4 -SshUser n8nuser -BackupDir "D:\VM Backups"
  backup-n8n-vm-full.cmd -CompressLevel 1    (fastest, less compression)
  backup-n8n-vm-full.cmd -CompressLevel 6    (gzip default, slower)

MODES
  -DryRun
      Discovery pass only. Connects to the VM, installs the disposable SSH
      key, uploads the runner, calls the read-only get-info to list
      volumes/images/sizes, prints the plan, and exits WITHOUT stopping any
      container or streaming any archive. The uploaded runner is removed
      and the SSH key is torn down exactly as in a live run. Safe to run
      any time — nothing changes on the VM or on Windows.

  -ValidateBackup "C:\path\to\VM-Restore-Point-20261014-100000"
      Offline validation of an existing backup folder. Does NOT connect to
      the VM. Rehashes every file against SHA256SUMS, re-runs tar.gz /
      pg_dumpall structure checks, and verifies manifest.json's artifact
      list. Returns exit 0 on pass, non-zero on any failure. Use before a
      restore and periodically after taking a backup.

OUTPUT: manifest.json
  Each successful backup now writes manifest.json alongside BACKUP-INFO.txt.
  It is the machine-readable record of what the backup contains:
  schemaVersion, backupId, createdUtc, source identity, per-artifact
  size + source/dest SHA-256 + verified flag, volume inventory, image
  count, stopped container IDs, and a verification block. -ValidateBackup
  reads this file.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DEFAULTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  VM IP        : 102.133.184.146
  SSH login    : n8nuser
  Local folder : %USERPROFILE%\Desktop\New folder\Azure n8n Configs\VM-Restore-Point-<timestamp>
  Compression  : gzip level 3  (practical balance of speed and ratio)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DIRECT STREAMING — HOW IT WORKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Previous versions created complete archives on the VM and then SCP'd them,
requiring enough free disk on the VM to hold everything twice.
This version streams each large archive directly:

  Ubuntu: tar/docker-save → gzip → SSH stdout
  Windows: .NET FileStream reads raw bytes from SSH Process.StandardOutput.BaseStream
           → writes binary to a .tmp file
           → SHA-256 computed on the received .tmp file
           → compared with the source SHA-256 sent by the VM over SSH stderr
           → only on match: .tmp promoted to the final filename

No large intermediate file is created on the VM.
The VM still needs a small staging directory (~100 MB) for reports, logs and DB dumps.

BINARY SAFETY
  Archives are written using System.IO.FileStream (raw byte stream), NOT PowerShell
  redirection (>), Set-Content, or Out-File, which perform text encoding on Windows.
  The source hash is calculated on the compressed byte stream (tar output piped through
  gzip | sha256sum on the VM). The destination hash is calculated on the same compressed
  bytes received on Windows. They must match for promotion to succeed.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COMPRESSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Tool           : gzip (universally available; no extra install needed)
  Default level  : 3  — fast, good ratio for Docker layers and SQL data
  Override       : -CompressLevel 1 (fastest) … -CompressLevel 9 (smallest)
  All archives use the same level for consistency.

  SSH transport compression is disabled (-o Compression=no) because the data
  is already compressed. Enabling both wastes CPU without benefit.

  The compressed byte stream (not the raw tar stream) is what is hashed and
  what is written to disk. Restore tools (tar, docker load) handle decompression.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROGRESS OUTPUT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Each streaming component displays a live progress line:
  [label] Component | 42% | 1.25 GiB | 21 MiB/s | ETA 1m 25s

  • Percentage is shown when the estimated uncompressed size is known in
    advance (measured with du on the VM). The estimate may be inaccurate
    because gzip compression ratio varies by content.
  • When the total is unknown (e.g. Docker images whose compressed size is
    unpredictable), the line shows bytes transferred and speed only.
  • Progress is written to the same line (overwriting), so it does not fill
    the terminal.
  • Progress output is NOT part of the binary archive stream. It goes to
    PowerShell's host (the console), while the binary data goes through
    the .NET process stream.

Transfer, hash verification, and archive validation are separate steps.
The progress bar reaches 100% when the last byte of the archive is received,
not when validation is complete.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HASH VERIFICATION AND ARCHIVE VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For every streamed component:
  1. Archive bytes written to a .tmp file on Windows.
  2. SSH process exit code checked.
  3. File size checked (non-zero).
  4. SHA-256 of the received .tmp file computed.
  5. Compared with the source SHA-256 sent by the VM on SSH stderr.
  6. On mismatch: .tmp renamed to .FAILED, error thrown, previous backup kept.
  7. On match: .tmp promoted to the final filename.
  8. Archive structure validated: tar -tzf for gzip/tar archives;
     presence of manifest.json checked for the Docker image archive;
     pg_dumpall header checked for the SQL cluster dump.
  9. Combined SHA256SUMS written for all files in the backup folder.

What validation proves:
  • SHA-256 match: the compressed bytes received on Windows are identical to
    the bytes that left the VM. No corruption during transfer.
  • tar -tzf pass: the archive is structurally readable.
  • pg_dumpall header check: the SQL dump is a real PostgreSQL cluster dump.
  A complete restore test on a separate VM is the strongest confirmation
  that the backup is fully usable.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WHAT IS BACKED UP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

host-files.tar.gz
  /opt/n8n-docker-caddy           — Compose stack, .env, local_files, Caddy config
  /home/n8nuser/firecrawl         — Firecrawl source and config
  /home/n8nuser/tgbot             — Telegram bot source and config
  /home/n8nuser/.config/rclone   — rclone credentials (if present)
  /etc/docker, /etc/containerd   — Docker and containerd host config
  Compose project working dirs discovered from Docker labels
  External bind-mount sources discovered from container metadata

docker-images-all.tar.gz
  All Docker images deduplicated by image ID (no double-export of same layers).
  Includes a docker commit writable-layer snapshot for each container.
  Manifest in reports/image-id-tag-map.tsv maps IDs to tags.
  Previously the script exported all tags AND all image IDs, which could
  double-export images. This version exports each unique image ID exactly once.

volumes/
  One <volume-name>.tar.gz per Docker volume, including:
    • Named volumes (e.g. n8n-docker-caddy_postgres_data_17, caddy_data)
    • Anonymous volumes
    • Unattached / orphaned volumes
  Volumes are archived while all containers are stopped (consistency).

database-dumps/
  postgres17-all-databases.sql     — pg_dumpall cluster dump (all DBs + roles)
  <dbname>-custom.dump             — pg_dump -Fc per-database dump for pg_restore

reports/
  containers-inspect.json, images-inspect.json, networks-inspect.json,
  volumes-inspect.json, docker-ps-a.txt, docker-images-list.txt,
  docker-system-df.txt, backup-environment.txt, container-snapshot-map.tsv,
  postgres-logical-dump-status.txt, image-id-tag-map.tsv, host-paths-archived.txt

container-logs/
  Last 5000 log lines per container.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WHERE FILES ARE SAVED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Windows local folder:
    %USERPROFILE%\Desktop\New folder\Azure n8n Configs\VM-Restore-Point-YYYYMMDD-HHmmss\

  SHA256SUMS — in the root of that folder, covers all files.
  BACKUP-INFO.txt — human-readable summary of the backup.

  No files remain on the VM after a successful backup.
  On failure, the VM staging directory (/home/n8nuser/VM-Restore-Point-…) is
  intentionally retained for diagnosis.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUCCESS vs FAILURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SUCCESS: the CMD window prints "[SUCCESS]" and exit code is 0.
  All 9 phases completed. SHA-256 source==dest for all streamed archives.
  All archives passed structure validation. DB dumps passed header check.
  SHA256SUMS written covering every file.

FAILURE: the CMD window prints "[FAILURE]" and exit code is 1.
  A .FAILED file may exist next to the archive that caused the hash mismatch.
  The partial local folder (if any) is kept for diagnosis.
  A previous verified backup is never overwritten.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONSISTENCY AND DOWNTIME
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • PostgreSQL cluster dump: taken while PostgreSQL is running (online, consistent).
  • Docker volumes: archived while ALL containers are stopped.
      Downtime: from confirmation prompt until containers are restarted (~minutes,
      depending on volume sizes and streaming speed).
  • Container writable-layer snapshots (docker commit): taken while containers
      are stopped.
  • Docker images: streamed after containers are restarted (no additional downtime).
  • If any phase fails after containers are stopped, the remote bash script's
      exit handler automatically attempts to restart the originally-running containers.
  • The script records which containers were running before stopping and only
      restarts those. Containers that were already stopped are not started.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RESTORE GUIDE (SUMMARY)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

On a fresh Ubuntu VM with Docker installed:

1. RESTORE PROJECT FILES
     scp host-files.tar.gz user@newvm:/tmp/
     ssh user@newvm "sudo tar --numeric-owner --xattrs --acls -xzpf /tmp/host-files.tar.gz -C /"

2. RESTORE DOCKER IMAGES
     scp docker-images-all.tar.gz user@newvm:/tmp/
     ssh user@newvm "docker load < /tmp/docker-images-all.tar.gz"

3. RESTORE VOLUMES (one per volume)
     scp volumes/n8n-docker-caddy_postgres_data_17.tar.gz user@newvm:/tmp/
     ssh user@newvm "
       docker volume create n8n-docker-caddy_postgres_data_17
       docker run --rm \
         -v n8n-docker-caddy_postgres_data_17:/target \
         -v /tmp:/src alpine \
         sh -c 'tar -xzf /src/n8n-docker-caddy_postgres_data_17.tar.gz -C /target'
     "
     Repeat for each volume in volumes/.

4. RESTORE POSTGRESQL FROM LOGICAL DUMP (alternative to raw volume restore)
     scp database-dumps/postgres17-all-databases.sql user@newvm:/tmp/
     # Start only the postgres container first, then:
     ssh user@newvm "docker exec -i <postgres-container> psql -U n8n < /tmp/postgres17-all-databases.sql"
     # Or use custom-format dumps for individual databases:
     # docker exec -i <postgres-container> pg_restore -U n8n -d n8n < /tmp/n8n-custom.dump

5. RESTART SERVICES
     ssh user@newvm "cd /opt/n8n-docker-caddy && docker compose up -d"

6. VERIFY
     Check n8n at https://azuren8n.vcollins.me and test key workflows.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DIAGNOSING DISK SPACE AND TRANSFER FAILURES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

If the backup fails with "No space left on device" or similar:

  On the VM:
    df -h                          # Check filesystem usage
    docker system df               # Check Docker layer/volume disk usage
    du -sh /home/n8nuser/VM-Restore-Point-*/  # Check staging dir size
    docker volume ls               # List volumes to identify large ones

  This script does NOT run docker system prune or docker volume prune.
  To reclaim space manually (with caution):
    docker image prune             # Remove dangling images only — review first
    # Never run docker volume prune — it deletes data

  If a transfer was interrupted:
    • A .tmp file may remain in the local folder — delete it manually.
    • A .FAILED file records the corrupt partial archive for diagnosis.
    • Re-run the backup from scratch (new timestamp, new folder).
    • The script never appends to a partial archive.

  If the VM staging folder remains after failure:
    ssh n8nuser@102.133.184.146 "ls -lh ~/VM-Restore-Point-*/"
    # Remove manually only after confirming the local backup is complete:
    ssh n8nuser@102.133.184.146 "rm -rf ~/VM-Restore-Point-YYYYMMDD-HHmmss"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SECRETS PROTECTION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • SSH host-key verification is preserved (StrictHostKeyChecking is not disabled).
  • The script does not print .env contents, passwords, tokens, or credentials
    to the console. Container inspect JSON (which may contain environment
    variables with secrets) is written to reports/containers-inspect.json inside
    the backup folder, not to the console.
  • The backup folder contains .env files, rclone credentials, TLS certificates,
    database contents, and application secrets.
  • Store the backup folder in an access-restricted location.
  • Keep an encrypted copy (e.g. using 7-Zip AES-256 or VeraCrypt).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
KNOWN LIMITATIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • This is NOT a bootable Azure disk image. It does not back up the OS,
    kernel, installed packages, or /var/lib/docker internals.
  • Docker layer data is exported via docker save, not as raw filesystem.
    Restore requires docker load on a running Docker Engine.
  • Container snapshot images (docker commit) capture the writable layer
    on top of the base image. They do NOT include mounted volume contents
    (volumes are archived separately). They also do NOT preserve running
    process state — only the filesystem.
  • docker commit snapshots are for forensic reference, not primary restore.
    Restore from Compose files + volumes + images, not from commit snapshots.
  • Anonymous volume names are not human-meaningful. Check volumes-inspect.json
    to understand which service owns each volume before restoring.
  • Percentage estimates during host-file and volume streaming are based on
    uncompressed du sizes. Actual compressed sizes differ; the percentage may
    exceed 100% if the estimate was too low.
  • The n8n-docker-caddy_postgres_data (old v16) volume is archived along with
    all other volumes without assumptions about its contents.
  • pg_restore.exe validation on Windows is best-effort; it requires installing
    PostgreSQL client tools on Windows. Validation also runs on the VM.
  • Restore has not been automatically tested. Perform a manual restore test
    on an isolated VM before decommissioning the source VM.

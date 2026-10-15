#!/usr/bin/env bash
# restore-n8n-vm-full.sh
#
# Restore a VM-Restore-Point-YYYYMMDD-HHmmss folder (produced by
# backup-n8n-vm-full.cmd) onto a fresh Ubuntu VM. Puts host files back at the
# exact same paths used on the source VM (/opt/n8n-docker-caddy,
# /home/n8nuser/firecrawl, /home/n8nuser/tgbot, /etc/docker, …) and restores
# every Docker volume by its original name so the Compose stacks come back up
# unchanged.
#
# USAGE on the target Ubuntu VM:
#   bash restore-n8n-vm-full.sh /path/to/VM-Restore-Point-YYYYMMDD-HHmmss
#
# Pass --no-start to extract everything but skip `docker compose up -d`
# (useful if you want to inspect .env or edit paths before boot).
#
# Pass --skip-hash-check only when you have already run -ValidateBackup from
# the Windows machine and don't want to pay the rehash cost again.
#
# Pass --assume-yes to skip the confirmation prompt (for automated restores
# on known-fresh VMs; never pass this on a VM that already carries data).
#
# Prerequisites on the target VM:
#   - Ubuntu with Docker Engine installed and running
#   - User with passwordless sudo (same model as the source VM)
#   - Enough free disk for the uncompressed data (several GiB)
#   - Nothing already running at /opt/n8n-docker-caddy (the script refuses
#     to overwrite a running stack)
#
# This script is NOT a dry-run. It writes to /, loads Docker images, creates
# volumes, and (unless --no-start) starts containers. Only run it on a VM
# you are prepared to replace with the backup's state.

set -Eeuo pipefail

# ─── CLI parsing ──────────────────────────────────────────────────────────────
BACKUP_DIR=""
NO_START=0
SKIP_HASH=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --no-start)       NO_START=1 ;;
        --skip-hash-check) SKIP_HASH=1 ;;
        --assume-yes|-y)  ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "Unknown flag: $arg" >&2; exit 2 ;;
        *)  if [[ -z "$BACKUP_DIR" ]]; then BACKUP_DIR="$arg"; else
                echo "Only one backup folder may be given." >&2; exit 2
            fi ;;
    esac
done

[[ -n "$BACKUP_DIR" ]] || { echo "Usage: $0 /path/to/VM-Restore-Point-YYYYMMDD-HHmmss [--no-start] [--skip-hash-check] [--assume-yes]" >&2; exit 2; }
[[ -d "$BACKUP_DIR" ]] || { echo "Not a directory: $BACKUP_DIR" >&2; exit 2; }
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

# ─── Helpers ──────────────────────────────────────────────────────────────────
PHASE_W=78
phase() { printf '\n%s\n[PHASE %s] %s\n%s\n' \
    "$(printf '=%.0s' $(seq 1 $PHASE_W))" "$1" "$2" "$(printf '=%.0s' $(seq 1 $PHASE_W))"; }
ok()    { printf '  \e[32mPASS\e[0m: %s\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '  \e[33mWARN\e[0m: %s\n' "$*" >&2; }
die()   { printf '\n\e[31mRESTORE FAILED\e[0m: %s\n' "$*" >&2; exit 1; }

# ─── Phase 1: Preflight ───────────────────────────────────────────────────────
phase 1/8 "Preflight: check tools, backup layout, target state"

command -v docker  >/dev/null 2>&1 || die 'docker not installed on this VM'
docker info >/dev/null 2>&1        || die 'docker daemon not reachable (is it running? are you in the docker group?)'
command -v sudo    >/dev/null 2>&1 || die 'sudo not installed'
command -v tar     >/dev/null 2>&1 || die 'tar not installed'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum not installed'
sudo -n true 2>/dev/null           || die 'sudo requires a password — set up NOPASSWD before running the restore'
ok "docker, sudo (NOPASSWD), tar, sha256sum all present"

for f in host-files.tar.gz docker-images-all.tar.gz SHA256SUMS; do
    [[ -f "$BACKUP_DIR/$f" ]] || die "Backup folder is missing required file: $f"
done
[[ -d "$BACKUP_DIR/volumes" ]] || die 'Backup folder is missing volumes/'
VOLUME_COUNT=$(find "$BACKUP_DIR/volumes" -maxdepth 1 -name '*.tar.gz' -type f | wc -l)
(( VOLUME_COUNT > 0 )) || die 'No volume archives found in volumes/'
ok "backup folder has host-files.tar.gz, docker-images-all.tar.gz, SHA256SUMS, volumes/ ($VOLUME_COUNT archives)"

# Refuse to overwrite a stack that is already running.
if [[ -d /opt/n8n-docker-caddy ]] && \
   docker ps --format '{{.Names}}' | grep -qE '^(n8n|n8n-docker-caddy|evolution-api|firecrawl|tgbot|redis|pgbouncer|warp)'; then
    die '/opt/n8n-docker-caddy exists AND related containers are running. Refusing to overwrite a live stack. Stop everything with `docker compose down` first, or restore to a fresh VM.'
fi
ok 'no competing stack is currently running'

# ─── Phase 2: SHA256 integrity re-check ───────────────────────────────────────
phase 2/8 "Verify SHA256SUMS of every file in the backup"
if (( SKIP_HASH )); then
    warn 'skipping hash re-check (--skip-hash-check given); the Windows -ValidateBackup pass is assumed to have already verified this folder.'
else
    cd "$BACKUP_DIR"
    # SHA256SUMS was written on Windows by PowerShell 5.1 with -Encoding UTF8
    # — which prepends a UTF-8 BOM and uses CRLF line endings. Linux
    # sha256sum -c cannot parse either, so normalise to a BOM-less, LF-only
    # copy before verifying. Paths inside use forward slashes (./file.tar.gz)
    # which already work on Linux.
    SUMS_UNIX="$(mktemp -t sha256sums.XXXXXX)"
    trap 'rm -f "$SUMS_UNIX"' EXIT
    sed $'1s/^\xef\xbb\xbf//' SHA256SUMS | tr -d '\r' > "$SUMS_UNIX"
    if ! sha256sum -c --quiet "$SUMS_UNIX"; then
        die 'SHA256SUMS verification failed — the backup folder is corrupt. Re-copy it before restoring.'
    fi
    ok "every file verified against SHA256SUMS ($(wc -l < "$SUMS_UNIX") entries)"
    rm -f "$SUMS_UNIX"; trap - EXIT
    cd - >/dev/null
fi

# ─── Final confirmation ───────────────────────────────────────────────────────
echo
echo '  This will OVERWRITE the following on this VM:'
echo '    /opt/n8n-docker-caddy'
echo '    /home/n8nuser/firecrawl'
echo '    /home/n8nuser/tgbot'
echo '    /etc/docker, /etc/containerd'
echo '  …and load/replace Docker images and create Docker volumes with the'
echo '  names from the backup. Running containers for restored services are'
echo "  started at the end unless --no-start was passed."
echo
if (( ASSUME_YES == 0 )); then
    read -r -p '  Type RESTORE to continue, anything else to cancel: ' confirm
    [[ "$confirm" == 'RESTORE' ]] || die 'cancelled by user'
fi

# ─── Phase 3: Restore host files ──────────────────────────────────────────────
phase 3/8 "Restore host files (tar extract into /)"
sudo tar --numeric-owner --xattrs --acls -xzpf "$BACKUP_DIR/host-files.tar.gz" -C /
ok 'host files extracted at their original paths'

# ─── Phase 4: Critical N8N_ENCRYPTION_KEY check ───────────────────────────────
phase 4/8 "Verify N8N_ENCRYPTION_KEY is present (critical)"
ENV_FILE='/opt/n8n-docker-caddy/.env'
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE after host-files extract"
if ! sudo grep -qE '^N8N_ENCRYPTION_KEY=.+' "$ENV_FILE"; then
    die "N8N_ENCRYPTION_KEY is missing from $ENV_FILE. Restoring the n8n database without the original key makes stored credentials permanently unreadable. Aborting."
fi
# Length check only; never print the key.
KEY_LEN=$(sudo grep -E '^N8N_ENCRYPTION_KEY=' "$ENV_FILE" | head -1 | sed 's/^N8N_ENCRYPTION_KEY=//' | tr -d '\r\n' | wc -c)
ok "N8N_ENCRYPTION_KEY present ($KEY_LEN chars, value never logged)"

# ─── Phase 5: Load Docker images ──────────────────────────────────────────────
phase 5/8 "Load Docker images from docker-images-all.tar.gz"
docker load < "$BACKUP_DIR/docker-images-all.tar.gz" > /tmp/docker-load.log 2>&1 \
    || { cat /tmp/docker-load.log >&2; die 'docker load failed'; }
LOADED=$(grep -c '^Loaded image' /tmp/docker-load.log || true)
ok "$LOADED image(s) loaded"
rm -f /tmp/docker-load.log

# ─── Phase 6: Restore every Docker volume ─────────────────────────────────────
phase 6/8 "Restore Docker volumes ($VOLUME_COUNT archives)"
FAILED_VOLS=()
IDX=0
for f in "$BACKUP_DIR"/volumes/*.tar.gz; do
    IDX=$((IDX+1))
    VOL="$(basename "$f" .tar.gz)"
    printf '  [%d/%d] %s\n' "$IDX" "$VOLUME_COUNT" "$VOL"

    # Create the volume if missing. If it already exists we overwrite its
    # contents, which is what the user asked for by running the restore.
    docker volume inspect "$VOL" >/dev/null 2>&1 || docker volume create "$VOL" >/dev/null

    # Mount an empty alpine, mount the backup folder read-only, extract. The
    # alpine image comes from docker-images-all.tar.gz load above, so no
    # network pull is needed.
    if ! docker run --rm \
            -v "${VOL}:/target" \
            -v "$BACKUP_DIR/volumes:/src:ro" \
            alpine \
            sh -c "cd /target && tar -xzpf \"/src/${VOL}.tar.gz\"" >/dev/null 2>&1; then
        FAILED_VOLS+=("$VOL")
        warn "FAILED to restore volume: $VOL"
    fi
done
if (( ${#FAILED_VOLS[@]} > 0 )); then
    die "Some volumes failed to restore: ${FAILED_VOLS[*]}"
fi
ok "all $VOLUME_COUNT volumes restored"

# ─── Phase 7: Start Docker Compose stacks ─────────────────────────────────────
phase 7/8 "Start Docker Compose stacks"
if (( NO_START )); then
    warn '--no-start given: skipping docker compose up. Start manually with:'
    info "  cd /opt/n8n-docker-caddy && docker compose up -d"
    [[ -f /home/n8nuser/firecrawl/docker-compose.yml || -f /home/n8nuser/firecrawl/compose.yml || -f /home/n8nuser/firecrawl/compose.yaml || -f /home/n8nuser/firecrawl/docker-compose.yaml ]] && \
        info "  cd /home/n8nuser/firecrawl && docker compose up -d"
else
    # Main stack: n8n + Caddy + Postgres + Redis + supporting containers
    cd /opt/n8n-docker-caddy
    docker compose up -d
    ok 'n8n-docker-caddy stack started'
    # Firecrawl, if it has its own compose
    if ls /home/n8nuser/firecrawl/docker-compose.y*ml /home/n8nuser/firecrawl/compose.y*ml 2>/dev/null | head -1 >/dev/null; then
        cd /home/n8nuser/firecrawl
        docker compose up -d && ok 'firecrawl stack started' || warn 'firecrawl stack did not start cleanly — check logs'
    else
        info 'firecrawl: no compose file found; start it manually if required'
    fi
    # Telegram bot: may be a bare Python app, systemd unit, or compose. Don't
    # guess — tell the user to start it the way it ran on the source VM.
    info 'telegram bot (/home/n8nuser/tgbot): start it the way it ran on the source VM (systemd, python, or docker compose)'
    cd - >/dev/null
fi

# ─── Phase 8: Final summary ───────────────────────────────────────────────────
phase 8/8 "Restore summary"
echo
if (( NO_START == 0 )); then
    echo '  Running containers now:'
    docker ps --format '    {{.Names}}  ({{.Status}})'
    echo
fi
ok 'host files, encryption key, images, volumes all restored'
echo
echo '  CRITICAL NEXT STEP — verify n8n credentials decrypt correctly:'
echo '    1. Open n8n in a browser'
echo '    2. Open any workflow that uses a credential (Postgres, API key, …)'
echo '    3. Confirm the credential is "ready" and not "credential is not decrypted"'
echo
echo '  If credentials appear not decrypted, STOP. Check that N8N_ENCRYPTION_KEY'
echo '  in /opt/n8n-docker-caddy/.env matches the one from the source VM.'
echo
echo "  Backup source: $BACKUP_DIR"
if [[ -f "$BACKUP_DIR/BACKUP-INFO.txt" ]]; then
    echo "  See $BACKUP_DIR/BACKUP-INFO.txt for the full backup provenance."
fi

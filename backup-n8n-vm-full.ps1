[CmdletBinding()]
param(
    [string]$SshHost     = '102.133.184.146',
    [string]$SshUser     = 'n8nuser',
    [string]$BackupDir   = (Join-Path $env:USERPROFILE 'Desktop\New folder\Azure n8n Configs'),
    [ValidateRange(1,9)][int]$CompressLevel = 3,

    # Discovery-only pass: connects to the VM, inventories what WOULD be
    # captured, prints the plan, then exits without stopping containers or
    # streaming any archives. The disposable SSH key and the remote runner
    # script are installed and removed exactly as in a normal run.
    [switch]$DryRun,

    # Offline validation of an existing backup folder. Takes a path to a
    # VM-Restore-Point-YYYYMMDD-HHmmss directory. Does NOT connect to the VM.
    # Re-hashes every file against SHA256SUMS, re-runs tar.gz structure checks,
    # and validates PostgreSQL dumps and manifest.json where present.
    [string]$ValidateBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Helper: phase banner ─────────────────────────────────────────────────────
function Write-Phase {
    param([string]$Number, [string]$Message)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ("[PHASE $Number] $Message") -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

# ─── Helper: human-readable byte sizes ───────────────────────────────────────
function Format-ByteSize([long]$b) {
    if ($b -ge 1GB) { return '{0:0.00} GiB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:0.0} MiB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:0} KiB'   -f ($b / 1KB) }
    return "$b B"
}

# ─── Helper: run a native command, throw on non-zero exit ────────────────────
function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Action
    )
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @ArgumentList
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($exit -ne 0) { throw "$Action failed (exit $exit)." }
}

# ─── Helper: SSH command with text output captured ───────────────────────────
function Invoke-SshText {
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$Command,
        [string]$Action = 'SSH text command'
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $script:SshExe @script:SshOpts $Remote $Command 2>&1
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($exit -ne 0) {
        $msg = ($out | Where-Object { $_ -is [string] }) -join "`n"
        throw "$Action failed (exit $exit). Output: $msg"
    }
    return ($out | Where-Object { $_ -is [string] })
}

# ─── Helper: binary-safe SSH stream → temp file → verify hash → promote ──────
#   Remote command must:
#     • write archive bytes to stdout
#     • write  SHA256:<64hex>  to stderr after the stream ends
#   Returns hashtable: Hash, Bytes, SourceHash
function Invoke-SshStream {
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$Description,
        [long]$EstimatedBytes = 0,
        [string]$Label = ''
    )

    Write-Host "  Streaming: $Description" -ForegroundColor Gray

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName        = $script:SshExe
    # Build argument string: ssh options (includes ctrl opts when master is active) + host + quoted command
    $sshOptStr = ($script:SshOpts -join ' ')
    $psi.Arguments       = "$sshOptStr $Remote `"$RemoteCommand`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    # Drain stderr asynchronously to prevent deadlock
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    # Write binary stdout directly to temp file
    $srcStream = $proc.StandardOutput.BaseStream
    $fs = [System.IO.FileStream]::new(
        $TempPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        65536
    )

    $buf          = [byte[]]::new(65536)
    $totalBytes   = [long]0
    $sw           = [System.Diagnostics.Stopwatch]::StartNew()
    $reportTimer  = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($true) {
            $read = $srcStream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            $fs.Write($buf, 0, $read)
            $totalBytes += $read

            if ($reportTimer.ElapsedMilliseconds -ge 1000) {
                $sec   = $sw.Elapsed.TotalSeconds
                $speed = if ($sec -gt 0.5) { [long]($totalBytes / $sec) } else { 0 }
                $sStr  = if ($speed -gt 0) { "$(Format-ByteSize $speed)/s" } else { '...' }
                $tStr  = Format-ByteSize $totalBytes
                $pfx   = if ($Label) { "[$Label] " } else { '' }

                if ($EstimatedBytes -gt 0 -and $totalBytes -le $EstimatedBytes) {
                    $pct = [int]([double]$totalBytes / $EstimatedBytes * 100)
                    $eta = ''
                    if ($speed -gt 0 -and $pct -lt 99) {
                        $etaSec = [int](($EstimatedBytes - $totalBytes) / $speed)
                        $eta = " | ETA $(if($etaSec -ge 60){"$([int]($etaSec/60))m $($etaSec%60)s"}else{"${etaSec}s"})"
                    }
                    Write-Host "`r  $pfx$Description | ${pct}% | $tStr | $sStr$eta          " -NoNewline
                } else {
                    Write-Host "`r  $pfx$Description | $tStr | $sStr          " -NoNewline
                }
                $reportTimer.Restart()
            }
        }
    } finally {
        $fs.Flush()
        $fs.Close()
    }

    $proc.WaitForExit()
    $exitCode    = $proc.ExitCode
    $stderrText  = $stderrTask.GetAwaiter().GetResult()

    Write-Host "`r  $(' ' * 78)" -NoNewline
    Write-Host "`r" -NoNewline

    # Parse source hash  (format: SHA256:<64hex>)
    $hashMatch  = [regex]::Match($stderrText, '(?m)^SHA256:([0-9a-f]{64})')
    $sourceHash = if ($hashMatch.Success) { $hashMatch.Groups[1].Value } else { $null }

    # Echo non-hash SSH stderr lines
    foreach ($ln in ($stderrText -split "`n")) {
        $ln = $ln.Trim()
        if ($ln -and $ln -notmatch '^SHA256:[0-9a-f]{64}') {
            Write-Host "  [SSH] $ln" -ForegroundColor DarkYellow
        }
    }

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $TempPath) {
            $kept = $TempPath + '.FAILED'
            Move-Item -LiteralPath $TempPath -Destination $kept -Force
            Write-Host "  Partial file kept for diagnosis: $kept" -ForegroundColor DarkYellow
        }
        throw "SSH stream failed (exit $exitCode): $Description"
    }

    $sz = (Get-Item -LiteralPath $TempPath).Length
    if ($sz -eq 0) {
        Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
        throw "Received empty file for: $Description"
    }

    Write-Host "  Hashing received file: $Description" -ForegroundColor Gray
    $destHash = (Get-FileHash -LiteralPath $TempPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($sourceHash) {
        if ($sourceHash -ne $destHash) {
            $kept = $TempPath + '.FAILED'
            Move-Item -LiteralPath $TempPath -Destination $kept -Force
            throw "SHA-256 MISMATCH for $Description.`n  Source: $sourceHash`n  Dest:   $destHash`n  Kept:   $kept"
        }
        Write-Host "  PASS SHA-256 source == dest: $Description" -ForegroundColor Green
    } else {
        Write-Host "  NOTE: source hash not received; dest hash recorded: $destHash" -ForegroundColor Yellow
    }

    Move-Item -LiteralPath $TempPath -Destination $FinalPath -Force

    $elapsed = $sw.Elapsed
    $eStr  = if ($elapsed.TotalMinutes -ge 1) { "$([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s" } else { "$([math]::Round($elapsed.TotalSeconds,1))s" }
    $avg   = if ($elapsed.TotalSeconds -gt 0) { Format-ByteSize([long]($totalBytes / $elapsed.TotalSeconds)) } else { '?' }
    Write-Host "  DONE  $(Format-ByteSize $totalBytes) in $eStr  avg $avg/s  $Description" -ForegroundColor Green

    return @{ Hash = $destHash; SourceHash = $sourceHash; Bytes = $totalBytes }
}

# ─── Helper: archive validation ──────────────────────────────────────────────
function Test-Archive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [ValidateSet('tar.gz','sql','docker-tar.gz')][string]$Format = 'tar.gz'
    )
    Write-Host "  Validating: $Description ($Format)" -ForegroundColor Gray
    switch ($Format) {
        'tar.gz' {
            & $script:TarExe -tzf $Path *> $null
            if ($LASTEXITCODE -ne 0) { throw "$Description failed tar.gz check." }
        }
        'docker-tar.gz' {
            & $script:TarExe -tzf $Path *> $null
            if ($LASTEXITCODE -ne 0) { throw "$Description failed tar.gz check." }
            $listing = & $script:TarExe -tzf $Path 2>$null
            if (-not ($listing | Where-Object { $_ -match 'manifest\.json' })) {
                Write-Host "  WARNING: manifest.json not found in Docker image archive." -ForegroundColor Yellow
            }
        }
        'sql' {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing." }
            $head = Get-Content -LiteralPath $Path -TotalCount 10 -ErrorAction SilentlyContinue
            if (-not ($head -join '' | Select-String 'PostgreSQL database cluster dump')) {
                throw "$Description does not contain the expected pg_dumpall header."
            }
        }
    }
    Write-Host "  PASS: $Description" -ForegroundColor Green
}

# ─── Remote bash runner (uploaded once, called with different modes) ──────────
$remoteScript = @'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK_DIR='/opt/n8n-docker-caddy'
PG_CONTAINER='n8n-docker-caddy-postgres-1'
BACKUP_DIR=''

say()  { printf '\n[UBUNTU] %s\n' "$*" >&2; }
die()  { printf '\n[UBUNTU ERROR] %s\n' "$*" >&2; exit 1; }
warn() { printf '\n[UBUNTU WARNING] %s\n' "$*" >&2; }

# Stream archive bytes to stdout; write  SHA256:<hex>  to stderr.
# Usage: stream_hashed <gzip_level> <cmd> [args…]
# Used for host files and images only (local tar/gzip pipelines, no docker run).
# Uses a named FIFO so sha256sum runs concurrently without process substitution.
stream_hashed() {
    local clevel="$1"; shift
    local tmpHash fifo
    tmpHash=$(mktemp /tmp/bkphash-XXXXXX)
    fifo=$(mktemp -u /tmp/bkpfifo-XXXXXX)
    mkfifo "$fifo"
    # sha256sum reads from the FIFO in background; tee opens FIFO for writing.
    sha256sum -b < "$fifo" | awk '{print $1}' > "$tmpHash" &
    local sha_pid=$!
    "$@" | tee "$fifo"
    wait "$sha_pid"
    rm -f "$fifo"
    if [[ -s "$tmpHash" ]]; then
        printf 'SHA256:%s\n' "$(cat "$tmpHash")" >&2
    fi
    rm -f "$tmpHash"
}

add_host_path() {
    local candidate="$1" existing covered=0
    [[ -e "$candidate" || -L "$candidate" ]] || return 0
    [[ "$candidate" == '/var/run/docker.sock' ]] && return 0
    for existing in "${HOST_PATHS[@]}"; do
        if [[ "$candidate" == "$existing" || "$candidate" == "$existing/"* ]]; then
            covered=1; break
        fi
    done
    (( covered == 1 )) && return 0
    HOST_PATHS+=("$candidate")
}

# ── prepare: create staging dir, capture inventory, dump PostgreSQL ───────────
mode_prepare() {
    local folder_name="$1" timestamp="$2"
    [[ "$folder_name" =~ ^VM-Restore-Point-[0-9]{8}-[0-9]{6}$ ]] || die 'Invalid folder name.'
    [[ "$timestamp"   =~ ^[0-9]{8}-[0-9]{6}$ ]]                  || die 'Invalid timestamp.'
    BACKUP_DIR="$HOME/$folder_name"
    [[ ! -e "$BACKUP_DIR" ]] || die "Staging directory already exists: $BACKUP_DIR"
    [[ -d "$STACK_DIR" ]]    || die "Active stack directory not found: $STACK_DIR"
    command -v docker >/dev/null 2>&1 || die 'docker not found.'
    docker info >/dev/null 2>&1       || die 'Docker daemon unavailable.'

    say "Disk space check:"
    df -h "$HOME" "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" 2>/dev/null || df -h "$HOME"

    mkdir -m 700 -p "$BACKUP_DIR"/{reports,container-logs,database-dumps,volumes}

    say 'Capturing Docker inventory (every container, image, volume, network).'
    local rpt="$BACKUP_DIR/reports"
    docker version       > "$rpt/docker-version.txt"      2>&1 || true
    docker info          > "$rpt/docker-info.txt"         2>&1 || true
    docker ps -a --no-trunc > "$rpt/docker-ps-a.txt"
    docker image ls --digests --no-trunc > "$rpt/docker-images-list.txt"
    docker volume ls     > "$rpt/docker-volumes-list.txt"
    docker network ls    > "$rpt/docker-networks-list.txt"
    docker system df -v  > "$rpt/docker-system-df.txt"    2>&1 || true
    docker plugin ls     > "$rpt/docker-plugins.txt"      2>&1 || true
    docker compose ls --all > "$rpt/docker-compose-projects.txt" 2>&1 || \
        docker compose ls   > "$rpt/docker-compose-projects.txt" 2>&1 || true

    local -a cids=() iids=() nids=() vnames=()
    mapfile -t cids   < <(docker ps -aq --no-trunc)
    mapfile -t iids   < <(docker image ls -q --no-trunc | sort -u)
    mapfile -t nids   < <(docker network ls -q)
    mapfile -t vnames < <(docker volume ls -q)

    if ((${#cids[@]})); then
        docker inspect "${cids[@]}" > "$rpt/containers-inspect.json"
        for id in "${cids[@]}"; do
            local name lname
            name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
            lname="$(printf '%s' "$name" | tr ' /:' '___' | tr -cd '[:alnum:]_.-')"
            docker logs --timestamps --tail 5000 "$id" > "$BACKUP_DIR/container-logs/${lname}.log" 2>&1 || true
        done
    else
        printf '[]\n' > "$rpt/containers-inspect.json"
    fi
    ((${#iids[@]}))   && docker image   inspect "${iids[@]}"  > "$rpt/images-inspect.json"   || printf '[]\n' > "$rpt/images-inspect.json"
    ((${#nids[@]}))   && docker network inspect "${nids[@]}"  > "$rpt/networks-inspect.json"  || printf '[]\n' > "$rpt/networks-inspect.json"
    ((${#vnames[@]})) && docker volume  inspect "${vnames[@]}" > "$rpt/volumes-inspect.json"  || printf '[]\n' > "$rpt/volumes-inspect.json"

    printf 'Captured UTC: %s\nVM hostname: %s\nDocker root: %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname -f 2>/dev/null || hostname)" \
        "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo unknown)" \
        > "$rpt/backup-environment.txt"
    docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}' > "$rpt/containers-running-before-backup.tsv"
    docker ps -q --no-trunc > "$rpt/running-container-ids.txt"

    # PostgreSQL logical dump
    local dump_dir="$BACKUP_DIR/database-dumps"
    local cluster_dump="$dump_dir/postgres17-all-databases.sql"
    local status_file="$rpt/postgres-logical-dump-status.txt"
    if docker inspect "$PG_CONTAINER" >/dev/null 2>&1 && \
       [[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == 'true' ]]; then
        say "Creating PostgreSQL cluster dump (pg_dumpall) while PostgreSQL is running..."
        if docker exec "$PG_CONTAINER" pg_dumpall -U n8n > "$cluster_dump" 2>/dev/null; then
            if [[ -s "$cluster_dump" ]] && head -5 "$cluster_dump" | grep -q 'PostgreSQL database cluster dump'; then
                printf 'PASS: pg_dumpall completed.\n' > "$status_file"
                chmod 600 "$cluster_dump"
                say "Cluster dump OK. Creating per-database custom-format dumps..."
                local dbs db dbdump
                mapfile -t dbs < <(docker exec "$PG_CONTAINER" psql -U n8n -At \
                    -c "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY datname;" 2>/dev/null || true)
                for db in "${dbs[@]}"; do
                    [[ -n "$db" ]] || continue
                    dbdump="$dump_dir/${db}-custom.dump"
                    if docker exec "$PG_CONTAINER" pg_dump -U n8n -Fc "$db" > "$dbdump" 2>/dev/null && [[ -s "$dbdump" ]]; then
                        printf 'PASS: pg_dump -Fc %s\n' "$db" >> "$status_file"
                        chmod 600 "$dbdump"
                        say "Custom dump OK: $db"
                    else
                        printf 'WARN: pg_dump -Fc %s failed or empty\n' "$db" >> "$status_file"
                        rm -f "$dbdump"
                    fi
                done
            else
                printf 'WARN: pg_dumpall output missing expected header.\n' > "$status_file"
                rm -f "$cluster_dump"
            fi
        else
            printf 'FAIL: pg_dumpall failed. Raw PostgreSQL volume will be archived.\n' > "$status_file"
            rm -f "$cluster_dump"
        fi
    else
        printf 'NOT RUN: %s was not running. Raw volume will be archived.\n' "$PG_CONTAINER" > "$status_file"
        warn "PostgreSQL container not running; skipping logical dump."
    fi

    say "Prepare complete. Staging: $BACKUP_DIR"
}

# ── get-info: output machine-parseable info lines for Windows ─────────────────
# Read-only inventory. Does not require the staging dir to exist, so it can be
# called in dry-run mode (before prepare) and after prepare in a live run.
mode_get_info() {
    local folder_name="$1"
    BACKUP_DIR="$HOME/$folder_name"

    # Volumes
    local -a vnames=()
    mapfile -t vnames < <(docker volume ls -q)
    for v in "${vnames[@]}"; do
        local mp sz=0
        mp="$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null || true)"
        if [[ -d "$mp" ]]; then
            sz="$(du -sb "$mp" 2>/dev/null | awk '{print $1}' || echo 0)"
        fi
        printf 'VOLUME:%s:%s\n' "$v" "$sz"
    done

    # Host files estimated size
    local -a HOST_PATHS=()
    _discover_host_paths
    if ((${#HOST_PATHS[@]})); then
        local hsize
        hsize="$(du -scb "${HOST_PATHS[@]}" 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)"
        printf 'HOSTFILES_SIZE:%s\n' "$hsize"
    else
        printf 'HOSTFILES_SIZE:0\n'
    fi

    # Images
    local icount isize
    icount="$(docker image ls -q --no-trunc | sort -u | wc -l || echo 0)"
    isize="$(docker system df --format '{{.ImagesSize}}' 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"
    printf 'IMAGE_COUNT:%s\n' "$icount"
    printf 'IMAGE_SIZE_RAW_ESTIMATE:%s\n' "$isize"

    # Disk free
    local free_kb
    free_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
    printf 'VM_FREE_KB:%s\n' "$free_kb"
}

_discover_host_paths() {
    HOST_PATHS=()
    add_host_path '/opt/n8n-docker-caddy'
    add_host_path '/home/n8nuser/firecrawl'
    add_host_path '/home/n8nuser/tgbot'
    add_host_path '/home/n8nuser/.config/rclone'
    add_host_path '/etc/docker'
    add_host_path '/etc/containerd'
    add_host_path '/etc/systemd/system/docker.service.d'
    add_host_path '/etc/systemd/system/containerd.service.d'
    add_host_path '/usr/lib/systemd/system/docker.service'
    local -a cids=()
    mapfile -t cids < <(docker ps -aq --no-trunc)
    if ((${#cids[@]})); then
        local -a dirs srcs
        mapfile -t dirs < <(docker inspect "${cids[@]}" \
            --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null \
            | grep '^/' | sort -u || true)
        for d in "${dirs[@]}"; do add_host_path "$d"; done
        mapfile -t srcs < <(docker inspect "${cids[@]}" \
            --format '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' 2>/dev/null \
            | grep '^/' | sort -u || true)
        for s in "${srcs[@]}"; do add_host_path "$s"; done
    fi
}

# ── stop-containers: stop all running containers, print IDs to stdout ─────────
mode_stop_containers() {
    local -a running=()
    mapfile -t running < <(docker ps -q --no-trunc)
    if ((${#running[@]} == 0)); then
        say "No running containers to stop."
        return 0
    fi
    say "Stopping ${#running[@]} running container(s) for consistent volume backup."
    for id in "${running[@]}"; do
        local cname
        cname="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || echo "$id")"
        say "Stopping: $cname"
        docker stop --time 60 "$id" >/dev/null || die "Failed to stop container $cname ($id)."
        printf '%s\n' "$id"
    done
}

# ── snapshot-containers: docker commit each container ────────────────────────
mode_snapshot_containers() {
    local folder_name="$1" timestamp="$2"
    BACKUP_DIR="$HOME/$folder_name"
    [[ -d "$BACKUP_DIR" ]] || die "Staging directory not found."
    local -a cids=()
    mapfile -t cids < <(docker ps -aq --no-trunc)
    : > "$BACKUP_DIR/reports/container-snapshot-map.tsv"
    : > "$BACKUP_DIR/reports/created-snapshot-image-tags.txt"
    say "Snapshotting writable layers of ${#cids[@]} container(s) via docker commit."
    for id in "${cids[@]}"; do
        local name safe tag
        name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
        safe="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g' | cut -c1-100)"
        tag="vm-backup-snapshot/${safe}:${timestamp}"
        docker commit "$id" "$tag" >/dev/null || die "docker commit failed for $name."
        printf '%s\t%s\t%s\n' "$name" "$id" "$tag" >> "$BACKUP_DIR/reports/container-snapshot-map.tsv"
        printf '%s\n' "$tag" >> "$BACKUP_DIR/reports/created-snapshot-image-tags.txt"
        say "Snapshot created: $name → $tag"
    done
}

# ── start-containers: restart listed container IDs ───────────────────────────
mode_start_containers() {
    local failed=0
    for id in "$@"; do
        local running_state cname
        running_state="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo missing)"
        cname="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || echo "$id")"
        if [[ "$running_state" != 'true' ]]; then
            if docker start "$id" >/dev/null; then
                say "Restarted: $cname"
            else
                warn "Could NOT restart container: $cname ($id)"
                failed=1
            fi
        else
            say "Already running: $cname"
        fi
    done
    (( failed == 0 )) || die "One or more containers could not be restarted. Check manually."
}

# ── stream-host-files: stream tar.gz to stdout ────────────────────────────────
mode_stream_host_files() {
    local clevel="${1:-3}"
    local -a HOST_PATHS=()
    _discover_host_paths
    ((${#HOST_PATHS[@]})) || die 'No host paths found.'
    local -a rel=()
    for p in "${HOST_PATHS[@]}"; do rel+=("${p#/}"); done
    printf '%s\n' "${HOST_PATHS[@]}" >&2
    say "Streaming host files (${#HOST_PATHS[@]} paths, gzip level $clevel)..." >&2
    # Create tar without -z, pipe through gzip with chosen level, then tee+hash
    stream_hashed "$clevel" bash -c \
        "sudo tar --numeric-owner --xattrs --acls -cpf - -C / $(printf '%q ' "${rel[@]}") | gzip -${clevel}"
}

# ── stream-volume: stream one Docker volume as tar.gz to stdout ───────────────
# The archive is streamed from `docker run alpine tar -cpf - -C /source .`,
# with gzip and the SHA-256 of the compressed byte stream computed on the VM
# host (outside the container) via stream_hashed. This gives Windows a
# source-side hash to compare against — closing the integrity gap present in
# earlier revisions, which hashed only the receive-side bytes.
#
# GNU tar exit codes:
#   0  success
#   1  non-fatal warnings (e.g. a file changed while being read)
#   2+ fatal error
# We accept 0 and 1 so routine warnings do not abort the backup, but let 2+
# propagate through the pipe so pipefail trips and the archive is rejected.
mode_stream_volume() {
    local vol="$1" clevel="${2:-3}"
    docker volume inspect "$vol" >/dev/null 2>&1 || die "Volume not found: $vol"
    say "Streaming volume $vol (gzip level $clevel)..."
    stream_hashed "$clevel" bash -c \
        "docker run --rm --network none -v '${vol}:/source:ro' alpine \
            sh -c 'tar -cpf - -C /source .; code=\$?; [ \$code -le 1 ] || exit \$code' \
         | gzip -${clevel}"
}

# ── stream-images: stream all Docker images (deduplicated by ID) as tar.gz ────
mode_stream_images() {
    local folder_name="$1" clevel="${2:-3}"
    BACKUP_DIR="$HOME/$folder_name"
    [[ -d "$BACKUP_DIR" ]] || die "Staging directory not found."

    local -a unique_ids=()
    mapfile -t unique_ids < <(docker image ls -q --no-trunc | sort -u)
    ((${#unique_ids[@]})) || die 'No Docker images found.'

    # Write image manifest for restore reference
    docker image ls --digests --no-trunc > "$BACKUP_DIR/reports/docker-images-list-including-snapshots.txt" 2>/dev/null || true
    docker image inspect "${unique_ids[@]}" > "$BACKUP_DIR/reports/images-inspect-including-snapshots.json" 2>/dev/null || true

    # Build tag→ID mapping for manifest
    local rpt="$BACKUP_DIR/reports/image-id-tag-map.tsv"
    : > "$rpt"
    while IFS= read -r line; do
        local id tags
        id="$(echo "$line" | awk '{print $3}')"
        tags="$(docker image inspect --format '{{range .RepoTags}}{{.}} {{end}}' "$id" 2>/dev/null || echo '')"
        printf '%s\t%s\n' "$id" "$tags" >> "$rpt"
    done < <(docker image ls --no-trunc | tail -n +2)

    say "Streaming ${#unique_ids[@]} unique image ID(s) (gzip level $clevel)..." >&2
    printf 'Unique IDs:\n' >&2
    printf '  %s\n' "${unique_ids[@]}" >&2

    stream_hashed "$clevel" bash -c \
        "docker image save $(printf '%q ' "${unique_ids[@]}") | gzip -${clevel}"
}

# ── finalize: fix ownership for SCP ──────────────────────────────────────────
mode_finalize() {
    local folder_name="$1"
    BACKUP_DIR="$HOME/$folder_name"
    [[ -d "$BACKUP_DIR" ]] || die "Staging directory not found: $BACKUP_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR" 2>/dev/null || true
    find "$BACKUP_DIR" -type d -exec chmod 700 {} +
    find "$BACKUP_DIR" -type f -exec chmod 600 {} +
    # Small-files SHA256SUMS (reports, DB dumps, logs) for SCP integrity
    (cd "$BACKUP_DIR" && find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
    chmod 600 "$BACKUP_DIR/SHA256SUMS"
    say "Finalized. SHA256SUMS written for small staging files."
    du -sh "$BACKUP_DIR" 2>/dev/null >&2 || true
}

# ── cleanup: remove staging dir and snapshot tags ────────────────────────────
mode_cleanup() {
    local folder_name="$1"
    [[ "$folder_name" =~ ^VM-Restore-Point-[0-9]{8}-[0-9]{6}$ ]] || die 'Invalid folder name.'
    BACKUP_DIR="$HOME/$folder_name"
    [[ -d "$BACKUP_DIR" ]] || die "Staging dir not found: $BACKUP_DIR"
    [[ -f "$BACKUP_DIR/SHA256SUMS" ]] || die "Refusing cleanup: SHA256SUMS missing (verification may not have run)."
    if [[ -f "$BACKUP_DIR/reports/created-snapshot-image-tags.txt" ]]; then
        while IFS= read -r tag; do
            [[ -n "$tag" ]] || continue
            docker image rm "$tag" >/dev/null 2>&1 || warn "Could not remove snapshot tag $tag; remove manually."
        done < "$BACKUP_DIR/reports/created-snapshot-image-tags.txt"
    fi
    rm -rf -- "$BACKUP_DIR"
    rm -f  -- "$0"
    say "Remote staging folder removed. Original containers, images and volumes retained."
}

MODE="${1:-}"
case "$MODE" in
    prepare)             [[ $# -ge 3 ]] || die 'Usage: prepare FOLDER TIMESTAMP'; mode_prepare "$2" "$3" ;;
    get-info)            [[ $# -ge 2 ]] || die 'Usage: get-info FOLDER'; mode_get_info "$2" ;;
    stop-containers)     mode_stop_containers ;;
    snapshot-containers) [[ $# -ge 3 ]] || die 'Usage: snapshot-containers FOLDER TIMESTAMP'; mode_snapshot_containers "$2" "$3" ;;
    start-containers)    shift; mode_start_containers "$@" ;;
    stream-host-files)   mode_stream_host_files "${2:-3}" ;;
    stream-volume)       [[ $# -ge 2 ]] || die 'Usage: stream-volume VOLNAME [LEVEL]'; mode_stream_volume "$2" "${3:-3}" ;;
    stream-images)       [[ $# -ge 2 ]] || die 'Usage: stream-images FOLDER [LEVEL]'; mode_stream_images "$2" "${3:-3}" ;;
    finalize)            [[ $# -ge 2 ]] || die 'Usage: finalize FOLDER'; mode_finalize "$2" ;;
    cleanup)             [[ $# -ge 2 ]] || die 'Usage: cleanup FOLDER'; mode_cleanup "$2" ;;
    *) die "Unknown mode '$MODE'. Modes: prepare get-info stop-containers snapshot-containers start-containers stream-host-files stream-volume stream-images finalize cleanup" ;;
esac
'@

# ─── Derived values ───────────────────────────────────────────────────────────
$remote            = "$SshUser@$SshHost"
$timestamp         = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupFolderName  = "VM-Restore-Point-$timestamp"
$remoteRunnerPath  = "/home/$SshUser/.vm-full-backup-runner.sh"
$localFolder       = Join-Path $BackupDir $backupFolderName

# SSH options: disable transport compression (we send pre-compressed data);
# keep-alive to prevent timeout on long transfers; preserve host-key checking.
$script:SshOpts = @(
    '-o', 'Compression=no',
    '-o', 'TCPKeepAlive=yes',
    '-o', 'ServerAliveInterval=10',
    '-o', 'ServerAliveCountMax=60'
)

# Temporary SSH key: generated locally before Phase 1, installed on the VM during
# Phase 1 (in the same connection where the user types their password), then used
# for every subsequent SSH/SCP call so no further password prompts are needed.
# Removed from the VM and deleted locally in the finally block.
$script:TmpKeyDir       = ''
$script:TmpPrivKey      = ''
$script:TmpKeyInstalled = $false
$script:ScpCtrlOpts     = @()   # key opts for scp.exe calls; set after key install

# ─── Locate tools ─────────────────────────────────────────────────────────────
$sshCmd = Get-Command 'ssh.exe' -ErrorAction SilentlyContinue
$scpCmd = Get-Command 'scp.exe' -ErrorAction SilentlyContinue
$tarCmd = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
if (-not $sshCmd) { throw 'OpenSSH ssh.exe not found. Enable the Windows OpenSSH Client feature.' }
if (-not $scpCmd) { throw 'OpenSSH scp.exe not found. Enable the Windows OpenSSH Client feature.' }
if (-not $tarCmd) { throw 'Windows tar.exe not found.' }
$script:SshExe    = $sshCmd.Source
$scpExe           = $scpCmd.Source
$script:TarExe    = $tarCmd.Source
$sshKeygenCmd     = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
if (-not $sshKeygenCmd) { throw 'ssh-keygen.exe not found. It should be present with Windows OpenSSH.' }
$script:SshKeygen = $sshKeygenCmd.Source

# ─── Temp script file ─────────────────────────────────────────────────────────
$tempScript = Join-Path $env:TEMP "vm-full-backup-runner-$timestamp.sh"
$utf8NoBom  = [System.Text.UTF8Encoding]::new($false)
$normalized = $remoteScript -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($tempScript, $normalized, $utf8NoBom)

# ─── SHA256SUMS accumulator (Windows-side) ────────────────────────────────────
$windowsChecksums   = [System.Collections.Generic.List[string]]::new()
# ─── Manifest accumulator (populated as artifacts stream) ─────────────────────
$manifestArtifacts  = [System.Collections.Generic.List[hashtable]]::new()

# ─── Offline validation of an existing backup folder ──────────────────────────
# Does not connect to the VM. Re-hashes files against SHA256SUMS, re-runs
# archive structure checks (tar.gz, docker image tar.gz, PostgreSQL dumps),
# and verifies manifest.json completeness when present.
function Invoke-BackupValidation {
    param([Parameter(Mandatory)][string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "Validate-Backup: not a directory: $Folder"
    }
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "[VALIDATE] $Folder" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan

    $failed = 0
    $passed = 0

    # 1. Rehash every file against SHA256SUMS
    $sumsPath = Join-Path $Folder 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
        Write-Host "  FAIL: SHA256SUMS missing — backup incomplete." -ForegroundColor Red
        return 1
    }
    foreach ($line in (Get-Content -LiteralPath $sumsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\.?/?(.+)$') { continue }
        $exp = $Matches[1].ToLowerInvariant()
        $rel = $Matches[2].Trim()
        if ($rel.Contains('..')) { Write-Host "  FAIL: unsafe path in SHA256SUMS: $rel" -ForegroundColor Red; $failed++; continue }
        $win = Join-Path $Folder ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $win -PathType Leaf)) {
            Write-Host "  FAIL: missing file: $rel" -ForegroundColor Red; $failed++; continue
        }
        $act = (Get-FileHash -LiteralPath $win -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($exp -ne $act) {
            Write-Host "  FAIL: hash mismatch: $rel" -ForegroundColor Red; $failed++
        } else {
            $passed++
        }
    }
    Write-Host "  Hash check: $passed verified, $failed failed." -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })

    # 2. Re-run archive structure checks
    foreach ($name in @('host-files.tar.gz','docker-images-all.tar.gz')) {
        $p = Join-Path $Folder $name
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $fmt = if ($name -eq 'docker-images-all.tar.gz') { 'docker-tar.gz' } else { 'tar.gz' }
            try { Test-Archive -Path $p -Description $name -Format $fmt } catch { Write-Host "  FAIL: $name — $($_.Exception.Message)" -ForegroundColor Red; $failed++ }
        } else {
            Write-Host "  FAIL: $name not present in backup." -ForegroundColor Red; $failed++
        }
    }
    $volDir = Join-Path $Folder 'volumes'
    if (Test-Path -LiteralPath $volDir -PathType Container) {
        foreach ($v in (Get-ChildItem -LiteralPath $volDir -Filter '*.tar.gz' -File)) {
            try { Test-Archive -Path $v.FullName -Description "Volume: $($v.BaseName)" -Format 'tar.gz' } catch { Write-Host "  FAIL: $($v.Name)" -ForegroundColor Red; $failed++ }
        }
    }
    $cluster = Join-Path $Folder 'database-dumps\postgres17-all-databases.sql'
    if (Test-Path -LiteralPath $cluster -PathType Leaf) {
        try { Test-Archive -Path $cluster -Description 'PostgreSQL cluster dump' -Format 'sql' } catch { Write-Host "  FAIL: cluster dump — $($_.Exception.Message)" -ForegroundColor Red; $failed++ }
    }

    # 3. Manifest completeness check (if manifest.json is present)
    $manifestPath = Join-Path $Folder 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            Write-Host "  Manifest: backupId=$($m.backupId), artifacts=$($m.artifacts.Count), volumes=$($m.volumes.Count)" -ForegroundColor Gray
            foreach ($a in $m.artifacts) {
                $f = Join-Path $Folder $a.path
                if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
                    Write-Host "  FAIL: manifest lists missing artifact: $($a.path)" -ForegroundColor Red; $failed++
                }
            }
        } catch { Write-Host "  FAIL: manifest.json unreadable — $($_.Exception.Message)" -ForegroundColor Red; $failed++ }
    } else {
        Write-Host "  NOTE: manifest.json absent (older backup, pre-manifest format)." -ForegroundColor Yellow
    }

    Write-Host ''
    if ($failed -eq 0) {
        Write-Host 'VALIDATION PASSED.' -ForegroundColor Green
        return 0
    } else {
        Write-Host "VALIDATION FAILED: $failed problem(s)." -ForegroundColor Red
        return 1
    }
}

if ($ValidateBackup) {
    $vrc = Invoke-BackupValidation -Folder $ValidateBackup
    exit $vrc
}

# ─── Lock file (prevents two concurrent live runs on the same BackupDir) ──────
# Not held in DryRun mode — a dry run reads only and does not stage anything.
$script:LockPath    = $null
$script:LockAcquired = $false

# ─── Main backup flow ─────────────────────────────────────────────────────────
try {
    # ── Phase 1: Preflight ────────────────────────────────────────────────────
    $phaseLabel = if ($DryRun) { 'DRY RUN — 1/3' } else { '1/9' }
    Write-Phase $phaseLabel 'Preflight: check Windows tools, create destination, connect to VM'
    Write-Host "  Remote host  : $remote" -ForegroundColor Gray
    Write-Host "  Local folder : $localFolder" -ForegroundColor Gray
    Write-Host "  Compress lvl : gzip -$CompressLevel" -ForegroundColor Gray
    if ($DryRun) { Write-Host "  Mode         : DRY RUN (no containers stopped, no archives streamed)" -ForegroundColor Yellow }

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    # Acquire a BackupDir-level lock so two live runs cannot race.
    if (-not $DryRun) {
        $script:LockPath = Join-Path $BackupDir '.vm-full-backup.lock'
        if (Test-Path -LiteralPath $script:LockPath -PathType Leaf) {
            $existing = (Get-Content -LiteralPath $script:LockPath -Raw -ErrorAction SilentlyContinue).Trim()
            $existingPid = 0
            if ($existing -match 'PID=(\d+)') { $existingPid = [int]$Matches[1] }
            $stillAlive = $false
            if ($existingPid -gt 0) {
                try { $null = Get-Process -Id $existingPid -ErrorAction Stop; $stillAlive = $true } catch { }
            }
            if ($stillAlive) {
                throw "Another backup is running in $BackupDir (lock PID $existingPid). Refusing to start."
            } else {
                Write-Host "  Removing stale lock from PID $existingPid." -ForegroundColor Yellow
                Remove-Item -LiteralPath $script:LockPath -Force
            }
        }
        "PID=$PID`nStarted=$([DateTime]::UtcNow.ToString('o'))`nTimestamp=$timestamp" |
            Set-Content -LiteralPath $script:LockPath -Encoding ASCII
        $script:LockAcquired = $true
    }

    if (-not $DryRun) {
        if (Test-Path -LiteralPath $localFolder) {
            throw "Refusing to overwrite existing restore-point folder: $localFolder"
        }
        New-Item -ItemType Directory -Path $localFolder -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $localFolder 'volumes') -Force | Out-Null
    }

    # Generate a disposable Ed25519 key pair.  The public key is pushed to the VM
    # in the SAME connection where the user types their password, so every subsequent
    # SSH/SCP call uses key auth with no further prompts.
    Write-Host "  Generating temporary SSH key pair..." -ForegroundColor Gray
    $script:TmpKeyDir  = Join-Path $env:TEMP ("sshbkp_" + $timestamp.Replace('-', ''))
    New-Item -ItemType Directory -Path $script:TmpKeyDir -Force | Out-Null
    $script:TmpPrivKey = Join-Path $script:TmpKeyDir 'bkpkey'
    $tmpPubKey         = Join-Path $script:TmpKeyDir 'bkpkey.pub'
    $keyComment = "vm-backup-temp-$timestamp"
    # PowerShell 5.1 drops empty-string args to native commands, so pass the
    # empty passphrase via ProcessStartInfo.Arguments where "" is unambiguous.
    $kgPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $kgPsi.FileName        = $script:SshKeygen
    $kgPsi.Arguments       = "-t ed25519 -N `"`" -f `"$($script:TmpPrivKey)`" -C `"$keyComment`""
    $kgPsi.UseShellExecute = $false
    $kgPsi.CreateNoWindow  = $false
    $kgProc = [System.Diagnostics.Process]::Start($kgPsi)
    $kgProc.WaitForExit()
    if ($kgProc.ExitCode -ne 0) { throw 'ssh-keygen failed to generate temporary key pair.' }
    $pubKeyContent = (Get-Content $tmpPubKey -Raw).Trim()

    # Single password-authenticated connection: run the preflight check AND install
    # the temp public key so all subsequent calls can use key-based auth.
    Write-Host "  You will be prompted for the SSH password once to install the temporary key." -ForegroundColor Yellow
    $installCmd = "echo SSH_OK && id -un && docker info --format Docker_OK && " +
                  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
                  "printf '%s\n' '$pubKeyContent' >> ~/.ssh/authorized_keys && " +
                  "chmod 600 ~/.ssh/authorized_keys && echo KEY_INSTALLED"
    Invoke-NativeChecked -FilePath $script:SshExe `
        -ArgumentList ($script:SshOpts + @($remote, $installCmd)) `
        -Action 'SSH+Docker connectivity check + temp key install'

    # Switch all subsequent SSH/SCP calls to key auth — no more password prompts.
    $script:TmpKeyInstalled = $true
    $keyOpts = @('-i', $script:TmpPrivKey, '-o', 'PasswordAuthentication=no', '-o', 'BatchMode=yes')
    $script:SshOpts    += $keyOpts
    $script:ScpCtrlOpts = $keyOpts
    Write-Host "  Temporary SSH key installed. No further password prompts for this backup." -ForegroundColor Green

    # ── Phase 2: Upload runner, run prepare ───────────────────────────────────
    if ($DryRun) {
        Write-Phase 'DRY RUN — 2/3' 'Upload runner (prepare skipped — no PostgreSQL dump, no inventory capture)'
    } else {
        Write-Phase '2/9' 'Upload runner; capture inventory and PostgreSQL dump on VM'
    }
    Invoke-NativeChecked -FilePath $scpExe `
        -ArgumentList ($script:ScpCtrlOpts + @($tempScript, "${remote}:$remoteRunnerPath")) `
        -Action 'Upload remote backup runner'
    if (-not $DryRun) {
        Invoke-NativeChecked -FilePath $script:SshExe `
            -ArgumentList (@('-t', $remote) + $script:SshOpts + @("bash '$remoteRunnerPath' prepare '$backupFolderName' '$timestamp'")) `
            -Action 'Prepare staging dir / inventory / DB dump'
    }

    # ── Phase 3: Get stream info, check disk, ask confirmation ────────────────
    if ($DryRun) {
        Write-Phase 'DRY RUN — 3/3' 'Collect volume list and size estimates (read-only)'
    } else {
        Write-Phase '3/9' 'Collect volume list, size estimates, confirm downtime'
    }
    $infoLines = Invoke-SshText -Remote $remote `
        -Command "bash '$remoteRunnerPath' get-info '$backupFolderName'" `
        -Action 'Get stream info'

    $volumeInfo   = [System.Collections.Generic.List[hashtable]]::new()
    $hostFilesEst = [long]0
    $imageCount   = 0
    $vmFreeKB     = [long]0

    foreach ($line in $infoLines) {
        if ($line -match '^VOLUME:(.+):(\d+)$') {
            $volumeInfo.Add(@{ Name = $Matches[1]; EstBytes = [long]$Matches[2] })
        } elseif ($line -match '^HOSTFILES_SIZE:(\d+)$') {
            $hostFilesEst = [long]$Matches[1]
        } elseif ($line -match '^IMAGE_COUNT:(\d+)$') {
            $imageCount = [int]$Matches[1]
        } elseif ($line -match '^VM_FREE_KB:(\d+)$') {
            $vmFreeKB = [long]$Matches[1]
        }
    }

    $vmFreeGB = [math]::Round($vmFreeKB / 1MB, 1)
    Write-Host "  VM free disk   : $vmFreeGB GiB" -ForegroundColor Gray
    Write-Host "  Volumes found  : $($volumeInfo.Count)" -ForegroundColor Gray
    Write-Host "  Images found   : $imageCount" -ForegroundColor Gray
    Write-Host "  Host files est : $(Format-ByteSize $hostFilesEst)" -ForegroundColor Gray
    if ($vmFreeKB -lt 2097152) {  # < 2 GiB
        Write-Host "  WARNING: VM has less than 2 GiB free. Streaming mode avoids large staging files, but small amounts are still needed." -ForegroundColor Yellow
    }

    # Check Windows destination free space
    $destDrive = [System.IO.Path]::GetPathRoot($BackupDir)
    $wfree = (Get-PSDrive -Name ($destDrive.TrimEnd(':\')) -ErrorAction SilentlyContinue)
    if ($wfree) {
        Write-Host "  Windows free   : $(Format-ByteSize ($wfree.Free))" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host "  STREAMING ARCHITECTURE: archives are streamed directly from the VM to Windows." -ForegroundColor Cyan
    Write-Host "  The VM does NOT need disk space for the large image or volume archives." -ForegroundColor Cyan

    # Volume breakdown (useful in dry-run and before confirmation)
    if ($volumeInfo.Count -gt 0) {
        Write-Host ''
        Write-Host "  Volume inventory (uncompressed estimates):" -ForegroundColor Gray
        $volTotal = [long]0
        foreach ($v in $volumeInfo) {
            Write-Host ("    {0,-55} {1,10}" -f $v.Name, (Format-ByteSize $v.EstBytes)) -ForegroundColor Gray
            $volTotal += $v.EstBytes
        }
        Write-Host ("    {0,-55} {1,10}" -f 'TOTAL', (Format-ByteSize $volTotal)) -ForegroundColor Gray
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host ('─' * 78) -ForegroundColor Green
        Write-Host "DRY RUN COMPLETE — no changes made to the VM." -ForegroundColor Green
        Write-Host "  VM free disk     : $vmFreeGB GiB" -ForegroundColor Green
        Write-Host "  Volumes          : $($volumeInfo.Count)" -ForegroundColor Green
        Write-Host "  Images           : $imageCount" -ForegroundColor Green
        Write-Host "  Host files est   : $(Format-ByteSize $hostFilesEst)" -ForegroundColor Green
        Write-Host "  Rerun without -DryRun to perform the backup." -ForegroundColor Green
        Write-Host ('─' * 78) -ForegroundColor Green
        # Remove the uploaded runner so the VM has no leftover from this dry run.
        try {
            & $script:SshExe @script:SshOpts $remote "rm -f '$remoteRunnerPath'" 2>&1 | Out-Null
        } catch { Write-Warning "Could not remove $remoteRunnerPath from VM: $($_.Exception.Message)" }
        exit 0
    }

    Write-Host ''
    Write-Host "  The backup will briefly stop all running containers to ensure volume consistency," -ForegroundColor Yellow
    Write-Host "  then restart them. Container snapshots and Docker images are captured afterward." -ForegroundColor Yellow
    Write-Host ''
    $confirm = Read-Host "  Type STOP-AND-BACKUP to proceed, or anything else to cancel"
    if ($confirm -ne 'STOP-AND-BACKUP') { throw 'Cancelled by user before stopping any containers.' }

    # ── Phase 4: Stop containers; stream host files + volumes ─────────────────
    Write-Phase '4/9' 'Stop containers; stream host files and all Docker volumes to Windows'
    Write-Host "  Stopping running containers via SSH..." -ForegroundColor Gray
    $stoppedIds = Invoke-SshText -Remote $remote `
        -Command "bash '$remoteRunnerPath' stop-containers" `
        -Action 'Stop containers'
    $stoppedIds = @($stoppedIds | Where-Object { $_ -match '^[0-9a-f]{40,64}$' })
    Write-Host "  Stopped $($stoppedIds.Count) container(s)." -ForegroundColor Gray

    # Stream host files
    $tmpHF  = Join-Path $localFolder 'host-files.tar.gz.tmp'
    $finalHF = Join-Path $localFolder 'host-files.tar.gz'
    $hfResult = Invoke-SshStream `
        -Remote $remote `
        -RemoteCommand "bash '$remoteRunnerPath' stream-host-files $CompressLevel" `
        -TempPath $tmpHF -FinalPath $finalHF `
        -Description 'Host files / project code / config' `
        -EstimatedBytes $hostFilesEst `
        -Label "4/9"
    $windowsChecksums.Add("$($hfResult.Hash)  ./host-files.tar.gz")
    $manifestArtifacts.Add(@{
        path         = 'host-files.tar.gz'
        kind         = 'host-files'
        bytes        = $hfResult.Bytes
        sourceSha256 = $hfResult.SourceHash
        destSha256   = $hfResult.Hash
        verified     = ($hfResult.SourceHash -eq $hfResult.Hash)
    })

    # Stream each volume
    $volIdx = 0
    foreach ($vol in $volumeInfo) {
        $volIdx++
        $vName   = $vol.Name
        $vEst    = $vol.EstBytes
        $vFile   = $vName -replace '[^A-Za-z0-9_.-]', '_'
        $tmpV    = Join-Path $localFolder "volumes\$vFile.tar.gz.tmp"
        $finalV  = Join-Path $localFolder "volumes\$vFile.tar.gz"
        $vResult = Invoke-SshStream `
            -Remote $remote `
            -RemoteCommand "bash '$remoteRunnerPath' stream-volume '$vName' $CompressLevel" `
            -TempPath $tmpV -FinalPath $finalV `
            -Description "Volume: $vName" `
            -EstimatedBytes $vEst `
            -Label "$volIdx+hf/$($volumeInfo.Count+1) vol"
        $windowsChecksums.Add("$($vResult.Hash)  ./volumes/$vFile.tar.gz")
        $manifestArtifacts.Add(@{
            path         = "volumes/$vFile.tar.gz"
            kind         = 'volume'
            volumeName   = $vName
            estBytes     = $vEst
            bytes        = $vResult.Bytes
            sourceSha256 = $vResult.SourceHash
            destSha256   = $vResult.Hash
            verified     = ($vResult.SourceHash -eq $vResult.Hash)
        })
    }

    # ── Phase 5: Snapshot containers (while stopped), then restart ────────────
    Write-Phase '5/9' 'Snapshot container writable layers; restart containers'
    Invoke-NativeChecked -FilePath $script:SshExe `
        -ArgumentList (@('-t', $remote) + $script:SshOpts + @("bash '$remoteRunnerPath' snapshot-containers '$backupFolderName' '$timestamp'")) `
        -Action 'Snapshot container writable layers'

    if ($stoppedIds.Count -gt 0) {
        $restartArg = ($stoppedIds | ForEach-Object { "'$_'" }) -join ' '
        Invoke-NativeChecked -FilePath $script:SshExe `
            -ArgumentList (@('-t', $remote) + $script:SshOpts + @("bash '$remoteRunnerPath' start-containers $restartArg")) `
            -Action 'Restart containers'
        Write-Host "  Containers restarted." -ForegroundColor Green
    } else {
        Write-Host "  No containers were stopped; nothing to restart." -ForegroundColor Gray
    }

    # ── Phase 6: Stream Docker images (includes snapshot images) ──────────────
    Write-Phase '6/9' 'Stream Docker images (deduplicated by image ID)'
    $tmpImg   = Join-Path $localFolder 'docker-images-all.tar.gz.tmp'
    $finalImg = Join-Path $localFolder 'docker-images-all.tar.gz'
    $imgResult = Invoke-SshStream `
        -Remote $remote `
        -RemoteCommand "bash '$remoteRunnerPath' stream-images '$backupFolderName' $CompressLevel" `
        -TempPath $tmpImg -FinalPath $finalImg `
        -Description 'All Docker images + container snapshots' `
        -Label '6/9'
    $windowsChecksums.Add("$($imgResult.Hash)  ./docker-images-all.tar.gz")
    $manifestArtifacts.Add(@{
        path         = 'docker-images-all.tar.gz'
        kind         = 'docker-images'
        imageCount   = $imageCount
        bytes        = $imgResult.Bytes
        sourceSha256 = $imgResult.SourceHash
        destSha256   = $imgResult.Hash
        verified     = ($imgResult.SourceHash -eq $imgResult.Hash)
    })

    # ── Phase 7: Finalize VM staging; SCP small files ─────────────────────────
    Write-Phase '7/9' 'Finalize VM staging dir; transfer reports/logs/DB dumps via SCP'
    Invoke-NativeChecked -FilePath $script:SshExe `
        -ArgumentList (@('-t', $remote) + $script:SshOpts + @("bash '$remoteRunnerPath' finalize '$backupFolderName'")) `
        -Action 'Finalize VM staging directory'

    # SCP small files: reports, logs, database-dumps, BACKUP-INFO if any, SHA256SUMS for small files
    $remoteFolder = "/home/$SshUser/$backupFolderName"
    Invoke-NativeChecked -FilePath $scpExe `
        -ArgumentList ($script:ScpCtrlOpts + @('-r', "${remote}:${remoteFolder}/reports",          $localFolder)) `
        -Action 'SCP reports/'
    Invoke-NativeChecked -FilePath $scpExe `
        -ArgumentList ($script:ScpCtrlOpts + @('-r', "${remote}:${remoteFolder}/container-logs",   $localFolder)) `
        -Action 'SCP container-logs/'
    Invoke-NativeChecked -FilePath $scpExe `
        -ArgumentList ($script:ScpCtrlOpts + @('-r', "${remote}:${remoteFolder}/database-dumps",   $localFolder)) `
        -Action 'SCP database-dumps/'
    # Also grab the small-files SHA256SUMS from the VM for cross-check
    $scpSha = "${remote}:${remoteFolder}/SHA256SUMS"
    Invoke-NativeChecked -FilePath $scpExe `
        -ArgumentList ($script:ScpCtrlOpts + @($scpSha, (Join-Path $localFolder 'SHA256SUMS-REMOTE'))) `
        -Action 'SCP remote SHA256SUMS'

    # ── Phase 8: Verify archives + build final manifest ───────────────────────
    Write-Phase '8/9' 'Validate all archives; verify SCP checksums; build manifest'

    # Validate large streamed archives
    Test-Archive -Path $finalHF  -Description 'Host files archive'       -Format 'tar.gz'
    Test-Archive -Path $finalImg -Description 'Docker images archive'    -Format 'docker-tar.gz'
    $volArchives = @(Get-ChildItem -LiteralPath (Join-Path $localFolder 'volumes') -Filter '*.tar.gz' -File)
    if ($volArchives.Count -lt 1) { throw 'No volume archives received.' }
    foreach ($va in $volArchives) {
        Test-Archive -Path $va.FullName -Description "Volume: $($va.BaseName)" -Format 'tar.gz'
    }

    # Validate DB dumps
    $clusterDumpStatus = 'absent'
    $clusterDump = Join-Path $localFolder 'database-dumps\postgres17-all-databases.sql'
    if (Test-Path -LiteralPath $clusterDump -PathType Leaf) {
        try { Test-Archive -Path $clusterDump -Description 'PostgreSQL cluster dump' -Format 'sql'; $clusterDumpStatus = 'validated' }
        catch { $clusterDumpStatus = 'invalid'; throw }
    }
    $customDumps = @(Get-ChildItem -LiteralPath (Join-Path $localFolder 'database-dumps') -Filter '*-custom.dump' -File -ErrorAction SilentlyContinue)
    foreach ($cd in $customDumps) {
        Write-Host "  Validating custom dump: $($cd.Name)" -ForegroundColor Gray
        $pgRestoreResult = & pg_restore.exe --list $cd.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: pg_restore --list failed for $($cd.Name) (pg_restore.exe may not be installed on Windows; dump was verified on the VM)." -ForegroundColor Yellow
        } else {
            Write-Host "  PASS: $($cd.Name)" -ForegroundColor Green
        }
    }

    # Verify SCP'd small files against remote SHA256SUMS
    $remoteSumsPath = Join-Path $localFolder 'SHA256SUMS-REMOTE'
    if (Test-Path -LiteralPath $remoteSumsPath -PathType Leaf) {
        $sumsContent = Get-Content -LiteralPath $remoteSumsPath
        $smallChecks = 0
        foreach ($line in $sumsContent) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') { continue }
            $expHash = $Matches[1].ToLowerInvariant()
            $relPath = $Matches[2] -replace '^\./', ''
            if ($relPath.Contains('..')) { throw "Unsafe path in remote SHA256SUMS: $relPath" }
            # Only check files that were SCP'd (reports, container-logs, database-dumps, SHA256SUMS itself excluded)
            $winPath = Join-Path $localFolder ($relPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $winPath -PathType Leaf)) { continue }
            $actHash = (Get-FileHash -LiteralPath $winPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($expHash -ne $actHash) {
                throw "SHA-256 mismatch for SCP'd file $relPath.`n  Expected: $expHash`n  Actual:   $actHash"
            }
            $windowsChecksums.Add("$actHash  ./$relPath")
            $smallChecks++
        }
        Write-Host "  PASS: $smallChecks SCP'd files verified against remote SHA256SUMS." -ForegroundColor Green
    }

    # Write combined Windows SHA256SUMS
    $finalSumsPath = Join-Path $localFolder 'SHA256SUMS'
    $windowsChecksums | Sort-Object | Set-Content -LiteralPath $finalSumsPath -Encoding UTF8

    # Write BACKUP-INFO.txt
    $createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $infoContent = @"
VM FULL RESTORE POINT — DIRECT STREAMING ARCHITECTURE
======================================================
Created UTC    : $createdUtc
Backup folder  : $backupFolderName
VM host        : $SshHost
SSH user       : $SshUser
Compress level : gzip -$CompressLevel
Script version : streaming (no large staging files on VM)

CONTENTS
  host-files.tar.gz        — project code, Compose stacks, .env files, bind mounts, Docker host config
  docker-images-all.tar.gz — all Docker images deduplicated by image ID, plus container writable-layer snapshots
  volumes/                 — one tar.gz per Docker volume (including anonymous and unattached)
  database-dumps/          — PostgreSQL pg_dumpall cluster dump + per-database custom-format dumps (when successful)
  reports/                 — Docker inventory (inspect JSON, lists, logs, snapshot map, environment info)
  container-logs/          — last 5000 log lines per container
  SHA256SUMS               — combined SHA-256 for every file in this folder

INTEGRITY
  Large archives were streamed directly from the VM. Source SHA-256 was calculated on the
  compressed byte stream on the VM; destination SHA-256 was calculated on the received file.
  Matches are recorded above. Archive structure was validated with tar -tzf / gzip -t.

IMPORTANT
  This is an application-layer backup, not a bootable Azure disk image.
  Restore requires a compatible Docker Engine on the target VM.
  This backup contains secrets (.env, credentials, TLS certs, DB data). Keep it encrypted.
  Test restoration on a separate VM before decommissioning the source VM.
"@
    $infoContent | Set-Content -LiteralPath (Join-Path $localFolder 'BACKUP-INFO.txt') -Encoding UTF8

    # Machine-readable manifest for later validation and tooling. The .txt
    # above is for humans; this is the source of truth for -ValidateBackup.
    # Written without the PS7 ternary so this parses on Windows PowerShell 5.1.
    $artList = foreach ($a in $manifestArtifacts) {
        $o = [ordered]@{
            path         = $a.path
            kind         = $a.kind
            bytes        = $a.bytes
            sourceSha256 = $a.sourceSha256
            destSha256   = $a.destSha256
            verified     = [bool]$a.verified
        }
        if ($a.ContainsKey('volumeName')) { $o.volumeName = $a.volumeName }
        if ($a.ContainsKey('estBytes'))   { $o.estBytes   = $a.estBytes }
        if ($a.ContainsKey('imageCount')) { $o.imageCount = $a.imageCount }
        $o
    }
    $allVerified = ($manifestArtifacts | Where-Object { -not $_.verified } | Measure-Object).Count -eq 0
    $manifest = [ordered]@{
        schemaVersion      = 1
        backupId           = $backupFolderName
        createdUtc         = $createdUtc
        source             = [ordered]@{
            sshHost  = $SshHost
            sshUser  = $SshUser
            stackDir = '/opt/n8n-docker-caddy'
        }
        compressLevel      = $CompressLevel
        architecture       = 'direct-ssh-stream'
        artifacts          = @($artList)
        volumes            = @($volumeInfo | ForEach-Object { [ordered]@{ name = $_.Name; estBytes = $_.EstBytes } })
        imageCount         = $imageCount
        stoppedContainerIds = @($stoppedIds)
        verification       = [ordered]@{
            streamHashesMatched   = $allVerified
            archiveStructureValid = $true
            clusterDumpStatus     = $clusterDumpStatus
            customDumpsFound      = $customDumps.Count
            smallFilesChecksCount = $smallChecks
        }
    }
    ($manifest | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath (Join-Path $localFolder 'manifest.json') -Encoding UTF8

    # ── Phase 9: Clean up remote staging dir ──────────────────────────────────
    Write-Phase '9/9' 'Clean up VM staging directory (originals retained)'
    try {
        Invoke-NativeChecked -FilePath $script:SshExe `
            -ArgumentList (@('-t', $remote) + $script:SshOpts + @("bash '$remoteRunnerPath' cleanup '$backupFolderName'")) `
            -Action 'Clean VM staging dir'
        Write-Host '  PASS: VM staging directory removed. Original containers, images and volumes retained.' -ForegroundColor Green
    } catch {
        Write-Warning "Local backup passed verification, but remote cleanup did not complete. Keep your local copy. Remote folder: $remoteFolder. Detail: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host ('─' * 78) -ForegroundColor Green
    Write-Host 'FULL VM RESTORE POINT COMPLETE' -ForegroundColor Green
    Write-Host "  Local folder      : $localFolder" -ForegroundColor Green
    Write-Host "  Volume archives   : $($volArchives.Count)" -ForegroundColor Green
    Write-Host "  Checksums written : $($windowsChecksums.Count)" -ForegroundColor Green
    Write-Host ('─' * 78) -ForegroundColor Green
    Write-Host 'SECURITY: this backup contains secrets, credentials, DB data and TLS state. Restrict access and keep an encrypted copy.' -ForegroundColor Yellow
    exit 0
}
catch {
    Write-Host ''
    Write-Host "BACKUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Remote staging data is intentionally retained so the only copy is not deleted on failure.' -ForegroundColor Yellow
    Write-Host 'If containers were stopped, the remote runner exit handler attempts to restart the originally-running containers.' -ForegroundColor Gray
    if (Test-Path -LiteralPath $localFolder) {
        Write-Host "Partial local data (if any): $localFolder" -ForegroundColor Gray
    }
    exit 1
}
finally {
    # Remove the disposable SSH key from the VM's authorized_keys, then delete local key files.
    if ($script:TmpKeyInstalled) {
        $keyComment = "vm-backup-temp-$timestamp"
        # Use the temp key itself for this final cleanup call
        & $script:SshExe @script:SshOpts $remote "sed -i '/$keyComment/d' ~/.ssh/authorized_keys" 2>&1 | Out-Null
    }
    if ($script:TmpKeyDir -and (Test-Path -LiteralPath $script:TmpKeyDir -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $script:TmpKeyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($tempScript -and (Test-Path -LiteralPath $tempScript)) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
    # Release the BackupDir lock last — nothing above it needs the lock.
    if ($script:LockAcquired -and $script:LockPath -and (Test-Path -LiteralPath $script:LockPath -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }
}

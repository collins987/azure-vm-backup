#!/usr/bin/env bash
# Extract the bash runner heredoc from backup-n8n-vm-full.ps1 and run bash -n
# over it. This is the one automated check that works without Windows, SSH,
# Docker, or the VM — everything else needs live acceptance.
#
# Usage: tests/syntax-check.sh   (run from repo root)
# Exit:  0 on success, non-zero on bash syntax error or extraction failure.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ps1="$repo_root/backup-n8n-vm-full.ps1"
tmp="$(mktemp -t vm-backup-remote-runner.XXXXXX.sh)"
trap 'rm -f "$tmp"' EXIT

[[ -f "$ps1" ]] || { echo "syntax-check: $ps1 not found" >&2; exit 2; }

awk "/^\\\$remoteScript = @'/{flag=1;next}/^'@/{flag=0}flag" "$ps1" > "$tmp"

lines=$(wc -l < "$tmp")
if (( lines < 100 )); then
    echo "syntax-check: extracted only $lines lines — heredoc markers may have changed" >&2
    exit 3
fi

bash -n "$tmp"
echo "syntax-check: PASS ($lines lines, bash -n clean)"

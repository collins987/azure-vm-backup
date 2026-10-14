# CLAUDE.md

Context for future Claude sessions working on this repository.

## What this is

A Windows → Ubuntu backup tool for a Docker-based n8n deployment on
Azure. Entry point is `backup-n8n-vm-full.cmd`, which runs
`backup-n8n-vm-full.ps1`. Everything else (`README.md`,
`README-n8n-vm-full-backup.txt`, `RESTORE.md`) is documentation.

## Architecture

- One PowerShell orchestrator; the remote-side bash is embedded as a
  single heredoc inside the `.ps1` and uploaded as a temp file over SCP.
- Large archives (`host-files.tar.gz`, each `volumes/*.tar.gz`,
  `docker-images-all.tar.gz`) are streamed over SSH stdout, written to a
  `.tmp` file on Windows with `[System.IO.FileStream]`, SHA-256-verified
  against the VM-side hash sent on SSH stderr, then promoted to the final
  filename.
- Small files (reports, logs, DB dumps) go via SCP after the live phase.
- A disposable Ed25519 key is created locally, installed on the VM in the
  one connection the user types their password into, used for every
  subsequent SSH/SCP call, and removed in the `finally` block.

## Invariants — things to preserve across any edit

- **Every streamed artifact must have a source hash on the VM AND a dest
  hash on Windows.** A path that lacks a source hash is a silent
  integrity gap (that was the bug fixed in commit "Fix critical integrity
  gap in volume streaming").
- **Never run `docker volume prune`, `docker system prune`, or anything
  else that removes production data.** The backup must never destroy
  anything on the VM to make space.
- **Never write a full-size archive to the VM.** Direct streaming is the
  whole point — the VM has limited disk.
- **Never promote `.tmp` to the final filename if any check fails.** The
  convention is `.tmp` → verify → rename, or `.tmp` → `.FAILED` on error.
- **Never log secrets.** `.env` contents, `N8N_ENCRYPTION_KEY`, DB
  passwords, API keys. The script may read these to the backup folder but
  must not print them to the console or include them in exception text.
- **Target PowerShell 5.1 and 7+.** The `.cmd` launcher prefers `pwsh.exe`
  and falls back to `powershell.exe`. Do not use PS7-only syntax like
  `? :`, `??`, `?.`, `-AsUTC`.
- **Target bash on Ubuntu with `set -Eeuo pipefail`.** The embedded bash
  runs with these set at the top. Any pipeline that intentionally tolerates
  a failure must say so explicitly (see `mode_stream_volume`'s GNU-tar
  exit-code handling).

## Code map

Inside `backup-n8n-vm-full.ps1`:

- Lines 1-16: parameters (`-SshHost`, `-SshUser`, `-BackupDir`,
  `-CompressLevel`, `-DryRun`, `-ValidateBackup`).
- `function Write-Phase`, `Format-ByteSize`, `Invoke-NativeChecked`,
  `Invoke-SshText`, `Invoke-SshStream`, `Test-Archive`: helpers.
- `$remoteScript = @'…'@`: the full bash runner (`prepare`, `get-info`,
  `stop-containers`, `snapshot-containers`, `start-containers`,
  `stream-host-files`, `stream-volume`, `stream-images`, `finalize`,
  `cleanup`).
- `function Invoke-BackupValidation`: offline validator (used by
  `-ValidateBackup`).
- Main `try { … }`: Phase 1-9. Dry-run exits after Phase 3.
- `finally { … }`: removes the disposable SSH key from the VM, deletes
  the local key dir, deletes the temp script, releases the BackupDir lock.

## How to test here (cloud container, no Windows, no VM)

- `bash -n` the embedded heredoc. The repo's `tests/syntax-check.sh`
  extracts it and runs this.
- Static review of the PS1 for PS7-only syntax: `grep -nE '\?\?|\?\s*\.|\?\s*:|-AsUTC' backup-n8n-vm-full.ps1`.
- Everything beyond that needs live acceptance against a real VM.

## How to test for real

Dry-run on the live infrastructure:

```powershell
.\backup-n8n-vm-full.cmd -DryRun
```

This installs/removes the SSH key, uploads/removes the runner, and lists
what would be captured — without stopping any container or writing any
archive.

Then a real backup against a disposable test VM before using it on
production.

## Known limitations

See the "KNOWN LIMITATIONS" section of `README.md`. The short list:

- Not a bootable disk image.
- Container snapshots (`docker commit`) do not include volume contents.
- Percentage estimates during streaming are approximate (based on
  uncompressed `du` sizes).
- Restore has not been automatically tested — see `RESTORE.md` and
  manually acceptance-test on a disposable VM.

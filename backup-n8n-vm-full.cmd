@echo off
setlocal EnableDelayedExpansion

:: Locate this script's own directory so the backup runs correctly regardless
:: of the caller's working directory, including paths that contain spaces.
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%backup-n8n-vm-full.ps1"

if not exist "%PS1%" (
    echo ERROR: backup-n8n-vm-full.ps1 not found next to this launcher.
    echo Expected: %PS1%
    exit /b 1
)

:: Prefer PowerShell 7 (pwsh.exe) for best binary-stream support.
:: Fall back to Windows PowerShell 5.1 (powershell.exe) if pwsh is not installed.
where /q pwsh.exe 2>nul
if %ERRORLEVEL% == 0 (
    set "PS_EXE=pwsh.exe"
    set "PS_VER=7"
) else (
    set "PS_EXE=powershell.exe"
    set "PS_VER=5.1"
)

echo.
echo Using !PS_EXE! (PowerShell !PS_VER!)
echo Script: %PS1%
echo.

:: Launch PowerShell with the script. All extra arguments are forwarded so the
:: caller can override -SshHost, -SshUser, -BackupDir, -CompressLevel.
"!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "BACKUP_EXIT=!ERRORLEVEL!"

echo.
if "!BACKUP_EXIT!" == "0" (
    echo [SUCCESS] Full VM restore-point backup complete.
    echo           Review the verified folder printed above.
) else (
    echo [FAILURE] Backup failed with exit code !BACKUP_EXIT!.
    echo           Read the error messages above.
    echo           Remote staging data is retained for diagnosis.
    echo           If services were stopped, the remote script attempted automatic restart.
)
echo.
pause
exit /b !BACKUP_EXIT!

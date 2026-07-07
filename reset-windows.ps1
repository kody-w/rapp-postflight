# reset-windows.ps1 — completely strip the global RAPP brainstem from this
# machine so the public one-liner can be tested as a true fresh install.
#
# Mirrors reset-mac.sh:
#   1. Kills the brainstem server (port 7071) and python brainstem.py processes
#   2. Stashes the Copilot auth token OUTSIDE ~\.brainstem (skip: -FreshAuth)
#   3. Archives ~\.brainstem to ~\brainstem-archives\ (skip: -NoBackup)
#   4. Deletes ~\.brainstem and ~\.local\bin\brainstem.cmd
#   5. VERIFIES every removal actually happened
#   6. Optional -FullFactory: also uninstalls Git / Python 3.11 / GitHub CLI
#      via winget to simulate a factory-fresh machine
#
# Usage:
#   .\reset-windows.ps1
#   .\reset-windows.ps1 -FreshAuth        # also discard the Copilot token
#   .\reset-windows.ps1 -NoBackup         # skip the archive
#   .\reset-windows.ps1 -FullFactory -Yes # ALSO remove git/python/gh

param(
    [switch]$FullFactory,
    [switch]$Yes,
    [switch]$FreshAuth,
    [switch]$NoBackup
)

$ErrorActionPreference = "Stop"
$BRAINSTEM_HOME = "$env:USERPROFILE\.brainstem"
$CLI_PATH = "$env:USERPROFILE\.local\bin\brainstem.cmd"
$ARCHIVE_DIR = "$env:USERPROFILE\brainstem-archives"
$TOKEN_STASH = "$env:USERPROFILE\.brainstem-token.stash"
$PORT = 7071

function OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [X] $msg" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "RAPP brainstem reset (Windows)" -ForegroundColor Cyan
Write-Host ""

# -- 1. Kill running server ---------------------------------------------------
$conns = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    $conns | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    OK "Killed server on port $PORT"
} else {
    OK "No server on port $PORT"
}
Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*brainstem.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# -- 2. Stash auth token ------------------------------------------------------
$tokenFile = "$BRAINSTEM_HOME\src\rapp_brainstem\.copilot_token"
if ($FreshAuth) {
    Remove-Item $TOKEN_STASH -Force -ErrorAction SilentlyContinue
    OK "Fresh-auth mode: token stash cleared (next install will device-auth)"
} elseif (Test-Path $tokenFile) {
    Copy-Item $tokenFile $TOKEN_STASH -Force
    OK "Copilot token stashed to $TOKEN_STASH"
} elseif (Test-Path $TOKEN_STASH) {
    OK "Using existing token stash at $TOKEN_STASH"
} else {
    Warn "No Copilot token found to stash — next install will device-auth"
}

# -- 3. Archive ---------------------------------------------------------------
if (Test-Path $BRAINSTEM_HOME) {
    if ($NoBackup) {
        Warn "Skipping backup (-NoBackup)"
    } else {
        New-Item -ItemType Directory -Force -Path $ARCHIVE_DIR | Out-Null
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $archive = "$ARCHIVE_DIR\brainstem-$stamp.zip"
        Write-Host "  Archiving ~\.brainstem (excluding venv)..."
        # Stage everything except venv/__pycache__, then zip the stage
        $stage = "$env:TEMP\brainstem-stage-$stamp"
        robocopy $BRAINSTEM_HOME $stage /E /XD "$BRAINSTEM_HOME\venv" "__pycache__" /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "robocopy failed staging the archive" }
        Compress-Archive -Path "$stage\*" -DestinationPath $archive -Force
        Remove-Item $stage -Recurse -Force
        if (-not (Test-Path $archive)) { Fail "Archive missing — aborting before delete" }
        OK "Archived to $archive"
    }
} else {
    OK "~\.brainstem does not exist (already clean)"
}

# -- 4. Delete ------------------------------------------------------------------
Remove-Item $BRAINSTEM_HOME -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $CLI_PATH -Force -ErrorAction SilentlyContinue

# -- 5. Verify ------------------------------------------------------------------
Write-Host ""
Write-Host "  Verifying strip..."
if (Test-Path $BRAINSTEM_HOME) { Fail "~\.brainstem still exists" } else { OK "~\.brainstem gone" }
if (Test-Path $CLI_PATH) { Fail "CLI still at $CLI_PATH" } else { OK "brainstem CLI gone" }
if (Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue) {
    Fail "Something still listening on :$PORT"
} else { OK "Port $PORT silent" }

# -- 6. Optional full factory ---------------------------------------------------
if ($FullFactory) {
    Write-Host ""
    Write-Host "  FULL FACTORY MODE — uninstalls Git, Python, and GitHub CLI" -ForegroundColor Red
    Write-Host "  via winget. Other tools on this machine depend on these."
    if (-not $Yes) {
        $answer = Read-Host "  Type 'factory' to proceed"
        if ($answer -ne "factory") { Fail "Aborted full-factory removal" }
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "winget not found — cannot deliver a factory strip; rerun without -FullFactory"
    }

    # gh.exe in use makes its own uninstall fail (issue #28 gap 3) — kill first.
    Get-Process gh -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Strip EVERY winget-known Python, not just 3.11 (issue #28 gap 2): any
    # leftover gets adopted by the installer and silently bypasses the
    # install-Python-from-zero path.
    $pkgs = @("GitHub.cli", "Git.Git")
    $pkgs += (winget list --id Python.Python --accept-source-agreements 2>$null |
        Select-String -Pattern 'Python\.Python\.[\d.]+' -AllMatches |
        ForEach-Object { $_.Matches.Value } | Select-Object -Unique)
    foreach ($pkg in $pkgs) {
        winget uninstall --id $pkg --silent --accept-source-agreements 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { OK "Uninstalled $pkg" } else { Warn "$pkg not installed or could not be removed" }
    }

    # VERIFY the strip (issue #28 gap 1): factory mode must not report success
    # while the bootstrap paths it exists to prove are still bypassed.
    # A hard requirement for git/gh; Python gets a PARTIAL verdict because
    # out-of-scope interpreters (Store shims, pyenv-win, custom C:\PythonXX)
    # are a legitimate machine state the installer is allowed to adopt.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    foreach ($cmd in @('git', 'gh')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { Fail "FACTORY STRIP INCOMPLETE: $cmd still resolves ($($found.Source)) — uninstall it manually, then rerun" }
        OK "$cmd gone from PATH"
    }
    $pyLeft = Get-Command python, python3 -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*WindowsApps*' }   # store shims aren't real installs
    if ($pyLeft) {
        Warn "PARTIAL FACTORY: Python still present outside winget's scope — the installer will adopt it instead of proving install-from-zero:"
        $pyLeft | ForEach-Object { Warn "    $($_.Source)" }
    } else {
        OK "No real Python on PATH — install-from-zero path will be exercised"
    }
}

Write-Host ""
OK "Reset complete — machine is ready for a fresh-install test"
Write-Host "   Run the installer:  iwr -useb https://kody-w.github.io/rapp-installer/install.ps1 | iex"
Write-Host "   Or the full test:   .\test-windows.ps1"
Write-Host ""
# robocopy exits 1 on "files copied successfully" (0-7 are all success), which
# would leak through $LASTEXITCODE and make test-windows.ps1 read a clean reset
# as a failure. Exit 0 explicitly.
exit 0

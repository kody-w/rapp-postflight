# test-windows.ps1 — the post-deploy gate (Windows). Strips the global
# brainstem, runs the PUBLIC installer exactly as a first-time user would,
# and verifies the result. On any failed check it rolls the rapp-installer
# repo back to the prior version (disable with -NoRollback).
#
# Checks (mirror of test-mac.sh):
#   1. Fresh install reaches a healthy server (/health 200) within 10 minutes
#   2. / (web UI) serves 200
#   3. Installed VERSION matches the repo's main VERSION
#   4. RESTART GATE: a server restart accepts connections within 15 seconds
#   5. With kept auth: Copilot shows authenticated in /health
#
# Usage:
#   .\test-windows.ps1
#   .\test-windows.ps1 -FreshAuth      # true first-user flow (interactive auth)
#   .\test-windows.ps1 -FullFactory    # also strip git/python/gh first
#   .\test-windows.ps1 -NoRollback     # report only, never touch the repo
#
# Exit code: 0 = GO, 1 = NO-GO

param(
    [switch]$FullFactory,
    [switch]$FreshAuth,
    [switch]$NoRollback,
    [switch]$NoBackup
)

$ErrorActionPreference = "Continue"
$INSTALL_URL = "https://kody-w.github.io/rapp-installer/install.ps1"
$RAW_VERSION_URL = "https://raw.githubusercontent.com/kody-w/rapp-installer/main/rapp_brainstem/VERSION"
$BRAINSTEM_HOME = "$env:USERPROFILE\.brainstem"
$TOKEN_STASH = "$env:USERPROFILE\.brainstem-token.stash"
$PORT = 7071
$HEALTH_URL = "http://localhost:$PORT/health"
$INSTALL_TIMEOUT = 600
$RESTART_BIND_LIMIT = 15
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG = "$env:USERPROFILE\brainstem-postflight-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$script:Pass = @()
$script:Fail = @()
function CheckPass($msg) { $script:Pass += $msg; Write-Host "  [OK] $msg" -ForegroundColor Green }
function CheckFail($msg) { $script:Fail += $msg; Write-Host "  [X] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "RAPP postflight — fresh-install test against: $INSTALL_URL" -ForegroundColor Cyan
Write-Host "   Log: $LOG"
Write-Host ""

# -- Step 1: strip --------------------------------------------------------------
$resetArgs = @{ Yes = $true }
if ($FreshAuth)   { $resetArgs.FreshAuth = $true }
if ($FullFactory) { $resetArgs.FullFactory = $true }
if ($NoBackup)    { $resetArgs.NoBackup = $true }
& "$SCRIPT_DIR\reset-windows.ps1" @resetArgs
if ($LASTEXITCODE -eq 1) { Write-Host "Reset failed — aborting"; exit 1 }

# -- Step 2: auth restore watcher -----------------------------------------------
$watcher = $null
if (Test-Path $TOKEN_STASH) {
    $watcher = Start-Job -ScriptBlock {
        param($home_, $stash)
        for ($i = 0; $i -lt 1200; $i++) {
            if (Test-Path "$home_\src\rapp_brainstem") {
                Copy-Item $stash "$home_\src\rapp_brainstem\.copilot_token" -Force
                return
            }
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $BRAINSTEM_HOME, $TOKEN_STASH
    Write-Host "  Auth watcher armed (token restores as soon as the clone lands)"
} else {
    Write-Host "  [!] No token stash — installer may require interactive device auth" -ForegroundColor Yellow
}

# -- Step 3: run the public installer -------------------------------------------
Write-Host ""
Write-Host "  Running the installer (output -> $LOG)..."
$T0 = Get-Date
$installJob = Start-Job -ScriptBlock {
    param($url, $log)
    try { Invoke-WebRequest -UseBasicParsing -Uri $url | Select-Object -ExpandProperty Content | Invoke-Expression *>> $log }
    catch { $_ | Out-File -Append $log }
} -ArgumentList $INSTALL_URL, $LOG

# -- Step 4: wait for health ------------------------------------------------------
$healthy = $false
while (((Get-Date) - $T0).TotalSeconds -lt $INSTALL_TIMEOUT) {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $HEALTH_URL -TimeoutSec 2 | Out-Null
        $healthy = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
$T_HEALTH = [int]((Get-Date) - $T0).TotalSeconds
if ($watcher) { Stop-Job $watcher -ErrorAction SilentlyContinue; Remove-Job $watcher -Force -ErrorAction SilentlyContinue }

Write-Host ""
if ($healthy) {
    CheckPass "Fresh install healthy in ${T_HEALTH}s (limit ${INSTALL_TIMEOUT}s)"
} else {
    CheckFail "Server never became healthy within ${INSTALL_TIMEOUT}s"
    if (Test-Path $LOG) { Get-Content $LOG -Tail 15 | ForEach-Object { Write-Host "    | $_" } }
}

if ($healthy) {
    # -- Check: web UI ------------------------------------------------------------
    try {
        $ui = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$PORT/" -TimeoutSec 5
        if ($ui.StatusCode -eq 200) { CheckPass "Web UI / serves 200" } else { CheckFail "Web UI / returned $($ui.StatusCode)" }
    } catch { CheckFail "Web UI / failed: $_" }

    # -- Check: version matches main ----------------------------------------------
    try {
        $remoteVer = (Invoke-WebRequest -UseBasicParsing -Uri $RAW_VERSION_URL -TimeoutSec 10).Content.Trim()
        $localVer = (Get-Content "$BRAINSTEM_HOME\src\rapp_brainstem\VERSION" -Raw).Trim()
        if ($localVer -eq $remoteVer) { CheckPass "Installed VERSION $localVer matches main" }
        else { CheckFail "VERSION mismatch: installed '$localVer' vs main '$remoteVer'" }
    } catch { CheckFail "Version check failed: $_" }

    # -- Check: Copilot auth --------------------------------------------------------
    if (Test-Path $TOKEN_STASH) {
        try {
            $health = Invoke-RestMethod -Uri $HEALTH_URL -TimeoutSec 5
            if ("$($health.copilot)" -match "u2713|✓") { CheckPass "Copilot authenticated (health reports OK)" }
            else { CheckFail "Copilot not authenticated (health reports '$($health.copilot)')" }
        } catch { CheckFail "Copilot auth check failed: $_" }
    }

    # -- Check: RESTART GATE (issue #14 regression) --------------------------------
    Write-Host "  Restart gate: killing server and timing a cold re-bind..."
    Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $venvPy = "$BRAINSTEM_HOME\venv\Scripts\python.exe"
    Start-Process -FilePath $venvPy -ArgumentList "brainstem.py" `
        -WorkingDirectory "$BRAINSTEM_HOME\src\rapp_brainstem" -WindowStyle Hidden `
        -RedirectStandardOutput "$LOG.restart.out" -RedirectStandardError "$LOG.restart.err"
    $R0 = Get-Date; $bound = $false
    while (((Get-Date) - $R0).TotalSeconds -le $RESTART_BIND_LIMIT) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $HEALTH_URL -TimeoutSec 1 | Out-Null
            $bound = $true; break
        } catch { Start-Sleep -Milliseconds 500 }
    }
    $T_BIND = [int]((Get-Date) - $R0).TotalSeconds
    if ($bound) { CheckPass "Restart accepts connections in ${T_BIND}s (limit ${RESTART_BIND_LIMIT}s)" }
    else { CheckFail "Restart did NOT accept connections within ${RESTART_BIND_LIMIT}s (issue #14 class)" }
}

# -- Verdict ------------------------------------------------------------------------
Write-Host ""
if ($script:Fail.Count -eq 0) {
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host " GO — $($script:Pass.Count)/$($script:Pass.Count) checks passed" -ForegroundColor Green
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host "  Server left running at http://localhost:$PORT"
    exit 0
}

Write-Host "===========================================" -ForegroundColor Red
Write-Host " NO-GO — $($script:Fail.Count) check(s) failed:" -ForegroundColor Red
$script:Fail | ForEach-Object { Write-Host "   X $_" -ForegroundColor Red }
Write-Host "===========================================" -ForegroundColor Red

if ($NoRollback) {
    Write-Host "  -NoRollback set: leaving the deploy in place. Full log: $LOG"
} else {
    Write-Host ""
    Write-Host "  Rolling the deploy back to the prior version..."
    & "$SCRIPT_DIR\rollback.ps1" -Yes
    if ($LASTEXITCODE -ne 0) { Write-Host "  Rollback failed — roll back manually (see rollback.ps1)" -ForegroundColor Red }
}
exit 1

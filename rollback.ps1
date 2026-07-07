# rollback.ps1 — roll kody-w/rapp-installer main back to the PRIOR version.
# Windows mirror of rollback.sh: finds the most recent commit on main whose
# rapp_brainstem/VERSION differs from HEAD, restores that full tree as a NEW
# commit (no history rewrite, no force-push), and pushes to main.
#
# Requires: git + gh (authenticated with push rights).

param([switch]$Yes)

$ErrorActionPreference = "Stop"
$REPO = "kody-w/rapp-installer"

function Fail($msg) { Write-Host "  [X] $msg" -ForegroundColor Red; exit 1 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "git not found — cannot roll back" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "gh not found — cannot roll back" }
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail "gh not authenticated — run 'gh auth login'" }

$work = Join-Path $env:TEMP "rapp-rollback-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Write-Host ""
    Write-Host "Rolling back $REPO main to the prior version" -ForegroundColor Cyan
    gh repo clone $REPO "$work\repo" -- --quiet
    Set-Location "$work\repo"

    $curVer = (Get-Content "rapp_brainstem\VERSION" -Raw).Trim()
    $target = $null; $prevVer = $null
    # Walk the FULL first-parent history (not just VERSION-touching commits):
    # the restore point is main as it stood immediately before the current
    # version landed. Path-filtering skipped inter-release commits and a
    # rollback once silently discarded PR #18's docs/install.ps1 (grail #24).
    # Skip prior "rollback:" commits too — their trees are synthetic snapshots.
    foreach ($c in (git rev-list --first-parent main)) {
        $subject = (git log -1 --format=%s $c | Out-String).Trim()
        if ($subject -like "rollback:*") { continue }
        $v = (git show "${c}:rapp_brainstem/VERSION" 2>$null | Out-String).Trim()
        if ($v -and $v -ne $curVer) { $target = $c; $prevVer = $v; break }
    }
    if (-not $target) { Fail "No prior version found on main (VERSION has always been $curVer)" }

    Write-Host "  Current release: v$curVer"
    Write-Host "  Rolling back to: v$prevVer ($($target.Substring(0,8)))"
    if (-not $Yes) {
        $answer = Read-Host "  Push this rollback to main? [y/N]"
        if ($answer -notin @("y", "Y")) { Fail "Aborted" }
    }

    git rm -rq . | Out-Null
    git checkout $target -- .
    git add -A
    git commit -q -m "rollback: v$curVer -> v$prevVer — post-deploy tests failed"
    if ($LASTEXITCODE -ne 0) { Fail "Nothing to commit — main may already match v$prevVer" }
    git push -q origin main
    if ($LASTEXITCODE -ne 0) { Fail "Push failed" }

    Write-Host "  [OK] main rolled back to v$prevVer" -ForegroundColor Green
    Write-Host "  [!] CDN note: the one-liner serves v$prevVer after cache expiry (5-10 min)." -ForegroundColor Yellow

    # Observability: a production rollback must never be discoverable only by
    # reading git history. File a grail issue automatically (best-effort).
    $stamp = Get-Date -Format "yyyy-MM-ddTHH:mmZ" -AsUTC
    $body = @"
Post-deploy tests failed on $env:COMPUTERNAME and main was automatically rolled back.

- **From:** v$curVer
- **To:** v$prevVer (restore target: $($target.Substring(0,8)))
- **Machine:** $env:COMPUTERNAME (Windows)

Next steps: check the postflight log on the machine that ran the gate, decide whether the deploy was actually bad or the harness misfired (see #24 for the false-positive history), and either fix-forward or reroll with a ``reroll:`` commit restoring the newer tree.
"@
    gh issue create -R $REPO --title "[AUTO-ROLLBACK] v$curVer -> v$prevVer ($stamp)" --body $body *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "  [OK] Rollback issue filed on $REPO" -ForegroundColor Green }
    else { Write-Host "  [!] Could not file the rollback issue — announce the rollback manually" -ForegroundColor Yellow }
} finally {
    Set-Location $env:TEMP
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

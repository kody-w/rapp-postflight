# rapp-postflight

Post-deploy tests for [rapp-installer](https://github.com/kody-w/rapp-installer).
This repo houses **only** these scripts — nothing else belongs here.

**The ritual: after every deploy to rapp-installer main, run the test script.
GO means the deploy is safe. NO-GO auto-rolls main back to the prior version.**

## Scripts

| Script | What it does |
|---|---|
| `test-mac.sh` / `test-windows.ps1` | The post-deploy gate: strip → fresh install from the public one-liner → verify → auto-rollback on failure |
| `reset-mac.sh` / `reset-windows.ps1` | Strip the global brainstem only (archive first, verify gone) |
| `rollback.sh` / `rollback.ps1` | Roll rapp-installer main back to the prior version (also callable manually) |

## Post-deploy usage

```bash
# macOS
./test-mac.sh
```

```powershell
# Windows
.\test-windows.ps1
```

Checks: fresh install healthy ≤ 10 min · web UI 200 · installed VERSION == main ·
**restart gate** (server re-bind ≤ 15 s — catches issue #14-class regressions) ·
Copilot auth intact.

## Flags

- `--fresh-auth` / `-FreshAuth` — discard the stashed Copilot token too (true first-user
  flow; the install will need interactive device auth, so not fully unattended)
- `--full-factory` / `-FullFactory` — ALSO uninstall git / python 3.11 / GitHub CLI
  (brew / winget) to simulate a factory-fresh machine. Requires typed confirmation.
  Note: rollback needs git+gh, so on a factory-stripped machine a failed test
  reports NO-GO but you roll back from another machine.
- `--no-rollback` / `-NoRollback` — report only; never touch the repo
- `--no-backup` / `-NoBackup` — skip archiving `~/.brainstem` before deleting it

## Safety properties

- `~/.brainstem` is archived to `~/brainstem-archives/` (venv excluded) before deletion,
  and the reset **verifies** the strip actually happened before reporting success.
- The Copilot token is stashed at `~/.brainstem-token.stash` and restored into the fresh
  install automatically, so the standard test runs fully unattended.
- Rollback never rewrites history: it restores the prior release's full tree as a new
  commit on main and pushes normally. CDN caches (github.io, raw.githubusercontent)
  take 5–10 minutes to serve the rolled-back version.

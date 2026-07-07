#!/usr/bin/env bash
# test-mac.sh — the post-deploy gate. Strips the global brainstem, runs the
# PUBLIC one-liner exactly as a first-time user would, and verifies the result.
# If any check fails, automatically rolls the rapp-installer repo back to the
# prior version (disable with --no-rollback).
#
# Checks:
#   1. Fresh install reaches a healthy server (/health 200) within 10 minutes
#   2. / (web UI) serves 200
#   3. Installed VERSION matches the repo's main VERSION
#   4. RESTART GATE: a server restart accepts connections within 15 seconds
#      (catches issue #14-class regressions: slow bind = dead browser tab)
#   5. With kept auth: Copilot shows authenticated in /health
#
# Usage:
#   ./test-mac.sh                   # standard post-deploy test (auth kept)
#   ./test-mac.sh --fresh-auth      # true first-user flow (interactive device auth)
#   ./test-mac.sh --full-factory    # also strip brew git/python3.11/gh first
#   ./test-mac.sh --no-rollback     # report only, never touch the repo
#
# Exit code: 0 = GO, 1 = NO-GO

set -uo pipefail

INSTALL_URL="https://kody-w.github.io/rapp-installer/install.sh"
RAW_VERSION_URL="https://raw.githubusercontent.com/kody-w/rapp-installer/main/rapp_brainstem/VERSION"
BRAINSTEM_HOME="$HOME/.brainstem"
TOKEN_STASH="$HOME/.brainstem-token.stash"
PORT=7071
HEALTH_URL="http://localhost:$PORT/health"
INSTALL_TIMEOUT=600
RESTART_BIND_LIMIT=15

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/brainstem-postflight-$(date +%Y%m%d-%H%M%S).log"

NO_ROLLBACK=false
RESET_FLAGS=(--yes)
for arg in "$@"; do
    case "$arg" in
        --no-rollback)  NO_ROLLBACK=true ;;
        --fresh-auth)   RESET_FLAGS+=(--fresh-auth) ;;
        --full-factory) RESET_FLAGS+=(--full-factory) ;;
        --no-backup)    RESET_FLAGS+=(--no-backup) ;;
        -h|--help)      grep '^#' "$0" | head -20; exit 0 ;;
        *) echo "Unknown flag: $arg (see --help)"; exit 2 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=(); FAIL=()
check_pass() { PASS+=("$1"); echo -e "  ${GREEN}✓${NC} $1"; }
check_fail() { FAIL+=("$1"); echo -e "  ${RED}✗${NC} $1"; }

echo ""
echo "🛫 RAPP postflight — fresh-install test against: $INSTALL_URL"
echo "   Log: $LOG"
echo ""

# ── Step 1: strip ─────────────────────────────────────────────────────────────
"$SCRIPT_DIR/reset-mac.sh" "${RESET_FLAGS[@]}" || { echo "Reset failed — aborting (nothing installed to test)"; exit 1; }

# ── Step 2: auth restore watcher ─────────────────────────────────────────────
# The installer clones ~/.brainstem/src minutes before its auth check runs.
# Drop the stashed token in as soon as the directory exists so the install
# stays fully unattended ("Already authenticated" path).
if [ -f "$TOKEN_STASH" ]; then
    (
        for _ in $(seq 1 1200); do
            if [ -d "$BRAINSTEM_HOME/src/rapp_brainstem" ]; then
                cp "$TOKEN_STASH" "$BRAINSTEM_HOME/src/rapp_brainstem/.copilot_token"
                exit 0
            fi
            sleep 0.5
        done
    ) &
    WATCHER_PID=$!
    echo "  Auth watcher armed (token restores as soon as the clone lands)"
else
    WATCHER_PID=""
    echo -e "  ${YELLOW}⚠${NC} No token stash — installer may require interactive device auth"
fi

# ── Step 3: run the public one-liner ─────────────────────────────────────────
echo ""
echo "  Running the one-liner (output → $LOG)..."
T0=$(date +%s)
# Download the installer to a file, then run it with stdin closed. Piping
# curl straight into `bash ... </dev/null` would override bash's stdin (the
# script pipe!) with /dev/null — bash reads an empty script and exits, and
# the install silently never happens.
INSTALLER_TMP=$(mktemp -t rapp-installer)
if ! curl -fsSL "$INSTALL_URL" -o "$INSTALLER_TMP"; then
    check_fail "Could not fetch the installer from $INSTALL_URL"
    echo -e "${RED} NO-GO — installer unreachable${NC}"
    exit 1
fi
bash "$INSTALLER_TMP" >"$LOG" 2>&1 </dev/null &
INSTALL_PID=$!

# ── Step 4: wait for health ───────────────────────────────────────────────────
HEALTHY=false
while [ $(( $(date +%s) - T0 )) -lt $INSTALL_TIMEOUT ]; do
    if curl -sf -o /dev/null --max-time 2 "$HEALTH_URL" 2>/dev/null; then
        HEALTHY=true
        break
    fi
    if ! kill -0 "$INSTALL_PID" 2>/dev/null && ! lsof -ti:"$PORT" >/dev/null 2>&1; then
        # installer exited without leaving a server behind
        sleep 3
        if ! lsof -ti:"$PORT" >/dev/null 2>&1; then break; fi
    fi
    sleep 2
done
T_HEALTH=$(( $(date +%s) - T0 ))
[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null

echo ""
if [ "$HEALTHY" = true ]; then
    check_pass "Fresh install healthy in ${T_HEALTH}s (limit ${INSTALL_TIMEOUT}s)"
else
    check_fail "Server never became healthy within ${INSTALL_TIMEOUT}s — tail of log:"
    tail -15 "$LOG" | sed 's/^/    | /'
fi

VENV_PY="$BRAINSTEM_HOME/venv/bin/python"

if [ "$HEALTHY" = true ]; then
    # ── Check: web UI ─────────────────────────────────────────────────────────
    ui_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:$PORT/")
    [ "$ui_code" = "200" ] && check_pass "Web UI / serves 200" || check_fail "Web UI / returned $ui_code"

    # ── Check: version matches main ──────────────────────────────────────────
    remote_ver=$(curl -fsSL --max-time 10 "$RAW_VERSION_URL" 2>/dev/null | tr -d '[:space:]')
    local_ver=$(tr -d '[:space:]' < "$BRAINSTEM_HOME/src/rapp_brainstem/VERSION" 2>/dev/null)
    if [ -n "$remote_ver" ] && [ "$local_ver" = "$remote_ver" ]; then
        check_pass "Installed VERSION $local_ver matches main"
    else
        check_fail "VERSION mismatch: installed '$local_ver' vs main '$remote_ver'"
    fi

    # ── Check: Copilot auth (only meaningful when auth was kept) ─────────────
    # Retry loop, NOT single-shot: a probe can time out while the server blocks
    # on its initial token exchange, and this check gates a production rollback.
    # A single flaky probe already rolled back a good deploy twice (grail #24).
    if [ -f "$TOKEN_STASH" ]; then
        copilot_state=""
        for _ in $(seq 1 6); do
            copilot_state=$("$VENV_PY" -c "
import json, urllib.request
h = json.load(urllib.request.urlopen('$HEALTH_URL', timeout=5))
print(h.get('copilot',''))" 2>/dev/null)
            [ "$copilot_state" = "✓" ] && break
            sleep 10
        done
        if [ "$copilot_state" = "✓" ]; then
            check_pass "Copilot authenticated (health reports ✓)"
        else
            check_fail "Copilot not authenticated after 6 probes over ~60s (last: '$copilot_state')"
        fi
    fi

    # ── Check: RESTART GATE (issue #14 regression) ────────────────────────────
    echo "  Restart gate: killing server and timing a cold re-bind..."
    lsof -ti:"$PORT" 2>/dev/null | xargs kill 2>/dev/null; sleep 1
    lsof -ti:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null; sleep 1
    (cd "$BRAINSTEM_HOME/src/rapp_brainstem" && nohup "$VENV_PY" brainstem.py >>"$LOG" 2>&1 &)
    R0=$(date +%s); BOUND=false
    while [ $(( $(date +%s) - R0 )) -le $RESTART_BIND_LIMIT ]; do
        if curl -sf -o /dev/null --max-time 1 "$HEALTH_URL" 2>/dev/null; then BOUND=true; break; fi
        sleep 0.5
    done
    T_BIND=$(( $(date +%s) - R0 ))
    if [ "$BOUND" = true ]; then
        check_pass "Restart accepts connections in ${T_BIND}s (limit ${RESTART_BIND_LIMIT}s)"
    else
        check_fail "Restart did NOT accept connections within ${RESTART_BIND_LIMIT}s (issue #14 class)"
    fi
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
if [ ${#FAIL[@]} -eq 0 ]; then
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN} GO — ${#PASS[@]}/${#PASS[@]} checks passed${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo "  Server left running at http://localhost:$PORT"

    # ── Golden gate (warn-only) ───────────────────────────────────────────────
    # After infrastructure goes GO, exercise actual chat behavior with the
    # rapp-bench goldens. WARN-ONLY by design: LLM output is nondeterministic
    # and the rollback trigger has a false-positive history (grail #24) — a
    # flaky golden must never roll back a healthy deploy.
    echo ""
    echo "  Golden gate (rapp-bench, warn-only)..."
    BENCH_DIR="$HOME/rapp-bench"
    if [ ! -d "$BENCH_DIR" ]; then
        gh repo clone kody-w/rapp-bench "$BENCH_DIR" -- --quiet 2>/dev/null || git clone -q https://github.com/kody-w/rapp-bench "$BENCH_DIR" 2>/dev/null || true
    else
        git -C "$BENCH_DIR" pull -q 2>/dev/null || true
    fi
    if [ -f "$BENCH_DIR/golden.py" ]; then
        if "$VENV_PY" "$BENCH_DIR/golden.py"; then
            echo -e "  ${GREEN}✓${NC} Goldens passed — chat behavior verified"
        else
            echo -e "  ${YELLOW}⚠${NC} GOLDEN WARNINGS — deploy stays (infra GO), but chat behavior regressed; investigate before demoing"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} rapp-bench unavailable — goldens skipped"
    fi
    exit 0
fi

echo -e "${RED}══════════════════════════════════════════${NC}"
echo -e "${RED} NO-GO — ${#FAIL[@]} check(s) failed:${NC}"
for f in "${FAIL[@]}"; do echo -e "${RED}   ✗ $f${NC}"; done
echo -e "${RED}══════════════════════════════════════════${NC}"

if [ "$NO_ROLLBACK" = true ]; then
    echo "  --no-rollback set: leaving the deploy in place. Full log: $LOG"
else
    echo ""
    echo "  Rolling the deploy back to the prior version..."
    "$SCRIPT_DIR/rollback.sh" --yes || echo -e "${RED}  Rollback failed — roll back manually (see rollback.sh)${NC}"
fi
exit 1

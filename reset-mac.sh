#!/usr/bin/env bash
# reset-mac.sh — completely strip the global RAPP brainstem from this machine
# so the public one-liner can be tested as a true fresh install.
#
# What it does, in order:
#   1. Kills the brainstem server (port 7071) and any brainstem.py processes
#   2. Stashes the Copilot auth token OUTSIDE ~/.brainstem (skip: --fresh-auth)
#   3. Archives ~/.brainstem to ~/brainstem-archives/ (skip: --no-backup)
#   4. Deletes ~/.brainstem and the ~/.local/bin/brainstem CLI
#   5. VERIFIES every removal actually happened
#   6. Optional --full-factory: also uninstalls git / python3.11 / GitHub CLI
#      (Homebrew only) to simulate a factory-fresh machine
#
# Usage:
#   ./reset-mac.sh                  # standard strip (auth stashed, backup kept)
#   ./reset-mac.sh --fresh-auth     # also discard the Copilot token
#   ./reset-mac.sh --no-backup      # skip the archive (faster, destructive)
#   ./reset-mac.sh --full-factory   # ALSO remove brew git/python3.11/gh
#   ./reset-mac.sh --yes            # no confirmation prompts

set -euo pipefail

BRAINSTEM_HOME="$HOME/.brainstem"
CLI_PATH="$HOME/.local/bin/brainstem"
ARCHIVE_DIR="$HOME/brainstem-archives"
TOKEN_STASH="$HOME/.brainstem-token.stash"
PORT=7071

FULL_FACTORY=false
ASSUME_YES=false
FRESH_AUTH=false
NO_BACKUP=false

for arg in "$@"; do
    case "$arg" in
        --full-factory) FULL_FACTORY=true ;;
        --yes)          ASSUME_YES=true ;;
        --fresh-auth)   FRESH_AUTH=true ;;
        --no-backup)    NO_BACKUP=true ;;
        -h|--help)      grep '^#' "$0" | head -22; exit 0 ;;
        *) echo "Unknown flag: $arg (see --help)"; exit 2 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
die()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }

echo ""
echo "🧹 RAPP brainstem reset"
echo ""

# ── 1. Kill running server ────────────────────────────────────────────────────
pids=$(lsof -ti:"$PORT" 2>/dev/null || true)
if [ -n "$pids" ]; then
    echo "$pids" | xargs kill 2>/dev/null || true
    sleep 1
    # escalate if still alive
    pids=$(lsof -ti:"$PORT" 2>/dev/null || true)
    [ -n "$pids" ] && echo "$pids" | xargs kill -9 2>/dev/null || true
    ok "Killed server on port $PORT"
else
    ok "No server on port $PORT"
fi
pkill -f "brainstem.py" 2>/dev/null && ok "Killed stray brainstem.py processes" || true

# ── 2. Stash auth token ───────────────────────────────────────────────────────
TOKEN_FILE="$BRAINSTEM_HOME/src/rapp_brainstem/.copilot_token"
if [ "$FRESH_AUTH" = true ]; then
    rm -f "$TOKEN_STASH"
    ok "Fresh-auth mode: token stash cleared (next install will device-auth)"
elif [ -f "$TOKEN_FILE" ]; then
    cp "$TOKEN_FILE" "$TOKEN_STASH"
    chmod 600 "$TOKEN_STASH"
    ok "Copilot token stashed to $TOKEN_STASH"
elif [ -f "$TOKEN_STASH" ]; then
    ok "Using existing token stash at $TOKEN_STASH"
else
    warn "No Copilot token found to stash — next install will device-auth"
fi

# ── 3. Archive ────────────────────────────────────────────────────────────────
if [ -d "$BRAINSTEM_HOME" ]; then
    if [ "$NO_BACKUP" = true ]; then
        warn "Skipping backup (--no-backup)"
    else
        mkdir -p "$ARCHIVE_DIR"
        stamp=$(date +%Y%m%d-%H%M%S)
        archive="$ARCHIVE_DIR/brainstem-$stamp.tar.gz"
        echo "  Archiving ~/.brainstem (excluding venv, __pycache__)..."
        tar czf "$archive" \
            --exclude='.brainstem/venv' \
            --exclude='__pycache__' \
            -C "$HOME" .brainstem
        [ -s "$archive" ] || die "Archive is empty — aborting before delete"
        ok "Archived to $archive ($(du -h "$archive" | cut -f1))"
    fi
else
    ok "~/.brainstem does not exist (already clean)"
fi

# ── 4. Delete ─────────────────────────────────────────────────────────────────
rm -rf "$BRAINSTEM_HOME"
rm -f "$CLI_PATH"

# ── 5. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "  Verifying strip..."
[ ! -e "$BRAINSTEM_HOME" ] && ok "~/.brainstem gone" || die "~/.brainstem still exists"
[ ! -e "$CLI_PATH" ] && ok "brainstem CLI gone" || die "CLI still at $CLI_PATH"
if lsof -ti:"$PORT" >/dev/null 2>&1; then die "Something still listening on :$PORT"; else ok "Port $PORT silent"; fi

# ── 6. Optional full factory ──────────────────────────────────────────────────
if [ "$FULL_FACTORY" = true ]; then
    echo ""
    echo -e "  ${RED}FULL FACTORY MODE${NC} — this uninstalls Homebrew git, python@3.11,"
    echo "  and gh from this machine. Other tools you use depend on these."
    echo "  (Apple's Xcode CLT git, if present, cannot be removed this way.)"
    if [ "$ASSUME_YES" != true ]; then
        printf "  Type 'factory' to proceed: "
        read -r answer
        [ "$answer" = "factory" ] || die "Aborted full-factory removal"
    fi
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew not found — cannot deliver a factory strip; rerun without --full-factory"
    fi
    for pkg in gh python@3.11 git; do
        if brew list "$pkg" >/dev/null 2>&1; then
            brew uninstall --quiet "$pkg" && ok "Uninstalled $pkg" || warn "Could not uninstall $pkg"
        else
            ok "$pkg not installed via brew"
        fi
    done
    hash -r
    # VERIFY the strip (issue #28): factory mode must not report success while
    # the bootstrap paths it exists to prove are still bypassed. gh is a hard
    # requirement (brew-owned, must be gone). python3.11 likewise when it came
    # from brew. git is a PARTIAL verdict: Apple's Xcode CLT git cannot be
    # removed this way, and the installer is allowed to adopt it.
    if command -v gh >/dev/null 2>&1; then
        die "FACTORY STRIP INCOMPLETE: gh still resolves ($(command -v gh)) — remove it manually, then rerun"
    fi
    ok "gh gone from PATH"
    if command -v python3.11 >/dev/null 2>&1; then
        case "$(command -v python3.11)" in
            /opt/homebrew/*|/usr/local/*) die "FACTORY STRIP INCOMPLETE: brew python3.11 still resolves ($(command -v python3.11))" ;;
            *) warn "PARTIAL FACTORY: non-brew python3.11 present ($(command -v python3.11)) — installer will adopt it instead of proving install-from-zero" ;;
        esac
    else
        ok "python3.11 gone from PATH — install-from-zero path will be exercised"
    fi
    command -v git >/dev/null 2>&1 && warn "PARTIAL FACTORY: git still on PATH ($(command -v git), likely Xcode CLT — not removable via brew)" || ok "git gone from PATH"
fi

echo ""
ok "Reset complete — machine is ready for a fresh-install test"
echo "   Run the installer:  curl -fsSL https://kody-w.github.io/rapp-installer/install.sh | bash"
echo "   Or the full test:   ./test-mac.sh"
echo ""

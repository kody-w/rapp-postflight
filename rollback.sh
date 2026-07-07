#!/usr/bin/env bash
# rollback.sh — roll kody-w/rapp-installer main back to the PRIOR version.
#
# "Prior version" = the most recent commit on main whose rapp_brainstem/VERSION
# content differs from HEAD's. The entire tree is restored to that snapshot in
# a single new commit (history is never rewritten, nothing is force-pushed),
# so fresh installs immediately get the last-known-good release.
#
# Called automatically by test-mac.sh / test-windows.ps1 on a NO-GO verdict.
# Safe to run manually: it shows the plan and asks before pushing (--yes skips).
#
# Requires: git + gh (authenticated with push rights to kody-w/rapp-installer).

set -euo pipefail

REPO="kody-w/rapp-installer"
ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
die() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

command -v git >/dev/null 2>&1 || die "git not found — cannot roll back (was --full-factory used? reinstall git first)"
command -v gh  >/dev/null 2>&1 || die "gh not found — cannot roll back (reinstall GitHub CLI and 'gh auth login')"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run 'gh auth login'"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "⏪ Rolling back $REPO main to the prior version"
gh repo clone "$REPO" "$WORK/repo" -- --quiet
cd "$WORK/repo"

cur_ver=$(tr -d '[:space:]' < rapp_brainstem/VERSION)
target=""
prev_ver=""
# Walk the FULL first-parent history (not just VERSION-touching commits): the
# restore point is main as it stood immediately before the current version
# landed. Filtering by the VERSION path skipped inter-release commits and a
# rollback once silently discarded PR #18's docs/install.ps1 (grail #24).
# Skip prior "rollback:" commits too — their trees are synthetic snapshots
# (possibly themselves missing inter-release work), not real main-line states.
for c in $(git rev-list --first-parent main); do
    case "$(git log -1 --format=%s "$c")" in rollback:*) continue ;; esac
    v=$(git show "$c:rapp_brainstem/VERSION" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$v" ] && [ "$v" != "$cur_ver" ]; then
        target="$c"
        prev_ver="$v"
        break
    fi
done
[ -n "$target" ] || die "No prior version found on main (VERSION has always been $cur_ver)"

echo "  Current release: v$cur_ver ($(git rev-parse --short HEAD))"
echo "  Rolling back to: v$prev_ver ($(git rev-parse --short "$target"))"
if [ "$ASSUME_YES" != true ]; then
    printf "  Push this rollback to main? [y/N] "
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "Aborted"
fi

# Restore the full tree of the target commit as a NEW commit on main.
git rm -rq . >/dev/null
git checkout "$target" -- .
git add -A
git commit -q -m "rollback: v$cur_ver -> v$prev_ver — post-deploy tests failed" || die "Nothing to commit — main may already match v$prev_ver"
git push -q origin main

echo -e "  ${GREEN}✓${NC} main rolled back to v$prev_ver ($(git rev-parse --short HEAD))"
echo -e "  ${YELLOW}⚠${NC} CDN note: kody-w.github.io + raw.githubusercontent cache for 5-10 min;"
echo "     the one-liner serves v$prev_ver after the cache expires. Verify with:"
echo "     curl -fsSL https://raw.githubusercontent.com/$REPO/main/rapp_brainstem/VERSION"

# Observability: a production rollback must never be discoverable only by
# reading git history. File a grail issue automatically (best-effort — an
# issue failure must not fail the rollback itself).
gh issue create -R "$REPO" \
    --title "⏪ AUTO-ROLLBACK: v$cur_ver -> v$prev_ver ($(date -u +%Y-%m-%dT%H:%MZ))" \
    --body "$(printf 'Post-deploy tests failed on %s and main was automatically rolled back.\n\n- **From:** v%s\n- **To:** v%s (restore target: %s)\n- **Machine:** %s (%s)\n\nNext steps: check the postflight log on the machine that ran the gate, decide whether the deploy was actually bad or the harness misfired (see #24 for the false-positive history), and either fix-forward or reroll with a `reroll:` commit restoring the newer tree.' "$(hostname)" "$cur_ver" "$prev_ver" "$(git rev-parse --short "$target")" "$(hostname)" "$(uname -s)")" \
    >/dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} Rollback issue filed on $REPO" \
    || echo -e "  ${YELLOW}⚠${NC} Could not file the rollback issue — announce the rollback manually"
echo ""

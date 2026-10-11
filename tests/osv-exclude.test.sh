#!/usr/bin/env bash
# osv-exclude.test.sh — osv-daily's directory exclusions really reach osv-scanner.
#
# Covers:
#   - a broad scan (here: a whole home folder) skips package caches and tool
#     homes at any depth (~/.bun, a repo's .claude/worktrees) and home-only
#     trees (~/go), so they never come back as red "projects"
#   - a `go/` folder INSIDE a repo is project code and is still scanned
#   - a target that itself lives under an excluded name (a worktree in
#     .claude/worktrees) is still scanned — exclusions are anchored per target
#   - a target given through a symlinked path is anchored correctly too
#
# Why this exists: osv-scanner 2.6.0 silently ignores the documented bare
# dirname form of --experimental-exclude, so the old list excluded nothing.
#
# Needs the real osv-scanner and network access (OSV API); the vulnerable
# fixture is PyYAML==5.3 in a requirements.txt. Runs inside an isolated HOME
# with every HIVEGUARD_* override set (never touches the real ~/.hiveguard or
# the launchd label).
#
# Usage: bash tests/osv-exclude.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

check() {  # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (expected: %s | got: %s)\n' "$1" "$2" "$3"
    FAILED=1
  fi
}

command -v osv-scanner >/dev/null || { echo "FAIL osv-scanner not installed"; exit 1; }

# Canonical temp root (see osv-coverage.test.sh), plus its raw /var spelling for
# the symlinked-target case.
RAW="$(mktemp -d)"
T="$(cd "$RAW" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"
export HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json"
export HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_SCHED_PLIST="$T/no-such.plist"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"   # no Finder xattr/python calls
TAB="$(printf '\t')"

vuln() { mkdir -p "$1"; printf 'PyYAML==5.3\n' > "$1/requirements.txt"; }
mkdir -p "$HOME/proj/app/.git" "$HOME/proj/mono/.git" "$HOME/proj/app/.claude/worktrees/wt"
printf 'gitdir: x\n' > "$HOME/proj/app/.claude/worktrees/wt/.git"
vuln "$HOME/proj/app"
vuln "$HOME/proj/app/.claude/worktrees/wt"
vuln "$HOME/proj/mono/go"
vuln "$HOME/.bun/install/cache/pkg"
vuln "$HOME/go/pkg/mod/example"

marked() { grep -c "^$1${TAB}active$TAB" "$HIVEGUARD_MARKERS" 2>/dev/null; }

# --- 1. a whole-home scan ----------------------------------------------------
"$REPO/bin/osv-daily" "$HOME" >/dev/null 2>&1
check "home scan: the real project is marked" "1" "$(marked "$HOME/proj/app")"
check "home scan: a go/ folder inside a repo is still scanned" "1" "$(marked "$HOME/proj/mono")"
check "home scan: ~/.bun cache is skipped" "0" \
  "$(grep -c "$HOME/.bun" "$HIVEGUARD_MARKERS")"
check "home scan: ~/go is skipped" "0" "$(grep -c "$HOME/go/" "$HIVEGUARD_MARKERS")"
check "home scan: a repo's .claude/worktrees is skipped" "0" \
  "$(grep -c '/.claude/' "$HIVEGUARD_MARKERS")"

# --- 2. a target that lives under an excluded name ---------------------------
: > "$HIVEGUARD_MARKERS"
"$REPO/bin/osv-daily" --probe "$HOME/proj/app/.claude/worktrees/wt" >/dev/null 2>&1
check "worktree target under .claude/ is still scanned" "1" \
  "$(marked "$HOME/proj/app/.claude/worktrees/wt")"

# --- 3. a target given through a symlinked path ------------------------------
: > "$HIVEGUARD_MARKERS"
# A clean repo whose only "finding" sits in a nested .bun cache: it would be
# marked red (the finding's nearest .git) unless the cache is excluded.
mkdir -p "$HOME/proj/clean/.git"
vuln "$HOME/proj/clean/tools/.bun/cache/pkg"
"$REPO/bin/osv-daily" "$RAW/home/proj" >/dev/null 2>&1
check "symlinked target: the project is marked" "1" "$(marked "$HOME/proj/app")"
check "symlinked target: a repo with only a nested .bun stays clean" "0" \
  "$(marked "$HOME/proj/clean")"

if [ "$FAILED" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "all osv-exclude checks passed"

#!/usr/bin/env bash
# strict-integration.test.sh — the whole strict-mode story, end to end.
#
# Unlike the per-tool tests this one wires the real pieces together: the real
# `hiveguard` dispatcher, the real `osv-daily` (real osv-scanner + network), the
# real zsh hook sourced by a real `zsh -f`, the real `strict-mode` CLI and the
# real `doctor`. Nothing is stubbed except `npm` itself — a script on PATH that
# prints `REAL npm …`, so "did the command actually run?" is observable.
#
# The ten steps:
#   1  a daily scan flags the vulnerable project red and records coverage
#   2  strict on → the flagged project refuses `npm`, exit 77
#   3  a pause releases that one project → the command runs again
#   4  resume → refused again
#   5  ack + re-scan → the marker flips to `acked` → the command runs
#   6  ack --remove + re-scan → `active` again → refused
#   7  an UNKNOWN project runs the command and scans itself in the background
#      (real detached probe, polled for up to 120 s); the next attempt is
#      refused, and the daily report/baseline are untouched by the probe
#   8  strict off → the command runs again everywhere
#   9  doctor reports strict mode and --quiet still prints one word
#   10 with strict off in a pristine HOME nothing is defined for `npm` and no
#      strict state file is ever created
#
# Needs the real osv-scanner and network access (OSV API); the vulnerable
# fixture is PyYAML==5.3 in a requirements.txt (CLAUDE.md's proven fixture).
# Takes a couple of minutes: four real scans plus one background probe.
#
# SAFETY: everything runs under an isolated HOME with every HIVEGUARD_*
# override set, so the real ~/.hiveguard, the real ~/.zshrc and the real launchd
# label com.hiveguard.osv-daily are never touched. HIVEGUARD_SCHED_PLIST points
# at a file that does not exist, so `_bgscan` always chooses `probe` and
# `osv-daily` never falls back to the real scheduled folders. `doctor` is only
# ever run WITHOUT --fix.
#
# Usage: bash tests/strict-integration.test.sh
set -uo pipefail          # deliberately not -e: a failed check must not abort

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HG="$REPO/bin/hiveguard"
export HG_HOOK="$REPO/bin/hiveguard-hook.zsh"   # read by the zsh steps below
TAB="$(printf '\t')"

FAILED=0
STEP=0
ok()  { printf 'ok   %s  %s\n' "$STEP" "$1"; }
bad() { printf 'FAIL %s  %s\n' "$STEP" "$1"; FAILED=1; }
check() {  # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1
       expected: [$2]
       got:      [$3]"; fi
}
contains() {  # desc needle haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1
       expected to contain: [$2]
       got:                 [$3]" ;;
  esac
}
lacks() {  # desc needle haystack
  case "$3" in
    *"$2"*) bad "$1
       must NOT contain: [$2]
       got:              [$3]" ;;
    *) ok "$1" ;;
  esac
}

command -v osv-scanner >/dev/null || { echo "FAIL osv-scanner not installed"; exit 1; }
command -v jq          >/dev/null || { echo "FAIL jq not installed"; exit 1; }

# --- isolated scaffold -------------------------------------------------------
# mktemp -d hands back /var/folders/…, a symlink to /private/var/folders/…; the
# zsh gate resolves ${PWD:A} and osv-daily realpath's its targets, so
# canonicalise the temp root once or no marker/coverage row ever matches.
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"
export HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv"
export HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json"
export HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_SCHED_PLIST="$T/no-such.plist"   # never the real launchd plist
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"    # no Finder xattr/python calls

REPORT="$HOME/.hiveguard/osv-projects.html"
PROBE_REPORT="$HOME/.hiveguard/osv-probe.html"
STRICT_LOG="$HOME/.hiveguard/strict.log"
ERR="$T/stderr"

mkdir -p "$T/stubs" "$T/proj/app/.git" "$T/proj/app/sub" "$T/elsewhere/x/.git"
printf '#!/bin/sh\necho "REAL npm $*"\n' > "$T/stubs/npm"; chmod +x "$T/stubs/npm"
printf 'PyYAML==5.3\n' > "$T/proj/app/requirements.txt"

# One shell step: a fresh `zsh -f` (no rc files) that sources the real hook,
# cds into a directory and runs `npm test`. stdout comes back from the function
# (the stub's line, the chpwd reminder and `rc=<n>`); stderr lands in $ERR.
npm_try() {  # $1 = directory
  HG_DIR="$1" PATH="$T/stubs:$PATH" zsh -f -c '
    source "$HG_HOOK"
    cd "$HG_DIR" || { print "rc=cd-failed"; exit 9 }
    npm test
    print rc=$?
  ' 2>"$ERR"
}
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -n1; }

# --- 1. a daily scan flags the project and records coverage ------------------
STEP=1
"$HG" daily "$T/proj" >/dev/null 2>&1 </dev/null
check "hiveguard daily exits 0" "0" "$?"
check "the vulnerable project is marked active" "1" \
  "$(grep -c "^$T/proj/app${TAB}active$TAB" "$HIVEGUARD_MARKERS")"
check "the scanned folder gets a coverage row" "1" \
  "$(grep -c "^$T/proj$TAB" "$HIVEGUARD_COVERAGE")"

# --- 2. strict on → the red project refuses the command ----------------------
STEP=2
"$HG" strict on >/dev/null
out="$(npm_try "$T/proj/app")"
check "a red project refuses npm with 77" "77" "$(rc_of "$out")"
lacks "the command never reached the binary" "REAL npm" "$out"
# The refusal quotes the marker row's summary verbatim — whatever the live OSV
# data makes it, so read it back rather than hardcoding a vulnerability count.
summary="$(awk -F'\t' -v r="$T/proj/app" '$1==r && $2=="active" { print $3 }' "$HIVEGUARD_MARKERS")"
contains "the refusal reuses the marker summary and names the root" \
  "$summary in $T/proj/app" "$(head -n1 "$ERR")"
contains "the refusal names the command in backticks" \
  '— refusing to run `npm`.' "$(head -n1 "$ERR")"
contains "the refusal points at the report" "hiveguard daily --open" "$(cat "$ERR")"
contains "the refusal offers the pause" "hiveguard strict pause" "$(cat "$ERR")"

# --- 3. a pause releases that one project ------------------------------------
STEP=3
"$HG" strict pause --for 30m "$T/proj/app" >/dev/null
out="$(npm_try "$T/proj/app")"
check "a paused project runs again" "0" "$(rc_of "$out")"
contains "the real command ran" "REAL npm test" "$out"

# --- 4. resume re-blocks it ---------------------------------------------------
STEP=4
"$HG" strict resume "$T/proj/app" >/dev/null
out="$(npm_try "$T/proj/app")"
check "resume re-blocks the project" "77" "$(rc_of "$out")"
lacks "the command never reached the binary" "REAL npm" "$out"

# --- 5. ack + re-scan → acked → allowed --------------------------------------
STEP=5
"$HG" ack "$T/proj/app/requirements.txt" >/dev/null 2>&1
check "hiveguard ack exits 0" "0" "$?"
"$HG" daily "$T/proj" >/dev/null 2>&1 </dev/null
check "the marker flips to acked" "1" \
  "$(grep -c "^$T/proj/app${TAB}acked$TAB" "$HIVEGUARD_MARKERS")"
out="$(npm_try "$T/proj/app")"
check "an acknowledged project runs" "0" "$(rc_of "$out")"
contains "the real command ran" "REAL npm test" "$out"

# --- 6. un-acking brings the block back --------------------------------------
STEP=6
"$HG" ack --remove "$T/proj/app/requirements.txt" >/dev/null 2>&1
check "hiveguard ack --remove exits 0" "0" "$?"
"$HG" daily "$T/proj" >/dev/null 2>&1 </dev/null
check "the marker is active again" "1" \
  "$(grep -c "^$T/proj/app${TAB}active$TAB" "$HIVEGUARD_MARKERS")"
out="$(npm_try "$T/proj/app")"
check "the project is refused again" "77" "$(rc_of "$out")"

# --- 7. an unknown project: runs now, scans itself, blocks next time ---------
# $T/elsewhere/x has no marker row and no coverage row covering it, so the gate
# takes rule 4: run the command AND detach one background scan. With no
# schedule plist that scan is a `--probe`, which must leave the daily report and
# the osv-last-scan.json baseline alone.
STEP=7
printf 'PyYAML==5.3\n' > "$T/elsewhere/x/requirements.txt"
rep_m1="$(stat -f %m "$REPORT")"; rep_h1="$(md5 -q "$REPORT")"
st_h1="$(md5 -q "$HIVEGUARD_STATE")"
rm -f "$HIVEGUARD_STRICT_ATTEMPTS" "$STRICT_LOG"

out="$(npm_try "$T/elsewhere/x")"
check "an unknown project runs the command" "0" "$(rc_of "$out")"
contains "the real command ran" "REAL npm test" "$out"
check "the background scan is debounce-recorded for the .git root" "$T/elsewhere/x" \
  "$(cut -f1 "$HIVEGUARD_STRICT_ATTEMPTS" 2>/dev/null | tail -n1)"
check "exactly one attempt row" "1" \
  "$(wc -l < "$HIVEGUARD_STRICT_ATTEMPTS" 2>/dev/null | tr -d ' ')"

# macOS has no GNU time-limit command, so poll: up to 120 s, one second at a
# time, and FAIL if the detached probe has not landed by then.
waited=0; landed=0
while [ "$waited" -lt 120 ]; do
  if grep -q "^$T/elsewhere/x${TAB}active$TAB" "$HIVEGUARD_MARKERS" 2>/dev/null &&
     grep -q 'bgscan .* → probe rc=' "$STRICT_LOG" 2>/dev/null; then
    landed=1; break
  fi
  sleep 1; waited=$((waited + 1))
done
check "the detached background probe lands within 120 s (waited ${waited}s)" "1" "$landed"
check "the probe logs its mode and exit code" "1" \
  "$(grep -c "bgscan $T/elsewhere/x → probe rc=0" "$STRICT_LOG" 2>/dev/null)"
check "the probe writes its own report" "yes" \
  "$([ -s "$PROBE_REPORT" ] && echo yes || echo no)"
check "the probe leaves the daily report's mtime alone" "$rep_m1" "$(stat -f %m "$REPORT")"
check "the probe leaves the daily report's content alone" "$rep_h1" "$(md5 -q "$REPORT")"
check "the probe leaves the diff baseline alone" "$st_h1" "$(md5 -q "$HIVEGUARD_STATE")"
check "the earlier project's marker row survives the probe" "1" \
  "$(grep -c "^$T/proj/app${TAB}active$TAB" "$HIVEGUARD_MARKERS")"

out="$(npm_try "$T/elsewhere/x")"
check "the next attempt in the now-flagged project is refused" "77" "$(rc_of "$out")"
lacks "the command never reached the binary" "REAL npm" "$out"

# --- 8. strict off → everything runs again -----------------------------------
STEP=8
"$HG" strict off >/dev/null
out="$(npm_try "$T/proj/app")"
check "a red project runs once strict is off" "0" "$(rc_of "$out")"
contains "the real command ran" "REAL npm test" "$out"
check "status says off" "Strict mode: off  (enable: hiveguard strict on)" \
  "$("$HG" strict status | head -n1)"

# --- 9. doctor (never --fix) -------------------------------------------------
STEP=9
dout="$("$HG" doctor 2>&1)"; drc=$?
case "$drc" in
  0|1) ok "doctor exits 0 or 1 (got $drc)" ;;
  *)   bad "doctor exits 0 or 1 (got $drc)
       output: [$dout]" ;;
esac
contains "doctor reports on strict mode" "strict mode:" "$dout"
q="$("$HG" doctor --quiet 2>/dev/null)"
check "doctor --quiet prints exactly one word" "1" "$(printf '%s' "$q" | wc -w | tr -d ' ')"

# --- 10. with strict off, the hook is an absolute no-op ----------------------
# A pristine HOME with no config key at all, and NONE of the HIVEGUARD_* state
# overrides, so every default path resolves inside that HOME. (The config lives
# outside .hiveguard only so the directory listing below shows nothing but what
# osv-daily itself wrote; HIVEGUARD_SCHED_PLIST stays pointed at the file that
# does not exist so the real launchd plist is still out of reach.)
STEP=10
H2="$T/home2"; mkdir -p "$H2"
printf 'mark_finder=0\n' > "$T/fresh-config"
fresh_env() {
  env -u HIVEGUARD_MARKERS -u HIVEGUARD_PAUSES -u HIVEGUARD_COVERAGE \
      -u HIVEGUARD_STRICT_ATTEMPTS -u HIVEGUARD_STATE -u HIVEGUARD_ACKS \
      HOME="$H2" HIVEGUARD_CONFIG="$T/fresh-config" \
      HIVEGUARD_SCHED_PLIST="$T/no-such.plist" PATH="$T/stubs:$PATH" "$@"
}
check "sourcing the hook defines nothing for npm" "0" \
  "$(fresh_env zsh -f -c 'source "$HG_HOOK"; print ${+functions[npm]}')"
check "sourcing the hook defines nothing for the other intercepted names" "0 0 0" \
  "$(fresh_env zsh -f -c 'source "$HG_HOOK"; print ${+functions[pip]} ${+functions[cargo]} ${+functions[make]}')"
check "sourcing the hook creates nothing under ~/.hiveguard" "" \
  "$(ls -A "$H2/.hiveguard" 2>/dev/null)"

fresh_env "$HG" daily "$T/proj" >/dev/null 2>&1 </dev/null
unexpected=""
for f in $(ls -A "$H2/.hiveguard" 2>/dev/null); do
  case "$f" in
    osv-projects.html|osv-daily.log|osv-last-scan.json|osv-markers.tsv|osv-coverage.tsv|osv-acks.json) ;;
    *) unexpected="$unexpected $f" ;;
  esac
done
check "only osv-daily's own files appear under ~/.hiveguard" "" "$unexpected"
for f in strict-pauses.tsv strict-attempts.tsv strict.log osv-probe.html; do
  check "strict mode never created $f" "absent" \
    "$([ -e "$H2/.hiveguard/$f" ] && echo present || echo absent)"
done

# --- isolation ---------------------------------------------------------------
STEP=0
check "no launchd agent touched in the test HOME" "0" \
  "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard)"
check "the test never wrote a ~/.zshrc" "absent" \
  "$([ -e "$HOME/.zshrc" ] && echo present || echo absent)"

if [ "$FAILED" = 0 ]; then
  echo "all strict-integration checks passed"
else
  echo "strict-integration: FAILURES above"
fi
exit "$FAILED"

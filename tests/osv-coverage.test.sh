#!/usr/bin/env bash
# osv-coverage.test.sh — osv-daily's scan-coverage file and --probe mode.
#
# Covers:
#   - a normal scan upserts one `folder<TAB>epoch` row per scanned folder
#   - a re-scan of the same folder upserts (never appends) and refreshes the epoch
#   - a scanner failure (no package sources) records NO coverage row
#   - --probe <path> writes its own report, leaves the daily report and the
#     osv-last-scan.json baseline untouched, marks the probed root itself
#     (root == target IS marked under --probe), preserves unrelated marker rows,
#     adds its own coverage row and logs a `probe ` line
#   - --probe usage errors exit 2
#
# Needs the real osv-scanner and network access (OSV API); the vulnerable fixture
# is PyYAML==5.3 in a requirements.txt. Runs entirely inside an isolated HOME
# with every HIVEGUARD_* override set, so it never touches the real ~/.hiveguard
# and never goes near the launchd label (HIVEGUARD_SCHED_PLIST points at a file
# that does not exist, so the scheduled-folder fallback stays out of the way).
#
# Usage: bash tests/osv-coverage.test.sh
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

# --- isolated environment ---------------------------------------------------
# mktemp -d lives under /var/folders, a symlink to /private/var/folders; osv-daily
# realpath's its targets, so canonicalise the temp root once or every comparison
# against a coverage/marker row fails.
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"
export HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json"
export HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_SCHED_PLIST="$T/no-such.plist"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"   # no Finder xattr/python calls

REPORT="$HOME/.hiveguard/osv-projects.html"
PROBE_REPORT="$HOME/.hiveguard/osv-probe.html"
TAB="$(printf '\t')"

mkdir -p "$T/proj/app/.git" "$T/proj/app/sub" "$T/elsewhere/x/.git" "$T/empty"
printf 'PyYAML==5.3\n' > "$T/proj/app/requirements.txt"
printf 'PyYAML==5.3\n' > "$T/elsewhere/x/requirements.txt"

# --- 1. a normal scan ------------------------------------------------------
"$REPO/bin/osv-daily" "$T/proj" >/dev/null 2>&1; rc=$?
check "normal scan exits 0" "0" "$rc"
check "coverage has exactly one row" "1" "$(wc -l < "$HIVEGUARD_COVERAGE" | tr -d ' ')"
check "coverage row names the scanned folder" "1" \
  "$(grep -c "^$T/proj$TAB" "$HIVEGUARD_COVERAGE")"
check "coverage epoch is fresh" "fresh" \
  "$(awk -F'\t' -v now="$(date +%s)" -v r="$T/proj" \
      '$1==r && now-$2>=0 && now-$2<300 { print "fresh" }' "$HIVEGUARD_COVERAGE")"
check "the vulnerable project is marked active" "1" \
  "$(grep -c "^$T/proj/app${TAB}active$TAB" "$HIVEGUARD_MARKERS")"
check "daily report written" "yes" "$([ -s "$REPORT" ] && echo yes || echo no)"
check "state file written" "yes" "$([ -s "$HIVEGUARD_STATE" ] && echo yes || echo no)"

# --- 2. re-scanning the same folder upserts, never appends -------------------
cov_before="$(awk -F'\t' -v r="$T/proj" '$1==r { print $2 }' "$HIVEGUARD_COVERAGE")"
sleep 1
"$REPO/bin/osv-daily" --rescan "$T/proj" >/dev/null 2>&1
check "re-scan keeps one coverage row" "1" "$(wc -l < "$HIVEGUARD_COVERAGE" | tr -d ' ')"
cov_after="$(awk -F'\t' -v r="$T/proj" '$1==r { print $2 }' "$HIVEGUARD_COVERAGE")"
check "re-scan refreshes the epoch" "newer" \
  "$([ "$cov_after" -gt "$cov_before" ] 2>/dev/null && echo newer || echo "$cov_after")"

# --- 3. --probe leaves the daily artifacts alone ----------------------------
rep_m1="$(stat -f %m "$REPORT")"; rep_h1="$(md5 -q "$REPORT")"
st_h1="$(md5 -q "$HIVEGUARD_STATE")"
sleep 1
"$REPO/bin/osv-daily" --probe "$T/elsewhere/x" >/dev/null 2>&1; rc=$?
check "probe exits 0" "0" "$rc"
check "probe report written" "yes" "$([ -s "$PROBE_REPORT" ] && echo yes || echo no)"
check "daily report mtime untouched" "$rep_m1" "$(stat -f %m "$REPORT")"
check "daily report content untouched" "$rep_h1" "$(md5 -q "$REPORT")"
check "state baseline untouched" "$st_h1" "$(md5 -q "$HIVEGUARD_STATE")"
check "probed root is itself marked active" "1" \
  "$(grep -c "^$T/elsewhere/x${TAB}active$TAB" "$HIVEGUARD_MARKERS")"
check "marker row outside the probe target preserved" "1" \
  "$(grep -c "^$T/proj/app${TAB}active$TAB" "$HIVEGUARD_MARKERS")"
check "probe adds its own coverage row" "2" "$(wc -l < "$HIVEGUARD_COVERAGE" | tr -d ' ')"
check "probe coverage row names the probed root" "1" \
  "$(grep -c "^$T/elsewhere/x$TAB" "$HIVEGUARD_COVERAGE")"
check "probe logs a 'probe ' line" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '^\[.*\] probe ')"
check "probe log line points at the probe report" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c "$PROBE_REPORT\$")"

# --- 4. --probe usage errors ------------------------------------------------
"$REPO/bin/osv-daily" --probe "$T/proj" "$T/elsewhere" >/dev/null 2>&1
check "--probe with two paths exits 2" "2" "$?"
"$REPO/bin/osv-daily" --probe "$T/proj" --open >/dev/null 2>&1
check "--probe with --open exits 2" "2" "$?"
"$REPO/bin/osv-daily" --probe --rescan "$T/proj" >/dev/null 2>&1
check "--probe --rescan exits 2" "2" "$?"   # --rescan is consumed as the path, then a stray positional
"$REPO/bin/osv-daily" --probe >/dev/null 2>&1
check "--probe with no path exits 2" "2" "$?"

# --- 5. a scanner failure never records coverage ----------------------------
# An empty directory has no manifests: osv-scanner 2.6.0 prints "No package
# sources found" and exits 128 with empty stdout, so SCAN_OK stays 0. osv-daily
# itself still exits 0 and still writes its "0 results" report (unchanged
# behaviour) — only the coverage row must be withheld.
rm -f "$HIVEGUARD_COVERAGE"
"$REPO/bin/osv-daily" "$T/empty" >/dev/null 2>&1; rc=$?
check "scan of a folder with no manifests still exits 0" "0" "$rc"
check "no coverage row on a scanner failure" "absent" \
  "$([ -e "$HIVEGUARD_COVERAGE" ] && echo "present: $(cat "$HIVEGUARD_COVERAGE")" || echo absent)"

# --- 6. help ----------------------------------------------------------------
check "--help documents --probe" "yes" \
  "$("$REPO/bin/osv-daily" --help | grep -q -- '--probe' && echo yes || echo no)"
check "--help documents the coverage file" "yes" \
  "$("$REPO/bin/osv-daily" --help | grep -q 'osv-coverage.tsv' && echo yes || echo no)"

# --- 7. nothing leaked outside the isolated HOME ----------------------------
check "no launchd agent touched" "0" \
  "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard)"

if [ "$FAILED" = 0 ]; then
  echo "all osv-coverage checks passed"
else
  echo "osv-coverage: FAILURES above"
fi
exit "$FAILED"

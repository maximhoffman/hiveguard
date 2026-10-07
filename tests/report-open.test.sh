#!/usr/bin/env bash
# report-open.test.sh — osv-daily's report anchors and `--open [--at <anchor>]`.
#
# Covers:
#   - every project card and package row in the report gets a stable DOM id
#     (p-<h12(src)>, f-<h12(src\0pkg)>) matching osv-run.json's anchors
#   - the report embeds a hashchange/load script that jumps to an anchor
#   - `--open` (no anchor) opens the plain report and stamps osv-report-opened
#   - `--open --at <anchor>` opens `file://$REPORT#<anchor>` via osascript,
#     falling back to plain `open` when osascript fails — either way the
#     opened stamp is written
#   - `--at` without `--open`, and an invalid anchor, both exit 2
#
# Fully offline: osv-scanner, osascript and open are stubs on
# HIVEGUARD_TOOL_PATH. Runs under an isolated HOME with every HIVEGUARD_*
# override set, so the real ~/.hiveguard and com.hiveguard.osv-daily are
# never touched.
#
# Usage: bash tests/report-open.test.sh
set -uo pipefail          # deliberately not -e: a failed check must not abort

HG="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
check() {  # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (expected: %s | got: %s)\n' "$1" "$2" "$3"
    FAILED=1
  fi
}

command -v jq >/dev/null || { echo "FAIL jq not installed"; exit 1; }

# --- isolated scaffold (plan section 2.4, copied) ----------------------------
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard" "$T/stubs" "$T/proj/app/.git"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"           HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv" HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json" HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_RUN="$HOME/.hiveguard/osv-run.json"         HIVEGUARD_SCAN_PID="$HOME/.hiveguard/osv-daily.pid"
export HIVEGUARD_REPORT_OPENED="$HOME/.hiveguard/osv-report-opened" HIVEGUARD_APP_PID="$HOME/.hiveguard/menubar.pid"
export HIVEGUARD_SCHED_PLIST="$T/sched.plist"
export HIVEGUARD_TOOL_PATH="$T/stubs"
export HIVEGUARD_BIN="$HG/bin/hiveguard"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
REPORT="$HOME/.hiveguard/osv-projects.html"; SRC="$T/proj/app/package-lock.json"; : > "$SRC"

cat > "$T/stubs/osv-scanner" <<'EOF'
#!/bin/sh
# STUB_JSON=file to emit, STUB_RC=exit (default 1), STUB_SLEEP=seconds, STUB_FAIL=1 → stderr only, exit 128
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
echo "Scanned $PWD/x and found 2 packages" >&2
if [ "${STUB_FAIL:-0}" = 1 ]; then echo "no package sources found" >&2; echo "fatal: giving up" >&2; exit 128; fi
cat "$STUB_JSON"; exit "${STUB_RC:-1}"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_NOTIFY"\n' > "$T/stubs/terminal-notifier"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_OSASCRIPT"; exit "${STUB_OSASCRIPT_RC:-0}"\n' > "$T/stubs/osascript"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_OPEN"\n' > "$T/stubs/open"
printf '#!/bin/sh\nexit "${STUB_LAUNCHCTL_RC:-0}"\n' > "$T/stubs/launchctl"
chmod +x "$T"/stubs/*
export T_LOG_NOTIFY="$T/notify.log" T_LOG_OSASCRIPT="$T/osascript.log" T_LOG_OPEN="$T/open.log"

mk_fixture() {  # $1=out file, $2=extra fast-uri id ("" for none)
  extra=""; extra_ids=""
  [ -n "$2" ] && { extra=",{\"id\":\"$2\",\"affected\":[]}"; extra_ids=",\"$2\""; }
  cat > "$1" <<EOF
{"results":[{"source":{"path":"$SRC","type":"lockfile"},"packages":[
 {"package":{"name":"fast-uri","version":"3.0.1","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-AAAA-0001","affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"3.0.6"}]}]}]},{"id":"GHSA-AAAA-0002","affected":[]}$extra],
  "groups":[{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"$extra_ids],"max_severity":"7.5"}]},
 {"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-BBBB-0001","affected":[{"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}],
  "groups":[{"ids":["GHSA-BBBB-0001"],"max_severity":"9.1"}]}]}]}
EOF
}
mk_fixture "$T/run1.json" ""; mk_fixture "$T/run2.json" "GHSA-AAAA-0003"

cat > "$HIVEGUARD_SCHED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.hiveguard.osv-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HG/bin/hiveguard</string>
    <string>daily</string>
    <string>$T/proj</string>
    <string>--if-due</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
EOF

h12() { printf '%s' "$1" | shasum | cut -c1-12; }
h12pkg() { printf '%s\0%s' "$1" "$2" | shasum | cut -c1-12; }
scan() { STUB_JSON="$1" "$HG/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }

# --- 1. report anchors --------------------------------------------------------
scan "$T/run1.json"   # baseline, so run2 below has a "new" entry to check anchors on
scan "$T/run2.json"
check "project card has the p- anchor" "1" \
  "$(grep -c "id=\"p-$(h12 "$SRC")\"" "$REPORT")"
check "fast-uri row has the f- anchor" "1" \
  "$(grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT")"
check "lodash row has the f- anchor" "1" \
  "$(grep -c "id=\"f-$(h12pkg "$SRC" lodash)\"" "$REPORT")"
check "report embeds the hashchange script" "yes" \
  "$(grep -q 'hashchange' "$REPORT" && echo yes || echo no)"

# --- 2. osv-run.json anchors match the report's --------------------------------
check "run file's new-entry anchor matches the report's f- id" \
  "f-$(h12pkg "$SRC" fast-uri)" "$(jq -r '.new[0].anchor' "$HIVEGUARD_RUN" 2>/dev/null)"
check "run file's new-entry project anchor matches the report's p- id" \
  "p-$(h12 "$SRC")" "$(jq -r '.new[0].project_anchor' "$HIVEGUARD_RUN" 2>/dev/null)"

# --- 3. --open (no anchor): opens the plain report, stamps opened -----------
rm -f "$T_LOG_OPEN" "$T_LOG_OSASCRIPT" "$HIVEGUARD_REPORT_OPENED"
"$HG/bin/osv-daily" --open >/dev/null 2>&1; rc=$?
check "--open exits 0" "0" "$rc"
check "--open calls plain open on the report" "$REPORT" "$(cat "$T_LOG_OPEN" 2>/dev/null)"
check "--open never calls osascript" "absent" \
  "$([ -e "$T_LOG_OSASCRIPT" ] && echo present || echo absent)"
stamp_fresh="no"
[ -s "$HIVEGUARD_REPORT_OPENED" ] && [ "$(( $(date +%s) - $(cat "$HIVEGUARD_REPORT_OPENED") ))" -lt 5 ] && stamp_fresh="yes"
check "--open stamps osv-report-opened" "yes" "$stamp_fresh"

# --- 4. --open --at <anchor>: osascript with the exact fragment URL ---------
A="f-$(h12pkg "$SRC" fast-uri)"
rm -f "$T_LOG_OPEN" "$T_LOG_OSASCRIPT" "$HIVEGUARD_REPORT_OPENED"
"$HG/bin/osv-daily" --open --at "$A" >/dev/null 2>&1; rc=$?
check "--open --at exits 0" "0" "$rc"
check "--open --at calls osascript with file://report#anchor" "1" \
  "$(grep -c "open location \"file://$REPORT#$A\"" "$T_LOG_OSASCRIPT" 2>/dev/null)"
check "--open --at never falls back to plain open (osascript succeeded)" "absent" \
  "$([ -e "$T_LOG_OPEN" ] && echo present || echo absent)"
stamp_fresh="no"
[ -s "$HIVEGUARD_REPORT_OPENED" ] && [ "$(( $(date +%s) - $(cat "$HIVEGUARD_REPORT_OPENED") ))" -lt 5 ] && stamp_fresh="yes"
check "--open --at stamps osv-report-opened too" "yes" "$stamp_fresh"

# --- 5. --open --at falls back to plain open when osascript fails ------------
rm -f "$T_LOG_OPEN" "$T_LOG_OSASCRIPT"
STUB_OSASCRIPT_RC=1 "$HG/bin/osv-daily" --open --at "$A" >/dev/null 2>&1
check "osascript failure falls back to plain open" "$REPORT" "$(cat "$T_LOG_OPEN" 2>/dev/null)"

# --- 6. argument validation ---------------------------------------------------
"$HG/bin/osv-daily" --at "$A" >/dev/null 2>&1
check "--at without --open exits 2" "2" "$?"
"$HG/bin/osv-daily" --open --at 'x-1' >/dev/null 2>&1
check "invalid anchor exits 2" "2" "$?"
"$HG/bin/osv-daily" --open --at 'p-tooshort' >/dev/null 2>&1
check "anchor with wrong hex length exits 2" "2" "$?"

# --- 7. help -------------------------------------------------------------------
check "--help documents --at" "yes" \
  "$("$HG/bin/osv-daily" --help | grep -q -- '--at' && echo yes || echo no)"

# --- 8. nothing leaked outside the isolated HOME ------------------------------
check "no launchd agent touched" "0" "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard)"

if [ "$FAILED" = 0 ]; then echo "all report-open checks passed"; else echo "report-open: FAILURES above"; fi
exit "$FAILED"

#!/usr/bin/env bash
# osv-run.test.sh — osv-daily's run outcome file, scan pid file and failed-scan path.
#
# Covers:
#   - every non-probe scan writes osv-run.json (ok, rc, error, counts, roots,
#     new, unseen, started/finished epochs) atomically
#   - `new` lists this run's new advisory ids per package, with anchors
#   - `unseen` carries over a never-opened finding across scans, is reset once
#     the report was opened after the previous run, and drops ids that vanished
#   - the scan pid file exists (and is live) while the scanner runs and is gone
#     afterwards
#   - a scanner failure writes ok:false + the error tail, keeps the report, the
#     diff baseline and the markers, logs a FAILED line and still exits 0
#   - --probe and an early --if-due exit never write osv-run.json
#
# Fully offline: osv-scanner is a stub on HIVEGUARD_TOOL_PATH that replays a
# JSON fixture. Runs under an isolated HOME with every HIVEGUARD_* override set,
# so the real ~/.hiveguard and the launchd label com.hiveguard.osv-daily are
# never touched.
#
# Usage: bash tests/osv-run.test.sh
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
J() { jq -r "$@" "$HIVEGUARD_RUN" 2>/dev/null | paste -sd' ' -; }

# --- 1. first scan: ok, no baseline → nothing new ---------------------------
scan "$T/run1.json"; check "first scan exits 0" "0" "$?"
check "run file: ok rc error new unseen active new_vulns" "true 1 null 0 0 3 0" \
  "$(J '.ok, .rc, .error, (.new|length), (.unseen|length), .counts.active.vulns, .counts.new_vulns')"
check "run file: schema 1, stamp and target set" "1 yes $T/proj" \
  "$(J '.schema, (if (.stamp|length) > 0 then "yes" else "no" end), .target')"
check "run file: roots aggregate for the project root" "active 3 1 0" \
  "$(jq -r --arg r "$T/proj/app" '.roots[$r] | "\(.status) \(.active_vulns) \(.crit_pkgs) \(.acked_vulns)"' "$HIVEGUARD_RUN" 2>/dev/null)"
check "run file: counts identical to the state file's" "same" \
  "$([ "$(jq -cS .counts "$HIVEGUARD_RUN" 2>/dev/null)" = "$(jq -cS .counts "$HIVEGUARD_STATE")" ] && echo same || echo differ)"
check "run file: exactly the documented keys" "counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen" \
  "$(jq -r 'keys|join(",")' "$HIVEGUARD_RUN" 2>/dev/null)"
check "no leftover .tmp next to the run file" "absent" \
  "$([ -e "$HIVEGUARD_RUN.tmp" ] && echo present || echo absent)"
check "scan pid file removed after the run" "absent" \
  "$([ -e "$HIVEGUARD_SCAN_PID" ] && echo present || echo absent)"

# --- 2. second scan: one new advisory → new + unseen ------------------------
scan "$T/run2.json"; check "second scan exits 0" "0" "$?"
check "new entry: new_vulns, count, pkg, ids, sev, fix, root" "1 1 fast-uri GHSA-AAAA-0003 7.5 3.0.6 $T/proj/app" \
  "$(J '.counts.new_vulns, (.new|length), .new[0].pkg, (.new[0].ids|join(",")), .new[0].sev, .new[0].fix, .new[0].root')"
check "new entry: src, version, eco" "$SRC 3.0.1 npm" "$(J '.new[0].src, .new[0].version, .new[0].eco')"
check "new entry: package anchor" "f-$(h12pkg "$SRC" fast-uri)" "$(J '.new[0].anchor')"
check "new entry: project anchor" "p-$(h12 "$SRC")" "$(J '.new[0].project_anchor')"
check "unseen = this run's new" "1 GHSA-AAAA-0003" "$(J '(.unseen|length), (.unseen[0].ids|join(","))')"

# --- 3. carry-over while the report was never opened ------------------------
scan "$T/run2.json"
check "unseen carried over (never opened)" "0 1 GHSA-AAAA-0003" \
  "$(J '.counts.new_vulns, (.unseen|length), (.unseen[0].ids|join(","))')"
check "carried entry keeps its anchors" "f-$(h12pkg "$SRC" fast-uri) p-$(h12 "$SRC")" \
  "$(J '.unseen[0].anchor, .unseen[0].project_anchor')"

# --- 4. report opened after the previous run → carry-over reset -------------
sleep 1; date +%s > "$HIVEGUARD_REPORT_OPENED"; sleep 1; scan "$T/run2.json"
check "unseen reset once the report was opened" "0" "$(J '.unseen|length')"

# --- 5. a carried id that disappeared is dropped ----------------------------
rm -f "$HIVEGUARD_REPORT_OPENED"
scan "$T/run1.json"; scan "$T/run2.json"
check "unseen before the id disappears" "1" "$(J '.unseen|length')"
scan "$T/run1.json"
check "unseen drops an id no longer present" "0" "$(J '.unseen|length')"
check "epochs: finished >= started, fresh" "epochs-ok" \
  "$(J 'if (.finished_epoch >= .started_epoch) and ((now|floor) - .finished_epoch) < 120 then "epochs-ok" else "bad" end')"

# --- 6. the pid file names a live osv-daily while the scanner runs ----------
STUB_SLEEP=3 STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null &
bg=$!
sleep 1
live="no"
[ -s "$HIVEGUARD_SCAN_PID" ] && kill -0 "$(cat "$HIVEGUARD_SCAN_PID")" 2>/dev/null && live="yes"
check "scan pid file is live during the scan" "yes" "$live"
check "scan pid file names the osv-daily process" "$bg" "$(cat "$HIVEGUARD_SCAN_PID" 2>/dev/null)"
wait "$bg"
check "scan pid file removed after a background scan" "absent" \
  "$([ -e "$HIVEGUARD_SCAN_PID" ] && echo present || echo absent)"

# --- 7. a foreign pid file is left alone by an early exit -------------------
printf '12345' > "$HIVEGUARD_SCAN_PID"
"$HG/bin/osv-daily" --if-due "$T/proj" >/dev/null 2>&1 </dev/null   # report is today → exits early
check "early --if-due exit leaves the pid file alone" "12345" "$(cat "$HIVEGUARD_SCAN_PID" 2>/dev/null)"
rm -f "$HIVEGUARD_SCAN_PID"

# --- 8. scanner failure: ok:false, state kept, FAILED logged, exit 0 --------
scan "$T/run2.json"
R1="$(md5 -q "$REPORT")"; S1="$(md5 -q "$HIVEGUARD_STATE")"; M1="$(md5 -q "$HIVEGUARD_MARKERS")"
rm -f "$T_LOG_NOTIFY"
out="$(STUB_FAIL=1 STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" "$T/proj" 2>/dev/null </dev/null)"; rc=$?
check "failed scan exits 0" "0" "$rc"
check "failed run: ok rc error-lines counts new unseen" "false 128 2 null 0 1" \
  "$(J '.ok, .rc, (.error|split("\n")|length), .counts, (.new|length), (.unseen|length)')"
check "failed run: roots null, unseen carried unchanged" "null GHSA-AAAA-0003" \
  "$(J '.roots, (.unseen[0].ids|join(","))')"
check "failed run: error has no progress lines" "0" \
  "$(jq -r '.error' "$HIVEGUARD_RUN" | grep -c '^Scanned')"
check "failed run: error text" "no package sources found|fatal: giving up" \
  "$(jq -r '.error' "$HIVEGUARD_RUN" | paste -sd'|' -)"
check "failed run: report, state, markers kept" "kept" \
  "$([ "$R1" = "$(md5 -q "$REPORT")" ] && [ "$S1" = "$(md5 -q "$HIVEGUARD_STATE")" ] && [ "$M1" = "$(md5 -q "$HIVEGUARD_MARKERS")" ] && echo kept || echo changed)"
check "failed run: FAILED line logged" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c 'FAILED rc=128 (no package sources found)$')"
check "failed run: prints the ✖ line" "✖ scan failed (rc=128) — previous report and state kept" "$out"
check "failed run: no notification" "absent" "$([ -e "$T_LOG_NOTIFY" ] && echo present || echo absent)"
check "failed run: pid file removed" "absent" \
  "$([ -e "$HIVEGUARD_SCAN_PID" ] && echo present || echo absent)"

# failure with no previous run file → unseen [] and error null when stderr is only progress
rm -f "$HIVEGUARD_RUN"
printf '#!/bin/sh\necho "Scanned x and found 0 packages" >&2\nexit 127\n' > "$T/stubs/osv-scanner.quiet"
chmod +x "$T/stubs/osv-scanner.quiet"
mv "$T/stubs/osv-scanner" "$T/stubs/osv-scanner.real"; mv "$T/stubs/osv-scanner.quiet" "$T/stubs/osv-scanner"
scan "$T/run1.json"
check "silent failure: ok rc error unseen" "false 127 null 0" "$(J '.ok, .rc, .error, (.unseen|length)')"
check "silent failure: log says no output" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c 'FAILED rc=127 (no output)$')"
mv "$T/stubs/osv-scanner.real" "$T/stubs/osv-scanner"

# --- 9. probe and early --if-due never write the run file --------------------
rm -f "$HIVEGUARD_RUN"
STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null
check "probe writes no run file" "absent" "$([ -e "$HIVEGUARD_RUN" ] && echo present || echo absent)"
check "probe writes no pid file" "absent" "$([ -e "$HIVEGUARD_SCAN_PID" ] && echo present || echo absent)"
STUB_FAIL=1 STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null
check "failed probe writes no run file" "absent" "$([ -e "$HIVEGUARD_RUN" ] && echo present || echo absent)"
scan "$T/run1.json"; rm -f "$HIVEGUARD_RUN"
STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --if-due "$T/proj" >/dev/null 2>&1 </dev/null
check "early --if-due writes no run file" "absent" "$([ -e "$HIVEGUARD_RUN" ] && echo present || echo absent)"

# --- 10. help + isolation ----------------------------------------------------
check "--help documents osv-run.json" "yes" \
  "$("$HG/bin/osv-daily" --help | grep -q 'osv-run.json' && echo yes || echo no)"
check "no launchd agent touched" "0" "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard)"

if [ "$FAILED" = 0 ]; then echo "all osv-run checks passed"; else echo "osv-run: FAILURES above"; fi
exit "$FAILED"

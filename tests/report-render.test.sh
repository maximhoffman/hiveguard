#!/usr/bin/env bash
# report-render.test.sh — `osv-daily --render`: the daily report rebuilt from the
# last scan's saved results (osv-last-scan.json `render` block) and the current
# acknowledgements, with no scan.
#
# Covers:
#   - a render right after a scan is byte-identical to that scan's report (stamp
#     included), keeps the report's modification time, never touches the scan
#     state (state, run file, coverage, opened stamp, scan pid), never notifies,
#     leaves no .tmp file and logs one `render` line
#   - the state file's `render` block: schema, scan targets, the per-package
#     records (ids, per-id severity, max severity, fix, root, new ids)
#   - a package ack, a whole-project ack and --clear: the report and the folder
#     markers follow, identical (stamp normalised) to a scan with that ack store
#   - the app / strict gates are evaluated at render time
#   - per-id severity: a partial package ack re-rates the remaining fragment
#   - an open-ended ack is cover-all and is never backfilled by a render
#   - refusals (scan in progress → 4, no render block / unknown block / no
#     state → 3, flag combinations → 2), recreation of a deleted report with the
#     state's mtime, the probe report untouched, timing, --help
#   - the scan path stays byte-identical to the 9e5df56 renderer (links off and
#     on) and the run file's key list is unchanged
#
# Fully offline: osv-scanner is a stub on HIVEGUARD_TOOL_PATH that replays a
# JSON fixture. Runs under an isolated HOME with every HIVEGUARD_* override set,
# so the real ~/.hiveguard and the launchd label com.hiveguard.osv-daily are
# never touched. "App running" is simulated by writing this shell's pid to
# HIVEGUARD_APP_PID. Section I extracts the 9e5df56 renderer with `git archive`
# from this checkout (read only).
#
# Usage: bash tests/report-render.test.sh
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

# --- isolated scaffold (plan section 2.5 = links plan 2.5 + helpers) ---------
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

links_on()  { printf '%s' "$$" > "$HIVEGUARD_APP_PID"; }      # "app running" at report time
links_off() { rm -f "$HIVEGUARD_APP_PID"; }
strict_on() { printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"; }
strict_off(){ printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"; }
reset_scan(){ rm -f "$HIVEGUARD_STATE" "$HIVEGUARD_RUN" "$HIVEGUARD_MARKERS" "$HIVEGUARD_COVERAGE" "$HIVEGUARD_ACKS" "$HIVEGUARD_PAUSES" "$HIVEGUARD_REPORT_OPENED"; }
enc()   { jq -rn --arg s "$1" '$s|@uri'; }                     # = python quote(safe="") for these paths (no "~")
count() { grep -o -- "$1" "${2:-$REPORT}" | wc -l | tr -d ' '; }  # rows are on one line: never grep -c

render()   { "$HG/bin/osv-daily" --render >/dev/null 2>&1 </dev/null; }          # rc = osv-daily's
mtime()    { stat -f %m "$1"; }
norm()     { sed 's/osv-daily · [^<]*/STAMP/' "$1"; }                            # stamp-normalised report (cross-scan diffs only)
scan_sig() { md5 -q "$HIVEGUARD_STATE"; md5 -q "$HIVEGUARD_RUN"; md5 -q "$HIVEGUARD_COVERAGE"
             [ -e "$HIVEGUARD_REPORT_OPENED" ] && echo opened || echo no-opened
             [ -e "$HIVEGUARD_SCAN_PID" ] && echo pid || echo no-pid; }            # the scan-only state, as one string
mk_fixture_split() {  # $1=out: run1, but fast-uri's two ids in SEPARATE groups (9.3 / 5.0) — per-id severity
  cat > "$1" <<EOF
{"results":[{"source":{"path":"$SRC","type":"lockfile"},"packages":[
 {"package":{"name":"fast-uri","version":"3.0.1","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-AAAA-0001","affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"3.0.6"}]}]}]},{"id":"GHSA-AAAA-0002","affected":[]}],
  "groups":[{"ids":["GHSA-AAAA-0001"],"max_severity":"9.3"},{"ids":["GHSA-AAAA-0002"],"max_severity":"5.0"}]},
 {"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-BBBB-0001","affected":[{"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}],
  "groups":[{"ids":["GHSA-BBBB-0001"],"max_severity":"9.1"}]}]}]}
EOF
}
mk_fixture_split "$T/split.json"
TAB="$(printf '\t')"

# --- A. render right after a scan: byte-identical (stamp included), mtime kept, scan state untouched ---
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/run1.json"; scan "$T/run2.json"
cp "$REPORT" "$T/scan.html"; S0="$(scan_sig)"; rm -f "$T_LOG_NOTIFY"; touch -t 202601010000 "$REPORT"
render; check "A: render rc" "0" "$?"
cmp -s "$T/scan.html" "$REPORT"; check "A: byte-identical to the scan's report (stamp included)" "0" "$?"
check "A: report mtime kept" "202601010000" "$(date -r "$(mtime "$REPORT")" '+%Y%m%d%H%M')"
check "A: scan state untouched" "$S0" "$(scan_sig)"
check "A: no .tmp left" "0" "$(ls "$HOME/.hiveguard" | grep -c '\.tmp$')"
check "A: no notification" "silent" "$([ -e "$T_LOG_NOTIFY" ] && echo notified || echo silent)"
check "A: one render log line" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '^\[[^]]*\] render projects=1 pkgs=2 vulns=4 crit=1 new=1 (acked: vulns=0 pkgs=0) markers=R1,Y0 → ')"
STAMP_S="$(jq -r '.stamp' "$HIVEGUARD_STATE")"
check "A: done line" "✅ report refreshed (scan of $STAMP_S): 4 active vulnerabilities across 1 projects (0 acknowledged) → $REPORT" \
  "$("$HG/bin/osv-daily" --render </dev/null | tail -n1)"

# --- B. the render block ---
check "B: state keys" "counts,findings,render,schema,stamp,target" "$(jq -r 'keys|join(",")' "$HIVEGUARD_STATE")"
check "B: render block shape" "1 $T/proj 2 eco,fix,id_sev,ids,maxsev,new_ids,pkg,root,src,version" \
  "$(jq -r '.render.schema, (.render.scan_targets|join(",")), (.render.packages|length), (.render.packages[0]|keys|join(","))' "$HIVEGUARD_STATE" | paste -sd' ' -)"
check "B: fast-uri record" "fast-uri 3.0.1 npm 3.0.6 7.5 GHSA-AAAA-0001,GHSA-AAAA-0002,GHSA-AAAA-0003 GHSA-AAAA-0003 7.5 $T/proj/app" \
  "$(jq -r '.render.packages[0] | .pkg, .version, .eco, .fix, .maxsev, (.ids|join(",")), (.new_ids|join(",")), .id_sev["GHSA-AAAA-0003"], .root' "$HIVEGUARD_STATE" | paste -sd' ' -)"
check "B: lodash record" "lodash 9.1 0 $SRC" \
  "$(jq -r '.render.packages[1] | .pkg, .maxsev, (.new_ids|length), .src' "$HIVEGUARD_STATE" | paste -sd' ' -)"
check "B: findings unchanged" "{\"$SRC\":{\"fast-uri\":[\"GHSA-AAAA-0001\",\"GHSA-AAAA-0002\",\"GHSA-AAAA-0003\"],\"lodash\":[\"GHSA-BBBB-0001\"]}}" \
  "$(jq -c '.findings' "$HIVEGUARD_STATE")"

# --- C. a package ack: the row moves; same bytes as a scan with that store ---
check "C: ack scopes from findings" "✔ muted package: fast-uri  (in $SRC) — 3 known advisories acknowledged; NEW future advisories will still alert." \
  "$("$HG/bin/hiveguard" ack "$SRC" fast-uri </dev/null | head -n1)"
render; check "C: render rc" "0" "$?"
check "C: mute / unmute / unmute all / mutedbadge / NEW" "1 1 1 0 0" \
  "$(count '>mute</button>') $(count '>unmute</button>') $(count '>unmute all</button>') $(count 'class="mutedbadge"') $(count 'NEW +')"
check "C: tiles" "1 1 1" \
  "$(count '<div class="n">1</div><div class="l">projects affected</div>') $(count '<div class="n">1</div><div class="l">vulnerabilities · +3 muted</div>') $(count '<div class="n">0</div><div class="l">new since last scan</div>')"
check "C: -k project card, plain acked fast-uri row" "1 1" \
  "$(grep -c "id=\"p-$(h12 "$SRC")-k\"" "$REPORT") $(grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT")"
check "C: markers" "$T/proj/app${TAB}active${TAB}1 active vulnerabilities (1 critical)" "$(cat "$HIVEGUARD_MARKERS")"
check "C: scan state untouched" "$S0" "$(scan_sig)"
cp "$REPORT" "$T/render-ack.html"; scan "$T/run1.json"; scan "$T/run2.json"
diff <(norm "$T/render-ack.html") <(norm "$REPORT") >/dev/null; check "C: same as a scan with that store" "0" "$?"

# --- D. whole project, then clear: markers follow, strict stops blocking ---
"$HG/bin/hiveguard" ack "$SRC" >/dev/null </dev/null; render
check "D: clean / no copySel / unmute all / whole project" "1 0 1 1" \
  "$(count '✅ No active vulnerabilities — everything found is acknowledged.') $(count 'id="copySel"') $(count '>unmute all</button>') $(count 'whole project')"
check "D: markers acked" "$T/proj/app${TAB}acked${TAB}4 acknowledged" "$(cat "$HIVEGUARD_MARKERS")"
check "D: status --json not blocked, no active ids" "[0,0]" \
  "$("$HG/bin/hiveguard" status --json | jq -c '[(.strict.blocked|length), .active_ids]')"
"$HG/bin/hiveguard" ack --clear >/dev/null </dev/null; render
diff <(norm "$T/scan.html") <(norm "$REPORT") >/dev/null; check "D: --clear → back to the scan report" "0" "$?"
check "D: --clear → markers back" "$T/proj/app${TAB}active${TAB}4 active vulnerabilities (1 critical)" "$(cat "$HIVEGUARD_MARKERS")"

# --- E. the gates apply at render time ---
links_on; render; check "E: links on render rc" "0" "$?"
check "E: act-link / cp-alt / pause" "3 3 0" "$(count 'class="act-link') $(count 'class="cp cp-alt"') $(count 'hiveguard://pause')"
cp "$REPORT" "$T/render-on.html"; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
diff <(norm "$T/render-on.html") <(norm "$REPORT") >/dev/null; check "E: same as a scan with the app" "0" "$?"
strict_on; render
check "E: strict on → pause links / act-links" "2 5" "$(count 'hiveguard://pause') $(count 'class="act-link')"
links_off; strict_off; render
check "E: app off → no links" "0" "$(count 'hiveguard://')"
diff <(norm "$T/scan.html") <(norm "$REPORT") >/dev/null; check "E: app off → the plain report" "0" "$?"

# --- F. per-id severity: a partial package ack re-rates the active fragment ---
reset_scan; scan "$T/split.json"; scan "$T/split.json"
check "F: CRIT 9.3 (card head + row) / markers 2 critical" "2 1" \
  "$(count 'CRIT 9.3') $(count '(2 critical)' "$HIVEGUARD_MARKERS")"
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":["GHSA-AAAA-0001"],"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"; A0="$(md5 -q "$HIVEGUARD_ACKS")"
render
check "F: MED 5.0 / mutedbadge / re-ack / critical tile" "1 1 1 1" \
  "$(count 'MED 5.0') $(count 'class="mutedbadge"') $(count '>re-ack</button>') $(count '<div class="n">1</div><div class="l">critical</div>')"
check "F: acked twin CRIT 9.3 (card head + row)" "2" \
  "$(sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o 'CRIT 9.3' | wc -l | tr -d ' ')"
check "F: markers 1 critical" "$T/proj/app${TAB}active${TAB}2 active vulnerabilities (1 critical)" "$(cat "$HIVEGUARD_MARKERS")"
check "F: ack store untouched" "$A0" "$(md5 -q "$HIVEGUARD_ACKS")"
cp "$REPORT" "$T/render-split.html"; scan "$T/split.json"; scan "$T/split.json"
diff <(norm "$T/render-split.html") <(norm "$REPORT") >/dev/null; check "F: same as a scan with that store" "0" "$?"

# --- G. open-ended ack: cover-all, never backfilled by a render ---
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":null,"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"; A0="$(md5 -q "$HIVEGUARD_ACKS")"
render
check "G: unmute / mutedbadge" "1 0" "$(count '>unmute</button>') $(count 'class="mutedbadge"')"
check "G: not backfilled" "$A0" "$(md5 -q "$HIVEGUARD_ACKS")"
rm -f "$HIVEGUARD_ACKS"

# --- H. refusals, recreation, probe, timing, help ---
R0="$(md5 -q "$REPORT")"
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"
check "H: scan in progress" "rc=4 osv-daily: a scan is in progress (pid $$); it writes a fresh report itself" "rc=$? $out"
rm -f "$HIVEGUARD_SCAN_PID"
cp "$HIVEGUARD_STATE" "$T/state.bak"; jq 'del(.render)' "$T/state.bak" > "$HIVEGUARD_STATE"
out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"
check "H: no render block" "rc=3 osv-daily: the saved scan predates report re-rendering — run: hiveguard daily" "rc=$? $out"
jq '.render.schema = 2' "$T/state.bak" > "$HIVEGUARD_STATE"; render; check "H: unknown render schema" "3" "$?"
rm -f "$HIVEGUARD_STATE"; out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"
check "H: no state" "rc=3 osv-daily: no saved scan to render from — run: hiveguard daily <folder>" "rc=$? $out"
cp "$T/state.bak" "$HIVEGUARD_STATE"
check "H: report kept by the refusals" "$R0" "$(md5 -q "$REPORT")"
rcs=""
for a in "--render $T/proj" "--render --open" "--render --rescan" "--render --if-due" "--render --probe $T/proj/app"; do
  "$HG/bin/osv-daily" $a >/dev/null 2>&1 </dev/null; rcs="$rcs$? "
done
check "H: usage combinations" "2 2 2 2 2 " "$rcs"
rm -f "$REPORT"; render; check "H: recreate rc" "0" "$?"
check "H: recreated" "recreated" "$([ -s "$REPORT" ] && echo recreated)"
check "H: recreated report has the state's mtime" "$(mtime "$HIVEGUARD_STATE")" "$(mtime "$REPORT")"
STUB_JSON="$T/run2.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null; P0="$(md5 -q "$HOME/.hiveguard/osv-probe.html")"
render; check "H: probe report untouched" "$P0" "$(md5 -q "$HOME/.hiveguard/osv-probe.html")"
TIMEFORMAT=%R; secs="$( { time render; } 2>&1 )"
check "H: render under 1 s ($secs s)" "fast" "$(awk -v s="$secs" 'BEGIN{print (s+0 < 1.0) ? "fast" : "slow"}')"
check "H: --help documents --render" "yes" "$([ "$("$HG/bin/osv-daily" --help | grep -c -- '--render')" -ge 2 ] && echo yes)"
check "H: --help documents the mtime rule" "yes" "$([ "$("$HG/bin/osv-daily" --help | grep -c 'modification time\|mtime')" -ge 1 ] && echo yes)"
check "H: no .tmp / scan pid / opened stamp" "0" \
  "$(ls -A "$HOME/.hiveguard" | grep -c '\.tmp$\|^osv-daily\.pid$\|^osv-report-opened$')"

# --- I. the scan path is unchanged: identical to the 9e5df56 renderer (links off and on); run file keys ---
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; cp "$REPORT" "$T/new.html"
cp "$HIVEGUARD_RUN" "$T/new-run.json"; cp "$HIVEGUARD_STATE" "$T/new-state.json"
mkdir -p "$T/base" && git -C "$HG" archive 9e5df56 bin 2>/dev/null | tar -x -C "$T/base" 2>/dev/null
check "I: 9e5df56 renderer extracted" "yes" "$([ -x "$T/base/bin/osv-daily" ] && echo yes)"
scan_base() { STUB_JSON="$1" "$T/base/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }
reset_scan; scan_base "$T/run1.json"; scan_base "$T/run2.json"
diff <(norm "$T/new.html") <(norm "$REPORT") >/dev/null; check "I: links off → identical to 9e5df56" "0" "$?"
untimed='del(.started_epoch, .finished_epoch, .stamp)'
check "I: run file content as 9e5df56's (times aside)" "$(jq -S "$untimed" "$HIVEGUARD_RUN")" "$(jq -S "$untimed" "$T/new-run.json")"
check "I: state as 9e5df56's plus the render block (stamp aside)" "$(jq -S 'del(.stamp)' "$HIVEGUARD_STATE")" \
  "$(jq -S 'del(.stamp, .render)' "$T/new-state.json")"
links_on; strict_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; cp "$REPORT" "$T/new-on.html"
reset_scan; scan_base "$T/run1.json"; scan_base "$T/run2.json"
# the links-on report gained the reload-on-return script after 9e5df56 (appended
# last); everything before it must still be byte-identical
strip_reload() { norm "$1" | awk '{l[NR]=$0} /var K=.hiveguard-reload./{cut=NR-2} END{n=cut?cut-1:NR; for(i=1;i<=n;i++) print l[i]}'; }
check "I: links on → the reload-on-return script is there" "1" "$(grep -c "var K='hiveguard-reload'" "$T/new-on.html")"
diff <(strip_reload "$T/new-on.html") <(strip_reload "$REPORT") >/dev/null; check "I: links + strict on → identical to 9e5df56 (reload script aside)" "0" "$?"
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
check "I: run file keys" "active,counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen" \
  "$(jq -r 'keys|join(",")' "$HIVEGUARD_RUN")"
check "I: run file active entry keys" "anchor,eco,fix,ids,pkg,project_anchor,root,sev,src,version" \
  "$(jq -r '.active[0]|keys|join(",")' "$HIVEGUARD_RUN")"
check "I: no .tmp left" "0" "$(ls "$HOME/.hiveguard" | grep -c '\.tmp$')"

# --- J. osv-ack refreshes by itself (H9) ---
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/run1.json"; scan "$T/run2.json"
cp "$REPORT" "$T/scan.html"; S0="$(scan_sig)"; rm -f "$T_LOG_NOTIFY"
L0="$(wc -l < "$HOME/.hiveguard/osv-daily.log" | tr -d ' ')"; touch -t 202601010000 "$REPORT"
OUT="$("$HG/bin/hiveguard" ack "$SRC" fast-uri </dev/null)"; check "J: ack rc" "0" "$?"
check "J: ack prints the refreshed line last" "  report and folder markers refreshed (reload the report if it is open)" "$(printf '%s\n' "$OUT" | tail -n1)"
check "J: ack output has 3 lines" "3" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
check "J: unmute / mute buttons without an explicit render" "1 1" "$(count '>unmute</button>') $(count '>mute</button>')"
check "J: markers" "$T/proj/app${TAB}active${TAB}1 active vulnerabilities (1 critical)" "$(cat "$HIVEGUARD_MARKERS")"
check "J: report mtime kept" "202601010000" "$(date -r "$(mtime "$REPORT")" '+%Y%m%d%H%M')"
check "J: scan state untouched" "$S0" "$(scan_sig)"
check "J: no notification" "silent" "$([ -e "$T_LOG_NOTIFY" ] && echo notified || echo silent)"
check "J: render log line" "1" \
  "$(tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '] render projects=1 pkgs=1 vulns=1 crit=1 (acked: vulns=3 pkgs=1) markers=R1,Y0 → ')"
check "J: whole-project ack refreshes" "  report and folder markers refreshed (reload the report if it is open)" \
  "$("$HG/bin/hiveguard" ack "$SRC" </dev/null | tail -n1)"
check "J: markers acked" "$T/proj/app${TAB}acked${TAB}4 acknowledged" "$(cat "$HIVEGUARD_MARKERS")"
check "J: clean report" "1" "$(count '✅ No active vulnerabilities — everything found is acknowledged.')"
check "J: --remove refreshes" "  report and folder markers refreshed (reload the report if it is open)" \
  "$("$HG/bin/hiveguard" ack --remove "$SRC" </dev/null | tail -n1)"
check "J: markers active again" "$T/proj/app${TAB}active${TAB}4 active vulnerabilities (1 critical)" "$(cat "$HIVEGUARD_MARKERS")"
cmp -s "$T/scan.html" "$REPORT"; check "J: back to the scan report" "0" "$?"
"$HG/bin/hiveguard" ack "$SRC" lodash >/dev/null </dev/null
check "J: lodash muted in the report" "1" "$(count '>unmute</button>')"
check "J: --clear refreshes" "  report and folder markers refreshed (reload the report if it is open)" \
  "$("$HG/bin/hiveguard" ack --clear </dev/null | tail -n1)"
cmp -s "$T/scan.html" "$REPORT"; check "J: --clear back to the scan report" "0" "$?"
check "J: five render log lines" "5" "$(( $(wc -l < "$HOME/.hiveguard/osv-daily.log" | tr -d ' ') - L0 ))"
# failure paths: the ack is applied, the note goes to stderr, exit 0
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"
OUT="$("$HG/bin/hiveguard" ack "$SRC" lodash 2>&1 >/dev/null </dev/null)"; RC=$?; rm -f "$HIVEGUARD_SCAN_PID"
check "J: scan running → rc 0" "0" "$RC"
check "J: scan running → note" "  (report not refreshed: a scan is in progress (pid $$); it writes a fresh report itself)" "$OUT"
check "J: scan running → the ack went through" "1" "$("$HG/bin/hiveguard" ack --list | grep -c 'lodash')"
R0="$(md5 -q "$REPORT")"; cp "$HIVEGUARD_STATE" "$T/state.bak"; jq 'del(.render)' "$T/state.bak" > "$HIVEGUARD_STATE"
OUT="$("$HG/bin/hiveguard" ack --remove "$SRC" lodash 2>&1 >/dev/null </dev/null)"; RC=$?; cp "$T/state.bak" "$HIVEGUARD_STATE"
check "J: predates → rc 0" "0" "$RC"
check "J: predates → note" "  (report not refreshed: the saved scan predates report re-rendering — run: hiveguard daily)" "$OUT"
check "J: predates → report kept" "$R0" "$(md5 -q "$REPORT")"
check "J: predates → the un-mute went through" "0" "$("$HG/bin/hiveguard" ack --list | grep -c 'lodash')"
rm -f "$HIVEGUARD_STATE" "$REPORT"
OUT="$("$HG/bin/hiveguard" ack "$SRC" lodash 2>&1 </dev/null)"; RC=$?
check "J: no state → rc 0" "0" "$RC"
check "J: no state → 'no scan data' note" "1" "$(printf '%s\n' "$OUT" | grep -c 'no scan data')"
check "J: no state → no refresh note" "0" "$(printf '%s\n' "$OUT" | grep -c 'refreshed')"
check "J: no state → no report written" "no-report" "$([ -e "$REPORT" ] && echo report-written || echo no-report)"
check "J: help mentions the refresh" "1" "$("$HG/bin/osv-ack" --help | grep -c -i 'refresh' | awk '{print ($1>=1)?1:0}')"

exit "$FAILED"

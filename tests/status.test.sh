#!/usr/bin/env bash
# status.test.sh — bin/status (hiveguard status [--json]) in full isolation.
#
# Everything runs against a throwaway HOME and every HIVEGUARD_* override, with
# HIVEGUARD_TOOL_PATH pointing at stubs (launchctl among them), so the real
# ~/.hiveguard, ~/.zshrc and launchd agent are never touched. No scan is ever
# run: the run outcome file and the ack store are hand-written fixtures shaped
# per docs/status-json.md. `status` is read-only — the test asserts it.
# bash 3.2 compatible (no associative arrays, no empty-array expansion under -u).
set -uo pipefail          # deliberately not -e: a failed check must not abort

HG="$(cd "$(dirname "$0")/.." && pwd)"
HV="$HG/bin/hiveguard"

FAILS=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() {  # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1
       expected: [$2]
       got:      [$3]"; fi
}

# --- isolated scaffold (plan section 2.4, inline) -----------------------------
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard" "$T/stubs" "$T/proj/app/.git"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"           HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv" HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json" HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_RUN="$HOME/.hiveguard/osv-run.json"         HIVEGUARD_SCAN_PID="$HOME/.hiveguard/osv-daily.pid"
export HIVEGUARD_REPORT_OPENED="$HOME/.hiveguard/osv-report-opened" HIVEGUARD_APP_PID="$HOME/.hiveguard/menubar.pid"
export HIVEGUARD_SCHED_PLIST="$T/sched.plist"                # a file under $T, never the real plist
export HIVEGUARD_TOOL_PATH="$T/stubs"                        # stubs win over /opt/homebrew/bin
export HIVEGUARD_BIN="$HV"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
REPORT="$HOME/.hiveguard/osv-projects.html"; SRC="$T/proj/app/package-lock.json"; : > "$SRC"

# stubs: launchctl is the one status calls (print only); the others must never run
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_LAUNCHCTL"\nexit "${STUB_LAUNCHCTL_RC:-0}"\n' > "$T/stubs/launchctl"
for s in osv-scanner terminal-notifier osascript open; do
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$T_LOG_FORBIDDEN"\n' "$s" > "$T/stubs/$s"
done
chmod +x "$T"/stubs/*
export T_LOG_LAUNCHCTL="$T/launchctl.log" T_LOG_FORBIDDEN="$T/forbidden.log"

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

# --- seed: a "red" status without a scan (plan H2 acceptance) ---------------
NOW=$(date +%s); cat > "$HIVEGUARD_RUN" <<EOF
{"schema":1,"ok":true,"rc":1,"error":null,"started_epoch":$((NOW-7230)),"finished_epoch":$((NOW-7200)),"stamp":"x","target":"$T/proj",
 "counts":{"active":{"projects":1,"pkgs":2,"vulns":4,"crit":1},"acked":{"projects":0,"pkgs":0,"vulns":0,"crit":0},"new_vulns":4,"resolved_vulns":0},
 "roots":{"$T/proj/app":{"status":"active","active_vulns":4,"crit_pkgs":1,"acked_vulns":0}},
 "new":[],"unseen":[
  {"src":"$SRC","root":"$T/proj/app","pkg":"fast-uri","version":"3.0.1","eco":"npm","sev":7.5,"fix":"3.0.6","ids":["GHSA-AAAA-0001","GHSA-AAAA-0002","GHSA-AAAA-0003"],"anchor":"f-000000000001","project_anchor":"p-000000000002"},
  {"src":"$SRC","root":"$T/proj/app","pkg":"lodash","version":"4.17.20","eco":"npm","sev":9.1,"fix":"4.17.21","ids":["GHSA-BBBB-0001"],"anchor":"f-000000000003","project_anchor":"p-000000000002"}]}
EOF
printf '%s\tactive\t4 active vulnerabilities (1 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
printf '%s\t%s\n%s\t%s\ngarbage\n' "$T/proj/app" "$((NOW+600))" "$T/other" "$((NOW-600))" > "$HIVEGUARD_PAUSES"
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"

snapshot() { (cd "$HOME" && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$(md5 -q "$f")" "$f"; done); }
BEFORE="$(snapshot)"

st() { "$HV" status --json; }
row() { paste -sd' ' -; }

# --- the seeded red document ------------------------------------------------
S="$(st)"; rc=$?
check "status --json exits 0" 0 "$rc"
check "output is valid JSON" true "$(jq -e 'type=="object"' <<<"$S" 2>/dev/null || echo false)"
check "compact (one line)" 1 "$(printf '%s\n' "$S" | wc -l | tr -d ' ')"
check "top-level keys (schema 1)" \
  "app attention attention_ids hiveguard now_epoch report scan schedule schema strict" \
  "$(jq -r 'keys|join(" ")' <<<"$S")"
check "core facts" "1 true git false null true 4 2 lodash true" \
  "$(jq -r '.schema, (.hiveguard.version|length > 0), .hiveguard.method, .scan.running, .scan.pid, .scan.last.ok, .attention_ids, (.attention|length), .attention[0].pkg, .attention[0].crit' <<<"$S" | row)"
check "version has no (brew) suffix" 0 "$(jq -r '.hiveguard.version' <<<"$S" | grep -c 'brew')"
check "now_epoch is current" true "$(jq --argjson n "$NOW" '(.now_epoch - $n) | (. >= 0 and . < 60)' <<<"$S")"
check "scan.last keys" "counts error finished_epoch ok rc stamp started_epoch target" \
  "$(jq -r '.scan.last|keys|join(" ")' <<<"$S")"
check "scan.last.counts verbatim" 4 "$(jq -r '.scan.last.counts.active.vulns' <<<"$S")"
check "second entry: fast-uri, 3 open, 0 acked" "fast-uri 3 0" \
  "$(jq -r '.attention[1] | .pkg, (.ids_open|length), (.ids_acked|length)' <<<"$S" | row)"
check "attention entry keys" "anchor crit eco fix ids_acked ids_open pkg project project_anchor root sev src version" \
  "$(jq -r '.attention[0]|keys|join(" ")' <<<"$S")"
check "attention project = root outside HOME kept as is" "$T/proj/app" "$(jq -r '.attention[0].project' <<<"$S")"
check "attention passes metadata through" "f-000000000003 p-000000000002 4.17.21 9.1 npm 4.17.20" \
  "$(jq -r '.attention[0] | .anchor, .project_anchor, .fix, .sev, .eco, .version' <<<"$S" | row)"
check "report: absent, never opened" "false null $REPORT" \
  "$(jq -r '.report.exists, .report.opened_epoch, .report.path' <<<"$S" | row)"
check "schedule from the plist + launchctl print" "true true 10 0 $T/proj" \
  "$(jq -r '.schedule.configured, .schedule.loaded, .schedule.hour, .schedule.minute, .schedule.folders[0]' <<<"$S" | row)"
check "launchctl called with print only" "print gui/$(id -u)/com.hiveguard.osv-daily" \
  "$(sort -u "$T_LOG_LAUNCHCTL")"
check "strict facts" "true false true 1 1 1 $T/proj/app false" \
  "$(jq -r '.strict.enabled, .strict.hook_sourced, (.strict.hook_hint|startswith("source ")), (.strict.blocked|length), .strict.blocked[0].crit_pkgs, (.strict.paused|length), .strict.paused[0].root, .app.running' <<<"$S" | row)"
check "hook_hint names the hook script" "source \"$HG/bin/hiveguard-hook.zsh\"" "$(jq -r '.strict.hook_hint' <<<"$S")"
check "blocked summary verbatim" "4 active vulnerabilities (1 critical)" "$(jq -r '.strict.blocked[0].summary' <<<"$S")"
check "paused until_epoch" "$((NOW+600))" "$(jq -r '.strict.paused[0].until_epoch' <<<"$S")"

# --- ack classification (plan 1.6) ------------------------------------------
printf '{"schema":2,"projects":{"%s":{"ids":null,"since":"2026-10-07"}},"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "open-ended project ack covers all" "0 0" "$(st | jq -r '.attention_ids, (.attention|length)' | row)"
printf '{"schema":2,"projects":{"%s":{"ids":{"lodash":["GHSA-BBBB-0001"]},"since":"x"}},"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "id-scoped project ack covers only its ids" "3 1 fast-uri" "$(st | jq -r '.attention_ids, (.attention|length), .attention[0].pkg' | row)"
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"],"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "package ack: partial" "2 2 GHSA-AAAA-0003 2" \
  "$(st | jq -r '.attention_ids, (.attention|length), (.attention[]|select(.pkg=="fast-uri")|(.ids_open|join(",")), (.ids_acked|length))' | row)"
printf '{"schema":2,"projects":{},"packages":{"%s":{"lodash":{"ids":null,"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "open-ended package ack" "3 1" "$(st | jq -r '.attention_ids, (.attention|length)' | row)"
printf '{"projects":["%s"],"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "v1 project store → open-ended" 0 "$(st | jq -r '.attention_ids')"
printf '{"projects":[],"packages":{"%s":["fast-uri"]}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "v1 package store → open-ended" "1 lodash" "$(st | jq -r '.attention_ids, .attention[0].pkg' | row)"
printf 'not json' > "$HIVEGUARD_ACKS"
check "unreadable ack store → nothing acked" 4 "$(st | jq -r '.attention_ids')"
rm -f "$HIVEGUARD_ACKS"

# --- report, schedule, scan pid, app pid, hook --------------------------------
: > "$REPORT"; printf '%s\n' "$NOW" > "$HIVEGUARD_REPORT_OPENED"
check "report exists + opened stamp" "true $NOW" "$(st | jq -r '.report.exists, .report.opened_epoch' | row)"
printf 'garbage\n' > "$HIVEGUARD_REPORT_OPENED"
check "malformed opened stamp → null" null "$(st | jq -r '.report.opened_epoch')"
rm -f "$HIVEGUARD_REPORT_OPENED" "$REPORT"
check "agent not loaded" false "$(STUB_LAUNCHCTL_RC=1 st | jq -r '.schedule.loaded')"
mv "$HIVEGUARD_SCHED_PLIST" "$T/p.bak"
check "no plist → not configured" "false 0 null null" \
  "$(st | jq -r '.schedule.configured, (.schedule.folders|length), .schedule.hour, .schedule.minute' | row)"
mv "$T/p.bak" "$HIVEGUARD_SCHED_PLIST"
cat > "$T/sched2.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.hiveguard.osv-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HG/bin/hiveguard</string>
    <string>daily</string>
    <string>$T/a &amp; b</string>
    <string>$T/c</string>
    <string>--if-due</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>5</integer></dict>
</dict></plist>
EOF
check "folders XML-unescaped, several, hour/minute" "$T/a & b|$T/c|7|5" \
  "$(HIVEGUARD_SCHED_PLIST="$T/sched2.plist" st | jq -r '(.schedule.folders|join("|")) + "|\(.schedule.hour)|\(.schedule.minute)"')"
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"
check "scan running (live pid)" "true $$" "$(st | jq -r '.scan.running, .scan.pid' | row)"
printf '99999' > "$HIVEGUARD_SCAN_PID"
check "stale scan pid → not running" "false null" "$(st | jq -r '.scan.running, .scan.pid' | row)"
rm -f "$HIVEGUARD_SCAN_PID"
printf '%s' "$$" > "$HIVEGUARD_APP_PID"
check "app running (live pid)" true "$(st | jq -r '.app.running')"
printf '99999' > "$HIVEGUARD_APP_PID"
check "stale app pid → not running" false "$(st | jq -r '.app.running')"
rm -f "$HIVEGUARD_APP_PID"
printf 'source "%s/bin/hiveguard-hook.zsh"\n' "$HG" > "$HOME/.zshrc"
check "hook sourced → no hint" "true null" "$(st | jq -r '.strict.hook_sourced, .strict.hook_hint' | row)"
rm -f "$HOME/.zshrc"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
check "strict off" false "$(st | jq -r '.strict.enabled')"
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"

# crit_pkgs falls back to the marker summary when the run has no roots
cp "$HIVEGUARD_RUN" "$T/r0.bak"
jq '.roots=null' "$T/r0.bak" > "$HIVEGUARD_RUN"
printf '%s\tactive\t9 active vulnerabilities (3 critical)\n%s\tacked\t1 acknowledged\n%s\tactive\t2 active vulnerabilities\n' \
  "$T/proj/app" "$T/proj/b" "$T/proj/c" > "$HIVEGUARD_MARKERS"
check "blocked: only active rows; crit_pkgs from summary, else 0" "2 3 0" \
  "$(st | jq -r '(.strict.blocked|length), .strict.blocked[0].crit_pkgs, .strict.blocked[1].crit_pkgs' | row)"
cp "$T/r0.bak" "$HIVEGUARD_RUN"
printf '%s\tactive\t4 active vulnerabilities (1 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"

# project label: $HOME/Projects/ stripped, else $HOME → ~
jq --arg a "$HOME/Projects/x/app" --arg b "$HOME/work/y" \
  '.unseen[0].root=$a | .unseen[1].root=$b' "$T/r0.bak" > "$HIVEGUARD_RUN"
check "project labels" "~/work/y|x/app" "$(st | jq -r '[.attention[].project]|join("|")')"
cp "$T/r0.bak" "$HIVEGUARD_RUN"

# sort: sev desc, then project, then pkg
jq '.unseen[1].sev=7.5 | .unseen[0].pkg="zeta"' "$T/r0.bak" > "$HIVEGUARD_RUN"
check "attention sorted sev desc, project, pkg" "lodash|zeta" "$(st | jq -r '[.attention[].pkg]|join("|")')"
cp "$T/r0.bak" "$HIVEGUARD_RUN"

# --- plain (human) mode -------------------------------------------------------
P="$("$HV" status)"
check "plain: ok line" "Last scan: x — ok — 1 project(s) with problems, 1 critical" "$(sed -n 1p <<<"$P")"
check "plain: new findings" "New findings: 4 advisory id(s) in 2 package(s)" "$(sed -n 2p <<<"$P")"
check "plain: protection ok" "Protection: ok" "$(sed -n 3p <<<"$P")"
check "plain: strict" "Strict mode: on, 1 paused" "$(sed -n 4p <<<"$P")"
check "plain: no running line when idle" 4 "$(printf '%s\n' "$P" | wc -l | tr -d ' ')"
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"
check "plain: running line" "Scan running: yes (pid $$)" "$("$HV" status | sed -n 5p)"
rm -f "$HIVEGUARD_SCAN_PID"
printf '{"schema":2,"projects":{"%s":{"ids":null,"since":"x"}},"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
check "plain: no new findings" "New findings: none" "$("$HV" status | sed -n 2p)"
rm -f "$HIVEGUARD_ACKS"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
check "plain: strict off" "Strict mode: off" "$("$HV" status | sed -n 4p)"
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
check "plain: not scheduled + not loaded" "Protection: NOT WORKING — daily scan not scheduled" \
  "$(STUB_LAUNCHCTL_RC=1 HIVEGUARD_SCHED_PLIST="$T/none.plist" "$HV" status | sed -n 3p)"
check "plain: agent not loaded" "Protection: NOT WORKING — agent not loaded" \
  "$(STUB_LAUNCHCTL_RC=1 "$HV" status | sed -n 3p)"
jq --argjson f "$((NOW-40*3600))" '.finished_epoch=$f' "$T/r0.bak" > "$HIVEGUARD_RUN"
check "plain: stale scan" "Protection: NOT WORKING — last scan 40h ago" "$("$HV" status | sed -n 3p)"
cp "$T/r0.bak" "$HIVEGUARD_RUN"

mv "$HIVEGUARD_RUN" "$T/r.bak"
check "no run file → null last, no attention" "null 0 0" "$(st | jq -r '.scan.last, .attention_ids, (.attention|length)' | row)"
check "plain: never scanned" "No scan has completed yet" "$("$HV" status | head -n1)"
check "plain: never scanned → protection" "Protection: NOT WORKING — no scan yet" "$("$HV" status | sed -n 3p)"
printf '{broken' > "$HIVEGUARD_RUN"
check "unparsable run file → null last" "null 0" "$(st | jq -r '.scan.last, .attention_ids' | row)"
mv "$T/r.bak" "$HIVEGUARD_RUN"

jq '.ok=false | .rc=128 | .error="no package sources found\nfatal: giving up" | .counts=null | .roots=null' "$HIVEGUARD_RUN" > "$T/f.json"; cp "$T/f.json" "$HIVEGUARD_RUN"
check "plain: failed scan lines" "Last scan: x — FAILED (rc=128) — no package sources found|Protection: NOT WORKING — last scan failed" \
  "$("$HV" status | sed -n '1p;3p' | paste -sd'|' -)"
check "json: failed scan counts null" "false 128 null" "$(st | jq -r '.scan.last.ok, .scan.last.rc, .scan.last.counts' | row)"
jq '.error=null' "$T/f.json" > "$HIVEGUARD_RUN"
check "plain: failed scan without error text" "Last scan: x — FAILED (rc=128) — no output" "$("$HV" status | head -n1)"
cp "$T/r0.bak" "$HIVEGUARD_RUN"

# --- arguments, help, dispatcher ---------------------------------------------
"$HV" status --bogus >/dev/null 2>&1; check "unknown argument → rc 2" 2 "$?"
"$HG/bin/status" --help >/dev/null 2>&1; check "--help → rc 0" 0 "$?"
check "--help names the contract doc" 1 "$("$HG/bin/status" --help | grep -c 'docs/status-json.md')"
check "dispatcher help lists status" 1 "$("$HV" help | grep -c 'hiveguard status')"

# --- read-only ----------------------------------------------------------------
check "nothing under HOME changed" "$BEFORE" "$(snapshot)"
check "no forbidden tool was run" 0 "$( [ -e "$T_LOG_FORBIDDEN" ] && wc -l < "$T_LOG_FORBIDDEN" | tr -d ' ' || echo 0)"
check "launchctl only ever print" 0 "$(grep -vc '^print ' "$T_LOG_LAUNCHCTL")"

# --- contract document covers every key ---------------------------------------
DOC="$HG/docs/status-json.md"
missing=""
for k in $(jq -r '[paths | map(select(type=="string")) | last | select(. != null)] | unique[]' <<<"$S"); do
  grep -qE "\`([a-z_]+(\[\])?\.)*$k(\[\])?\`" "$DOC" 2>/dev/null || missing="$missing $k"
done
check "contract doc names every key" "" "$missing"
check "contract doc has schema history" 1 "$(grep -c '^## Schema history' "$DOC" 2>/dev/null || echo 0)"

if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all status checks passed"

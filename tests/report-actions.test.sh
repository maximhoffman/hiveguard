#!/usr/bin/env bash
# report-actions.test.sh — osv-daily's report action links (hiveguard://) and the
# run file's `active` list.
#
# Covers:
#   - app NOT running → no links, no extra CSS, the historical footer sentence,
#     today's copy buttons (the markers of a report byte-identical to 1.6.0's)
#   - app running → `mark as known` / `mark project as known` links with the
#     exact hrefs (percent-encoded with no safe characters, HTML-escaped), the
#     terminal command tucked behind a small `copy` button, the CSS and footer
#   - pause links (1 h / 2 h) only when strict mode is on, with the realpath'd root
#   - a pierced (muted-badge) row gets a `mark as known` link; the Acknowledged section
#     keeps its unmute buttons and never gets a link
#   - --probe reports and a dead app pid never render links
#   - anchors and the hash-jump script are intact with links on
#   - osv-run.json `active`: every active package fragment, sorted, with anchors;
#     shrinks after an ack; carried unchanged by a failed scan; never written by
#     a probe
#
# Fully offline: osv-scanner is a stub on HIVEGUARD_TOOL_PATH that replays a
# JSON fixture. Runs under an isolated HOME with every HIVEGUARD_* override set,
# so the real ~/.hiveguard and the launchd label com.hiveguard.osv-daily are
# never touched. "App running" is simulated by writing this shell's pid to
# HIVEGUARD_APP_PID.
#
# Usage: bash tests/report-actions.test.sh
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

# --- isolated scaffold (plan section 2.5 = base plan 2.4 + helpers) ----------
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
  "vulnerabilities":[{"id":"GHSA-AAAA-0001","affected":[{"package":{"name":"fast-uri","ecosystem":"npm"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"3.0.6"}]}]}]},{"id":"GHSA-AAAA-0002","affected":[]}$extra],
  "groups":[{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"$extra_ids],"max_severity":"7.5"}]},
 {"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-BBBB-0001","affected":[{"package":{"name":"lodash","ecosystem":"npm"},"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}],
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
J() { jq -r "$@" "$HIVEGUARD_RUN" 2>/dev/null | paste -sd' ' -; }

ENC="$(enc "$SRC")"; ROOTENC="$(enc "$T/proj/app")"
dead_pid() { sh -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# --- 1. app NOT running → today's report --------------------------------------
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
check "off: no hiveguard:// link"           "0" "$(count 'hiveguard://')"
check "off: no act-link"                     "0" "$(count 'act-link')"
check "off: no reload-on-return script"      "0" "$(count 'hiveguard-reload')"
check "off: no waiting overlay"              "0" "$(count 'hgwait')"
check "off: no cp-alt"                       "0" "$(count 'cp-alt')"
check "off: no actg span"                    "0" "$(count 'actg')"
check "off: today's copy buttons (mute x2, mute project)" "3" "$(count 'class="cp"')"
check "off: mute / mute project labels"      "2 1" "$(count '>mute</button>') $(count '>mute project</button>')"
check "off: historical footer sentence"      "1" "$(count 'Mute an old project with the “mute” button (→ hiveguard ack).')"
check "off: no links footer sentence"        "0" "$(count 'Buttons act through the HiveGuard menu bar app')"
check "off: .hl rule directly before </style>" "1" \
  "$(grep -A1 '^\.hl{' "$REPORT" | grep -c '^</style>$')"
strict_on; scan "$T/run2.json"
check "off + strict on: still no link"       "0" "$(count 'hiveguard://')"
strict_off

# --- 2. app running, strict off → ack links, copy tucked away, no pause -------
links_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
check "on: act-link count"                    "3" "$(count 'class="act-link')"
# a hiveguard:// link followed in the report's own tab makes Opera/Chromium close that tab
check "on: every act-link opens in a new tab"  "3" "$(count 'class="act-link[^>]*" target="_blank" rel="noopener">')"
# after a button click the page reloads once the user comes back from the app's dialog
check "on: reload-on-return script, once"      "1" "$(count "var K='hiveguard-reload'")"
check "on: waiting overlay — style, builder, click-to-reload, visibility" "1 1 1 1" \
  "$(count '#hgwait{position:fixed') $(count "o.id='hgwait'") $(count "t.textContent='Confirm in the HiveGuard app'") $(count "addEventListener('visibilitychange'")"
check "on: a flash of focus keeps the wait" "1" "$(count 'if(Date.now()-away<AWAY) return;')"
check "on: the overlay survives reloads and goes only on a click" "1 1 1" \
  "$(count 'if(waiting) cover(); else showGone();') $(count 'waiting:waiting') $(count 'waiting=false; save();')"
check "on: it arms on a hiveguard: link click"  "1" "$(count "closest('a\[href^=\"hiveguard:\"\]')")"
# after the reload a row/card that left is replaced for a moment by a highlighted note
check "on: leaving-row note style, once"        "1" "$(count '\.gone{transition')"
check "on: leaving-row/card note texts"          "2" "$(count ' — marked as known')"
check "on: fast-uri ack href" "1" "$(count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=fast-uri\"")"
check "on: lodash ack href"   "1" "$(count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=lodash\"")"
check "on: ack-project href"  "1" "$(count "href=\"hiveguard://ack-project?v=1&amp;src=$ENC\"")"
check "on: src is percent-encoded (no raw slash after src=)" "0" "$(count 'src=/')"
check "on: no pause link with strict off"    "0" "$(count 'hiveguard://pause')"
check "on: link labels"                      "2 1" "$(count '>mark as known</a>') $(count '>mark project as known</a>')"
check "on: copy buttons are cp-alt only"     "3 0" "$(count 'class="cp cp-alt"') $(count 'class="cp"')"
check "on: copy button commands"             "1 1" \
  "$(count "data-cmd=\"hiveguard ack $SRC fast-uri\"") $(count "data-cmd=\"hiveguard ack $SRC\"")"
check "on: copy aria-labels"                 "3" "$(count 'aria-label="Copy command: hiveguard ack ')"
check "on: copy label"                       "3" "$(count '>copy</button>')"
check "on: row link markup" "1" \
  "$(count "<span class=\"actg\"><a class=\"act-link\" href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=lodash\" title=\"Mark this finding as known via the HiveGuard app (asks for confirmation)\" target=\"_blank\" rel=\"noopener\">mark as known</a><button class=\"cp cp-alt\" type=\"button\" data-cmd=\"hiveguard ack $SRC lodash\" title=\"Copy the terminal command instead\" aria-label=\"Copy command: hiveguard ack $SRC lodash\">copy</button></span>")"
check "on: card link markup" "1" \
  "$(count "<span class=\"actg\"><a class=\"act-link\" href=\"hiveguard://ack-project?v=1&amp;src=$ENC\" title=\"Mark every finding of this project as known via the HiveGuard app (asks for confirmation)\" target=\"_blank\" rel=\"noopener\">mark project as known</a><button class=\"cp cp-alt\" type=\"button\" data-cmd=\"hiveguard ack $SRC\" title=\"Copy the terminal command instead\" aria-label=\"Copy command: hiveguard ack $SRC\">copy</button></span>")"
check "on: CSS and footer"                   "1 1" \
  "$(count '\.act-link{') $(count 'Buttons act through the HiveGuard menu bar app (it asks before changing anything); “copy” gives the terminal command instead.')"
check "on: historical footer sentence gone"  "0" "$(count 'Mute an old project with the “mute” button')"
check "on: anchors intact" "1 1 1" \
  "$(grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT") $(grep -c "id=\"f-$(h12pkg "$SRC" lodash)\"" "$REPORT") $(grep -c "id=\"p-$(h12 "$SRC")\"" "$REPORT")"
check "on: hash-jump script intact"          "yes" "$(grep -q hashchange "$REPORT" && echo yes || echo no)"
check "on: toolbar untouched"                "1 1" "$(count 'id="copySel"') $(count 'data-ack="hiveguard ack ')"

# --- 3. strict on → pause links with the realpath'd root ----------------------
strict_on; scan "$T/run2.json"
check "strict: pause 1h href" "1" "$(count "href=\"hiveguard://pause?v=1&amp;root=$ROOTENC&amp;for=1h\"")"
check "strict: pause 2h href" "1" "$(count "href=\"hiveguard://pause?v=1&amp;root=$ROOTENC&amp;for=2h\"")"
check "strict: pause labels + all links" "1 1 5" \
  "$(count '>pause strict 1 h</a>') $(count '>pause strict 2 h</a>') $(count 'class="act-link')"
check "strict: pause titles" "1 1" \
  "$(count 'title="Pause strict mode for this project for 1 hour via the HiveGuard app (asks for confirmation)"') $(count 'title="Pause strict mode for this project for 2 hours via the HiveGuard app (asks for confirmation)"')"
check "strict: pause links sit between ack-project and copy" "1" \
  "$(count "mark project as known</a><a class=\"act-link pause\" href=\"hiveguard://pause?v=1&amp;root=$ROOTENC&amp;for=1h\"")"

# a finding whose root IS the scan target is not blockable → no pause link
mkdir -p "$T/flat"; FSRC="$T/flat/package-lock.json"; : > "$FSRC"
sed "s|$SRC|$FSRC|g" "$T/run1.json" > "$T/flat.json"
STUB_JSON="$T/flat.json" "$HG/bin/osv-daily" "$T/flat" >/dev/null 2>&1 </dev/null
check "strict: root that is the scan target gets no pause link" "0 1" \
  "$(count 'hiveguard://pause') $(count '>mark project as known</a>')"
strict_off

# --- 4. pierced row → mark-as-known link; acked section untouched --------------------
reset_scan; scan "$T/run1.json"; "$HG/bin/hiveguard" ack "$SRC" fast-uri >/dev/null </dev/null; scan "$T/run2.json"
check "pierced: mark-as-known links (pierced + ordinary row) + package-form href" "2 1" \
  "$(count '>mark as known</a>') $(count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=fast-uri\"")"
check "pierced: new-advisory title" "1" \
  "$(count "title=\"A new advisory appeared in a package you had muted. Mark it as known too (asks for confirmation).\"")"
check "pierced: muted badge kept" "1" "$(count 'class="mutedbadge"')"
check "acked: unmute buttons kept" "1 1" "$(count '>unmute</button>') $(count '>unmute all</button>')"
check "acked: no link in the Acknowledged section" "0" \
  "$(sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o 'act-link' | wc -l | tr -d ' ')"
check "acked: unmute buttons stay plain cp" "2" \
  "$(sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o 'class="cp"' | wc -l | tr -d ' ')"

# project-level mute pierced → mark-as-known link in the project form
reset_scan; scan "$T/run1.json"; "$HG/bin/hiveguard" ack "$SRC" >/dev/null </dev/null; scan "$T/run2.json"
check "pierced (project mute): mark-as-known ack-project link (pierced row only: lodash is under the project mute)" "1 1" \
  "$(count '>mark as known</a>') $(count "<a class=\"act-link\" href=\"hiveguard://ack-project?v=1&amp;src=$ENC\" title=\"A new advisory")"
check "pierced (project mute): copy keeps the project command" "1" \
  "$(count "data-cmd=\"hiveguard ack $SRC\" title=\"Copy the terminal command instead\" aria-label=\"Copy command: hiveguard ack $SRC\">copy</button></span></td>")"

# --- 5. probe and dead pid never render links ---------------------------------
links_on; reset_scan
STUB_JSON="$T/run2.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null
check "probe: report written, no link" "yes 0" \
  "$([ -s "$HOME/.hiveguard/osv-probe.html" ] && echo yes || echo no) $(count 'act-link' "$HOME/.hiveguard/osv-probe.html")"
printf '%s' "$(dead_pid)" > "$HIVEGUARD_APP_PID"; scan "$T/run2.json"
check "dead pid: no link"   "0" "$(count 'act-link')"
printf 'garbage' > "$HIVEGUARD_APP_PID"; scan "$T/run2.json"
check "garbage pid: no link" "0" "$(count 'act-link')"
links_on; scan "$T/run2.json"
check "pid file left untouched" "$$" "$(cat "$HIVEGUARD_APP_PID")"
check "no opened stamp written" "absent" "$([ -e "$HIVEGUARD_REPORT_OPENED" ] && echo present || echo absent)"

# --- 6. run file: active[] ----------------------------------------------------
links_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
check "run: documented keys" "active,counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen" \
  "$(jq -r 'keys|join(",")' "$HIVEGUARD_RUN" 2>/dev/null)"
check "run: active entries" "2 lodash GHSA-AAAA-0001,GHSA-AAAA-0002,GHSA-AAAA-0003 $T/proj/app f-$(h12pkg "$SRC" fast-uri) 3.0.6" \
  "$(J '(.active|length), .active[0].pkg, (.active[1].ids|join(",")), .active[1].root, .active[1].anchor, .active[1].fix')"
check "run: active entry keys" "anchor,eco,fix,ids,pkg,project_anchor,root,sev,src,version" \
  "$(jq -r '.active[0]|keys|join(",")' "$HIVEGUARD_RUN" 2>/dev/null)"
check "run: active[0] sev, src, project anchor" "9.1 $SRC p-$(h12 "$SRC")" \
  "$(J '.active[0].sev, .active[0].src, .active[0].project_anchor')"
"$HG/bin/hiveguard" ack "$SRC" fast-uri >/dev/null </dev/null; scan "$T/run2.json"
check "run: active shrinks after an ack" "1 lodash" "$(J '(.active|length), .active[0].pkg')"
STUB_FAIL=1 scan "$T/run1.json"
check "run: failed scan carries active" "false 1 lodash" "$(J '.ok, (.active|length), .active[0].pkg')"
rm -f "$HIVEGUARD_RUN"; STUB_FAIL=1 scan "$T/run1.json"
check "run: failed scan with no previous run → active []" "false 0" "$(J '.ok, (.active|length)')"
rm -f "$HIVEGUARD_RUN"; STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null
check "run: probe writes no run file" "absent" "$([ -e "$HIVEGUARD_RUN" ] && echo present || echo absent)"

# --- 7. help, notifier handoff, isolation --------------------------------------
check "--help documents hiveguard:// links" "yes" \
  "$("$HG/bin/osv-daily" --help | grep -q 'hiveguard://' && echo yes || echo no)"
links_off; reset_scan; rm -f "$T_LOG_NOTIFY"; scan "$T/run1.json"
check "notifier still fires with the app not running" "1" "$(wc -l < "$T_LOG_NOTIFY" 2>/dev/null | tr -d ' ')"
links_on; rm -f "$T_LOG_NOTIFY"; scan "$T/run1.json"
check "notifier skipped with the app running" "absent" "$([ -e "$T_LOG_NOTIFY" ] && echo present || echo absent)"
check "no launchd agent touched" "0" "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard)"

if [ "$FAILED" = 0 ]; then echo "all report-actions checks passed"; else echo "report-actions: FAILURES above"; fi
exit "$FAILED"

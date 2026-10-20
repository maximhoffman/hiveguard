#!/usr/bin/env bash
# report-advisories.test.sh — advisory descriptions in the daily report, the
# per-version-line "Fixed in", "no score", and the "mark as known" label
# (plan docs/superpowers/plans/2026-10-20-report-advisory-details-plan.md).
#
# Covers:
#   A  fixes (regression fixture tests/fixtures/advisory-details.json, trimmed
#      real osv-scanner output): render.packages fix / id_fix, the report's
#      "Fixed in" cells, the run file's active[].fix and `status --json`
#   B  the version comparator and the affected[] matching (synthetic fixture):
#      pre-releases, several spans, last_affected, an entry without `package`,
#      GIT ranges, another package's entries, the highest per-advisory fix,
#      the fallback when no span contains the version
#   C  "no score": badge, counts, markers, ordering of rows and cards, card head
#   D  descriptions: render.advisories, the 4 000-character cap, the Advisory
#      cell and the advisory list row byte for byte, the advdb JSON table, HTML
#      and </script> escaping, the summary fallbacks, the lead rule, new ids
#   E  legacy layout: a state without render.advisories still renders
#   F  sections: the acked section, a partial ack (the -k twin), the probe report
#   G  the pierced row's label and tooltip ("mark as known" / "mute"); the old
#      label is gone from the page
#   H  render parity: --render is byte-identical to the scan's report; the
#      state's key lists
#
# Fully offline: osv-scanner is a stub on HIVEGUARD_TOOL_PATH that replays a JSON
# fixture. Runs under an isolated HOME with every HIVEGUARD_* override set, so the
# real ~/.hiveguard and the launchd label com.hiveguard.osv-daily are never touched.
# "App running" is simulated by writing this shell's pid to HIVEGUARD_APP_PID.
#
# Usage: bash tests/report-advisories.test.sh
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

# --- isolated scaffold (same as report-render.test.sh) ------------------------
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.hiveguard" "$T/stubs"
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
REPORT="$HOME/.hiveguard/osv-projects.html"
TAB="$(printf '\t')"
OLDLABEL="re-""ack"        # the retired button label, spelled so this file never contains it

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
links_on()  { printf '%s' "$$" > "$HIVEGUARD_APP_PID"; }
links_off() { rm -f "$HIVEGUARD_APP_PID"; }
strict_off(){ printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"; }
reset_scan(){ rm -f "$HIVEGUARD_STATE" "$HIVEGUARD_RUN" "$HIVEGUARD_MARKERS" "$HIVEGUARD_COVERAGE" "$HIVEGUARD_ACKS" "$HIVEGUARD_PAUSES" "$HIVEGUARD_REPORT_OPENED"; }
count() { grep -o -- "$1" "${2:-$REPORT}" | wc -l | tr -d ' '; }        # rows are on one line: never grep -c
cnt_in() { printf '%s\n' "$1" | grep -o -- "$2" | wc -l | tr -d ' '; }    # count a pattern inside a string
render() { "$HG/bin/osv-daily" --render >/dev/null 2>&1 </dev/null; }
ids_of() { grep -o 'data-adv="[^"]*"' | sed 's/data-adv="//; s/"//' | paste -sd, -; }   # stdin: list row

# --- projects and fixtures ------------------------------------------------------
mkproj() { mkdir -p "$T/proj/$1/.git"; : > "$T/proj/$1/$2"; }             # dir, lockfile name
mkproj go go.mod; mkproj web package-lock.json
GO="$T/proj/go/go.mod"; WEB="$T/proj/web/package-lock.json"
for d in synb synd syn2z syn2a syn3 syng; do mkproj "$d" package-lock.json; done
mk_real() { sed "s|__SRC_GO__|$GO|; s|__SRC_NPM__|$WEB|" "$HG/tests/fixtures/advisory-details.json" > "$1"; }
mk_real "$T/real.json"
scan_real() { links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/real.json"; }

state_pkg() {  # pkg jq-expr → value from the state's render.packages
  jq -r --arg n "$1" ".render.packages[] | select(.pkg==\$n) | $2" "$HIVEGUARD_STATE"
}
rows()     { sed 's#</tr>#</tr>\
#g' "${1:-$REPORT}"; }                                                           # one <tr> per line (a card's rows share a line)
row_of()   { rows | grep -F "<tr id=\"f-$1\">" | head -n1; }                       # the package row
fixcell()  { row_of "$1" | sed -n 's/.*\(<td class="mono fix">.*<\/td>\)<td class="ids">.*/\1/p'; }
idcell()   { row_of "$1" | sed -n 's/.*\(<td class="ids">.*<\/td>\)<td class="act">.*/\1/p'; }
listrow()  { rows | grep -F "id=\"a-f-$1\" hidden" | head -n1; }                   # the advisory list row
advdb()    { grep 'id="advdb"' "${1:-$REPORT}" | sed -n 's/.*<script type="application\/json" id="advdb">\(.*\)<\/script>.*/\1/p'; }
firstsev() { grep -o '<span class="sev [a-z]*">[^<]*' "$REPORT" | head -n1; }
pknames()  { grep -o '<td class="pk">[^<]*' "$REPORT" | sed 's/.*">//' | paste -sd, -; }

# synthetic packages, in the shape of the real fixture (every affected[] entry carries `package`)
aff() {  # name eco type events-json → one affected[] entry
  printf '{"package":{"name":"%s","ecosystem":"%s"},"ranges":[{"type":"%s","events":%s}]}' "$1" "$2" "$3" "$4"
}
bpk() {  # name version eco id affected-array-json → one package object, group severity 5.0
  printf '{"package":{"name":"%s","version":"%s","ecosystem":"%s"},"vulnerabilities":[{"id":"%s","summary":"s %s","affected":%s}],"groups":[{"ids":["%s"],"max_severity":"5.0"}]}' \
    "$1" "$2" "$3" "$4" "$4" "$5" "$4"
}
spk() {  # name sev → npm 1.0.0 package, one advisory, no affected[], group severity $2 ("" = unscored)
  printf '{"package":{"name":"%s","version":"1.0.0","ecosystem":"npm"},"vulnerabilities":[{"id":"GHSA-S000-%s","summary":"sum %s","affected":[]}],"groups":[{"ids":["GHSA-S000-%s"],"max_severity":"%s"}]}' \
    "$1" "$1" "$1" "$1" "$2"
}
dv() {  # id summary details → vulnerability object
  printf '{"id":"%s","summary":"%s","details":"%s","affected":[]}' "$1" "$2" "$3"
}
dpk() {  # name vulnerability-objects groups-json → npm 1.0.0 package
  printf '{"package":{"name":"%s","version":"1.0.0","ecosystem":"npm"},"vulnerabilities":[%s],"groups":%s}' "$1" "$2" "$3"
}
wrap() { printf '{"results":[{"source":{"path":"%s","type":"lockfile"},"packages":[%s]}]}\n' "$1" "$2"; }

# --- A. fixes: the regression fixture ------------------------------------------
scan_real
check "A: x/net fix" "0.60.0" "$(state_pkg golang.org/x/net .fix)"
check "A: vitest fix" "4.1.11" "$(state_pkg vitest .fix)"
check "A: @vitest/mocker fix" "4.1.11" "$(state_pkg @vitest/mocker .fix)"
check "A: nanoid fix" "3.3.18" "$(state_pkg nanoid .fix)"
check "A: x/net id_fix (all five ids)" \
  '{"GO-2026-6603":"0.60.0","GO-2026-6610":"0.60.0","GO-2026-6611":"0.60.0","GO-2026-6612":"0.60.0","GO-2026-6617":"0.60.0"}' \
  "$(state_pkg golang.org/x/net '.id_fix' | jq -S -c .)"
check "A: vitest id_fix" '{"GHSA-82fw-gwwq-j7x9":"4.1.11"}' "$(state_pkg vitest '.id_fix' | jq -S -c .)"
check "A: @vitest/mocker id_fix" '{"GHSA-82fw-gwwq-j7x9":"4.1.11"}' "$(state_pkg @vitest/mocker '.id_fix' | jq -S -c .)"
check "A: nanoid id_fix" '{"GHSA-2v37-7h3g-55p8":"3.3.18"}' "$(state_pkg nanoid '.id_fix' | jq -S -c .)"
check "A: report cells 0.60.0 / 4.1.11 x2 / 3.3.18" "1 2 1" \
  "$(count '<td class="mono fix">0.60.0</td>') $(count '<td class="mono fix">4.1.11</td>') $(count '<td class="mono fix">3.3.18</td>')"
check "A: the old wrong fixes are gone (1.27.2 / 5.0.0-rc.2 / 5.1.6)" "0 0 0" \
  "$(grep -v 'id="advdb"' "$REPORT" | grep -o '1\.27\.2' | wc -l | tr -d ' ') $(grep -v 'id="advdb"' "$REPORT" | grep -o '5\.0\.0-rc\.2' | wc -l | tr -d ' ') $(grep -v 'id="advdb"' "$REPORT" | grep -o '5\.1\.6' | wc -l | tr -d ' ')"
runfix() { jq -r --arg n "$1" '.active[] | select(.pkg==$n) | .fix' "$HIVEGUARD_RUN"; }
check "A: run file active[].fix" "0.60.0 4.1.11 4.1.11 3.3.18" \
  "$(runfix golang.org/x/net) $(runfix vitest) $(runfix @vitest/mocker) $(runfix nanoid)"
check "A: status --json x/net fix" "0.60.0" \
  "$("$HG/bin/hiveguard" status --json </dev/null | jq -r '.active[] | select(.pkg=="golang.org/x/net") | .fix')"

# --- B. comparator and affected[] matching -------------------------------------
SRC_B="$T/proj/synb/package-lock.json"
N_REL='[{"introduced":"6.0.0.beta1"},{"fixed":"6.0.0.beta3"}]'
W_PKG='{"package":{"name":"w","version":"2.0.0","ecosystem":"npm"},"vulnerabilities":[{"id":"GHSA-B000-W001","summary":"w1","affected":['"$(aff w npm SEMVER '[{"introduced":"0"},{"fixed":"2.0.5"}]')"']},{"id":"GHSA-B000-W002","summary":"w2","affected":['"$(aff w npm SEMVER '[{"introduced":"0"},{"fixed":"2.1.0"}]')"']}],"groups":[{"ids":["GHSA-B000-W001","GHSA-B000-W002"],"max_severity":"5.0"}]}'
DJ_AFF='{"package":{"name":"django","ecosystem":"PyPI"},"ranges":[{"type":"ECOSYSTEM","events":[{"introduced":"2.0a1"},{"fixed":"2.0.13"}]},{"type":"ECOSYSTEM","events":[{"introduced":"2.2a1"},{"fixed":"2.2.4"}]}]}'
Q_AFF='{"package":{"name":"q","ecosystem":"npm"},"ranges":[{"type":"SEMVER","events":[{"introduced":"2.1.0"},{"fixed":"4.1.11"}]},{"type":"SEMVER","events":[{"introduced":"5.0.0-beta.1"},{"fixed":"5.0.0-rc.2"}]}]}'
PKGS_B="$(bpk rails 6.0.0.beta2 RubyGems GHSA-B000-0001 "[$(aff rails RubyGems ECOSYSTEM "$N_REL")]"),
$(bpk actionpack 6.0.1 RubyGems GHSA-B000-0002 "[$(aff actionpack RubyGems ECOSYSTEM "$N_REL")]"),
$(bpk Django 2.2.0 PyPI GHSA-B000-0003 "[$DJ_AFF]"),
$(bpk x 1.0.0 npm GHSA-B000-0004 "[$(aff x npm SEMVER '[{"introduced":"0"},{"last_affected":"1.0.0"}]')]"),
$(bpk y 1.0.0 npm GHSA-B000-0005 '[{"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"1.0.1"}]}]}]'),
$(bpk z 1.0.0 npm GHSA-B000-0006 "[$(aff z npm GIT '[{"introduced":"0"},{"fixed":"abc123def"}]')]"),
$(bpk golang.org/x/text 0.3.7 Go GHSA-B000-0007 "[$(aff stdlib Go SEMVER '[{"introduced":"0"},{"fixed":"1.20"}]'),$(aff golang.org/x/text Go SEMVER '[{"introduced":"0"},{"fixed":"0.3.8"}]')]"),
$W_PKG,
$(bpk pre 5.0.0-rc.1 npm GHSA-B000-0009 "[$(aff pre npm SEMVER '[{"introduced":"5.0.0-beta.1"},{"fixed":"5.0.0-rc.2"}]')]"),
$(bpk q 4.1.11 npm GHSA-B000-0010 "[$Q_AFF]")"
wrap "$SRC_B" "$PKGS_B" > "$T/b.json"
jq -e . "$T/b.json" >/dev/null || echo "FAIL B fixture is not valid JSON"
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/b.json"
NONE='<td class="mono fix"><span class="none">—</span></td>'
bcheck() {  # desc pkg expected-fix ("" = none)
  local cell="<td class=\"mono fix\">$3</td>"; [ -z "$3" ] && cell="$NONE"
  check "B: $1 (state)" "$3" "$(state_pkg "$2" .fix)"
  check "B: $1 (report)" "$cell" "$(fixcell "$(h12pkg "$SRC_B" "$2")")"
}
bcheck "rails 6.0.0.beta2 in [beta1, beta3): a pre-release tag compares below its release" rails 6.0.0.beta3
bcheck "actionpack 6.0.1 outside the only span, no fix above it" actionpack ""
bcheck "Django 2.2.0: the 2.2 span, not the 2.0 one" Django 2.2.4
bcheck "x 1.0.0 with last_affected only → no fix" x ""
bcheck "y 1.0.0: an entry without package never matches" y ""
bcheck "z 1.0.0: a GIT range only → no fix" z ""
bcheck "x/text 0.3.7: the stdlib entry is ignored, its own entry used" golang.org/x/text 0.3.8
bcheck "w 2.0.0 with two advisories → the higher fix" w 2.1.0
bcheck "pre 5.0.0-rc.1 in [5.0.0-beta.1, 5.0.0-rc.2)" pre 5.0.0-rc.2
bcheck "q 4.1.11 fallback: no span contains it, the lowest fix above it" q 5.0.0-rc.2
check "B: w id_fix holds both" '{"GHSA-B000-W001":"2.0.5","GHSA-B000-W002":"2.1.0"}' "$(state_pkg w '.id_fix' | jq -S -c .)"
check "B: packages without a fix have an empty id_fix" "{} {} {}" \
  "$(state_pkg x '.id_fix' | jq -c .) $(state_pkg y '.id_fix' | jq -c .) $(state_pkg z '.id_fix' | jq -c .)"

# --- C. no score ---------------------------------------------------------------
scan_real
check "C: no score badges (card head + row + 5 list badges)" "7" "$(count '<span class="sev na">no score</span>')"
check "C: no LOW 0.0" "0" "$(count 'LOW 0\.0')"
check "C: critical tile is 0" "1" "$(count '<div class="n">0</div><div class="l">critical</div>')"
check "C: go marker has no critical" "$T/proj/go${TAB}active${TAB}5 active vulnerabilities" "$(grep "^$T/proj/go$TAB" "$HIVEGUARD_MARKERS")"
check "C: web marker has no critical" "$T/proj/web${TAB}active${TAB}3 active vulnerabilities" "$(grep "^$T/proj/web$TAB" "$HIVEGUARD_MARKERS")"
check "C: scored badges of the real fixture (HIGH 8.2 head+row+list, MED 5.9 2 rows+2 list)" "3 4" \
  "$(count '<span class="sev high">HIGH 8\.2</span>') $(count '<span class="sev med">MED 5\.9</span>')"
SRC_C="$T/proj/syn3/package-lock.json"
wrap "$SRC_C" "$(spk hi 7.5),$(spk ns ""),$(spk md 5.0),$(spk cr 9.1)" > "$T/c1.json"
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/c1.json"
check "C: row order CRIT, HIGH, no score, MED" "cr,hi,ns,md" "$(pknames)"
check "C: card head = the top row (CRIT 9.1)" '<span class="sev crit">CRIT 9.1' "$(firstsev)"
check "C: the critical tile counts only the CRIT" "1" "$(count '<div class="n">1</div><div class="l">critical</div>')"
wrap "$T/proj/syn2z/package-lock.json" "$(spk nz "")" > "$T/c2z.json"
wrap "$T/proj/syn2a/package-lock.json" "$(spk ma 5.0)" > "$T/c2a.json"
jq -s '{results: (.[0].results + .[1].results)}' "$T/c2a.json" "$T/c2z.json" > "$T/c2.json"
reset_scan; rm -f "$REPORT"; scan "$T/c2.json"
check "C: the unscored card comes before the MED card" "syn2z,syn2a" "$(grep -o '<span class="pn">[^<]*' "$REPORT" | sed 's/.*">//' | paste -sd, -)"
check "C: the first card is headed no score" '<span class="sev na">no score' "$(firstsev)"
wrap "$SRC_C" "$(spk ns ""),$(spk hi 7.5)" > "$T/c3.json"
reset_scan; rm -f "$REPORT"; scan "$T/c3.json"
check "C: a card with HIGH + unscored is headed HIGH" '<span class="sev high">HIGH 7.5' "$(firstsev)"
check "C: HIGH + unscored → HIGH row first" "hi,ns" "$(pknames)"

# --- D. descriptions -----------------------------------------------------------
scan_real
S63="HTTP/2 server memory exhaustion due to Trailer headers in net/http"
check "D: render.advisories has the 7 distinct ids" "7" "$(jq '.render.advisories|keys|length' "$HIVEGUARD_STATE")"
check "D: GO-2026-6603 summary" "$S63" "$(jq -r '.render.advisories["GO-2026-6603"].summary' "$HIVEGUARD_STATE")"
check "D: GO-2026-6603 aliases" '["BIT-golang-2026-78659","CVE-2026-78659"]' "$(jq -c '.render.advisories["GO-2026-6603"].aliases' "$HIVEGUARD_STATE")"
check "D: GO-2026-6603 not truncated" "false" "$(jq -r '.render.advisories["GO-2026-6603"].truncated' "$HIVEGUARD_STATE")"
check "D: GO-2026-6603 details > 500 chars" "yes" \
  "$([ "$(jq '.render.advisories["GO-2026-6603"].details|length' "$HIVEGUARD_STATE")" -gt 500 ] && echo yes)"
check "D: advisory entry keys" "aliases,details,summary,truncated" "$(jq -r '.render.advisories["GO-2026-6603"]|keys|join(",")' "$HIVEGUARD_STATE")"
check "D: column header is Advisory, no IDs header" "yes 0" \
  "$([ "$(count '<th>Advisory</th>')" -ge 1 ] && echo yes) $(count '<th>IDs</th>')"
HX="$(h12pkg "$GO" golang.org/x/net)"
check "D: x/net Advisory cell (nothing is new after one scan)" \
  "<td class=\"ids\"><a class=\"\" href=\"https://osv.dev/GO-2026-6603\" target=\"_blank\" rel=\"noopener\">GO-2026-6603</a> <button class=\"advt\" type=\"button\" aria-expanded=\"false\" aria-controls=\"a-f-$HX\" title=\"$S63\"><span class=\"advs\">$S63</span><span class=\"more\">+4 more</span></button></td>" \
  "$(idcell "$HX")"
LIST="$(listrow "$HX")"
check "D: list row: 1 row, 5 <li>, 5 CVE aliases, 5 'fixed in 0.60.0', 5 data-adv" "1 5 5 5 5" \
  "$(count "id=\"a-f-$HX\" hidden") $(cnt_in "$LIST" '<li>') $(cnt_in "$LIST" 'class="alias">CVE-') $(cnt_in "$LIST" 'fixed in 0\.60\.0') $(cnt_in "$LIST" 'data-adv=')"
check "D: list row opens as a hidden full-width row" "1" \
  "$(cnt_in "$LIST" "<tr class=\"adv\" id=\"a-f-$HX\" hidden><td colspan=\"6\"><ul class=\"advl\">")"
check "D: no BIT- alias rendered outside advdb" "0" "$(grep -v 'id="advdb"' "$REPORT" | grep -o 'BIT-golang' | wc -l | tr -d ' ')"
LI1="$(printf '%s\n' "$LIST" | sed 's#</li>#</li>\n#g' | grep -o '<li>.*</li>' | head -n1)"
check "D: first <li> byte for byte" \
  "<li><a class=\"\" href=\"https://osv.dev/GO-2026-6603\" target=\"_blank\" rel=\"noopener\">GO-2026-6603</a><span class=\"alias\">CVE-2026-78659</span><span class=\"sev na\">no score</span><span class=\"sum\">$S63</span><span class=\"afix\">fixed in 0.60.0</span><details class=\"advd\"><summary>details</summary><pre class=\"advtext\" data-adv=\"GO-2026-6603\"></pre></details></li>" \
  "$LI1"
check "D: unscored ids keep scanner order" "GO-2026-6603,GO-2026-6610,GO-2026-6611,GO-2026-6612,GO-2026-6617" "$(printf '%s\n' "$LIST" | ids_of)"
check "D: no NEW badge after one scan" "0" "$(count '<span class="newbadge">NEW</span>')"
check "D: 4 toggles (x/net + 3 npm rows), one '+4 more'" "4 1" "$(count 'class="advt"') $(count '<span class="more">+4 more</span>')"
ADV="$(advdb)"
check "D: advdb parses with jq and holds the 7 ids" "7" "$(printf '%s' "$ADV" | jq 'keys|length' 2>/dev/null)"
check "D: advdb text of GO-2026-6603 is the stored details" "$(jq -r '.render.advisories["GO-2026-6603"].details' "$HIVEGUARD_STATE")" \
  "$(printf '%s' "$ADV" | jq -r '."GO-2026-6603"' 2>/dev/null)"
check "D: advdb is emitted once" "1" "$(count 'id="advdb"')"
check "D: the click and toggle handlers are in the page" "1 1" "$(count "closest('button.advt')") $(count "pre.advtext")"
# new ids: a second scan adds a scored advisory to x/net; it leads and is new
jq '.results[0].packages[0].vulnerabilities += [{"id":"GO-2026-9999","summary":"New thing","aliases":["CVE-2026-9999"],"affected":[{"package":{"name":"golang.org/x/net","ecosystem":"Go"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"0.61.0"}]}]}]}] | .results[0].packages[0].groups += [{"ids":["GO-2026-9999"],"max_severity":"9.0"}]' \
  "$T/real.json" > "$T/real2.json"
scan_real; scan "$T/real2.json"
check "D: new lead Advisory cell (class new, +5 more)" \
  "<td class=\"ids\"><a class=\"new\" href=\"https://osv.dev/GO-2026-9999\" target=\"_blank\" rel=\"noopener\">GO-2026-9999</a> <button class=\"advt\" type=\"button\" aria-expanded=\"false\" aria-controls=\"a-f-$HX\" title=\"New thing\"><span class=\"advs\">New thing</span><span class=\"more\">+5 more</span></button></td>" \
  "$(idcell "$HX")"
LIST="$(listrow "$HX")"
check "D: the new, scored id leads the list" "GO-2026-9999,GO-2026-6603,GO-2026-6610,GO-2026-6611,GO-2026-6612,GO-2026-6617" "$(printf '%s\n' "$LIST" | ids_of)"
check "D: list: one NEW badge, one CRIT 9.0 badge, the new id's own fix" "1 1 1" \
  "$(cnt_in "$LIST" '<span class="newbadge">NEW</span>') $(cnt_in "$LIST" '<span class="sev crit">CRIT 9\.0</span>') $(cnt_in "$LIST" 'fixed in 0\.61\.0')"
check "D: only the new id's link is accented" "1" "$(cnt_in "$LIST" 'class="new"')"
check "D: package fix becomes the highest per-advisory fix" "0.61.0" "$(state_pkg golang.org/x/net .fix)"

# synthetic descriptions fixture
SRC_D="$T/proj/synd/package-lock.json"
BIG="$(awk 'BEGIN{for(i=0;i<1200;i++) printf "word "}')"
PKGS_D="$(dpk esc "$(dv GHSA-D000-ESC1 '<b>x</b>' 'before </script><b>x</b> after')" '[{"ids":["GHSA-D000-ESC1"],"max_severity":"5.0"}]'),
$(dpk fs "$(dv GHSA-D000-FS01 '' 'First sentence. Second.')" '[{"ids":["GHSA-D000-FS01"],"max_severity":"5.0"}]'),
$(dpk nd "$(dv GHSA-D000-ND01 '' '')" '[{"ids":["GHSA-D000-ND01"],"max_severity":"5.0"}]'),
$(dpk big "$(dv GHSA-D000-BIG1 'big one' "$BIG")" '[{"ids":["GHSA-D000-BIG1"],"max_severity":"5.0"}]'),
$(dpk lead "$(dv GHSA-D000-LD01 'low one' 'x'),$(dv GHSA-D000-LD02 'high one' 'y')" '[{"ids":["GHSA-D000-LD01"],"max_severity":"5.0"},{"ids":["GHSA-D000-LD02"],"max_severity":"9.3"}]')"
wrap "$SRC_D" "$PKGS_D" > "$T/d.json"
jq -e . "$T/d.json" >/dev/null || echo "FAIL D fixture is not valid JSON"
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/d.json"
BIGST='.render.advisories["GHSA-D000-BIG1"]'
check "D: 6000-char details stored ≤ 4000" "yes" "$([ "$(jq "$BIGST.details|length" "$HIVEGUARD_STATE")" -le 4000 ] && echo yes)"
check "D: ... flagged truncated, cut at a word end" "true true" "$(jq -r "$BIGST.truncated" "$HIVEGUARD_STATE") $(jq -r "$BIGST.details|endswith(\"word\")" "$HIVEGUARD_STATE")"
ADV="$(advdb)"
check "D: advdb text of the truncated advisory ends with the notice" "true" \
  "$(printf '%s' "$ADV" | jq -r '."GHSA-D000-BIG1"|endswith("… (truncated — full text on osv.dev)")')"
check "D: a short advisory carries no notice" "false" "$(printf '%s' "$ADV" | jq -r '."GHSA-D000-FS01"|endswith("full text on osv.dev)")')"
check "D: </script> in a text is escaped as <\\/script>; the raw sequence is absent" "yes 0" \
  "$([ "$(grep -F -c '<\/script>' "$REPORT")" -ge 1 ] && echo yes) $(grep -F -c '</script><b>' "$REPORT")"
check "D: the escaped table still decodes to the original text" 'before </script><b>x</b> after' "$(printf '%s' "$ADV" | jq -r '."GHSA-D000-ESC1"')"
check "D: HTML in a summary is escaped (no raw <b> outside advdb)" "yes 0" \
  "$([ "$(count '&lt;b&gt;')" -ge 1 ] && echo yes) $(grep -v 'id="advdb"' "$REPORT" | grep -o '<b>' | wc -l | tr -d ' ')"
check "D: empty summary → first sentence of details" 'title="First sentence."><span class="advs">First sentence.</span>' \
  "$(idcell "$(h12pkg "$SRC_D" fs)" | grep -o 'title="First sentence\."><span class="advs">First sentence\.</span>')"
check "D: neither → no description" 'title="no description"><span class="advs">no description</span>' \
  "$(idcell "$(h12pkg "$SRC_D" nd)" | grep -o 'title="no description"><span class="advs">no description</span>')"
HL="$(h12pkg "$SRC_D" lead)"
check "D: lead = highest per-id severity, not the first" "yes" \
  "$(idcell "$HL" | grep -q 'href="https://osv.dev/GHSA-D000-LD02".*title="high one"><span class="advs">high one</span><span class="more">+1 more</span>' && echo yes)"
check "D: list order follows the lead rule" "GHSA-D000-LD02,GHSA-D000-LD01" "$(listrow "$HL" | ids_of)"
check "D: per-id badges in that order" "CRIT 9.3,MED 5.0" \
  "$(listrow "$HL" | grep -o '<span class="sev [a-z]*">[^<]*' | sed 's/.*">//' | paste -sd, -)"

# --- E. legacy layout ----------------------------------------------------------
scan_real
cp "$HIVEGUARD_STATE" "$T/state.full"; cp "$REPORT" "$T/scan.html"
jq 'del(.render.advisories)' "$T/state.full" > "$HIVEGUARD_STATE"
render; check "E: legacy render rc" "0" "$?"
check "E: IDs header, no Advisory header" "yes 0" "$([ "$(count '<th>IDs</th>')" -ge 1 ] && echo yes) $(count '<th>Advisory</th>')"
check "E: no toggle, no list row, no advdb" "0 0 0" "$(count 'class="advt"') $(count '<tr class="adv"') $(count 'id="advdb"')"
check "E: the saved fixes are shown" "1 2 1" \
  "$(count '<td class="mono fix">0.60.0</td>') $(count '<td class="mono fix">4.1.11</td>') $(count '<td class="mono fix">3.3.18</td>')"
check "E: legacy ids cell: 4 links and '+1'" "1" "$(count '<span class="more">+1</span>')"
check "E: no score still applies (head + row, no list)" "2 0" "$(count '<span class="sev na">no score</span>') $(count 'LOW 0\.0')"
cp "$T/state.full" "$HIVEGUARD_STATE"; render
cmp -s "$T/scan.html" "$REPORT"; check "E: restored state → the full report again" "0" "$?"

# --- F. sections ---------------------------------------------------------------
scan_real
"$HG/bin/hiveguard" ack "$WEB" nanoid >/dev/null 2>&1 </dev/null
HN="$(h12pkg "$WEB" nanoid)"
ACKED="$(sed -n '/class="ackwrap"/,$p' "$REPORT")"
check "F: the acked nanoid row has the Advisory toggle" "1" "$(cnt_in "$ACKED" "aria-controls=\"a-f-$HN\"")"
check "F: acked list row has the plain id, no -k twin" "1 0" "$(cnt_in "$ACKED" "id=\"a-f-$HN\" hidden") $(count "id=\"a-f-$HN-k\"")"
check "F: acked list row: 1 <li>, fixed in 3.3.18" "1 1" "$(cnt_in "$(listrow "$HN")" '<li>') $(cnt_in "$(listrow "$HN")" 'fixed in 3\.3\.18')"
check "F: the acked lead link is never accented (cell + list)" "2" "$(cnt_in "$ACKED" '<a class="" href="https://osv.dev/GHSA-2v37-7h3g-55p8"')"
SRC_G="$T/proj/syng/package-lock.json"
wrap "$SRC_G" "$(dpk mp "$(dv GHSA-G000-0001 'first one' 'a'),$(dv GHSA-G000-0002 'second one' 'b')" \
  '[{"ids":["GHSA-G000-0001"],"max_severity":"9.3"},{"ids":["GHSA-G000-0002"],"max_severity":"5.0"}]')" > "$T/g.json"
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/g.json"
printf '{"schema":2,"projects":{},"packages":{"%s":{"mp":{"ids":["GHSA-G000-0001"],"since":"x"}}}}\n' "$SRC_G" > "$HIVEGUARD_ACKS"
render; check "F: partial ack render rc" "0" "$?"
HM="$(h12pkg "$SRC_G" mp)"
check "F: active list row a-f-<h12> and acked twin a-f-<h12>-k" "1 1" "$(count "id=\"a-f-$HM\" hidden") $(count "id=\"a-f-$HM-k\" hidden")"
check "F: the twin's toggle points at the -k row" "1" "$(count "aria-controls=\"a-f-$HM-k\"")"
check "F: active row lists the remaining id, the twin the acked one" "GHSA-G000-0002 GHSA-G000-0001" "$(listrow "$HM" | ids_of) $(listrow "$HM-k" | ids_of)"
rm -f "$HOME/.hiveguard/osv-probe.html"
STUB_JSON="$T/real.json" "$HG/bin/osv-daily" --probe "$T/proj/web" >/dev/null 2>&1 </dev/null
PROBE="$HOME/.hiveguard/osv-probe.html"
check "F: the probe report has the Advisory column, advdb and a toggle" "yes 1 yes" \
  "$([ "$(count '<th>Advisory</th>' "$PROBE")" -ge 1 ] && echo yes) $(count 'id="advdb"' "$PROBE") $([ "$(count 'class="advt"' "$PROBE")" -ge 1 ] && echo yes)"

# --- G. the pierced row's label ------------------------------------------------
# state of F's partial ack is still in place: mp is muted for GHSA-G000-0001, GHSA-G000-0002 pierces it
TIP='A new advisory appeared in a package you had muted. Mark it as known too (asks for confirmation).'
links_off; render
check "G: app off → mute button, muted badge" "1 1" "$(count '>mute</button>') $(count 'class="mutedbadge"')"
check "G: app off → the old label is gone" "0" "$(count "$OLDLABEL")"
links_on; render
check "G: app on → mark as known link with the new tooltip" "1" \
  "$(count "title=\"$TIP\" target=\"_blank\" rel=\"noopener\">mark as known</a>")"
check "G: app on → it is the package ack link" "1" "$(grep -o "href=\"hiveguard://ack?[^\"]*\" title=\"$TIP\"" "$REPORT" | wc -l | tr -d ' ')"
check "G: app on → neither the old label nor the old tooltip" "0 0" "$(count "$OLDLABEL") $(count 'Fold the new advisory')"
links_off

# --- H. render parity and state shape ------------------------------------------
scan_real
cp "$REPORT" "$T/scan.html"
render; check "H: render rc" "0" "$?"
cmp -s "$T/scan.html" "$REPORT"; check "H: --render is byte-identical to the scan's report" "0" "$?"
check "H: package record keys" "eco,fix,id_fix,id_sev,ids,maxsev,new_ids,pkg,root,src,version" \
  "$(jq -r '.render.packages[0]|keys|join(",")' "$HIVEGUARD_STATE")"
check "H: render block keys" "advisories,packages,scan_targets,schema" "$(jq -r '.render|keys|join(",")' "$HIVEGUARD_STATE")"
check "H: render.schema stays 1" "1" "$(jq -r '.render.schema' "$HIVEGUARD_STATE")"
check "H: run file keys unchanged" "active,counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen" \
  "$(jq -r 'keys|join(",")' "$HIVEGUARD_RUN")"
check "H: no .tmp left" "0" "$(ls "$HOME/.hiveguard" | grep -c '\.tmp$')"

exit "$FAILED"

#!/usr/bin/env bash
# strict-cli.test.sh — bin/strict-mode (hiveguard strict …) in full isolation.
#
# Everything runs against a throwaway HOME and the HIVEGUARD_* overrides, so the
# real ~/.hiveguard, the real ~/.zshrc and the real launchd agent are never
# touched. No scan is ever run: _bgscan is only exercised via --dry-run.
# bash 3.2 compatible (no associative arrays, no empty-array expansion under -u).
set -uo pipefail          # deliberately not -e: a failed check must not abort

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SM="$REPO/bin/strict-mode"

FAILS=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() {  # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1
       expected: [$2]
       got:      [$3]"; fi
}
check_contains() {  # label needle haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1
       expected to contain: [$2]
       got:                 [$3]" ;;
  esac
}

# --- isolated scaffold -------------------------------------------------------
# mktemp -d hands back /var/folders/… which is a symlink to /private/var/…;
# strict-mode canonicalises every root, so canonicalise the temp root once.
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
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
mkdir -p "$T/proj/app/.git" "$T/proj/app/sub" "$T/elsewhere/x/.git"

# --- on / off / config -------------------------------------------------------
check "status defaults to off" \
  "Strict mode: off  (enable: hiveguard strict on)" "$("$SM" status | head -n1)"

check "on: headline" \
  "✔ Strict mode on — flagged (red) projects refuse to run/build/install until you fix or pause them." \
  "$("$SM" on | head -n1)"
check "on: states the honest scope" 1 "$("$SM" on | grep -c 'cannot stop an IDE Run button')"
check "on: writes strict=1" 1 "$(grep -c '^strict=1$' "$HIVEGUARD_CONFIG")"
check "on: preserves other config keys" 1 "$(grep -c '^mark_finder=0$' "$HIVEGUARD_CONFIG")"
check "on: reports the hook is not sourced" 1 \
  "$("$SM" on | grep -c 'Terminal hook: not sourced in ~/.zshrc')"
if [ "$("$SM" on | grep -c 'hiveguard-hook.zsh')" -ge 1 ]; then
  ok "on: prints the source line for ~/.zshrc"
else
  bad "on: prints the source line for ~/.zshrc"
fi
check "on: never writes ~/.zshrc" "absent" \
  "$([ -e "$HOME/.zshrc" ] && echo present || echo absent)"

check "off: headline" \
  "✔ Strict mode off. Open terminals stop blocking at their next prompt." \
  "$("$SM" off | head -n1)"
check "off: writes strict=0" 1 "$(grep -c '^strict=0$' "$HIVEGUARD_CONFIG")"
check "off: replaces the key, never appends" 1 "$(grep -c '^strict=' "$HIVEGUARD_CONFIG")"

"$SM" on >/dev/null

# --- pause -------------------------------------------------------------------
printf '%s\tactive\t12 active vulnerabilities (2 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"

out="$( cd "$T/proj/app/sub" && "$SM" pause )"
check_contains "pause: headline names the root and the duration" \
  "✔ Strict mode paused for $T/proj/app until " "$(printf '%s' "$out" | head -n1)"
check_contains "pause: headline ends with the reassurance" \
  "(1h). Other projects stay protected." "$(printf '%s' "$out" | head -n1)"
check_contains "pause: prints how to lift it early" \
  "  lift early: hiveguard strict resume \"$T/proj/app\"" "$out"
check "pause: from a subdir resolves to the innermost marker root" \
  "$T/proj/app" "$(cut -f1 "$HIVEGUARD_PAUSES")"
check "pause: default duration is one hour" "one-hour" \
  "$(awk -F'\t' -v now="$(date +%s)" '{d=$2-now; if (d>3590 && d<=3600) print "one-hour"}' "$HIVEGUARD_PAUSES")"

( cd "$T/proj/app" && "$SM" pause --for 2h ) >/dev/null
check "pause --for 2h: two hours from now" "two-hours" \
  "$(awk -F'\t' -v now="$(date +%s)" '{d=$2-now; if (d>7190 && d<=7200) print "two-hours"}' "$HIVEGUARD_PAUSES")"
check "pause: re-pausing upserts, never appends" 1 "$(wc -l < "$HIVEGUARD_PAUSES" | tr -d ' ')"

"$SM" pause "$T/proj/app" --for 90 >/dev/null 2>&1
check "pause: a unitless duration is a usage error" 2 "$?"
check "pause: the duration error names the accepted forms" \
  "invalid --for: 90  (use 30m, 2h, 1d)" \
  "$("$SM" pause "$T/proj/app" --for 90 2>&1 >/dev/null)"
for badur in 2w "" h -1h 2H; do
  "$SM" pause "$T/proj/app" --for "$badur" >/dev/null 2>&1
  check "pause: --for '$badur' is rejected" 2 "$?"
done

check "pause: an unflagged root is allowed, with a note" 1 \
  "$("$SM" pause "$T/elsewhere/x" | grep -c 'not currently flagged')"
check "pause: an unflagged .git root resolves to itself" \
  "$T/elsewhere/x
$T/proj/app" "$(cut -f1 "$HIVEGUARD_PAUSES" | sort)"

# --- status ------------------------------------------------------------------
check "status: on" "Strict mode: on" "$("$SM" status | head -n1)"
check "status: lists every running pause" 2 \
  "$("$SM" status | sed -n '/^Paused:/,$p' | grep -c 'until .* min left)')"
check "status: lists the blocked root" 1 \
  "$("$SM" status | sed -n '/^Blocked (red) projects:/,/^Paused:/p' | grep -c "$T/proj/app")"
check "status: counts the blocked roots" "Blocked (red) projects: 1" \
  "$("$SM" status | grep '^Blocked (red) projects:')"

# --- resume ------------------------------------------------------------------
check "resume: lifts the pause" "✔ Pause lifted for $T/proj/app." \
  "$("$SM" resume "$T/proj/app")"
check "resume: says so when there is nothing to lift" "No pause active for $T/proj/app." \
  "$("$SM" resume "$T/proj/app")"
check "resume: exits 0 with nothing to lift" 0 "$("$SM" resume "$T/proj/app" >/dev/null; echo $?)"
check "resume --all: confirms" "✔ All pauses lifted." "$("$SM" resume --all)"
check "resume --all: empties the file" 0 "$(wc -l < "$HIVEGUARD_PAUSES" | tr -d ' ')"

printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s) - 5 ))" > "$HIVEGUARD_PAUSES"
"$SM" status >/dev/null
check "status: prunes expired pause rows" 0 "$(wc -l < "$HIVEGUARD_PAUSES" | tr -d ' ')"
check "status: says (none) with no pauses left" 1 \
  "$("$SM" status | sed -n '/^Paused:/,$p' | grep -c '(none)')"

# --- _bgscan (dry run only — a real scan is never started here) ---------------
check "_bgscan: no schedule at all → probe" "probe $T/proj/app" \
  "$("$SM" _bgscan --dry-run "$T/proj/app")"

cat > "$HIVEGUARD_SCHED_PLIST" <<EOF
<plist><dict><key>ProgramArguments</key><array><string>/x/hiveguard</string><string>daily</string><string>$T/proj</string><string>--if-due</string></array></dict></plist>
EOF
check "_bgscan: under a scheduled folder → rescan" "rescan" \
  "$("$SM" _bgscan --dry-run "$T/proj/app")"
check "_bgscan: a scheduled folder itself → rescan" "rescan" \
  "$("$SM" _bgscan --dry-run "$T/proj")"
check "_bgscan: outside every scheduled folder → probe" "probe $T/elsewhere/x" \
  "$("$SM" _bgscan --dry-run "$T/elsewhere/x")"

# the same extraction must also cope with the multi-line plist daily-schedule
# actually writes, including a scheduled folder whose path contains a space
mkdir -p "$T/other dir/p"
cat > "$HIVEGUARD_SCHED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.hiveguard.osv-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/hiveguard</string>
    <string>daily</string>
    <string>$T/other dir</string>
    <string>--if-due</string>
  </array>
</dict>
</plist>
EOF
check "_bgscan: real plist layout, folder with a space → rescan" "rescan" \
  "$("$SM" _bgscan --dry-run "$T/other dir/p")"
check "_bgscan: real plist layout, unrelated root → probe" "probe $T/proj/app" \
  "$("$SM" _bgscan --dry-run "$T/proj/app")"
"$SM" _bgscan --dry-run >/dev/null 2>&1
check "_bgscan: a missing root is a usage error" 2 "$?"
check "_bgscan --dry-run: starts no scan and writes no log" "absent" \
  "$([ -e "$HOME/.hiveguard/strict.log" ] && echo present || echo absent)"

# --- usage -------------------------------------------------------------------
"$SM" bogus >/dev/null 2>&1
check "an unknown verb is a usage error" 2 "$?"
check "the unknown-verb message points at --help" \
  "unknown verb: bogus (see: hiveguard strict --help)" "$("$SM" bogus 2>&1 >/dev/null)"
if [ "$("$SM" --help | grep -c 'hiveguard strict pause')" -ge 1 ]; then
  ok "--help renders the verb table"
else
  bad "--help renders the verb table"
fi

# --- isolation ---------------------------------------------------------------
check "nothing leaked outside the test HOME" "absent" \
  "$([ -e "$HOME/Library/LaunchAgents" ] && echo present || echo absent)"

if [ "$FAILS" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$FAILS"
  exit 1
fi
printf '\nall strict-cli checks passed\n'
exit 0

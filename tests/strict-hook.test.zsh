#!/usr/bin/env zsh
# strict-hook.test.zsh — tests for bin/hiveguard-strict.zsh (strict mode's zsh guard).
#
# Run:  zsh -f tests/strict-hook.test.zsh
#
# Self-contained: builds its own isolated HOME under mktemp and points every
# HIVEGUARD_* override at it, so the real ~/.hiveguard, the real ~/.zshrc and the
# launchd label com.hiveguard.osv-daily are never touched. The dispatcher the
# guard would call for a background scan is stubbed via HIVEGUARD_BIN, so no
# scan, no network and no notification ever happen here.
#
# Prints `ok <name>` / `FAIL <name>` per check; exits non-zero if anything failed.

emulate -L zsh
setopt no_unset

typeset -g REPO="${0:A:h:h}"
typeset -g STRICT="$REPO/bin/hiveguard-strict.zsh"
typeset -g HOOK="$REPO/bin/hiveguard-hook.zsh"
typeset -g BUMBLEBEE="$REPO/bin/bumblebee-guard.sh"

# --- isolated scaffold -------------------------------------------------------
# mktemp -d hands back a /var/folders path that is a symlink to /private/var; the
# guard canonicalises $PWD with ${PWD:A}, so canonicalise the root once here too.
typeset -g T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$T"' EXIT INT TERM

export HOME="$T/home"
mkdir -p "$HOME/.hiveguard"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"
export HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv"
export HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json"
export HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_SCHED_PLIST="$T/no-such.plist"

mkdir -p "$T/stubs" "$T/proj/app/.git" "$T/proj/app/sub" "$T/elsewhere/x/.git" "$T/loose/dir"
print -r -- '#!/bin/sh
echo "REAL npm $*"' > "$T/stubs/npm"
print -r -- '#!/bin/sh
echo "$@" >> '"$T"'/bgcalls' > "$T/stubs/hg"
chmod +x "$T/stubs/npm" "$T/stubs/hg"
export PATH="$T/stubs:/usr/bin:/bin"
export HIVEGUARD_BIN="$T/stubs/hg"

typeset -gi FAILED=0

ok()   { print -r -- "ok $1" }
bad()  { print -r -- "FAIL $1"; [[ -n ${2:-} ]] && print -r -- "     $2"; FAILED=1 }
is()   { # name expected actual
  if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
contains() { # name haystack needle
  if [[ $2 == *$3* ]]; then ok "$1"; else bad "$1" "[$2] does not contain [$3]"; fi
}
lacks() { # name haystack needle
  if [[ $2 != *$3* ]]; then ok "$1"; else bad "$1" "[$2] unexpectedly contains [$3]"; fi
}

typeset -g ZOUT="" ZERR=""
zrun() { # zsh -f -c "$1"; stdout in $ZOUT, stderr in $ZERR
  ZOUT="$(zsh -f -c "$1" 2>"$T/err")"
  ZERR=""
  # `cat`, not $(<file): `zsh -n` on this script evaluates $(<…) for real.
  [[ -s $T/err ]] && ZERR="$(cat "$T/err")"
  return 0
}

cfg()      { print -r -- "$1" > "$HIVEGUARD_CONFIG" }
markers()  { print -rn -- "$1" > "$HIVEGUARD_MARKERS" }
now()      { print -r -- $EPOCHSECONDS }
zmodload -i zsh/datetime

# =============================================================================
# A. OFF is a true no-op: nothing defined, the real command runs, no files made
# =============================================================================
cfg 'mark_finder=0'
zrun "source $STRICT; (( \${+functions[npm]} )) && print DEFINED || print undefined; cd $T/proj/app; npm test; print rc=\$?"
is "A/off: npm undefined + real command + rc 0" 'undefined
REAL npm test
rc=0' "$ZOUT"
is "A/off: no state files created" 'config' "$(ls "$HOME/.hiveguard")"

# =============================================================================
# B. ON + red marker → refused with 77, stub not run, message on stderr only
# =============================================================================
cfg 'mark_finder=0
strict=1'
markers "$T/proj/app	active	12 active vulnerabilities (2 critical)
"
zrun "source $STRICT; cd $T/proj/app/sub; npm install left-pad; print rc=\$?"
is       "B/red: exit 77" 'rc=77' "$ZOUT"
lacks    "B/red: the real npm never ran" "$ZOUT" 'REAL npm'
contains "B/red: summary + root + command on stderr" "${ZERR%%$'\n'*}" \
         "12 active vulnerabilities (2 critical) in $T/proj/app — refusing to run \`npm\`"
contains "B/red: says how to see detail" "$ZERR" 'hiveguard daily --open'
contains "B/red: offers the pause" "$ZERR" 'hiveguard strict pause'

# =============================================================================
# C. No repair exemption — the gate never looks at the arguments
# =============================================================================
zrun "source $STRICT; cd $T/proj/app; npm update; print rc=\$?; npm audit fix; print rc=\$?"
is "C: npm update and npm audit fix are refused too" 'rc=77
rc=77' "$ZOUT"

# =============================================================================
# D. acked → runs
# =============================================================================
markers "$T/proj/app	acked	3 acknowledged
"
zrun "source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "D/acked: runs" 'REAL npm test
rc=0' "$ZOUT"

# =============================================================================
# Innermost marker root wins (same rule as the chpwd reminder)
# =============================================================================
markers "$T/proj	acked	outer acked
$T/proj/app	active	inner is red
"
zrun "source $STRICT; cd $T/proj/app/sub; npm test; print rc=\$?"
is "innermost: inner active beats outer acked" 'rc=77' "$ZOUT"
markers "$T/proj	active	outer is red
$T/proj/app	acked	inner acked
"
zrun "source $STRICT; cd $T/proj/app/sub; npm test; print rc=\$?"
is "innermost: inner acked beats outer active" 'REAL npm test
rc=0' "$ZOUT"

# =============================================================================
# E. A running pause releases the project; an expired one does not
# =============================================================================
markers "$T/proj/app	active	12 active vulnerabilities
"
print -r -- "$T/proj/app	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
zrun "source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "E/pause: running pause → runs" 'REAL npm test
rc=0' "$ZOUT"
print -r -- "$T/proj/app	$(( $(now) - 1 ))" > "$HIVEGUARD_PAUSES"
zrun "source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "E/pause: expired pause → refused" 'rc=77' "$ZOUT"
# A pause for a DIFFERENT root must not release this one.
print -r -- "$T/elsewhere/x	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
zrun "source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "E/pause: another project's pause does not apply" 'rc=77' "$ZOUT"

# =============================================================================
# F. No marker + fresh coverage → runs silently, no attempts row, no bg scan
# =============================================================================
: > "$HIVEGUARD_MARKERS"
rm -f "$HIVEGUARD_PAUSES" "$HIVEGUARD_STRICT_ATTEMPTS" "$T/bgcalls"
print -r -- "$T/proj	$(now)" > "$HIVEGUARD_COVERAGE"
zrun "source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "F/known-clean: runs" 'REAL npm test
rc=0' "$ZOUT"
is "F/known-clean: silent" '' "$ZERR"
if [[ ! -e $HIVEGUARD_STRICT_ATTEMPTS && ! -e $T/bgcalls ]]; then
  ok "F/known-clean: no attempts row, no background scan"
else
  bad "F/known-clean: no attempts row, no background scan" "files were created"
fi

# =============================================================================
# G. Stale coverage → unknown: runs, one attempt row, one bg scan, debounced
# =============================================================================
print -r -- "$T/proj	$(( $(now) - 700000 ))" > "$HIVEGUARD_COVERAGE"
zrun "source $STRICT; cd $T/proj/app/sub; npm test; print rc=\$?; npm test; print rc=\$?"
is "G/unknown: both attempts run" 'REAL npm test
rc=0
REAL npm test
rc=0' "$ZOUT"
sleep 1
is "G/unknown: exactly one background scan, root = nearest .git ancestor" \
   "strict _bgscan $T/proj/app" "$(cat "$T/bgcalls")"
is "G/unknown: one attempts row" "$T/proj/app" "$(cut -f1 "$HIVEGUARD_STRICT_ATTEMPTS")"

# =============================================================================
# H. No .git anywhere above the cwd → the root is the cwd itself
# =============================================================================
zrun "source $STRICT; cd $T/loose/dir; npm test >/dev/null; print rc=\$?"
is "H/unknown: runs" 'rc=0' "$ZOUT"
sleep 1
is "H/unknown: root falls back to the cwd" "strict _bgscan $T/loose/dir" \
   "$(tail -n1 "$T/bgcalls")"

# =============================================================================
# I. The hot path does not fork — any fork dies under `ulimit -u 1`
# =============================================================================
markers "$T/proj/app	active	1 active vulnerabilities
"
zrun "ulimit -u 1; source $STRICT; cd $T/proj/app; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "I/no-fork: blocked path" 'rc=77
alive' "$ZOUT"
print -r -- "$T/proj/app	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
zrun "ulimit -u 1; source $STRICT; cd $T/proj/app; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "I/no-fork: paused path" 'rc=0
alive' "$ZOUT"
markers "$T/proj/app	acked	3 acknowledged
"
zrun "ulimit -u 1; source $STRICT; cd $T/proj/app; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "I/no-fork: acked path" 'rc=0
alive' "$ZOUT"
: > "$HIVEGUARD_MARKERS"
print -r -- "$T/proj	$(now)" > "$HIVEGUARD_COVERAGE"
zrun "ulimit -u 1; source $STRICT; cd $T/proj/app; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "I/no-fork: known-clean path" 'rc=0
alive' "$ZOUT"
zrun "ulimit -u 1; PATH=/var/empty; source $STRICT; cd $T/proj/app; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "I/no-fork: nothing external is reachable at all" 'rc=0
alive' "$ZOUT"
# The detector itself must be real: a genuine fork has to die here.
zrun 'ulimit -u 1; x=$(/bin/echo hi); print alive'
lacks "I/no-fork: the ulimit detector actually catches a fork" "$ZOUT" 'alive'

# =============================================================================
# J. Composes with the bumblebee guard in BOTH source orders
# =============================================================================
markers "$T/proj/app	active	1 active vulnerabilities
"
rm -f "$HIVEGUARD_PAUSES"
zrun "source $BUMBLEBEE; source $STRICT; cd $T/proj/app; npm test; print rc=\$?
[[ \$functions[npm] == *_hiveguard_strict_gate* ]] && print wrapped
[[ \$functions[_hiveguard_strict_orig_npm] == *_bb_node_guard* ]] && print bb-preserved"
is "J/bumblebee-first: blocked, wrapped, bumblebee preserved" 'rc=77
wrapped
bb-preserved' "$ZOUT"
zrun "source $STRICT; source $BUMBLEBEE
[[ \$functions[npm] == *_hiveguard_strict_gate* ]] || print overwritten-as-expected
for f in \$precmd_functions; do \$f; done
cd $T/proj/app; npm test; print rc=\$?
[[ \$functions[_hiveguard_strict_orig_npm] == *_bb_node_guard* ]] && print bb-preserved"
is "J/strict-first: the precmd hook repairs the wrapper" 'overwritten-as-expected
rc=77
bb-preserved' "$ZOUT"
# Clean project: the gate proceeds and bumblebee's own pass-through reaches npm.
: > "$HIVEGUARD_MARKERS"
print -r -- "$T/proj	$(now)" > "$HIVEGUARD_COVERAGE"
zrun "source $BUMBLEBEE; source $STRICT; cd $T/proj/app; npm test; print rc=\$?"
is "J/clean: both guards pass through to the real npm" 'REAL npm test
rc=0' "$ZOUT"

# =============================================================================
# K. `strict off` mid-session restores bumblebee's function body byte-for-byte
# =============================================================================
zrun "source $BUMBLEBEE; orig=\$functions[npm]; source $STRICT
print -r -- 'mark_finder=0
strict=0' > \$HIVEGUARD_CONFIG
_hiveguard_strict_sync
[[ \$functions[npm] == \$orig ]] && print restored
(( \${+functions[_hiveguard_strict_orig_npm]} )) || print orig-gone"
is "K/off: bumblebee restored byte-for-byte, copy removed" 'restored
orig-gone' "$ZOUT"
# Without bumblebee the function must disappear entirely.
cfg 'mark_finder=0
strict=1'
zrun "source $STRICT; (( \${+functions[npm]} )) && print wrapped
print -r -- 'mark_finder=0
strict=0' > \$HIVEGUARD_CONFIG
_hiveguard_strict_sync
(( \${+functions[npm]} )) || print gone"
is "K/off: a wrapper we invented is removed, not left behind" 'wrapped
gone' "$ZOUT"

# =============================================================================
# L. The existing hook sources the sibling; sourcing twice is a no-op
# =============================================================================
cfg 'mark_finder=0
strict=1'
zrun "source $HOOK; source $HOOK
(( \${+functions[_hiveguard_strict_gate]} )) && print via-hook
(( \${+functions[npm]} )) && print wrapped
print hooks=\${#\${(M)precmd_functions:#_hiveguard_strict_sync}}"
is "L/hook: sibling sourced, wrappers installed, one precmd hook only" 'via-hook
wrapped
hooks=1' "$ZOUT"
zrun "source $STRICT; source $STRICT; print loaded=\$_HIVEGUARD_STRICT_LOADED
print hooks=\${#\${(M)precmd_functions:#_hiveguard_strict_sync}}"
is "L/strict: a second source of the guard is a no-op" 'loaded=1
hooks=1' "$ZOUT"

# =============================================================================
# strict_commands_extra extends the intercepted set (and `off` unwraps it)
# =============================================================================
cfg 'mark_finder=0
strict=1
strict_commands_extra=foo bar'
markers "$T/proj/app	active	1 active vulnerabilities
"
zrun "source $STRICT; (( \${+functions[foo]} )) && print foo-wrapped
(( \${+functions[bar]} )) && print bar-wrapped
cd $T/proj/app; foo --whatever; print rc=\$?"
is "extra: configured names are wrapped and gated" 'foo-wrapped
bar-wrapped
rc=77' "$ZOUT"
zrun "source $STRICT; print -r -- 'mark_finder=0
strict=0' > \$HIVEGUARD_CONFIG
_hiveguard_strict_sync
(( \${+functions[foo]} )) || print foo-gone"
is "extra: turning strict off unwraps the extra names too" 'foo-gone' "$ZOUT"
# Dropping a name from the config unwraps just that name.
cfg 'mark_finder=0
strict=1
strict_commands_extra=foo'
zrun "source $STRICT; (( \${+functions[foo]} )) && print foo-wrapped
print -r -- 'mark_finder=0
strict=1' > \$HIVEGUARD_CONFIG
_hiveguard_strict_sync
(( \${+functions[foo]} )) || print foo-gone
(( \${+functions[npm]} )) && print npm-still-wrapped"
is "extra: a name removed from the config is unwrapped, the defaults stay" 'foo-wrapped
foo-gone
npm-still-wrapped' "$ZOUT"

# =============================================================================
if (( FAILED )); then
  print -r -- "FAILED"
  exit 1
fi
print -r -- "all strict-hook checks passed"
exit 0

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
# Target-aware fixtures: a red project `A` = $T/proj/app with files to point at,
# a venv-style `python` symlink that resolves OUT of the project (like a real
# venv), a node_modules/.bin binary, and a project inside the fake home.
mkdir -p "$T/tmp" "$T/proj/app/tools" "$T/proj/app/.venv/bin" "$T/proj/app/node_modules/.bin" \
         "$T/proj/tools" "$T/home/red/.git"
: > "$T/proj/app/tools/x.py"; : > "$T/proj/app/requirements.txt"; : > "$T/proj/tools/y.py"
print -r -- '#!/bin/sh
echo "REAL python $*"' > "$T/stubs/python"
print -r -- '#!/bin/sh
echo "REAL pip $*"' > "$T/stubs/pip"
chmod +x "$T/stubs/python" "$T/stubs/pip"
ln -s "$T/stubs/python" "$T/proj/app/.venv/bin/python"      # a real venv is a symlink out
cp "$T/stubs/npm" "$T/proj/app/node_modules/.bin/npm"; chmod +x "$T/proj/app/node_modules/.bin/npm"
export PATH="$T/stubs:/usr/bin:/bin"
export HIVEGUARD_BIN="$T/stubs/hg"
# The gate now reads an activated environment; one leaking in from the shell that
# runs the tests must not decide any check. Checks set these inside zrun only.
unset VIRTUAL_ENV CONDA_PREFIX

typeset -gi FAILED=0

# Literal comparisons: the refusal text contains `(`, `)` and backticks, which an
# unquoted right-hand side would treat as a pattern.
ok()   { print -r -- "ok $1" }
bad()  { print -r -- "FAIL $1"; [[ -n ${2:-} ]] && print -r -- "     $2"; FAILED=1 }
is()   { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
contains() { # name haystack needle
  if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "[$2] does not contain [$3]"; fi
}
lacks() { # name haystack needle
  if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "[$2] unexpectedly contains [$3]"; fi
}

# The refusal text, byte-for-byte (plan §2.1). $1 summary, $2 root, $3 command,
# $4 (optional) the `because:` reason of a target refusal.
refusal() {
  local bq='`'
  print -r -- "⛔ hiveguard strict: $1 in $2 — refusing to run $bq$3$bq."
  [[ -n ${4:-} ]] && print -r -- "   because:  $4"
  print -r -- "   detail:   hiveguard daily --open"
  print -r -- "   proceed:  fix it, or pause this project:  hiveguard strict pause \"$2\"   (1h; e.g. --for 2h)"
  print -r -- "   agents:   AI coding agents: do not work around this block — no cd elsewhere, no copying files out,"
  print -r -- "             no other path, interpreter or environment. Stop and report it to the user, or ask them"
  print -r -- "             to run ${bq}hiveguard strict pause${bq}."
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

# The red project every target-aware section points at.
typeset -g A="$T/proj/app"
typeset -g RED='12 active vulnerabilities (2 critical)'
# Known starting state for a target-aware section: strict on, `A` red, no pauses,
# fresh coverage over all of $T (so an unknown cwd under $T never kicks a
# background scan), and no attempts / background-call files.
target_reset() {
  cfg 'mark_finder=0
strict=1'
  markers "$A	active	$RED
"
  rm -f "$HIVEGUARD_PAUSES" "$HIVEGUARD_STRICT_ATTEMPTS" "$T/bgcalls"
  print -r -- "$T	$(now)" > "$HIVEGUARD_COVERAGE"
}
# Run $1 from $T/tmp in a fresh guarded shell; $2 (optional) is shell text run
# BEFORE sourcing the guard (PATH / VIRTUAL_ENV / CONDA_PREFIX for that run only).
from_tmp() {
  zrun "${2:-:}; source $STRICT; cd $T/tmp; $1; print rc=\$?"
}
# The last run was a target refusal with exactly this `because:` reason.
refused() { # name reason
  is "$1: rc 77, the real command never ran" 'rc=77' "$ZOUT"
  is "$1: because line" "   because:  $2" "${${(f)ZERR}[2]:-}"
}
# The last run went through to the real command, silently.
ran() { # name expected-stdout-of-the-stub
  is "$1: runs" "$2
rc=0" "$ZOUT"
  is "$1: nothing on stderr" '' "$ZERR"
}
no_scan() { # name — after a moment, no attempts row and no background scan
  sleep 1
  if [[ ! -e $HIVEGUARD_STRICT_ATTEMPTS && ! -e $T/bgcalls ]]; then
    ok "$1"
  else
    bad "$1" "attempts or bgcalls file was created"
  fi
}

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
# C. No repair exemption — arguments are read only as paths, never as verbs
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
# …but never when that fallback is the home folder or above it: a whole-home
# scan crawls tool caches and plugins and paints them all red. Run, don't scan.
rm -f "$HIVEGUARD_STRICT_ATTEMPTS" "$T/bgcalls"
zrun "source $STRICT; cd \$HOME; npm test >/dev/null; print rc=\$?; cd /; npm test >/dev/null; print rc=\$?"
is "H/home: runs from the home folder and from /" 'rc=0
rc=0' "$ZOUT"
sleep 1
if [[ ! -e $HIVEGUARD_STRICT_ATTEMPTS && ! -e $T/bgcalls ]]; then
  ok "H/home: no attempts row, no background scan"
else
  bad "H/home: no attempts row, no background scan" "files were created"
fi

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

# S. Every target-aware path is fork-free too.
target_reset
zrun "ulimit -u 1; source $STRICT; cd $T/tmp; _hiveguard_strict_gate python $A/tools/x.py; print rc=\$?; print alive"
is "S/no-fork: argument refusal" 'rc=77
alive' "$ZOUT"
zrun "ulimit -u 1; PATH=$A/.venv/bin:$T/stubs:/usr/bin:/bin; source $STRICT; cd $T/tmp; _hiveguard_strict_gate python -c 1; print rc=\$?; print alive"
is "S/no-fork: executable refusal" 'rc=77
alive' "$ZOUT"
zrun "ulimit -u 1; VIRTUAL_ENV=$A/.venv; source $STRICT; cd $T/tmp; _hiveguard_strict_gate npm test; print rc=\$?; print alive"
is "S/no-fork: environment refusal" 'rc=77
alive' "$ZOUT"
# 40 arguments, many of them existing paths (., .., ~, the cwd) outside any root.
manyargs="test a b c --x=y --prefix=$T/tmp . .. ~ $T/tmp/nope"
manyargs="$manyargs $manyargs $manyargs $manyargs"
zrun "ulimit -u 1; source $STRICT; cd $T/tmp; _hiveguard_strict_gate npm $manyargs; print rc=\$?; print alive"
is "S/no-fork: a clean run with 40 arguments" 'rc=0
alive' "$ZOUT"

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
# M. Shell snapshots (Claude Code): the wrapper survives without its helpers
# =============================================================================
# Claude Code never sources ~/.zshrc per command. It replays a snapshot of the
# shell's functions, dropping every name that starts with a single `_` (it
# treats them as completion functions), and carries no globals or zmodloads.
# So the snapshot has `npm` but neither the gate nor its state. Mimic that.
snapshot() { # $1 = setup to source, $2 = snapshot file
  zrun "$1
for f in \${(ko)functions}; do [[ \$f == _[^_]* ]] || typeset -f -- \$f; done > $2"
}
cfg 'mark_finder=0
strict=1'
markers "$T/proj/app	active	1 active vulnerabilities
"
rm -f "$HIVEGUARD_PAUSES"
snapshot "source $STRICT" "$T/snap.zsh"
zrun "source $T/snap.zsh; cd $T/proj/app; npm test; print rc=\$?"
is "M/snapshot: a red project is still refused" 'rc=77' "$ZOUT"
lacks "M/snapshot: no command-not-found" "$ZERR" 'command not found'
: > "$HIVEGUARD_MARKERS"
print -r -- "$T/proj	$(now)" > "$HIVEGUARD_COVERAGE"
zrun "source $T/snap.zsh; cd $T/proj/app; npm test; print rc=\$?"
is "M/snapshot: a clean project runs the real command" 'REAL npm test
rc=0' "$ZOUT"
# Bumblebee's body must still run after the gate, though its own helper is gone
# too: the gate refuses first, and nothing points at a lost _orig_ copy.
markers "$T/proj/app	active	1 active vulnerabilities
"
snapshot "source $BUMBLEBEE; source $STRICT" "$T/snap-bb.zsh"
zrun "source $T/snap-bb.zsh; cd $T/proj/app; npm test; print rc=\$?"
is "M/snapshot+bumblebee: a red project is refused by the gate" 'rc=77' "$ZOUT"
lacks "M/snapshot+bumblebee: no lost _orig_ copy is called" "$ZERR" '_hiveguard_strict_orig_npm'
# hiveguard moved or uninstalled after the snapshot was taken: warn, then run.
mkdir -p "$T/gone"
cp "$STRICT" "$T/gone/hiveguard-strict.zsh"
snapshot "source $T/gone/hiveguard-strict.zsh" "$T/snap-gone.zsh"
rm -rf "$T/gone"
zrun "source $T/snap-gone.zsh; cd $T/proj/app; npm test; print rc=\$?"
is "M/snapshot, guard file gone: the command still runs" 'REAL npm test
rc=0' "$ZOUT"
contains "M/snapshot, guard file gone: one-line warning" "$ZERR" 'running npm unchecked'
# The bumblebee guard has the same shape (public npm/pip/go/… over `_bb_*`
# helpers and BB_* globals) and must survive a snapshot too.
: > "$HIVEGUARD_MARKERS"
snapshot "source $BUMBLEBEE" "$T/snap-bbonly.zsh"
zrun "source $T/snap-bbonly.zsh; cd $T/proj/app; npm test; print rc=\$?
npm install left-pad; print rc=\$?"
is "M/snapshot bumblebee-only: pass-through and install both reach npm" 'REAL npm test
rc=0
REAL npm install left-pad
rc=0' "$ZOUT"
lacks "M/snapshot bumblebee-only: no command-not-found" "$ZERR" 'command not found'
lacks "M/snapshot bumblebee-only: helpers reloaded, not run unchecked" "$ZERR" 'running unchecked'
# No bumblebee binary here, so its preflight speaks — proof the gate really ran.
contains "M/snapshot bumblebee-only: the install went through bumblebee's gate" "$ZERR" 'Gate skipped'
# Reloading bumblebee's helpers must not replace hiveguard's npm wrapper.
zrun "source $T/snap-bb.zsh; cd $T/proj/app; npm test; print rc=\$?
[[ \$functions[npm] == *_hiveguard_strict_gate* ]] && print still-gated"
is "M/snapshot+bumblebee clean: runs, and the strict wrapper survives the reload" 'REAL npm test
rc=0
still-gated' "$ZOUT"
mkdir -p "$T/gone"
cp "$BUMBLEBEE" "$T/gone/bumblebee-guard.sh"
snapshot "source $T/gone/bumblebee-guard.sh" "$T/snap-bbgone.zsh"
rm -rf "$T/gone"
zrun "source $T/snap-bbgone.zsh; cd $T/proj/app; npm test; print rc=\$?"
is "M/snapshot, bumblebee file gone: the command still runs" 'REAL npm test
rc=0' "$ZOUT"
contains "M/snapshot, bumblebee file gone: one-line warning" "$ZERR" 'running unchecked'

# R. A target refusal works from the snapshot shell too.
target_reset
snapshot "source $STRICT" "$T/snap-target.zsh"
zrun "source $T/snap-target.zsh; cd $T/tmp; python $A/tools/x.py; print rc=\$?"
is "R/snapshot: an argument into a red project is refused" 'rc=77' "$ZOUT"
lacks "R/snapshot: no command-not-found" "$ZERR" 'command not found'

# =============================================================================
# N. The refusal message, byte-for-byte (cwd form and target form)
# =============================================================================
target_reset
zrun "source $STRICT; cd $A/sub; npm install left-pad; print rc=\$?"
is "N/cwd: rc 77" 'rc=77' "$ZOUT"
is "N/cwd: the exact 6-line refusal, no because: line" "$(refusal "$RED" "$A" npm)" "$ZERR"
from_tmp "python $A/tools/x.py"
is "N/target: rc 77, the real python never ran" 'rc=77' "$ZOUT"
is "N/target: the exact refusal with the because: line" \
   "$(refusal "$RED" "$A" python "the argument $A/tools/x.py points into that project ($A/tools/x.py)")" \
   "$ZERR"

# =============================================================================
# O. Argument targets (cwd $T/tmp, which itself is not red)
# =============================================================================
target_reset
from_tmp "python ../proj/app/tools/x.py"
refused "O/relative path" "the argument ../proj/app/tools/x.py points into that project ($A/tools/x.py)"
from_tmp "pip install -r $A/requirements.txt"
refused "O/option value as its own argument" \
        "the argument $A/requirements.txt points into that project ($A/requirements.txt)"
from_tmp "npm --prefix=$A install"
refused "O/glued --opt=path" "the argument --prefix=$A points into that project ($A)"
from_tmp "npm DESTDIR=$A test"
refused "O/glued VAR=path" "the argument DESTDIR=$A points into that project ($A)"
# `--prefix=~/red` reaches the gate with the tilde unexpanded; the gate expands it.
markers "$A	active	$RED
$T/home/red	active	home red
"
from_tmp "npm --prefix='~/red' test"
refused "O/glued ~/ path" "the argument --prefix=~/red points into that project ($T/home/red)"
contains "O/glued ~/ path: headline names the home project" "${ZERR%%$'\n'*}" "home red in $T/home/red"
markers "$A	active	$RED
"
from_tmp "pip install -e $A"
refused "O/directory target" "the argument $A points into that project ($A)"
# Strings that are not existing paths never match anything.
from_tmp "python $A/nope.py"
ran "O/nonexistent path inside the red root" "REAL python $A/nope.py"
from_tmp "pip install requests"
ran "O/bare word" "REAL pip install requests"
from_tmp "npm install @scope/pkg"
ran "O/@scope/pkg" "REAL npm install @scope/pkg"
from_tmp "pip install pkg==1.0"
ran "O/pkg==1.0" "REAL pip install pkg==1.0"
from_tmp "python -c 'print(1)'"
ran "O/-c code" "REAL python -c print(1)"
# The target's own marker decides: acked runs, a running pause runs, expired refuses.
markers "$A	acked	3 acknowledged
"
from_tmp "python $A/tools/x.py"
ran "O/acked target" "REAL python $A/tools/x.py"
markers "$A	active	$RED
"
print -r -- "$A	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
from_tmp "python $A/tools/x.py"
ran "O/paused target" "REAL python $A/tools/x.py"
print -r -- "$A	$(( $(now) - 1 ))" > "$HIVEGUARD_PAUSES"
from_tmp "python $A/tools/x.py"
refused "O/expired pause on the target" "the argument $A/tools/x.py points into that project ($A/tools/x.py)"
rm -f "$HIVEGUARD_PAUSES"
# Innermost root per location: the cwd sits in an acked inner project, the
# argument points into the active outer one.
markers "$T/proj	active	outer is red
$A	acked	inner acked
"
zrun "source $STRICT; cd $A/sub; npm test; print rc=\$?"
ran "O/innermost: cwd in the acked inner project" "REAL npm test"
zrun "source $STRICT; cd $A/sub; python ../../tools/y.py; print rc=\$?"
refused "O/innermost: argument into the active outer project" \
        "the argument ../../tools/y.py points into that project ($T/proj/tools/y.py)"
contains "O/innermost: headline names the outer project" "${ZERR%%$'\n'*}" "outer is red in $T/proj"
# The cwd's project is paused, the target's is not: the target still refuses.
: > "$T/elsewhere/x/f.py"
markers "$A	active	$RED
$T/elsewhere/x	active	elsewhere red
"
print -r -- "$A	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
zrun "source $STRICT; cd $A; npm test; print rc=\$?"
ran "O/disagree: paused cwd runs" "REAL npm test"
zrun "source $STRICT; cd $A; python $T/elsewhere/x/f.py; print rc=\$?"
is "O/disagree: target in another red project → rc 77" 'rc=77' "$ZOUT"
is "O/disagree: the refusal names the target's project" \
   "$(refusal 'elsewhere red' "$T/elsewhere/x" python "the argument $T/elsewhere/x/f.py points into that project ($T/elsewhere/x/f.py)")" \
   "$ZERR"
# Targets are judged against markers only: they never start a background scan.
target_reset
: > "$HIVEGUARD_MARKERS"
print -r -- "$T/tmp	$(now)" > "$HIVEGUARD_COVERAGE"
from_tmp "python $T/elsewhere/x/f.py"
ran "O/no scan: an unknown target runs" "REAL python $T/elsewhere/x/f.py"
no_scan "O/no scan: the unknown target is not scanned"
markers "$A	active	$RED
"
zrun "source $STRICT; cd $T/loose/dir; python $A/tools/x.py; print rc=\$?"
refused "O/no scan: refused from an unknown cwd" \
        "the argument $A/tools/x.py points into that project ($A/tools/x.py)"
no_scan "O/no scan: a refusal is terminal, the unknown cwd is not scanned"

# =============================================================================
# P. Executable targets: the bare name resolves into the red project
# =============================================================================
target_reset
from_tmp "python -c 'print(1)'" "PATH=$A/.venv/bin:$T/stubs:/usr/bin:/bin"
# The venv's python is a symlink to $T/stubs/python: only the directory form
# (resolve the directory, keep the name) lands inside the project.
refused "P/venv bin on PATH" "\`python\` resolves to $A/.venv/bin/python, inside that project"
from_tmp "npm test" "PATH=$A/node_modules/.bin:$T/stubs:/usr/bin:/bin"
refused "P/node_modules/.bin on PATH" "\`npm\` resolves to $A/node_modules/.bin/npm, inside that project"
markers "$A	acked	3 acknowledged
"
from_tmp "npm test" "PATH=$A/node_modules/.bin:$T/stubs:/usr/bin:/bin"
ran "P/acked: the project's own binary runs" "REAL npm test"
markers "$A	active	$RED
"
print -r -- "$A	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
from_tmp "npm test" "PATH=$A/node_modules/.bin:$T/stubs:/usr/bin:/bin"
ran "P/paused: the project's own binary runs" "REAL npm test"
rm -f "$HIVEGUARD_PAUSES"
cfg 'mark_finder=0
strict=1
strict_commands_extra=foo'
from_tmp "foo"
is "P/name not on PATH: plain command-not-found" 'rc=127' "$ZOUT"
lacks "P/name not on PATH: the gate says nothing" "$ZERR" 'hiveguard'

# =============================================================================
# Q. Environment targets: an activated VIRTUAL_ENV / CONDA_PREFIX of a red project
# =============================================================================
target_reset
from_tmp "npm test" "export VIRTUAL_ENV=$A/.venv"
refused "Q/VIRTUAL_ENV" "VIRTUAL_ENV=$A/.venv is that project's environment"
from_tmp "pip install x" "export CONDA_PREFIX=$A/.conda"
refused "Q/CONDA_PREFIX (need not exist)" "CONDA_PREFIX=$A/.conda is that project's environment"
markers "$A	acked	3 acknowledged
"
from_tmp "npm test" "export VIRTUAL_ENV=$A/.venv"
ran "Q/acked environment" "REAL npm test"
markers "$A	active	$RED
"
print -r -- "$A	$(( $(now) + 3600 ))" > "$HIVEGUARD_PAUSES"
from_tmp "npm test" "export VIRTUAL_ENV=$A/.venv"
ran "Q/paused environment" "REAL npm test"
rm -f "$HIVEGUARD_PAUSES"
from_tmp "npm test" "export VIRTUAL_ENV=$T/elsewhere/x/.venv"
ran "Q/environment with no marker" "REAL npm test"
no_scan "Q/environment with no marker: no scan"

# =============================================================================
if (( FAILED )); then
  print -r -- "FAILED"
  exit 1
fi
print -r -- "all strict-hook checks passed"
exit 0

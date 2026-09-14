#!/usr/bin/env zsh
# hiveguard-strict.zsh — strict mode: a project hiveguard flagged red refuses to
# run, build, test or install until you fix it or pause it.
#
# Sourced automatically from the end of hiveguard-hook.zsh (its sibling), so the
# single line already in ~/.zshrc
#   source /path/to/hiveguard-hook.zsh
# is all the shell integration there is. This file is also sourceable on its own;
# sourcing either file twice is a no-op.
#
# Off by default. `hiveguard strict on` flips `strict=1` in the config file; every
# open terminal picks that up at its next prompt (a precmd hook re-syncs). While
# strict mode is off NOTHING is defined for the intercepted names — `type npm` is
# exactly what it was without this file.
#
# HONEST SCOPE: a terminal-level guard. It only intercepts a BARE command name
# resolved by a shell that sourced this file. It cannot stop an IDE Run button, a
# double-click, Docker Desktop, a process that is already running, `./gradlew`,
# `sudo npm …`, an absolute path, an alias defined later, `zsh -c`, cron or
# launchd. It is a discipline tool, not a sandbox.
#
# How it intercepts: for every name in $_HIVEGUARD_STRICT_CMDS (plus the config
# key `strict_commands_extra=a b c`) it installs a shell function that calls the
# gate first and the original second. An already-defined function — the bumblebee
# guard's npm/pnpm/yarn/bun/pip/go/cargo — is preserved as
# `_hiveguard_strict_orig_<cmd>` and still runs, so the two guards compose in
# EITHER source order: the precmd sync re-wraps when bumblebee loads last, and
# `strict off` restores bumblebee's function body byte-for-byte.
#
# Rules the gate applies, in order, for the current directory:
#   1. strict off                         → run (nothing else is read)
#   2. innermost marker root containing it:
#        active → refuse, unless a still-running pause row for that exact root
#        acked  → run
#   3. no marker, but a coverage row covering it is younger than 7 days → run
#   4. otherwise unknown/stale → run now AND kick off one debounced background
#      scan, so the NEXT attempt is blocked if the scan finds something.
# There is no repair exemption: the gate never looks at the command's arguments,
# so `npm install`, `npm update` and `npm audit fix` are refused like everything
# else. Pausing the project is the only way through.
#
# State (all read-only on the hot path except the attempts append in rule 4):
#   ${HIVEGUARD_CONFIG:-$HOME/.hiveguard/config}
#       `strict=1` / `strict=0` (last occurrence wins), `strict_commands_extra=`
#   ${HIVEGUARD_MARKERS:-$HOME/.hiveguard/osv-markers.tsv}
#       root<TAB>status<TAB>summary  (status: active | acked)
#   ${HIVEGUARD_PAUSES:-$HOME/.hiveguard/strict-pauses.tsv}
#       root<TAB>until_epoch
#   ${HIVEGUARD_COVERAGE:-$HOME/.hiveguard/osv-coverage.tsv}
#       target<TAB>scanned_epoch
#   ${HIVEGUARD_STRICT_ATTEMPTS:-$HOME/.hiveguard/strict-attempts.tsv}
#       root<TAB>attempt_epoch
#   $HIVEGUARD_BIN — the dispatcher used for background scans (tests only;
#       defaults to the `hiveguard` sitting next to this file)
#
# This runs on EVERY intercepted command, so it is zsh-builtins-only: file reads
# via $(<file) (zsh reads the file itself — no fork), $EPOCHSECONDS from
# zsh/datetime, $functions from zsh/parameter, parameter expansion for parsing.
# No jq/awk/date/grep/python, no $(cmd), no subshells. The ONLY fork on any
# strict path is the detached background scan for an unknown project.

# Idempotent: define everything and register the precmd hook once.
if [[ -z ${_HIVEGUARD_STRICT_LOADED:-} ]]; then
  typeset -g _HIVEGUARD_STRICT_LOADED=1
  # `:a` (not `:A`) keeps a Homebrew `opt` path instead of the versioned Cellar.
  typeset -g _HIVEGUARD_STRICT_DIR="${${(%):-%x}:a:h}"
  # Freshness of scan coverage AND debounce window for background scans: 7 days.
  typeset -gi _HIVEGUARD_STRICT_FRESH=604800
  # Every package manager the README covers, the runtimes that execute a project,
  # and the build/task runners that run project-defined code. Not being in this
  # list *is* the allowlist — there is no allowlist data structure.
  typeset -ga _HIVEGUARD_STRICT_CMDS=(
    npm pnpm yarn bun npx pnpx bunx node deno
    pip pip3 python python3 uv uvx poetry pipenv pytest
    cargo go
    gem bundle bundler rake ruby
    composer php
    make cmake gradle mvn mix swift just
  )
  # Extra names from `strict_commands_extra=` (refreshed on every config read).
  typeset -ga _hiveguard_strict_extra=()
  # Names this shell currently has wrapped, so a name that leaves the list (or a
  # `strict off`) is unwrapped even when the config no longer mentions it.
  typeset -ga _hiveguard_strict_wrapped=()
  # Out-parameter of _hiveguard_strict_col2 (capturing stdout would fork).
  typeset -g _hiveguard_strict_reply=""
  # The refusal text quotes the command name in backticks. Spelled as an escape
  # so this file contains nothing that even looks like a command substitution.
  typeset -g _HIVEGUARD_STRICT_BQ=$'\x60'

  zmodload -i zsh/parameter   # $functions
  zmodload -i zsh/datetime    # $EPOCHSECONDS

  # 0 iff the config says `strict=1` (last `strict=` line wins, like config_get).
  # Always refreshes $_hiveguard_strict_extra from `strict_commands_extra=`, so
  # turning strict off still unwraps the user's extra names.
  _hiveguard_strict_enabled() {
    local cfg="${HIVEGUARD_CONFIG:-$HOME/.hiveguard/config}"
    _hiveguard_strict_extra=()
    [[ -r $cfg && -s $cfg ]] || return 1
    local content line on=""
    local -a lines
    content=$(<$cfg)
    lines=("${(@f)content}")
    for line in "${lines[@]}"; do
      case $line in
        (strict=*)                on=${line#strict=} ;;
        (strict_commands_extra=*) _hiveguard_strict_extra=( ${=line#strict_commands_extra=} ) ;;
      esac
    done
    [[ $on == 1 ]]
  }

  # Scan a two-column TSV and leave the LARGEST column-2 integer of the matching
  # rows in $_hiveguard_strict_reply (empty when nothing matched). $3 is `exact`
  # (column 1 must equal the key) or `under` (column 1 must equal or contain it).
  # One $(<file) read, no fork; a missing/unreadable file is simply "no match".
  _hiveguard_strict_col2() {
    local file="$1" key="$2" mode="$3"
    _hiveguard_strict_reply=""
    [[ -r $file && -s $file ]] || return 0
    local content line k v
    local -a lines fields
    content=$(<$file)
    lines=("${(@f)content}")
    for line in "${lines[@]}"; do
      [[ -z $line ]] && continue
      # (ps:\t:) splits on a literal tab (p = recognise print-style escapes).
      fields=("${(@ps:\t:)line}")
      (( ${#fields[@]} >= 2 )) || continue
      k=${fields[1]}
      v=${fields[2]}
      if [[ $mode == exact ]]; then
        [[ $key == "$k" ]] || continue
      else
        [[ $key == "$k" || $key == "$k"/* ]] || continue
      fi
      [[ $v == <-> ]] || continue   # ignore malformed rows instead of erroring
      [[ -n $_hiveguard_strict_reply ]] && (( v <= _hiveguard_strict_reply )) && continue
      _hiveguard_strict_reply=$v
    done
  }

  # $1 = command name. Install the wrapper, preserving any existing function.
  _hiveguard_strict_wrap() {
    local c="$1"
    # Never wrap a wrapper: the marker in the body is the only recursion guard.
    [[ $functions[$c] == *_hiveguard_strict_gate* ]] && return 0
    if (( ${+functions[$c]} )); then
      functions[_hiveguard_strict_orig_${c}]=$functions[$c]
      functions[$c]='_hiveguard_strict_gate '$c' "$@" || return $?; _hiveguard_strict_orig_'$c' "$@"'
    else
      (( ${+functions[_hiveguard_strict_orig_${c}]} )) && unfunction _hiveguard_strict_orig_${c}
      functions[$c]='_hiveguard_strict_gate '$c' "$@" || return $?; command '$c' "$@"'
    fi
    (( ${_hiveguard_strict_wrapped[(I)$c]} )) || _hiveguard_strict_wrapped+=( $c )
  }

  # $1 = command name. Undo _hiveguard_strict_wrap: restore the preserved body
  # byte-for-byte, or remove the function when we created it out of nothing.
  _hiveguard_strict_unwrap() {
    local c="$1"
    if [[ $functions[$c] == *_hiveguard_strict_gate* ]]; then
      if (( ${+functions[_hiveguard_strict_orig_${c}]} )); then
        functions[$c]=$functions[_hiveguard_strict_orig_${c}]
        unfunction _hiveguard_strict_orig_${c}
      else
        unfunction $c
      fi
    fi
    _hiveguard_strict_wrapped=( ${_hiveguard_strict_wrapped:#${c}} )
  }

  # Bring this shell in line with the config. Runs at source time and before
  # every prompt — that is what repairs the wrappers when the bumblebee guard is
  # sourced after us, and what makes `hiveguard strict off` take effect in every
  # open terminal without touching them.
  _hiveguard_strict_sync() {
    emulate -L zsh
    local c
    local -a want prev
    prev=( $_hiveguard_strict_wrapped )
    if _hiveguard_strict_enabled; then
      want=( $_HIVEGUARD_STRICT_CMDS $_hiveguard_strict_extra )
      for c in $prev; do
        (( ${want[(I)$c]} )) || _hiveguard_strict_unwrap $c
      done
      for c in $want; do
        _hiveguard_strict_wrap $c
      done
    else
      for c in $prev; do
        _hiveguard_strict_unwrap $c
      done
    fi
    return 0   # sourcing this file must not leave a non-zero $? behind
  }

  # $1 = the intercepted command name; $2… are the command's own arguments and
  # are deliberately IGNORED (no repair exemption). 0 = proceed, 77 = refused.
  _hiveguard_strict_gate() {
    emulate -L zsh
    local cmd="$1"

    # Rule 1 — strict off: read nothing else, write nothing, proceed.
    _hiveguard_strict_enabled || return 0

    local now=$EPOCHSECONDS
    local cur="${PWD:A}"

    # Rule 2 — innermost (longest) marker root that equals or contains $cur,
    # exactly the rule the chpwd reminder uses.
    local markers="${HIVEGUARD_MARKERS:-$HOME/.hiveguard/osv-markers.tsv}"
    local best_root="" best_status="" best_summary="" best_len=-1
    # `status` is a read-only zsh special var (last exit code) — use `st`.
    local content line root st summary
    local -a lines fields
    if [[ -r $markers && -s $markers ]]; then
      content=$(<$markers)
      lines=("${(@f)content}")
      for line in "${lines[@]}"; do
        [[ -z $line ]] && continue
        fields=("${(@ps:\t:)line}")
        (( ${#fields[@]} >= 3 )) || continue
        root=${fields[1]}
        st=${fields[2]}
        summary=${fields[3]}
        [[ $cur == "$root" || $cur == "$root"/* ]] || continue
        (( ${#root} > best_len )) || continue
        best_len=${#root}
        best_root=$root
        best_status=$st
        best_summary=$summary
      done
    fi

    if [[ -n $best_root ]]; then
      # Anything that is not `active` (i.e. `acked`) is acknowledged data: run.
      [[ $best_status == active ]] || return 0

      # A still-running pause for that exact root releases this one project.
      # An active marker blocks regardless of how old the scan data is: a known
      # vulnerability does not expire, and red is the same signal that drives the
      # Finder tag and the cd reminder, neither of which has a freshness window.
      _hiveguard_strict_col2 \
        "${HIVEGUARD_PAUSES:-$HOME/.hiveguard/strict-pauses.tsv}" "$best_root" exact
      [[ -n $_hiveguard_strict_reply ]] && (( _hiveguard_strict_reply > now )) && return 0

      local color="" reset=""
      [[ -t 2 ]] && { color=$'\e[31m'; reset=$'\e[0m' }
      local bq=$_HIVEGUARD_STRICT_BQ
      print -u2 -r -- "${color}⛔ hiveguard strict: ${best_summary} in ${best_root} — refusing to run ${bq}${cmd}${bq}.${reset}"
      print -u2 -r -- "   detail:   hiveguard daily --open"
      print -u2 -r -- "   proceed:  fix it, or pause this project:  hiveguard strict pause   (1h; e.g. --for 2h)"
      return 77
    fi

    # Rule 3 — no marker row: a clean project legitimately has none, so trust a
    # scan that covered this directory inside the freshness window.
    _hiveguard_strict_col2 \
      "${HIVEGUARD_COVERAGE:-$HOME/.hiveguard/osv-coverage.tsv}" "$cur" under
    [[ -n $_hiveguard_strict_reply ]] &&
      (( _hiveguard_strict_reply >= now - _HIVEGUARD_STRICT_FRESH )) && return 0

    # Rule 4 — unknown or stale. Never prompt, never wait: run the command and
    # scan in the background. The project root is the nearest `.git` ancestor
    # (dir or file, so worktrees count), mirroring osv-daily's finding_root, so
    # the marker row a finding creates later matches this same root.
    local dir="$cur"
    root=""
    while :; do
      [[ -e $dir/.git ]] && { root=$dir; break }
      [[ $dir == / ]] && break
      dir=${dir:h}
      [[ -n $dir ]] || break
    done
    [[ -n $root ]] || root=$cur

    # Debounce: one background scan per project per freshness window.
    local att="${HIVEGUARD_STRICT_ATTEMPTS:-$HOME/.hiveguard/strict-attempts.tsv}"
    _hiveguard_strict_col2 "$att" "$root" exact
    [[ -n $_hiveguard_strict_reply ]] &&
      (( _hiveguard_strict_reply >= now - _HIVEGUARD_STRICT_FRESH )) && return 0

    # zf_mkdir is zsh/files' builtin mkdir, loaded under its zf_ name so the
    # user's own `mkdir` is untouched. Only reached on this (forking) path.
    [[ -d ${att:h} ]] ||
      { zmodload -F zsh/files b:zf_mkdir 2>/dev/null && zf_mkdir -p -- "${att:h}" 2>/dev/null }
    print -r -- "$root"$'\t'"$now" >> "$att" 2>/dev/null

    # The one permitted fork. The subshell keeps job-control chatter out of an
    # interactive shell; `trap '' HUP` lets the scan outlive the terminal.
    local hg="${HIVEGUARD_BIN:-$_HIVEGUARD_STRICT_DIR/hiveguard}"
    ( trap '' HUP; "$hg" strict _bgscan "$root" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
  }

  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _hiveguard_strict_sync
fi

# Source time: get this shell into the right state immediately, so a `zsh -c` or
# a script (which never reaches a prompt) is guarded too.
_hiveguard_strict_sync

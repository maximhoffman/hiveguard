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
# HONEST SCOPE: a terminal-level guard. It intercepts a BARE command name resolved
# by a shell that sourced this file, and judges WHERE the command is typed and WHERE
# it points (argument paths, the binary it resolves to, an activated VIRTUAL_ENV /
# CONDA_PREFIX). It cannot see paths hardcoded inside a script that was copied out
# of the project, an absolute path to a binary, `./gradlew`, `sudo npm …`, `env`,
# `xargs`, `sh -c`, version-manager shims, an alias defined later, `zsh -c`, an IDE
# Run button, a double-click, Docker Desktop, cron, launchd, or a process that is
# already running. It is a discipline tool, not a sandbox.
#
# How it intercepts: for every name in $_HIVEGUARD_STRICT_CMDS (plus the config
# key `strict_commands_extra=a b c`) it installs a shell function that calls the
# gate first and the original second. An already-defined function — the bumblebee
# guard's npm/pnpm/yarn/bun/pip/go/cargo — still runs (its body is carried inline
# after the gate, and a copy is kept as `_hiveguard_strict_orig_<cmd>`), so the
# two guards compose in EITHER source order: the precmd sync re-wraps when
# bumblebee loads last, and `strict off` restores bumblebee's function body
# byte-for-byte. The wrappers also work in a shell snapshot that lost the gate
# (Claude Code's Bash tool): they re-source this file by absolute path.
#
# Rules the gate applies, in order:
#   1. strict off                         → run (nothing else is read)
#   2. for each LOCATION — the current directory, then every argument that is an
#      existing path (resolved against the cwd; `--opt=path` and `~/` handled), then
#      the directory the bare name resolves to on PATH (and its fully resolved
#      file), then $VIRTUAL_ENV and $CONDA_PREFIX — take the innermost marker root
#      containing it:
#        active → refuse, unless a still-running pause row for that exact root
#        acked  → this location is fine
#      The first blocking location decides the message (a `because:` line names an
#      argument / executable / environment trigger; none for the cwd).
#   3. nothing blocked and the cwd has an (acked) marker root → run
#   4. no marker for the cwd, but a coverage row covering it is younger than 7 days → run
#   5. otherwise unknown/stale → run now AND kick off one debounced background scan
#      of the cwd's project, so the NEXT attempt is blocked if the scan finds
#      something. Targets are judged against markers only — they never trigger a
#      scan (a target can be anywhere, including folders a background agent cannot
#      read, and the cwd is what the user is actually working in).
# There is no repair exemption: arguments are read ONLY as paths, never as verbs, so
# `npm install`, `npm update` and `npm audit fix` are refused like everything else.
# Pausing the project is the only way through.
#
# State (all read-only on the hot path except the attempts append in rule 5):
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
# zsh/datetime, $functions and $commands from zsh/parameter, parameter expansion
# for parsing and path resolution (`:A`, `:h`, `:t`), `[[ -e ]]` for existence.
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
  #
  # The wrapper is self-sufficient: a shell snapshot (Claude Code replays the
  # shell's functions instead of sourcing ~/.zshrc, dropping every `_`-prefixed
  # name and all globals) keeps `npm` but loses the gate, its state and any
  # `_hiveguard_strict_orig_*` copy. So the wrapper (re)sources this file by
  # absolute path when the gate is missing, warns and runs if that file is gone,
  # and carries an existing function's body INLINE rather than calling the copy,
  # which is kept only so `strict off` can restore it byte-for-byte.
  _hiveguard_strict_wrap() {
    local c="$1"
    # Never wrap a wrapper: the marker in the body is the only recursion guard.
    [[ $functions[$c] == *_hiveguard_strict_gate* ]] && return 0
    local self="${(qq)_HIVEGUARD_STRICT_DIR}/hiveguard-strict.zsh"
    local pre='(( ${+functions[_hiveguard_strict_gate]} )) || builtin source -- '$self' 2>/dev/null
if (( ${+functions[_hiveguard_strict_gate]} )); then _hiveguard_strict_gate '$c' "$@" || return $?
else print -u2 -r -- "hiveguard strict: guard not loadable, running '$c' unchecked"; fi
'
    if (( ${+functions[$c]} )); then
      functions[_hiveguard_strict_orig_${c}]=$functions[$c]
      functions[$c]=$pre$functions[$c]
    else
      (( ${+functions[_hiveguard_strict_orig_${c}]} )) && unfunction _hiveguard_strict_orig_${c}
      functions[$c]=$pre'command '$c' "$@"'
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

  # $1 = the intercepted command name; $2… are the command's own arguments, read
  # only as candidate paths (rule 2) — never as verbs. 0 = proceed, 77 = refused.
  _hiveguard_strict_gate() {
    emulate -L zsh
    local cmd="$1"
    shift

    # Rule 1 — strict off: read nothing else, write nothing, proceed.
    _hiveguard_strict_enabled || return 0

    local now=$EPOCHSECONDS
    local cur="${PWD:A}"
    local bq=$_HIVEGUARD_STRICT_BQ

    # Read the markers ONCE into three parallel arrays; every location below is
    # judged against them. Blank and malformed rows are skipped.
    local markers="${HIVEGUARD_MARKERS:-$HOME/.hiveguard/osv-markers.tsv}"
    local content line
    local -a lines fields mroots msts msums
    if [[ -r $markers && -s $markers ]]; then
      content=$(<$markers)
      lines=("${(@f)content}")
      for line in "${lines[@]}"; do
        [[ -z $line ]] && continue
        fields=("${(@ps:\t:)line}")
        (( ${#fields[@]} >= 3 )) || continue
        mroots+=( "${fields[1]}" )
        msts+=( "${fields[2]}" )
        msums+=( "${fields[3]}" )
      done
    fi

    # Rule 2 — the locations, in evaluation order, each with the `because:` text
    # a refusal on it prints (empty for the cwd: the headline already names it).
    local -a locs whys cands
    locs=( "$cur" )
    whys=( "" )

    # Arguments that are existing paths. Candidates: the whole argument and, if
    # it has a `=`, the part after the first one (`--prefix=../app`, `DESTDIR=x`).
    # A bare option is skipped (its value is the next argument). `~`/`~/…` is
    # expanded here because the shell leaves a glued `--opt=~/x` alone. A path
    # that does not exist is not the project's data — and this test keeps `-c
    # "code"`, URLs, `pkg==1.0`, `@scope/pkg` from matching anything.
    local a c p
    for a in "$@"; do
      cands=( "$a" )
      [[ $a == *=* ]] && cands+=( "${a#*=}" )
      for c in "${cands[@]}"; do
        [[ -z $c || $c == -* ]] && continue
        [[ $c == '~' || $c == '~/'* ]] && c="${HOME:-}${c[2,-1]}"
        p=${c:A}
        [[ -e $p ]] || continue
        locs+=( "$p" )
        whys+=( "the argument $a points into that project ($p)" )
      done
    done

    # The executable the bare name resolves to on PATH ($commands ignores the
    # wrapper function). Its canonical DIRECTORY first — a venv's `python` is a
    # symlink out of the project, so only `:h:A` keeps `.venv/bin` — then the
    # fully resolved file (a shim outside that links to a script inside).
    local exe="${commands[$cmd]:-}"
    if [[ -n $exe ]]; then
      p="${bq}${cmd}${bq} resolves to ${exe:h:A}/${exe:t}, inside that project"
      locs+=( "${exe:h:A}" "${exe:A}" )
      whys+=( "$p" "$p" )
    fi

    # The activated environment. Being set is the signal: no existence test.
    local var val
    for var in VIRTUAL_ENV CONDA_PREFIX; do
      val=${(P)var:-}
      [[ -n $val ]] || continue
      locs+=( "${val:A}" )
      whys+=( "$var=$val is that project's environment" )
    done

    # Per location: the innermost (longest) marker root that equals or contains
    # it — exactly the rule the chpwd reminder uses. `acked` is fine; `active`
    # blocks unless a still-running pause row exists for that exact root. An
    # active marker blocks regardless of how old the scan data is: a known
    # vulnerability does not expire, and red is the same signal that drives the
    # Finder tag and the cd reminder, neither of which has a freshness window.
    # The pauses file is read only when a location would otherwise block, and a
    # root found paused is remembered so it is not read again for this call.
    local -a cleared
    local -i i j best best_len cwd_known=0
    local loc root
    for (( i = 1; i <= ${#locs[@]}; i++ )); do
      loc=${locs[i]}
      best=0
      best_len=-1
      for (( j = 1; j <= ${#mroots[@]}; j++ )); do
        root=${mroots[j]}
        [[ $loc == "$root" || $loc == "$root"/* ]] || continue
        (( ${#root} > best_len )) || continue
        best_len=${#root}
        best=$j
      done
      (( best )) || continue
      (( i == 1 )) && cwd_known=1
      [[ ${msts[best]} == active ]] || continue
      root=${mroots[best]}
      (( ${cleared[(Ie)$root]} )) && continue
      _hiveguard_strict_col2 \
        "${HIVEGUARD_PAUSES:-$HOME/.hiveguard/strict-pauses.tsv}" "$root" exact
      if [[ -n $_hiveguard_strict_reply ]] && (( _hiveguard_strict_reply > now )); then
        cleared+=( "$root" )
        continue
      fi

      # Refusal is terminal: no coverage check, no background scan.
      local color="" reset=""
      [[ -t 2 ]] && { color=$'\e[31m'; reset=$'\e[0m' }
      print -u2 -r -- "${color}⛔ hiveguard strict: ${msums[best]} in ${root} — refusing to run ${bq}${cmd}${bq}.${reset}"
      [[ -n ${whys[i]} ]] && print -u2 -r -- "   because:  ${whys[i]}"
      print -u2 -r -- "   detail:   hiveguard daily --open"
      print -u2 -r -- "   proceed:  fix it, or pause this project:  hiveguard strict pause \"${root}\"   (1h; e.g. --for 2h)"
      print -u2 -r -- "   agents:   AI coding agents: do not work around this block — no cd elsewhere, no copying files out,"
      print -u2 -r -- "             no other path, interpreter or environment. Stop and report it to the user, or ask them"
      print -u2 -r -- "             to run ${bq}hiveguard strict pause${bq}."
      return 77
    done

    # Rule 3 — nothing blocked and the cwd has a marker root (acked, or active
    # but paused): known data, run.
    (( cwd_known )) && return 0

    # Rule 4 — no marker row: a clean project legitimately has none, so trust a
    # scan that covered this directory inside the freshness window.
    _hiveguard_strict_col2 \
      "${HIVEGUARD_COVERAGE:-$HOME/.hiveguard/osv-coverage.tsv}" "$cur" under
    [[ -n $_hiveguard_strict_reply ]] &&
      (( _hiveguard_strict_reply >= now - _HIVEGUARD_STRICT_FRESH )) && return 0

    # Rule 5 — unknown or stale. Never prompt, never wait: run the command and
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

    # Never scan the home folder or anything above it (a command typed in ~ or
    # /): that crawls every tool cache and plugin under ~ and paints them red.
    local home="${HOME:A}"
    [[ $root == / || $home == "$root" || $home == "$root"/* ]] && return 0

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

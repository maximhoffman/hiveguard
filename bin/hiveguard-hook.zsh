#!/usr/bin/env zsh
# hiveguard-hook.zsh — chpwd reminder for projects hiveguard has flagged.
#
# Opt in by sourcing this from ~/.zshrc:
#   source /path/to/hiveguard-hook.zsh
#
# When you `cd` into (or start a shell inside) a project directory that
# `hiveguard daily` flagged as having vulnerabilities, prints a one-line
# reminder. State is read from:
#   ${HIVEGUARD_MARKERS:-$HOME/.hiveguard/osv-markers.tsv}
# — tab-separated rows `root<TAB>status<TAB>summary`, status is `active` or
# `acked`, root is an absolute path. Missing or empty file → silent.
#
# Runs on every prompt/cd, so it is zsh-builtins-only: no jq/awk/grep/python
# and no subshell forks on the hot path. Sourcing this file twice is safe
# (hook registration is guarded by a sentinel).

# Idempotent: only register the chpwd hook + define the function once.
if [[ -z ${_HIVEGUARD_HOOK_LOADED:-} ]]; then
  typeset -g _HIVEGUARD_HOOK_LOADED=1
  # Last root we warned about in THIS shell, for per-shell dedupe.
  typeset -g _hiveguard_last_root=""

  _hiveguard_cd_check() {
    emulate -L zsh

    local markers="${HIVEGUARD_MARKERS:-$HOME/.hiveguard/osv-markers.tsv}"
    [[ -s $markers ]] || { _hiveguard_last_root=""; return }

    local content
    content=$(<$markers) 2>/dev/null || { _hiveguard_last_root=""; return }
    [[ -z $content ]] && { _hiveguard_last_root=""; return }

    local cur="${PWD:A}"
    local -a lines
    lines=("${(@f)content}")

    # Pick the longest (most specific) matching root, so nested roots resolve
    # to the innermost project.
    local best_root="" best_status="" best_summary="" best_len=-1
    # `status` is a read-only zsh special var (last exit code) — use `st`.
    local line root st summary
    local -a fields
    for line in "${lines[@]}"; do
      [[ -z $line ]] && continue
      # (ps:\t:) splits on a literal tab (p = recognize print-style escapes).
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

    if [[ -z $best_root ]]; then
      # Left every flagged project — allow re-warning on re-entry.
      _hiveguard_last_root=""
      return
    fi

    # Dedupe: don't repeat the same warning while hopping between
    # subdirectories of the same flagged project.
    [[ $best_root == $_hiveguard_last_root ]] && return
    _hiveguard_last_root=$best_root

    local msg color="" reset=""
    if [[ $best_status == active ]]; then
      msg="⛔ hiveguard: ${best_summary} in this project — hiveguard daily --open"
      [[ -t 1 ]] && color=$'\e[31m'
    else
      msg="⚠ hiveguard: ${best_summary} — hiveguard ack --list"
      [[ -t 1 ]] && color=$'\e[33m'
    fi
    [[ -n $color ]] && reset=$'\e[0m'

    print -r -- "${color}${msg}${reset}"
  }

  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd _hiveguard_cd_check
fi

# Also check once at source time, so a shell that starts inside a flagged
# project warns immediately (not just on the next cd). The dedupe above keeps
# a second `source` of this file from repeating an already-shown warning.
_hiveguard_cd_check

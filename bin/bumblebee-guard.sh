#!/usr/bin/env bash
# =============================================================================
# bumblebee-guard.sh
#
# Check packages for known supply-chain compromises BEFORE they install.
# Overrides npm / pnpm / yarn / bun / pip / go so that, before the real
# install, they check against the bumblebee threat catalog (threat_intel).
#
# Enable: add this line to the end of ~/.zshrc
#     source ~/bin/bumblebee-guard.sh
# and restart the terminal (or `source ~/.zshrc`).
#
# Requires: bumblebee, jq, and a git clone of the catalog at $HOME/bumblebee-src.
#
# IMPORTANT — what this does NOT do:
#   * It does not protect against a fresh attack not yet in threat_intel.
#     It's a "don't install the KNOWN-bad" filter, not a guarantee of clean.
#   * Keep the catalog fresh:  git -C ~/bumblebee-src pull
# =============================================================================

# --- Settings ----------------------------------------------------------------
BB_CATALOG="${BB_CATALOG:-$HOME/bumblebee-src/threat_intel}"
BB_BIN="$(command -v bumblebee 2>/dev/null || echo "$HOME/go/bin/bumblebee")"
# -----------------------------------------------------------------------------

# Message and red banner on a finding.
_bb_alert() {
  printf '\n\033[41m\033[1m  ⛔️  BUMBLEBEE: COMPROMISED PACKAGE DETECTED  \033[0m\n' >&2
  printf '\033[1m%s\033[0m\n' "$1" >&2
}
_bb_ok()   { printf '\033[32m✅ bumblebee: clean — %s\033[0m\n' "$1"; }
_bb_info() { printf '\033[33m🐝 bumblebee: %s\033[0m\n' "$1"; }

# Check that the tools are present.
_bb_preflight() {
  if [ ! -x "$BB_BIN" ]; then
    echo "bumblebee not found ($BB_BIN). Gate skipped." >&2; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not installed (brew install jq). Gate skipped." >&2; return 1
  fi
  if [ ! -d "$BB_CATALOG" ]; then
    echo "Threat catalog not found ($BB_CATALOG). Gate skipped." >&2; return 1
  fi
  return 0
}

# Scan a directory on disk via bumblebee. 0 = clean, 1 = findings.
_bb_scan_dir() {
  local dir="$1" profile="${2:-deep}" n
  n="$("$BB_BIN" scan --profile "$profile" --root "$dir" \
        --exposure-catalog "$BB_CATALOG" --findings-only 2>/dev/null \
        | grep -c '"record_type":"finding"')"
  [ "${n:-0}" -gt 0 ] && return 1 || return 0
}

# Print findings (details after a block).
_bb_report_dir() {
  "$BB_BIN" scan --profile "${2:-deep}" --root "$1" \
    --exposure-catalog "$BB_CATALOG" --findings-only 2>/dev/null \
    | jq -r 'select(.record_type=="finding") |
        "  • \(.severity)\t\(.ecosystem)\t\(.package_name)@\(.version)\n    \(.source_file)"'
}

# Direct check of a single package against the catalog (for pip dry-run). 0 = match.
_bb_catalog_hit() {
  jq -e --arg e "$1" --arg n "$2" --arg v "$3" \
    '.entries[]? | select(.ecosystem==$e and .package==$n and ((.versions // [])|index($v)))' \
    "$BB_CATALOG"/*.json >/dev/null 2>&1
}

_bb_is_node_install() {
  case "$1" in install|i|in|add|ci|update|up) return 0;; *) return 1;; esac
}

# --- Shared gate for Node managers ------------------------------------------
# Strategy: install with --ignore-scripts (dangerous lifecycle scripts are NOT
# run) -> scan -> if clean, run the deferred scripts.
_bb_node_guard() {
  local mgr="$1"; shift
  # Not an install command (run/test/ls/...) — pass through untouched.
  if ! _bb_is_node_install "${1:-}"; then command "$mgr" "$@"; return $?; fi
  if ! _bb_preflight; then command "$mgr" "$@"; return $?; fi

  # Global install: cwd won't help, so check via a baseline scan afterward.
  local global=0 a
  for a in "$@"; do case "$a" in -g|--global) global=1;; esac; done

  _bb_info "installing without running scripts and checking against the threat catalog..."
  command "$mgr" "$@" --ignore-scripts || { echo "$mgr: install failed" >&2; return 1; }

  local scope_dir="$PWD" profile="deep"
  [ "$global" -eq 1 ] && profile="baseline"

  if _bb_scan_dir "$scope_dir" "$profile"; then
    _bb_ok "running the deferred lifecycle scripts"
    # rebuild is available in npm/pnpm/yarn; bun doesn't run untrusted scripts itself.
    case "$mgr" in
      npm|pnpm|yarn) command "$mgr" rebuild ;;
      bun)           : ;;  # bun doesn't run postinstall without trustedDependencies
    esac
  else
    _bb_alert "Packages were DOWNLOADED, but scripts did NOT run. Found:"
    _bb_report_dir "$scope_dir" "$profile" >&2
    {
      echo ""
      echo "Roll back the install:"
      echo "  git checkout -- package.json package-lock.json pnpm-lock.yaml yarn.lock bun.lock 2>/dev/null"
      echo "  rm -rf node_modules"
    } >&2
    return 2
  fi
}

npm()  { _bb_node_guard npm  "$@"; }
pnpm() { _bb_node_guard pnpm "$@"; }
yarn() { _bb_node_guard yarn "$@"; }
bun()  { _bb_node_guard bun  "$@"; }

# --- pip: pre-check via dry-run ---------------------------------------------
# Requires pip >= 23 (--dry-run/--report). The set of packages that would be
# installed is computed without installing, then checked against the catalog.
pip() {
  if [ "${1:-}" != "install" ]; then command pip "$@"; return $?; fi
  if ! _bb_preflight; then command pip "$@"; return $?; fi

  local report hits=0 name ver
  report="$(mktemp)"
  _bb_info "computing the install plan (pip --dry-run) and checking..."
  if ! command pip install "${@:2}" --dry-run --quiet --report "$report" >/dev/null 2>&1; then
    rm -f "$report"
    echo "pip: couldn't build a plan (needs pip>=23). Installing normally without the check." >&2
    command pip install "${@:2}"; return $?
  fi

  while IFS= read -r name && IFS= read -r ver; do
    [ -z "$name" ] && continue
    if _bb_catalog_hit pypi "$name" "$ver"; then
      _bb_alert "pypi: $name@$ver is in the threat catalog"; hits=1
    fi
  done < <(jq -r '.install[]?.metadata | .name, .version' "$report" 2>/dev/null)
  rm -f "$report"

  if [ "$hits" -ne 0 ]; then
    echo "Install cancelled." >&2; return 2
  fi
  _bb_ok "installing for real"
  command pip install "${@:2}"
}

# --- Go: check AFTER (no install scripts; downloads are protected by go.sum) -
go() {
  command go "$@"; local rc=$?
  case "${1:-}" in
    get|install|mod|build)
      _bb_preflight || return $rc
      if ! _bb_scan_dir "$PWD" deep; then
        _bb_alert "go: a module from the threat catalog was found"
        _bb_report_dir "$PWD" deep >&2
      fi ;;
  esac
  return $rc
}

# --- Rust: bumblebee does NOT cover crates.io. Point to the right tool.
cargo() {
  case "${1:-}" in
    add|install|update|build)
      if command -v cargo-audit >/dev/null 2>&1; then
        command cargo "$@"; local rc=$?
        _bb_info "cargo: checking against the RustSec database (cargo audit)..."
        command cargo audit
        return $rc
      else
        _bb_info "for Rust install an auditor:  cargo install cargo-audit  (bumblebee doesn't check crates)"
      fi ;;
  esac
  command cargo "$@"
}

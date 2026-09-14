#!/usr/bin/env bash
# tests/run.sh — run every test file in this directory, report PASS/FAIL per
# file, and print a summary. Keeps going after a failure (no `set -e`) so one
# broken test doesn't hide the rest.
#
# Usage: tests/run.sh [filter]
#   filter   optional substring — only test files whose name contains it run.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
filter="${1:-}"

# nullglob so an unmatched pattern expands to nothing instead of the literal
# glob string.
shopt -s nullglob
sh_files=("$dir"/*.test.sh)
zsh_files=("$dir"/*.test.zsh)
shopt -u nullglob

pass=0
fail=0

# bash 3.2 (macOS default) throws "unbound variable" under `set -u` when
# "${arr[@]}" expands an empty array — guard with the ${arr[@]+"${arr[@]}"}
# idiom rather than dropping set -u.
for f in "${sh_files[@]+"${sh_files[@]}"}"; do
  base="$(basename "$f")"
  case "$base" in
    *"$filter"*) ;;
    *) continue ;;
  esac
  if bash "$f"; then
    echo "PASS $base"
    pass=$((pass + 1))
  else
    rc=$?
    echo "FAIL $base (rc=$rc)"
    fail=$((fail + 1))
  fi
done

for f in "${zsh_files[@]+"${zsh_files[@]}"}"; do
  base="$(basename "$f")"
  case "$base" in
    *"$filter"*) ;;
    *) continue ;;
  esac
  if zsh -f "$f"; then
    echo "PASS $base"
    pass=$((pass + 1))
  else
    rc=$?
    echo "FAIL $base (rc=$rc)"
    fail=$((fail + 1))
  fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

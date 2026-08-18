#!/usr/bin/env bash
# hiveguard installer — symlinks the CLI tools into ~/bin, checks prerequisites,
# and (optionally) schedules the daily OSV scan via launchd.
#
#   ./install.sh              # interactive install
#   ./install.sh --no-agent   # skip the launchd daily-scan agent
#   ./install.sh --hour 9     # schedule the daily scan at 09:00 (default 10:00)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin"
HOUR=10; MIN=0; WANT_AGENT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-agent) WANT_AGENT=0 ;;
    --hour) shift; HOUR="$1" ;;
    --min)  shift; MIN="$1" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac; shift
done

say()  { printf '\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$1"; }

# ── 1. prerequisites ────────────────────────────────────────────────────────
say "Checking prerequisites"
MISSING=()
need() { command -v "$1" >/dev/null 2>&1 && ok "$1" || { warn "$1 missing"; MISSING+=("$2"); }; }
need brew        "install Homebrew: https://brew.sh"
need jq          "brew install jq"
need osv-scanner "brew install osv-scanner"
need gh          "brew install gh   (optional: brew-changelog uses it)"
command -v bumblebee >/dev/null 2>&1 && ok "bumblebee" \
  || warn "bumblebee binary not found — install-time gating is optional; see README (Prerequisites)"
[ -d "$HOME/bumblebee-src/threat_intel" ] && ok "bumblebee catalog (~/bumblebee-src)" \
  || warn "bumblebee threat catalog not found — clone it, see README"

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo; warn "Resolve the above, then re-run. Required: jq, osv-scanner."
  printf '   %s\n' "${MISSING[@]}"
fi

# ── 2. symlink CLIs into ~/bin ──────────────────────────────────────────────
say "Linking tools into $BIN"
mkdir -p "$BIN" "$HOME/.hiveguard"
for tool in hiveguard safe-add deps-audit osv-daily brew-changelog; do
  target="$BIN/$tool"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.pre-hiveguard.bak"; warn "backed up existing $tool → $tool.pre-hiveguard.bak"
  fi
  ln -sf "$REPO/bin/$tool" "$target"; ok "$tool → $REPO/bin/$tool"
done
case ":$PATH:" in
  *":$BIN:"*) ok "$BIN is on PATH" ;;
  *) warn "$BIN is NOT on your PATH — commands resolve only by full path until you add:"
     echo "     export PATH=\"\$HOME/bin:\$PATH\"    # in ~/.zshrc, then open a new terminal" ;;
esac

# ── 3. bumblebee guard (install-time gate) ──────────────────────────────────
say "bumblebee guard (shell install-gate)"
GUARD="$BIN/bumblebee-guard.sh"
ln -sf "$REPO/bin/bumblebee-guard.sh" "$GUARD"; ok "guard → $GUARD"
if ! grep -q 'bumblebee-guard.sh' "$HOME/.zshrc" 2>/dev/null; then
  warn "Not sourced in ~/.zshrc. Add this line to enable install-time gating:"
  echo "     source \"$GUARD\""
else
  ok "already sourced in ~/.zshrc"
fi

# ── 4. daily launchd agent ──────────────────────────────────────────────────
if [ "$WANT_AGENT" -eq 1 ]; then
  say "Scheduling daily OSV scan at $(printf '%02d:%02d' "$HOUR" "$MIN")"
  PLIST="$HOME/Library/LaunchAgents/com.hiveguard.osv-daily.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s#__BIN__#$BIN#g" -e "s#__HOME__#$HOME#g" \
      -e "s#__HOUR__#$HOUR#g" -e "s#__MIN__#$MIN#g" \
      "$REPO/launchd/com.hiveguard.osv-daily.plist.template" > "$PLIST"
  UID_="$(id -u)"
  launchctl bootout   "gui/$UID_/com.hiveguard.osv-daily" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$PLIST" && ok "launchd agent loaded"
  launchctl enable    "gui/$UID_/com.hiveguard.osv-daily" 2>/dev/null || true
  echo "     test now:  launchctl kickstart -k gui/$UID_/com.hiveguard.osv-daily"
else
  say "Skipping launchd agent (--no-agent)"
fi

echo; say "Done. Try:  safe-add npm left-pad --check-only"

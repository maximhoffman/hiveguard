#!/usr/bin/env bash
# =============================================================================
# bumblebee-guard.sh
#
# Проверка пакетов на известные supply-chain компрометации ПЕРЕД установкой.
# Переопределяет команды npm / pnpm / yarn / bun / pip / go так, чтобы перед
# фактической установкой свериться с каталогом угроз bumblebee (threat_intel).
#
# Подключение: добавьте в конец ~/.zshrc строку
#     source ~/bin/bumblebee-guard.sh
# и перезапустите терминал (или `source ~/.zshrc`).
#
# Требуется: bumblebee, jq, и git-клон каталога в $HOME/bumblebee-src.
#
# ВАЖНО — что это НЕ делает:
#   * Не защищает от свежей атаки, которой ещё нет в каталоге threat_intel.
#     Это фильтр «не дать поставить ЗАВЕДОМО плохое», а не гарантия чистоты.
#   * Держите каталог свежим:  git -C ~/bumblebee-src pull
# =============================================================================

# --- Настройки ---------------------------------------------------------------
BB_CATALOG="${BB_CATALOG:-$HOME/bumblebee-src/threat_intel}"
BB_BIN="$(command -v bumblebee 2>/dev/null || echo "$HOME/go/bin/bumblebee")"
# -----------------------------------------------------------------------------

# Сообщение и красный баннер при находке.
_bb_alert() {
  printf '\n\033[41m\033[1m  ⛔️  BUMBLEBEE: ОБНАРУЖЕН СКОМПРОМЕТИРОВАННЫЙ ПАКЕТ  \033[0m\n' >&2
  printf '\033[1m%s\033[0m\n' "$1" >&2
}
_bb_ok()   { printf '\033[32m✅ bumblebee: чисто — %s\033[0m\n' "$1"; }
_bb_info() { printf '\033[33m🐝 bumblebee: %s\033[0m\n' "$1"; }

# Проверка наличия инструментов.
_bb_preflight() {
  if [ ! -x "$BB_BIN" ]; then
    echo "bumblebee не найден ($BB_BIN). Гейт пропущен." >&2; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq не установлен (brew install jq). Гейт пропущен." >&2; return 1
  fi
  if [ ! -d "$BB_CATALOG" ]; then
    echo "Каталог угроз не найден ($BB_CATALOG). Гейт пропущен." >&2; return 1
  fi
  return 0
}

# Скан каталога на диске через bumblebee. 0 = чисто, 1 = есть находки.
_bb_scan_dir() {
  local dir="$1" profile="${2:-deep}" n
  n="$("$BB_BIN" scan --profile "$profile" --root "$dir" \
        --exposure-catalog "$BB_CATALOG" --findings-only 2>/dev/null \
        | grep -c '"record_type":"finding"')"
  [ "${n:-0}" -gt 0 ] && return 1 || return 0
}

# Печать найденного (для подробностей после блокировки).
_bb_report_dir() {
  "$BB_BIN" scan --profile "${2:-deep}" --root "$1" \
    --exposure-catalog "$BB_CATALOG" --findings-only 2>/dev/null \
    | jq -r 'select(.record_type=="finding") |
        "  • \(.severity)\t\(.ecosystem)\t\(.package_name)@\(.version)\n    \(.source_file)"'
}

# Прямая сверка одного пакета с каталогом (для pip dry-run). 0 = совпадение.
_bb_catalog_hit() {
  jq -e --arg e "$1" --arg n "$2" --arg v "$3" \
    '.entries[]? | select(.ecosystem==$e and .package==$n and ((.versions // [])|index($v)))' \
    "$BB_CATALOG"/*.json >/dev/null 2>&1
}

_bb_is_node_install() {
  case "$1" in install|i|in|add|ci|update|up) return 0;; *) return 1;; esac
}

# --- Общий гейт для Node-менеджеров -----------------------------------------
# Стратегия: поставить с --ignore-scripts (опасные lifecycle-скрипты НЕ
# выполняются) -> просканировать -> если чисто, до-запустить скрипты.
_bb_node_guard() {
  local mgr="$1"; shift
  # Не install-команда (run/test/ls/...) — пропускаем без вмешательства.
  if ! _bb_is_node_install "${1:-}"; then command "$mgr" "$@"; return $?; fi
  if ! _bb_preflight; then command "$mgr" "$@"; return $?; fi

  # Глобальная установка: cwd не поможет, сверяемся через baseline после.
  local global=0 a
  for a in "$@"; do case "$a" in -g|--global) global=1;; esac; done

  _bb_info "ставлю без запуска скриптов и проверяю по каталогу угроз…"
  command "$mgr" "$@" --ignore-scripts || { echo "$mgr: установка не удалась" >&2; return 1; }

  local scope_dir="$PWD" profile="deep"
  [ "$global" -eq 1 ] && profile="baseline"

  if _bb_scan_dir "$scope_dir" "$profile"; then
    _bb_ok "запускаю отложенные lifecycle-скрипты"
    # rebuild доступен в npm/pnpm/yarn; bun сам не запускает недоверенные скрипты.
    case "$mgr" in
      npm|pnpm|yarn) command "$mgr" rebuild ;;
      bun)           : ;;  # bun не запускает postinstall без trustedDependencies
    esac
  else
    _bb_alert "Пакеты СКАЧАНЫ, но скрипты НЕ запускались. Найдено:"
    _bb_report_dir "$scope_dir" "$profile" >&2
    {
      echo ""
      echo "Откатить установку:"
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

# --- pip: предварительная проверка через dry-run ----------------------------
# Требует pip >= 23 (флаги --dry-run/--report). Список того, что встанет,
# вычисляется без установки и сверяется с каталогом.
pip() {
  if [ "${1:-}" != "install" ]; then command pip "$@"; return $?; fi
  if ! _bb_preflight; then command pip "$@"; return $?; fi

  local report hits=0 name ver
  report="$(mktemp)"
  _bb_info "вычисляю план установки (pip --dry-run) и проверяю…"
  if ! command pip install "${@:2}" --dry-run --quiet --report "$report" >/dev/null 2>&1; then
    rm -f "$report"
    echo "pip: не удалось построить план (нужен pip>=23). Ставлю обычным образом без проверки." >&2
    command pip install "${@:2}"; return $?
  fi

  while IFS= read -r name && IFS= read -r ver; do
    [ -z "$name" ] && continue
    if _bb_catalog_hit pypi "$name" "$ver"; then
      _bb_alert "pypi: $name@$ver есть в каталоге угроз"; hits=1
    fi
  done < <(jq -r '.install[]?.metadata | .name, .version' "$report" 2>/dev/null)
  rm -f "$report"

  if [ "$hits" -ne 0 ]; then
    echo "Установка отменена." >&2; return 2
  fi
  _bb_ok "ставлю по-настоящему"
  command pip install "${@:2}"
}

# --- Go: проверка ПОСЛЕ (install-скриптов нет, загрузки защищены go.sum) -----
go() {
  command go "$@"; local rc=$?
  case "${1:-}" in
    get|install|mod|build)
      _bb_preflight || return $rc
      if ! _bb_scan_dir "$PWD" deep; then
        _bb_alert "go: найден модуль из каталога угроз"
        _bb_report_dir "$PWD" deep >&2
      fi ;;
  esac
  return $rc
}

# --- Rust: bumblebee НЕ покрывает crates.io. Подсказываем правильный инструмент.
cargo() {
  case "${1:-}" in
    add|install|update|build)
      if command -v cargo-audit >/dev/null 2>&1; then
        command cargo "$@"; local rc=$?
        _bb_info "cargo: проверяю по базе RustSec (cargo audit)…"
        command cargo audit
        return $rc
      else
        _bb_info "для Rust поставьте аудитор:  cargo install cargo-audit  (bumblebee crates не проверяет)"
      fi ;;
  esac
  command cargo "$@"
}

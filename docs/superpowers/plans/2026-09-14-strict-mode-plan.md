# Strict mode — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-09-14
Spec: `docs/superpowers/specs/2026-09-14-strict-mode-design.md` (approved product design)

This document is the design. Implementer agents are dispatched straight from it and
must not redesign. Section 1 resolves every open architecture question; section 2 is
the shared contract (file formats, names, exit codes) that all tasks must match
byte-for-byte; section 3 is the task list in waves; section 4 is the orchestrator's
independent verification script for each wave.

Conventions used throughout:

- `REPO` = the checkout being worked on (`/Users/mh/Projects/Develop/hiveguard`).
- Every test and every verification command runs with an **isolated HOME**
  (`HOME=$(mktemp -d)`) and the `HIVEGUARD_*` overrides from section 2.3. Nothing may
  touch the real `~/.hiveguard`, the real `~/.zshrc`, or the launchd label
  `com.hiveguard.osv-daily`. `doctor` is only ever run without `--fix`.
- macOS gotcha baked into every test: `mktemp -d` returns a path under `/var/folders`,
  which is a symlink to `/private/var/folders`. Both the zsh hook (`${PWD:A}`) and
  `osv-daily` (`canon_path`) resolve symlinks, so tests must canonicalise their temp
  root once: `T="$(cd "$(mktemp -d)" && pwd -P)"`.
- bash 3.2 everywhere (no associative arrays, guard empty arrays under `set -u`), no
  `timeout` (poll with a `while` loop and `sleep 1`), BSD `date`/`awk`/`sed`.

---

## 1. Architecture decisions (resolved)

### 1.1 Interception mechanism: zsh function wrappers, re-asserted from `precmd`

**Mechanism.** A new file `bin/hiveguard-strict.zsh` defines, for every intercepted
command name `C` (section 1.2), a shell function `C` whose body is exactly:

```
_hiveguard_strict_gate C "$@" || return $?; <original> "$@"
```

where `<original>` is `command C` when no function `C` existed before wrapping, or
`_hiveguard_strict_orig_C` — a copy of the pre-existing function's body — when one did
(that is how the bumblebee guard's `npm()`/`pnpm()`/`yarn()`/`bun()`/`pip()`/`go()`/
`cargo()` are preserved). The copy is made with zsh's `functions` special array:
`functions[_hiveguard_strict_orig_C]=$functions[C]` then `functions[C]='…'`. Verified on
zsh 5.9 (macOS 15): `functions[]` assignment defines the function, the wrapper's
`"$@"` passes arguments intact, the gate's non-zero return propagates.

Why not the alternatives:
- `preexec` cannot cancel a command in zsh (there is no supported abort from a preexec
  hook). Rejected.
- A ZLE `accept-line` widget only fires for lines typed at the ZLE prompt (not `zsh -c`,
  not sourced scripts, not `eval`), and fights every other ZLE plugin (autosuggestions,
  syntax highlighting, vi-mode). Rejected.
- Function wrappers are exactly what `bumblebee-guard.sh` already does, so the two
  compose by the same rule, and they are testable with `zsh -f -c 'source …; npm test'`.

**Composition with `bin/bumblebee-guard.sh` in BOTH load orders — without editing it.**
`bumblebee-guard.sh` is also sourced from bash by `bin/safe-add`, so it stays untouched.
Strict mode owns the composition on its side:

- *bumblebee first, strict second*: at source time `_hiveguard_strict_sync` finds
  `functions[npm]` already defined (bumblebee's body), copies it to
  `_hiveguard_strict_orig_npm`, and installs the wrapper. Call chain:
  `npm` → gate → bumblebee's guard → `command npm`. Both checks run.
- *strict first, bumblebee second*: bumblebee's `npm() {…}` overwrites the wrapper.
  Strict registers a `precmd` hook (`add-zsh-hook precmd _hiveguard_strict_sync`) that
  runs before every prompt; the first prompt happens after `~/.zshrc` is fully sourced,
  so the sync sees `functions[npm]` without the marker string `_hiveguard_strict_gate`,
  copies bumblebee's (new) body to `_hiveguard_strict_orig_npm`, and re-installs the
  wrapper. Same call chain, both checks run. The same mechanism repairs a mid-session
  `source ~/bin/bumblebee-guard.sh`.
- The wrapper body is only ever installed when the current body does **not** contain
  the marker, so a wrapper can never wrap itself (no recursion).
- `strict off` (config flip) makes the next `precmd` **unwrap**: `functions[C]` is
  restored from `_hiveguard_strict_orig_C` (bumblebee's body, byte-identical) or
  `unfunction C` when there was no original. The shell ends up exactly as if strict had
  never been sourced.

**Hot-path budget.** `_hiveguard_strict_gate` and `_hiveguard_strict_sync` are
zsh-builtins-only: file reads via `$(<file)` (zsh reads the file directly, no fork —
verified under `ulimit -u 1`), `zmodload zsh/parameter` for `$functions`, `zmodload
zsh/datetime` for `$EPOCHSECONDS`, parameter expansion for parsing. No `jq`, `awk`,
`date`, `grep`, no `$(cmd)`, no subshells. The **only** fork on any strict path is the
detached background scan on the *unknown-project* path, at most once per project per
freshness window (section 1.5). The verification plan proves the no-fork property by
running the blocked / known-clean / paused paths under `ulimit -u 1`, where any fork
fails loudly.

**No repair-command exemption.** The gate refuses every intercepted command name for a
blocked project, including `npm install`, `npm update`, `npm audit fix`, `pip install
-U`, `cargo update`. The pause is the only way through. No task may add a carve-out,
and no argument inspection exists in the gate (it never looks at `$2…`).

### 1.2 Intercepted command set and the allowlist

**Intercepted (the default set, `_HIVEGUARD_STRICT_CMDS`):**

```
npm pnpm yarn bun npx pnpx bunx node deno
pip pip3 python python3 uv uvx poetry pipenv pytest
cargo go
gem bundle bundler rake ruby
composer php
make cmake gradle mvn mix swift just
```

Rationale: every package manager the README lists as covered, the runtimes that execute
a project (`node`, `deno`, `python*`, `ruby`, `php`), and the build/task runners that
run project-defined code (`make`, `cmake`, `gradle`, `mvn`, `mix`, `swift`, `just`).
Users extend the set with the config key `strict_commands_extra=<space-separated names>`
(read by `_hiveguard_strict_sync` from the config file — no hot-path cost beyond the
config read it already does).

**Never intercepted (by construction — the hook only ever wraps the names above):**
`hiveguard`, `hvg` (every subcommand: scan, ack, pause, report must always work),
`git`, `gh`, `brew`, `docker`, editors (`vim`, `nvim`, `code`, `subl`, `emacs`, `open`),
navigation and inspection (`cd`, `ls`, `cat`, `less`, `find`, `rg`, `grep`), and all
shell builtins. There is no allowlist data structure: not being in the intercepted set
*is* the allowlist. Docs must state the honest boundary: only a **bare command name**
resolved through the shell is intercepted — `./gradlew`, `./node_modules/.bin/x`,
`sudo npm …`, an `alias npm=…` defined after the hook, and anything launched outside a
shell that sourced the hook (IDE Run, double-click, Docker Desktop, already-running
processes, `zsh -c`, cron, launchd) are not.

### 1.3 State files and env overrides

| Purpose | File (default) | Env override | Format |
|---|---|---|---|
| Enabled flag | `~/.hiveguard/config` | `HIVEGUARD_CONFIG` (existing) | `strict=1` (absent / any other value = off); optional `strict_commands_extra=a b c` |
| Blocked / acked roots | `~/.hiveguard/osv-markers.tsv` | `HIVEGUARD_MARKERS` (existing) | existing: `root<TAB>status<TAB>summary` |
| Pauses | `~/.hiveguard/strict-pauses.tsv` | `HIVEGUARD_PAUSES` (new) | `root<TAB>until_epoch` — one row per root; `root` is canonical (realpath); `until_epoch` is integer Unix seconds |
| Scan coverage | `~/.hiveguard/osv-coverage.tsv` | `HIVEGUARD_COVERAGE` (new) | `target<TAB>scanned_epoch` — one row per canonical scan target, upserted by every successful real scan |
| Background-scan debounce | `~/.hiveguard/strict-attempts.tsv` | `HIVEGUARD_STRICT_ATTEMPTS` (new) | `root<TAB>attempt_epoch` — appended by the zsh hook when it kicks off a background scan |
| Background-scan log | `~/.hiveguard/strict.log` | none (fixed to `$HOME`, like the report) | free text, one line per background scan |
| Probe report | `~/.hiveguard/osv-probe.html` | none (fixed to `$HOME`) | HTML, written only by `osv-daily --probe` |
| Dispatcher used by the hook for background scans | sibling `hiveguard` of the hook file | `HIVEGUARD_BIN` (new, tests only) | path |

Pauses are **time-based, per root, cross-shell**: the zsh gate honours a row whose
`until_epoch > EPOCHSECONDS`; expired rows are ignored by the gate (it never writes)
and pruned by any write from the bash CLI. Closing a terminal changes nothing.

### 1.4 Known vs unknown/stale — replaces the spec's suggested derivation

The spec suggested deriving "known" from `osv-last-scan.json`'s `target` + `stamp`.
**Replaced**, for three concrete reasons: (1) `target` is the *un-canonicalised*,
space-joined argv string (`TARGET_STR="${TARGETS[*]}"`), so it is ambiguous for paths
with spaces and does not match the realpath'd `$PWD` the hook sees; (2) it holds only
the *last* scan's targets, so a one-off `hiveguard daily ~/other` would make every
`~/Projects` project "unknown" until the next scheduled run; (3) parsing JSON with zsh
builtins on the hot path is fragile. The minimum new state is the coverage TSV above.

**Rules the gate applies, in order** (for `cur=${PWD:A}`):

1. Strict off (config) → proceed. Nothing else is read.
2. Innermost marker row whose root equals or contains `cur` (same longest-prefix rule
   as the chpwd hook):
   - status `active` → **blocked**, unless a pause row for that exact root is still
     running → proceed. Blocked = refuse (section 1.8). An active marker blocks
     **regardless of coverage age** — see 1.9 for why.
   - status `acked` → proceed (there is data; it is acknowledged).
3. No marker row → consult coverage: a row whose target equals or contains `cur` and
   whose `scanned_epoch >= EPOCHSECONDS - 604800` (7 days) → **known clean** → proceed
   silently.
4. Otherwise → **unknown/stale** → proceed *and* kick off a debounced background scan
   (1.5). Never prompt, never wait.

Root for the unknown case (no marker row exists): the nearest ancestor of `cur`
(including `cur`) that contains `.git` (dir or file — worktrees), else `cur`. This
mirrors `osv-daily`'s `finding_root`, so a monorepo sub-package resolves to the repo
root and the later marker row will match.

### 1.5 Background scan and debounce

The gate (zsh) does, on the unknown path only:

1. Read the attempts file; if a row for `root` has `attempt_epoch >= EPOCHSECONDS -
   604800` → do nothing (debounced).
2. Else append `root<TAB>EPOCHSECONDS` (`print -r -- … >> file`, builtin), then detach:
   `( trap '' HUP; "$hg" strict _bgscan "$root" >/dev/null 2>&1 & )` where
   `hg=${HIVEGUARD_BIN:-$_HIVEGUARD_STRICT_DIR/hiveguard}`. The subshell form prints no
   job-control notice in interactive shells; `trap '' HUP` lets the scan survive the
   terminal closing.

`hiveguard strict _bgscan <root>` (bash, `bin/strict-mode`) decides what to scan:

- If `root` equals or sits under one of the **scheduled** folders (read from the launchd
  plist via the same awk as `osv-daily`, honouring `HIVEGUARD_SCHED_PLIST`) →
  `osv-daily --rescan` (no path → the scheduled folders). This refreshes the daily
  report, state baseline, markers and coverage consistently; the usual notification
  fires.
- Else → `osv-daily --probe "$root"`: same scan pipeline restricted to that root, report
  written to `~/.hiveguard/osv-probe.html` (the daily report and the diff baseline in
  `osv-last-scan.json` are **not** touched), markers synced for that root (the root
  itself *is* marked — the "target is never a root" rule is disabled under `--probe`
  because the probe target is a project root by construction), coverage row upserted,
  notification fires on active findings and opens the probe report.
- Every `_bgscan` appends one line to `~/.hiveguard/strict.log`:
  `[YYYY-MM-DD HH:MM] bgscan <root> → rescan|probe rc=<n>`.

Result: the current command ran; if the scan finds something the project turns red and
the **next** attempt is blocked — exactly the spec's story.

### 1.6 Subcommand surface

Dispatcher: `hiveguard strict …` → `exec "$BIN/strict-mode" "$@"`. Verbs:

```
hiveguard strict status                    # on/off, hook sourced?, blocked roots, running pauses (default verb)
hiveguard strict on | off                  # flip strict=1|0 in config; takes effect at the next prompt in every open terminal
hiveguard strict pause [path] [--for 2h]   # release ONE project for a while (default 1h; Nm / Nh / Nd)
hiveguard strict resume [path | --all]     # lift a pause early
hiveguard strict _bgscan [--dry-run] <root> # internal: background scan for an unknown project
hiveguard strict -h | --help
```

`path` defaults to the current directory and is resolved to a project root with the
same rules as the gate (innermost marker root containing it, else nearest `.git`
ancestor, else the canonical path itself). Pausing an unflagged root is allowed (a
note is printed); it is harmless and covers "I know the next scan will flag it".

`strict on` never edits `~/.zshrc`. It prints the one-line honest scope statement and,
when `~/.zshrc` does not source `hiveguard-hook.zsh`, the exact line to add (resolved
for brew vs git like `folder-mark hook`).

Shell integration is a **sibling file** `bin/hiveguard-strict.zsh`, sourced from the end
of the existing `bin/hiveguard-hook.zsh`, so users who already source the hook get
strict mode with **no `~/.zshrc` change** — enabling is one config flip. The strict file
is also sourceable on its own (sentinel-guarded, idempotent).

### 1.7 Non-interactive shells

The hook does not check interactivity. Whoever sources it gets the wrappers; the gate
writes its refusal to stderr (colour only when stderr is a tty) and returns non-zero
either way. Zsh does not read `~/.zshrc` for `zsh -c`, scripts, cron or launchd, so
those are simply unprotected — the honest terminal-level boundary from the spec, stated
in README. One consequence to document: in a shell with no prompt (`zsh -c`, a script)
`precmd` never runs, so the *strict-first-then-bumblebee* load order is only repaired at
the first prompt; tests simulate the prompt by calling `_hiveguard_strict_sync`.

### 1.8 Refusal: message and exit code

Written to **stderr**, then return **77** (`EX_NOPERM` from sysexits — distinct from
2 = usage and bumblebee's 2 = compromised, so a calling script can tell them apart):

```
⛔ hiveguard strict: 12 active vulnerabilities (2 critical) in /Users/mh/Projects/app — refusing to run `npm`.
   detail:   hiveguard daily --open
   proceed:  fix it, or pause this project:  hiveguard strict pause   (1h; e.g. --for 2h)
```

Line 1 reuses the marker row's summary verbatim (`<summary> in <root>`). Red
(`\e[31m`) only when `[[ -t 2 ]]`. No prompt, no network, no file writes on this path.

### 1.9 Decisions worth flagging to the maintainer (made, not deferred)

- **An active (red) marker blocks regardless of how old the last scan is.** The spec's
  "data older than 7 days → do not block" is applied to the *absence* of a marker (the
  coverage rule), not to an existing red marker: red is exactly the signal driving the
  Finder tag and the cd reminder, neither of which has a freshness window, and a known
  vulnerability does not expire with time. If the maintainer wants stale red markers to
  fall through, the change is one condition in the gate (rule 2) plus one test.
- **`hiveguard add npm <pkg>` inside a flagged project is not gated.** The spec exempts
  all hiveguard subcommands; `safe-add` runs `npm install` from bash where the hook is
  not loaded. Documented as a known gap; not implemented.
- **Bare command names only.** `./gradlew`, `sudo npm`, aliases and absolute paths
  bypass function wrappers. Documented, not worked around.
- **`--probe` does not write `osv-last-scan.json`**, so `hiveguard ack` on a probed,
  never-scheduled project records an open-ended mute (no advisory ids). Documented.

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 Names

| Thing | Name |
|---|---|
| Zsh hook file | `bin/hiveguard-strict.zsh` |
| Sentinel | `_HIVEGUARD_STRICT_LOADED` |
| Hook dir (captured at source time with `${${(%):-%x}:a:h}` — `:a`, not `:A`, so the brew `opt` path is kept, not the versioned Cellar path) | `_HIVEGUARD_STRICT_DIR` |
| Default command list (array) | `_HIVEGUARD_STRICT_CMDS` |
| Gate | `_hiveguard_strict_gate <cmd> [args…]` → 0 proceed / 77 refused |
| Sync (source time + precmd) | `_hiveguard_strict_sync` |
| Wrap / unwrap one name | `_hiveguard_strict_wrap <cmd>` / `_hiveguard_strict_unwrap <cmd>` |
| Preserved original | `_hiveguard_strict_orig_<cmd>` |
| Marker substring that identifies a wrapper body | `_hiveguard_strict_gate` |
| Freshness / debounce window | 604800 seconds, constant `_HIVEGUARD_STRICT_FRESH=604800` |
| Refusal exit code | 77 |
| bash CLI | `bin/strict-mode` |
| Dispatcher verb | `strict` |
| Probe report | `$HOME/.hiveguard/osv-probe.html` |
| Strict log | `$HOME/.hiveguard/strict.log` |

### 2.2 File formats (exact)

- `strict-pauses.tsv`: `root<TAB>until_epoch\n`, root canonical, one row per root, no
  header. Writers (bash) prune rows with `until_epoch <= now` on every write.
- `osv-coverage.tsv`: `target<TAB>scanned_epoch\n`, target canonical (`canon_path`),
  one row per target (upsert). Written by `osv-daily` after a successful scan
  (osv-scanner exit 0 or 1 **and** non-empty JSON) — never on a scanner failure.
- `strict-attempts.tsv`: `root<TAB>attempt_epoch\n`, append-only from zsh; bash CLI
  may prune rows older than the window when it writes pauses (optional).
- `config`: `strict=1`, `strict=0` (last occurrence wins, like `config_get`);
  `strict_commands_extra=name name …`.

### 2.3 Isolated environment for all tests and verification

```bash
REPO=/Users/mh/Projects/Develop/hiveguard
T="$(cd "$(mktemp -d)" && pwd -P)"; export HOME="$T/home"; mkdir -p "$HOME/.hiveguard"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"
export HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv"
export HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json"
export HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_SCHED_PLIST="$T/no-such.plist"      # never the real launchd plist
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"         # no Finder xattr/python calls in tests
mkdir -p "$T/stubs"; printf '#!/bin/sh\necho "REAL npm $*"\n' > "$T/stubs/npm"; chmod +x "$T/stubs/npm"
mkdir -p "$T/proj/app/.git" "$T/proj/app/sub" "$T/elsewhere/x/.git"
```

Zsh checks run as `zsh -f -c '…'` (no rc files) with `PATH="$T/stubs:/usr/bin:/bin"`.
`osv-daily` checks need the real `osv-scanner` and network (OSV API); the vulnerable
fixture is `printf 'PyYAML==5.3\n' > "$T/proj/app/requirements.txt"` (CLAUDE.md's
proven fixture). Note: if `terminal-notifier` is installed, a scan with findings pops a
real desktop notification — harmless, expected.

---

## 3. Tasks

Model tiers: `sonnet` = mechanical, fully specified; `opus` = stateful/subtle. No two
tasks in one wave write the same file.

### Wave 1 (parallel: T1, T2, T3, T4)

---

#### T1 — `osv-daily`: coverage file + `--probe` mode

- **Model:** opus
- **Owns:** `bin/osv-daily`, `tests/osv-coverage.test.sh`
- **Depends on:** nothing

**Do:**

1. New env: `COVERAGE="${HIVEGUARD_COVERAGE:-$HOME/.hiveguard/osv-coverage.tsv}"`.
2. Capture the scanner outcome in **both** scan branches without changing existing
   behaviour: in the non-interactive branch replace `… 2>/dev/null || true` with
   `scan_rc=0; … 2>/dev/null || scan_rc=$?` (output/exit of osv-daily unchanged). Set
   `SCAN_OK=1` iff `[ -s "$JSON" ]` (evaluated **before** the empty-JSON fallback) and
   `scan_rc` is 0 or 1.
3. After the `folder-mark sync` block, if `SCAN_OK=1`, upsert one row per
   `CANON_TARGETS` entry: `target<TAB>$(date +%s)` into `$COVERAGE`, atomic
   (`mktemp` + awk `$1!=r` + append + `mv`, like `folder-mark`'s `tsv_upsert`). Rows for
   other targets are preserved. `mkdir -p` the parent.
4. New flag `--probe <path>` (exactly one path; combining with `--open`, `--rescan`,
   `--if-due`, or extra positional paths → usage error exit 2):
   - never prompts, never shows the progress spinner (`SHOW_PROGRESS=0`), scans
     immediately;
   - `REPORT="$HOME/.hiveguard/osv-probe.html"`;
   - `STATE=""` before the python step, so no baseline is read and none written
     (`osv-last-scan.json` is untouched);
   - export `PROBE=1` to the python block; in `finding_root` aggregation the
     `if root in scan_targets: continue` skips are **disabled** when `PROBE=1` (the
     probe target is a project root by construction);
   - the log line is `[STAMP] probe projects=… → $REPORT` (prefix the existing format
     with `probe `); the notification fires as usual with `-open file://$REPORT`;
   - markers sync and coverage upsert run exactly as for a normal scan (target = the
     canonical probe path);
   - exit 0 on completion (same as a normal scan).
5. Header comment: document `--probe` (one line under the flag list) and the coverage
   file (one sentence next to the state-file sentence). Keep `help.awk` rendering
   intact (a ` # ` row for the flag).
6. Write `tests/osv-coverage.test.sh` (bash 3.2, self-contained, uses section 2.3's
   scaffold, real osv-scanner, prints `ok`/`FAIL` lines, exits non-zero on any FAIL).

**Acceptance criteria** (orchestrator runs with the 2.3 scaffold and the PyYAML fixture):

```bash
cd "$T" && "$REPO/bin/osv-daily" "$T/proj" >/dev/null 2>&1; echo "rc=$?"           # rc=0
cat "$HIVEGUARD_COVERAGE"                                                            # exactly one row: "$T/proj<TAB><epoch>"
awk -F'\t' -v now="$(date +%s)" '{ if ($1=="'"$T"'/proj" && now-$2>=0 && now-$2<300) print "fresh" }' "$HIVEGUARD_COVERAGE"   # fresh
grep -c "^$T/proj/app"$'\t'"active"$'\t' "$HIVEGUARD_MARKERS"                                # 1
ls "$HOME/.hiveguard/osv-projects.html" "$HIVEGUARD_STATE" >/dev/null && echo both    # both
# probe an unscheduled root without touching the daily artifacts:
S1="$(stat -f %m "$HOME/.hiveguard/osv-projects.html")"; ST1="$(md5 -q "$HIVEGUARD_STATE")"
mkdir -p "$T/elsewhere/x/.git"; printf 'PyYAML==5.3\n' > "$T/elsewhere/x/requirements.txt"
"$REPO/bin/osv-daily" --probe "$T/elsewhere/x" >/dev/null 2>&1; echo "rc=$?"          # rc=0
[ -s "$HOME/.hiveguard/osv-probe.html" ] && echo probe-report                         # probe-report
[ "$S1" = "$(stat -f %m "$HOME/.hiveguard/osv-projects.html")" ] && echo daily-untouched   # daily-untouched
[ "$ST1" = "$(md5 -q "$HIVEGUARD_STATE")" ] && echo state-untouched                   # state-untouched
grep -c "^$T/elsewhere/x"$'\t'"active"$'\t' "$HIVEGUARD_MARKERS"                              # 1  (root == target IS marked under --probe)
grep -c "^$T/proj/app"$'\t'"active"$'\t' "$HIVEGUARD_MARKERS"                                # 1  (row outside the probe target preserved)
wc -l < "$HIVEGUARD_COVERAGE"                                                        # 2
tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '^\[.*\] probe '                   # 1
"$REPO/bin/osv-daily" --probe "$T/a" "$T/b" >/dev/null 2>&1; echo "rc=$?"             # rc=2
"$REPO/bin/osv-daily" --probe "$T/a" --open >/dev/null 2>&1; echo "rc=$?"             # rc=2
# scanner failure never writes coverage: an empty dir has no manifests
rm -f "$HIVEGUARD_COVERAGE"; mkdir -p "$T/empty"; "$REPO/bin/osv-daily" "$T/empty" >/dev/null 2>&1; echo "rc=$?"   # rc=0 (unchanged behaviour)
[ ! -e "$HIVEGUARD_COVERAGE" ] && echo no-coverage-on-failure                        # no-coverage-on-failure  (osv-scanner exits >1 with no sources → SCAN_OK=0)
bash "$REPO/tests/osv-coverage.test.sh"; echo "rc=$?"                                # rc=0
"$REPO/bin/osv-daily" --help | grep -c -- '--probe'                                   # ≥1
```

If the "empty dir" case turns out to produce non-empty JSON with exit 0/1 on the
installed osv-scanner version, the implementer replaces that check with a
non-existent path (`"$T/nope"`) and records the observed behaviour in the test file.

**Do not:** change the report HTML, the notification text for normal scans, the
`--if-due`/`--open`/`--rescan` semantics, the state-file schema, or any exit code of
existing paths; do not touch `folder-mark`; do not add a whole-home default.

---

#### T2 — `bin/hiveguard-strict.zsh` (the guard) + sourcing from the existing hook

- **Model:** opus
- **Owns:** `bin/hiveguard-strict.zsh` (new), `bin/hiveguard-hook.zsh` (append only),
  `tests/strict-hook.test.zsh`
- **Depends on:** nothing (uses the section 2 contracts; stubs the dispatcher via
  `HIVEGUARD_BIN`)

**Do:**

1. Create `bin/hiveguard-strict.zsh` with a header comment in the style of
   `hiveguard-hook.zsh` (what it is, the honest scope line, the state files with env
   overrides, the builtins-only policy, idempotent sourcing). Structure:

   ```zsh
   if [[ -z ${_HIVEGUARD_STRICT_LOADED:-} ]]; then
     typeset -g _HIVEGUARD_STRICT_LOADED=1
     typeset -g _HIVEGUARD_STRICT_DIR="${${(%):-%x}:a:h}"
     typeset -gi _HIVEGUARD_STRICT_FRESH=604800
     typeset -ga _HIVEGUARD_STRICT_CMDS=( npm pnpm yarn bun npx pnpx bunx node deno
       pip pip3 python python3 uv uvx poetry pipenv pytest cargo go
       gem bundle bundler rake ruby composer php make cmake gradle mvn mix swift just )
     zmodload -i zsh/parameter; zmodload -i zsh/datetime

     _hiveguard_strict_enabled()  # 0 iff config has strict=1 (last strict= line wins); also fills _hiveguard_strict_extra (array) from strict_commands_extra=
     _hiveguard_strict_wrap()     # $1=cmd; return if body already contains the marker; copy existing body to _hiveguard_strict_orig_$1; install wrapper
     _hiveguard_strict_unwrap()   # $1=cmd; only if body contains the marker; restore orig or unfunction
     _hiveguard_strict_sync()     # emulate -L zsh; if enabled: wrap each of CMDS+extra; else: unwrap each of CMDS+extra
     _hiveguard_strict_gate()     # emulate -L zsh; rules of section 1.4; refusal of 1.8; bg scan of 1.5

     autoload -Uz add-zsh-hook
     add-zsh-hook precmd _hiveguard_strict_sync
   fi
   _hiveguard_strict_sync   # source-time: correct state immediately, even with no prompt
   ```

   Wrapper body text (single-quoted, name spliced in):
   `'_hiveguard_strict_gate '$c' "$@" || return $?; _hiveguard_strict_orig_'$c' "$@"'`
   or `'… || return $?; command '$c' "$@"'` when no prior function existed.

2. `_hiveguard_strict_gate` reads, via `$(<file)` guarded by `[[ -r ]]`, only what the
   current rule needs (config → markers → pauses → coverage → attempts) and never
   writes except the attempts append on the unknown path. Innermost-root selection is
   the same loop as `_hiveguard_cd_check`. Use `st`, not `status`, as a variable name.
   Root for the unknown path: walk `cur` upward while `[[ ! -e $dir/.git ]]` and
   `$dir != /`; fallback `cur`. Detach the scan exactly as in 1.5 with
   `hg=${HIVEGUARD_BIN:-$_HIVEGUARD_STRICT_DIR/hiveguard}`.
3. Append to the **end** of `bin/hiveguard-hook.zsh` (after the existing final
   `_hiveguard_cd_check` line), nothing else in that file changes:

   ```zsh
   # Strict mode (opt-in via `hiveguard strict on`) lives in a sibling file so the one
   # `source` line above also enables the guard. Missing sibling (older install) → skip.
   [[ -r "${${(%):-%x}:a:h}/hiveguard-strict.zsh" ]] && source "${${(%):-%x}:a:h}/hiveguard-strict.zsh"
   ```

4. Write `tests/strict-hook.test.zsh` (`#!/usr/bin/env zsh`, run as `zsh -f
   tests/strict-hook.test.zsh`; self-contained scaffold per 2.3; `HIVEGUARD_BIN` points
   at a stub that appends its argv to `$T/bgcalls`). It must cover every acceptance
   line below plus: innermost root wins; `strict_commands_extra=foo` wraps `foo`;
   a second `source` is a no-op; `precmd` re-wrap after bumblebee overwrote the wrapper;
   `strict=0` mid-session restores bumblebee's `npm` body byte-identically.

**Acceptance criteria** (scaffold 2.3; `Z='zsh -f -c'`, `export PATH="$T/stubs:/usr/bin:/bin"`;
each block is one `zsh -f -c` invocation whose stdout/stderr are checked):

```bash
# A. OFF is a no-op: nothing defined for intercepted names, stub runs, no files created
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; (( ${+functions[npm]} )) && print DEFINED || print undefined; cd '"$T"'/proj/app; npm test; print rc=$?'
#   → undefined / REAL npm test / rc=0
ls "$HOME/.hiveguard"                                        # only: config
# B. ON + red marker → blocked, exit 77, stub NOT run, message on stderr only
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
printf '%s\tactive\t12 active vulnerabilities (2 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app/sub; npm install left-pad; print rc=$?' 2>"$T/err"
#   stdout → rc=77 (and NO "REAL npm" line);  $T/err line 1 contains: "12 active vulnerabilities (2 critical) in $T/proj/app — refusing to run `npm`"
grep -c 'hiveguard strict pause' "$T/err"                    # 1
# C. no repair exemption
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm update; print rc=$?; npm audit fix; print rc=$?' 2>/dev/null   # rc=77 / rc=77
# D. acked → runs
printf '%s\tacked\t3 acknowledged\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?'     # REAL npm test / rc=0
# E. pause running → runs; expired pause → blocked
printf '%s\tactive\t12 active vulnerabilities\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s) + 3600 ))" > "$HIVEGUARD_PAUSES"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?' 2>/dev/null   # REAL npm test / rc=0
printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s) - 1 ))" > "$HIVEGUARD_PAUSES"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?' 2>/dev/null   # rc=77
# F. no marker + fresh coverage → runs silently, no attempts row, no bg call
: > "$HIVEGUARD_MARKERS"; rm -f "$HIVEGUARD_PAUSES" "$HIVEGUARD_STRICT_ATTEMPTS" "$T/bgcalls"
printf '#!/bin/sh\necho "$@" >> '"$T"'/bgcalls\n' > "$T/stubs/hg"; chmod +x "$T/stubs/hg"; export HIVEGUARD_BIN="$T/stubs/hg"
printf '%s\t%s\n' "$T/proj" "$(date +%s)" > "$HIVEGUARD_COVERAGE"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?'   # REAL npm test / rc=0
[ ! -e "$HIVEGUARD_STRICT_ATTEMPTS" ] && [ ! -e "$T/bgcalls" ] && echo quiet             # quiet
# G. stale coverage → unknown: runs, attempts row appended, bg scan called once, debounced on repeat
printf '%s\t%s\n' "$T/proj" "$(( $(date +%s) - 700000 ))" > "$HIVEGUARD_COVERAGE"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app/sub; npm test; print rc=$?; npm test; print rc=$?'   # REAL npm test / rc=0 / REAL npm test / rc=0
sleep 1; cat "$T/bgcalls"                                    # exactly one line: strict _bgscan $T/proj/app   (root = nearest .git ancestor)
wc -l < "$HIVEGUARD_STRICT_ATTEMPTS"                         # 1
cut -f1 "$HIVEGUARD_STRICT_ATTEMPTS"                         # $T/proj/app
# H. no coverage at all + no .git anywhere → root is cwd
mkdir -p "$T/loose/dir"; zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/loose/dir; npm test >/dev/null; print rc=$?'   # rc=0
sleep 1; tail -n1 "$T/bgcalls"                               # strict _bgscan $T/loose/dir
# I. HOT PATH DOES NOT FORK (blocked, known-clean, paused, and acked paths) — any fork dies under ulimit -u 1
printf '%s\tactive\t1 active vulnerabilities\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
zsh -f -c 'ulimit -u 1; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; _hiveguard_strict_gate npm test; print rc=$?; print alive' 2>/dev/null   # rc=77 / alive
printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s) + 3600 ))" > "$HIVEGUARD_PAUSES"
zsh -f -c 'ulimit -u 1; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; _hiveguard_strict_gate npm test; print rc=$?; print alive'   # rc=0 / alive
: > "$HIVEGUARD_MARKERS"; printf '%s\t%s\n' "$T/proj" "$(date +%s)" > "$HIVEGUARD_COVERAGE"
zsh -f -c 'ulimit -u 1; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; _hiveguard_strict_gate npm test; print rc=$?; print alive'   # rc=0 / alive
zsh -f -c 'ulimit -u 1; PATH=/var/empty; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; _hiveguard_strict_gate npm test; print rc=$?; print alive'   # rc=0 / alive  (no external command anywhere)
# J. composition with bumblebee, both orders, both checks present
printf '%s\tactive\t1 active vulnerabilities\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
zsh -f -c 'source '"$REPO"'/bin/bumblebee-guard.sh; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?; [[ $functions[npm] == *_hiveguard_strict_gate* ]] && print wrapped; [[ $functions[_hiveguard_strict_orig_npm] == *_bb_node_guard* ]] && print bb-preserved' 2>/dev/null
#   → rc=77 / wrapped / bb-preserved
zsh -f -c 'source '"$REPO"'/bin/hiveguard-strict.zsh; source '"$REPO"'/bin/bumblebee-guard.sh; [[ $functions[npm] == *_hiveguard_strict_gate* ]] || print overwritten-as-expected; _hiveguard_strict_sync; cd '"$T"'/proj/app; npm test; print rc=$?; [[ $functions[_hiveguard_strict_orig_npm] == *_bb_node_guard* ]] && print bb-preserved' 2>/dev/null
#   → overwritten-as-expected / rc=77 / bb-preserved
: > "$HIVEGUARD_MARKERS"   # clean → bumblebee's guard actually runs (its pass-through for non-install verbs) and reaches the stub
zsh -f -c 'source '"$REPO"'/bin/bumblebee-guard.sh; source '"$REPO"'/bin/hiveguard-strict.zsh; cd '"$T"'/proj/app; npm test; print rc=$?' 2>/dev/null   # REAL npm test / rc=0
# K. OFF mid-session restores bumblebee byte-for-byte
zsh -f -c 'source '"$REPO"'/bin/bumblebee-guard.sh; orig=$functions[npm]; source '"$REPO"'/bin/hiveguard-strict.zsh; print -r -- "mark_finder=0
strict=0" > $HIVEGUARD_CONFIG; _hiveguard_strict_sync; [[ $functions[npm] == $orig ]] && print restored; (( ${+functions[_hiveguard_strict_orig_npm]} )) || print orig-gone'   # restored / orig-gone
# L. the existing hook sources the sibling; sourcing twice is safe
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
zsh -f -c 'source '"$REPO"'/bin/hiveguard-hook.zsh; source '"$REPO"'/bin/hiveguard-hook.zsh; (( ${+functions[_hiveguard_strict_gate]} )) && print via-hook; (( ${+functions[npm]} )) && print wrapped'   # via-hook / wrapped
# M. test file passes
zsh -f "$REPO/tests/strict-hook.test.zsh"; echo "rc=$?"     # rc=0
```

**Do not:** edit `bumblebee-guard.sh`; inspect command arguments in the gate (no
`install`/`update` special-casing in either direction); add any prompt or `read`; call
`jq`/`awk`/`date`/`python`/`grep`/`$(cmd)` anywhere in the strict file; change the
existing chpwd reminder's behaviour or output; register more than one precmd hook;
write any file other than the attempts append.

---

#### T3 — `bin/strict-mode` (the CLI: on/off/status/pause/resume/_bgscan)

- **Model:** opus
- **Owns:** `bin/strict-mode` (new, executable), `tests/strict-cli.test.sh`
- **Depends on:** nothing (calls `osv-daily` only in `_bgscan` without `--dry-run`;
  the dry-run path is what tests exercise)

**Do:**

1. bash, `set -euo pipefail`, header comment block renderable by `help.awk` with the
   exact verb table of section 1.6 (` # ` rows), the honest scope line, and the state
   files with their env overrides. Resolve `BINDIR`/`REPO` by the symlink-chain loop
   used in `folder-mark`. `usage()` via `help.awk` like the other tools.
2. Env: `CONFIG`, `MARKERS`, `PAUSES` (`HIVEGUARD_PAUSES`), `SCHED_PLIST`
   (`HIVEGUARD_SCHED_PLIST`, default the real plist path), `STRICT_LOG="$HOME/.hiveguard/strict.log"`.
   Copy `config_get`/`config_set` from `folder-mark` (same semantics).
3. `resolve_root <path>`: canonicalise (`cd … && pwd -P`, fallback python realpath,
   fallback input — copy `canon_path` from `osv-daily`); innermost marker root that
   equals or contains it (longest match); else walk up for `.git` (dir or file); else
   the canonical path. Print the root.
4. `pause [path] [--for <dur>]`: `<dur>` matches `^[0-9]+[mhd]$` (default `1h`); bad
   duration → stderr `invalid --for: …  (use 30m, 2h, 1d)` exit 2. Compute
   `until=$(date +%s)+seconds`; prune expired rows; upsert `root<TAB>until` atomically;
   print `✔ Strict mode paused for <root> until YYYY-MM-DD HH:MM (<dur>). Other projects stay protected.`
   then `  lift early: hiveguard strict resume "<root>"`; if `<root>` has no `active`
   marker row also print `  (note: this project is not currently flagged — the pause is recorded anyway)`.
   Human time via `date -r "$until" '+%Y-%m-%d %H:%M'` (BSD date).
5. `resume [path|--all]`: `--all` empties the file and prints `✔ All pauses lifted.`;
   otherwise remove that root's row → `✔ Pause lifted for <root>.`; nothing to lift →
   `No pause active for <root>.` exit 0.
6. `on`: `config_set strict 1`; print
   `✔ Strict mode on — flagged (red) projects refuse to run/build/install until you fix or pause them.`
   `  Terminal-level guard: it cannot stop an IDE Run button, a double-click, Docker Desktop, or a process already running.`
   `  Takes effect at the next prompt in every open terminal.`
   then the hook status line exactly as `folder-mark status` prints it (`Terminal hook:
   sourced in ~/.zshrc (…)` / `Terminal hook: not sourced in ~/.zshrc`), and when not
   sourced, the `source "<hook path>"` line (same `hook_script_path` logic as
   `folder-mark`: brew opt prefix vs sibling). `off`: `config_set strict 0`; print
   `✔ Strict mode off. Open terminals stop blocking at their next prompt.`
7. `status` (default verb): prints, in this order,
   `Strict mode: on` | `Strict mode: off  (enable: hiveguard strict on)`;
   the `Terminal hook:` line; `Blocked (red) projects: N` followed by one
   `  <root>\t<summary>` line per `active` marker row (or `  (none)`);
   `Paused:` followed by `  <root>\tuntil YYYY-MM-DD HH:MM (<n> min left)` per running
   pause (or `  (none)`). Expired rows are pruned as a side effect. Exit 0.
8. `_bgscan [--dry-run] <root>`: read scheduled folders from `$SCHED_PLIST` (copy the
   awk from `osv-daily`; missing file → none), canonicalise each; if `<root>` equals or
   is under one → mode `rescan` else `probe`. `--dry-run` prints `rescan` or
   `probe <root>` and exits 0 (nothing else runs). Without it: run
   `"$BINDIR/osv-daily" --rescan` or `"$BINDIR/osv-daily" --probe "$root"` with
   stdout+stderr appended to `$STRICT_LOG`, then append
   `[YYYY-MM-DD HH:MM] bgscan <root> → <mode> rc=<n>`; exit 0 regardless of the scan's rc.
9. Unknown verb → `unknown verb: X (see: hiveguard strict --help)` exit 2.
10. `tests/strict-cli.test.sh` (bash 3.2; scaffold 2.3) covering every acceptance line.

**Acceptance criteria** (scaffold 2.3; `SM="$REPO/bin/strict-mode"`):

```bash
"$SM" status | head -n1                                   # Strict mode: off  (enable: hiveguard strict on)
"$SM" on | head -n1                                       # ✔ Strict mode on — flagged (red) projects refuse to run/build/install until you fix or pause them.
"$SM" on | grep -c 'cannot stop an IDE Run button'        # 1
grep -c '^strict=1$' "$HIVEGUARD_CONFIG"                  # 1
grep -c '^mark_finder=0$' "$HIVEGUARD_CONFIG"             # 1   (other keys preserved)
"$SM" on | grep -c 'Terminal hook: not sourced in ~/.zshrc'   # 1   (isolated HOME has no .zshrc)
"$SM" on | grep -c 'hiveguard-hook.zsh'                   # ≥1  (prints the source line)
"$SM" off | head -n1                                      # ✔ Strict mode off. Open terminals stop blocking at their next prompt.
grep -c '^strict=0$' "$HIVEGUARD_CONFIG"                  # 1
grep -c '^strict=' "$HIVEGUARD_CONFIG"                    # 1   (replaced, not appended)
"$SM" on >/dev/null
printf '%s\tactive\t12 active vulnerabilities (2 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
( cd "$T/proj/app/sub" && "$SM" pause ) | head -n1        # ✔ Strict mode paused for $T/proj/app until <YYYY-MM-DD HH:MM> (1h). Other projects stay protected.
cut -f1 "$HIVEGUARD_PAUSES"                               # $T/proj/app   (innermost marker root, from a subdir)
awk -F'\t' -v now="$(date +%s)" '{d=$2-now; if (d>3590 && d<=3600) print "one-hour"}' "$HIVEGUARD_PAUSES"   # one-hour
( cd "$T/proj/app" && "$SM" pause --for 2h ) >/dev/null; awk -F'\t' -v now="$(date +%s)" '{d=$2-now; if (d>7190 && d<=7200) print "two-hours"}' "$HIVEGUARD_PAUSES"   # two-hours
wc -l < "$HIVEGUARD_PAUSES"                               # 1   (upsert, not append)
"$SM" pause "$T/proj/app" --for 90 >/dev/null 2>&1; echo "rc=$?"     # rc=2
"$SM" pause "$T/elsewhere/x" | grep -c 'not currently flagged'        # 1   (unflagged .git root)
cut -f1 "$HIVEGUARD_PAUSES" | sort                         # $T/elsewhere/x  then  $T/proj/app
"$SM" status | sed -n '/^Paused:/,$p' | grep -c 'until .* min left)'  # 2
"$SM" status | sed -n '/^Blocked (red) projects:/,/^Paused:/p' | grep -c "$T/proj/app"   # 1
"$SM" resume "$T/proj/app"                                # ✔ Pause lifted for $T/proj/app.
"$SM" resume "$T/proj/app"                                # No pause active for $T/proj/app.
"$SM" resume --all; wc -l < "$HIVEGUARD_PAUSES"           # ✔ All pauses lifted.  /  0
printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s) - 5 ))" > "$HIVEGUARD_PAUSES"; "$SM" status >/dev/null; wc -l < "$HIVEGUARD_PAUSES"   # 0   (expired row pruned)
"$SM" _bgscan --dry-run "$T/proj/app"                     # probe $T/proj/app   (no schedule plist)
cat > "$HIVEGUARD_SCHED_PLIST" <<EOF
<plist><dict><key>ProgramArguments</key><array><string>/x/hiveguard</string><string>daily</string><string>$T/proj</string><string>--if-due</string></array></dict></plist>
EOF
"$SM" _bgscan --dry-run "$T/proj/app"                     # rescan
"$SM" _bgscan --dry-run "$T/elsewhere/x"                  # probe $T/elsewhere/x
"$SM" bogus >/dev/null 2>&1; echo "rc=$?"                 # rc=2
"$SM" --help | grep -c 'hiveguard strict pause'           # ≥1
bash "$REPO/tests/strict-cli.test.sh"; echo "rc=$?"       # rc=0
```

**Do not:** edit `~/.zshrc` (print, never write); touch `folder-mark`, `osv-daily`, or
the dispatcher; run `launchctl` anywhere; add verbs beyond the table; add a
"repair-command" allowance of any kind; use `timeout`; use associative arrays.

---

#### T4 — dispatcher wiring + test runner

- **Model:** sonnet
- **Owns:** `bin/hiveguard`, `tests/run.sh` (new, executable)
- **Depends on:** nothing

**Do:**

1. `bin/hiveguard`: add `strict) exec "$BIN/strict-mode" "$@" ;;` after the `mark)`
   line. In the header comment add, after the `mark` row under **Actions**:
   `#   hiveguard strict on|off|status|pause|resume   # refuse to run/build a red-flagged project (terminal-level)`.
   Keep column alignment consistent with neighbouring rows (help.awk pads by widest
   command anyway).
2. `tests/run.sh` (bash, `set -uo pipefail` — not `-e`, it must keep going): for each
   `tests/*.test.sh` run `bash "$f"`, for each `tests/*.test.zsh` run `zsh -f "$f"`;
   print `PASS <file>` / `FAIL <file> (rc=N)`; final line `N passed, M failed`; exit 1 if
   any failed. Accept an optional filter argument (substring of the filename). Must work
   with zero test files present (prints `0 passed, 0 failed`, exit 0).

**Acceptance criteria:**

```bash
"$REPO/bin/hiveguard" help | grep -c 'hiveguard strict'     # 1   (non-tty path prints the raw block)
"$REPO/bin/hiveguard" strict --help >/dev/null 2>&1; echo "rc=$?"   # rc=0 once T3 lands; before T3: rc=1 with "No such file" — either is acceptable in wave 1
"$REPO/bin/hiveguard" bogus >/dev/null 2>&1; echo "rc=$?"   # rc=2 (unchanged)
bash "$REPO/tests/run.sh" nomatch; echo "rc=$?"               # 0 passed, 0 failed / rc=0
bash "$REPO/tests/run.sh"; echo "rc=$?"                       # PASS/FAIL per file, exit 0 iff all pass (after wave 1 lands)
```

**Do not:** change any other dispatcher case; add a `strict` alias; reformat the help
block; add test helpers beyond the runner.

---

### Wave 2 (parallel: T5, T6, T7, T8) — after all of wave 1 is verified

---

#### T5 — `doctor`: strict-mode health section

- **Model:** sonnet
- **Owns:** `bin/doctor`
- **Depends on:** T2, T3

**Do:** insert a new section **between** "Folder markers" (6) and "Prerequisites"
(renumber the comment banners 7 → strict, 8 → prerequisites). Reuse `MCONFIG`,
`hook_line`, `hp_expanded` computed in section 6. Logic:

- `strict` value via the same awk-last-wins read as `mark_finder_on`.
- off → `ok "strict mode: off (enable with: hiveguard strict on)"`.
- on → `ok "strict mode: on"`, then:
  - no `hook_line` → `bad "strict mode is on but the terminal hook is not sourced in ~/.zshrc — nothing is being blocked"` + `remedy "run: hiveguard mark hook   (then add the printed line to ~/.zshrc)"`;
  - hook sourced but `"$(dirname "$hp_expanded")/hiveguard-strict.zsh"` missing →
    `bad "the sourced hook ($hp) has no hiveguard-strict.zsh next to it — an older install; strict mode is not active"` + remedy `hiveguard mark hook`;
  - else `ok "terminal hook provides strict mode ($hp)"`.
  - pauses file `${HIVEGUARD_PAUSES:-$HOME/.hiveguard/strict-pauses.tsv}`: count rows
    with `$2 > now` → `ok "running pauses: N"`; any row with fewer than 2 fields or a
    non-numeric `$2` → `warn "pause file has N malformed row(s)"`.
  - coverage `${HIVEGUARD_COVERAGE:-$HOME/.hiveguard/osv-coverage.tsv}` absent/empty →
    `warn "no scan coverage recorded yet — every project counts as unknown (runs, then scans in the background)"` + remedy `hiveguard daily <folder>`; else
    `ok "scan coverage: N folder(s), freshest <YYYY-MM-DD HH:MM>"`.
- Header comment "Checks:" sentence gains "strict mode".

**Acceptance criteria** (scaffold 2.3; never `--fix`):

```bash
"$REPO/bin/doctor" | grep -c 'strict mode: off'                          # 1
"$REPO/bin/doctor" --quiet; echo                                          # one word (warn or fail — unchanged semantics), no other output
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
"$REPO/bin/doctor" | grep -c 'strict mode is on but the terminal hook is not sourced'   # 1
"$REPO/bin/doctor" >/dev/null 2>&1; echo "rc=$?"                          # rc=1   (a ✖ is present)
printf 'source "%s/bin/hiveguard-hook.zsh"\n' "$REPO" > "$HOME/.zshrc"
"$REPO/bin/doctor" | grep -c 'terminal hook provides strict mode'         # 1
"$REPO/bin/doctor" | grep -c 'no scan coverage recorded yet'              # 1
printf '%s\t%s\n' "$T/proj" "$(date +%s)" > "$HIVEGUARD_COVERAGE"; printf '%s\t%s\n' "$T/proj/app" "$(( $(date +%s)+600 ))" > "$HIVEGUARD_PAUSES"
"$REPO/bin/doctor" | grep -c 'scan coverage: 1 folder'                    # 1
"$REPO/bin/doctor" | grep -c 'running pauses: 1'                          # 1
printf 'garbage\n' >> "$HIVEGUARD_PAUSES"; "$REPO/bin/doctor" | grep -c 'malformed row'   # 1
"$REPO/bin/doctor" --help | grep -c 'strict'                              # ≥1
```

**Do not:** add any `--fix` behaviour for strict (nothing here is a safe auto-repair);
edit `~/.zshrc`; call `launchctl` in the new section; change the verdict rules of
`--quiet`.

---

#### T6 — installer prompt + formula caveats

- **Model:** sonnet
- **Owns:** `install.sh`, `packaging/hiveguard.rb`
- **Depends on:** T3

**Do:**

1. `install.sh`: flags `--strict` / `--no-strict` (header comment rows too). New step
   "3b. strict mode" after the bumblebee-guard step: if a flag was given use it;
   else if `[ -t 0 ]` ask exactly:
   `Enable strict mode? A project the daily scan flags red refuses to run/build until you fix or pause it. Terminal-level only — it can't stop an IDE Run button, a double-click, or a running process. [y/N] `
   default **no** (empty answer, anything but `y`/`Y` → no); non-interactive with no
   flag → no. On yes: `"$REPO/bin/hiveguard" strict on` (its own output covers the hook
   hint). On no: `ok "strict mode left off (enable any time: hiveguard strict on)"`.
2. `packaging/hiveguard.rb`: confirm `libexec.install "bin", …` ships the whole `bin/`
   directory (it does — no per-file list exists, so `bin/strict-mode` and
   `bin/hiveguard-strict.zsh` are included automatically). Add to `caveats`, after the
   terminal-reminder paragraph:
   ```
   Strict mode (off by default) makes a project the daily scan flagged red refuse
   to run/build/install until you fix it or pause it for a while:
     hiveguard strict on            # needs the terminal hook line above in ~/.zshrc
     hiveguard strict pause --for 2h
   It is a terminal-level guard: it cannot stop an IDE Run button, a double-click,
   Docker Desktop, or a process that is already running.
   ```
   Do not write the literal placeholder tokens (`__URL__`-style) anywhere in prose.

**Acceptance criteria** (scaffold 2.3; the installer symlinks into `$HOME/bin` and calls
`schedule on` — run it with `--no-agent` so launchd is never touched):

```bash
"$REPO/install.sh" --no-agent --no-strict </dev/null | grep -c 'strict mode left off'   # 1
grep -c '^strict=' "$HIVEGUARD_CONFIG" 2>/dev/null || echo 0                             # 0
"$REPO/install.sh" --no-agent </dev/null | grep -c 'strict mode left off'                # 1   (non-interactive default = no)
"$REPO/install.sh" --no-agent --strict </dev/null | grep -c 'Strict mode on'             # 1
grep -c '^strict=1$' "$HIVEGUARD_CONFIG"                                                # 1
"$REPO/install.sh" --help | grep -c -- '--strict'                                        # ≥1
grep -c 'libexec.install "bin"' "$REPO/packaging/hiveguard.rb"                           # 1
grep -c 'hiveguard strict on' "$REPO/packaging/hiveguard.rb"                             # 1
ruby -c "$REPO/packaging/hiveguard.rb"                                                   # Syntax OK
ls -la "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard                      # 0   (nothing scheduled in the isolated HOME)
```

**Do not:** edit `~/.zshrc`; make yes the default; call `schedule on` in any new code
path; add new formula dependencies; touch `bin/`.

---

#### T7 — end-to-end integration test (hook + CLI + osv-daily + doctor)

- **Model:** opus
- **Owns:** `tests/strict-integration.test.sh`
- **Depends on:** T1, T2, T3, T4

**Do:** one bash 3.2 script using scaffold 2.3 (real osv-scanner + network, PyYAML
fixture in `$T/proj/app`, stub `npm` on PATH, `zsh -f` for every shell step, the real
`bin/hiveguard` dispatcher — no `HIVEGUARD_BIN` stub here). Steps, each printing
`ok <n>` or `FAIL <n>` and the script exiting non-zero on any FAIL:

1. `hiveguard daily "$T/proj"` → markers row active for `$T/proj/app`, coverage row for
   `$T/proj`.
2. `hiveguard strict on`; `zsh -f`: `source bin/hiveguard-hook.zsh; cd $T/proj/app; npm test` → rc 77, stderr has `refusing to run \`npm\``, no `REAL npm`.
3. `hiveguard strict pause --for 30m "$T/proj/app"`; same zsh step → `REAL npm test`, rc 0.
4. `hiveguard strict resume "$T/proj/app"` → rc 77 again.
5. `hiveguard ack "$T/proj/app/requirements.txt"`; `hiveguard daily "$T/proj"` → marker
   flips to `acked` → npm runs, rc 0.
6. `hiveguard ack --remove …`; `hiveguard daily "$T/proj"` → `active` → rc 77.
7. Unknown project end-to-end: `mkdir -p $T/elsewhere/x/.git`, PyYAML fixture inside;
   `zsh -f`: `cd $T/elsewhere/x; npm test` → `REAL npm test`, rc 0 (unknown → runs);
   attempts row present; poll up to 120 s (`while … sleep 1`) until
   `$HIVEGUARD_MARKERS` has an `active` row for `$T/elsewhere/x` and `strict.log` has a
   `bgscan … → probe rc=` line; then `npm test` again → rc 77. Daily report mtime and
   `osv-last-scan.json` unchanged by the probe.
8. `hiveguard strict off` → npm runs, rc 0; `hiveguard strict status` first line says off.
9. `doctor` (no `--fix`) exits 0 or 1 and prints a `strict mode:` line; `doctor --quiet`
   prints exactly one word.
10. Absolute no-op check: with strict off from a fresh HOME (no config key), sourcing
    `hiveguard-hook.zsh` leaves `${+functions[npm]}` = 0 and the only files under
    `$HOME/.hiveguard` are those `osv-daily` itself writes.

**Acceptance criteria:**

```bash
bash "$REPO/tests/strict-integration.test.sh"; echo "rc=$?"     # every step "ok", rc=0
bash "$REPO/tests/run.sh"; echo "rc=$?"                          # all PASS, rc=0
ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard  # 0 (in the test's HOME)
```

**Do not:** modify any `bin/` file (report defects to the orchestrator instead); use
`timeout`; skip the background-scan step because it is slow — cap it at 120 s and FAIL
if it does not land.

---

#### T8 — docs: README + CHANGELOG

- **Model:** sonnet
- **Owns:** `README.md`, `CHANGELOG.md`
- **Depends on:** T2, T3 (for exact command output wording)

**Do:**

1. README subcommand table: add after the `mark` row:
   `| \`hiveguard strict on\|off\|status\|pause\|resume\` | **Strict mode** (off by default): a project the daily scan flagged red refuses to run, build, test or install until you fix it or pause it (one project, one hour by default). Terminal-level guard only — it can't stop an IDE Run button, a double-click, Docker Desktop, or a process already running. |`
2. New section `### Strict mode` right after `### Folder markers`, containing: what it
   does in two sentences; the honest scope paragraph (one line, same wording); how to
   enable (`hiveguard strict on` + the hook line requirement, "takes effect at the next
   prompt"); a command block with `status`, `pause [--for 2h]`, `resume`, `off`; the
   refusal example from section 1.8; the rules list (red → blocked, acked → allowed,
   no repair exemption — "to fix it, pause first", unknown/stale → runs now and scans in
   the background, next attempt blocked); the intercepted command list verbatim and
   `strict_commands_extra=`; the not-intercepted list (hiveguard/hvg, git, editors,
   navigation) and the bare-command-name boundary (`./gradlew`, `sudo`, aliases);
   composition note: "works with the bumblebee guard in either `source` order — both
   checks run".
3. Data table (`Where hiveguard keeps its data`): rows for `osv-markers.tsv` (if
   missing), `strict-pauses.tsv`, `osv-coverage.tsv`, `strict-attempts.tsv`,
   `strict.log`, `osv-probe.html`.
4. `hiveguard daily` section: one sentence on `--probe <path>` (internal, used by
   strict mode's background scan; writes `osv-probe.html`, leaves the daily report and
   baseline alone).
5. `hiveguard doctor` paragraph: add "strict mode (enabled but hook not sourced)".
6. Limitations: bullets for terminal-level scope; bare command names only; `hiveguard
   add` inside a flagged project is not gated.
7. `CHANGELOG.md` under `## [Unreleased]`:
   - **Added**: strict mode (`hiveguard strict on|off|status|pause|resume`, sibling
     `hiveguard-strict.zsh` auto-sourced by the existing hook, no repair exemption,
     per-project timed pauses, unknown/stale projects run and trigger a debounced
     background scan); `hiveguard daily --probe <path>`; `osv-coverage.tsv`; `doctor`
     strict section; installer `--strict/--no-strict` and prompt (default no).
   - **Changed**: nothing behavioural when strict is off (state it explicitly).

**Acceptance criteria:**

```bash
grep -c 'hiveguard strict on|off|status|pause|resume' "$REPO/README.md"   # ≥1 (table row)
grep -c '^### Strict mode' "$REPO/README.md"                               # 1
grep -c 'strict-pauses.tsv' "$REPO/README.md"                              # ≥1
grep -c 'osv-coverage.tsv' "$REPO/README.md"                               # ≥1
grep -c -- '--probe' "$REPO/README.md"                                     # ≥1
grep -c 'IDE' "$REPO/README.md"                                            # ≥2 (table + section)
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$REPO/CHANGELOG.md" | grep -c 'strict'   # ≥3
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$REPO/CHANGELOG.md" | grep -c '^### Added'   # 1
```

**Do not:** cut a versioned CHANGELOG section (stays under Unreleased); claim
protection beyond the terminal; touch `CLAUDE.md` (gitignored, maintainer-owned);
change screenshots.

---

## 4. Verification plan (orchestrator)

Run each block in a **fresh** scaffold (section 2.3). Never run `doctor --fix`,
`schedule on/off`, or `install.sh` without `--no-agent`. Every expected value is stated
inline in the task's acceptance block; the orchestrator runs those blocks verbatim and
compares. Summary of what to run per wave and the one-line pass condition:

### Wave 1

```bash
# fresh scaffold (2.3) first, then:
# T1
bash "$REPO/tests/osv-coverage.test.sh" && echo T1-tests-ok
# + run T1's acceptance block by hand (coverage row, --probe leaves daily artifacts untouched, root==target marked, usage errors → 2)
# T2
zsh -f "$REPO/tests/strict-hook.test.zsh" && echo T2-tests-ok
# + run T2's acceptance blocks A–L by hand; the non-negotiables to eyeball:
#   A: OFF → ${+functions[npm]} is 0, "REAL npm test", no new files
#   B/C: red → rc=77, stub not run, `npm update` and `npm audit fix` also 77
#   I: every `ulimit -u 1` line prints "alive" (no fork on blocked/paused/known paths)
#   J/K: both load orders → rc=77 on red AND _hiveguard_strict_orig_npm contains _bb_node_guard; off → restored byte-identical
# T3
bash "$REPO/tests/strict-cli.test.sh" && echo T3-tests-ok
# + T3's acceptance block (pause math ±10 s, upsert not append, expired pruned, _bgscan --dry-run rescan vs probe)
# T4
"$REPO/bin/hiveguard" help | grep -c 'hiveguard strict'      # 1
bash "$REPO/tests/run.sh"; echo "rc=$?"                       # all PASS, rc=0
# hygiene for the whole wave:
git -C "$REPO" status --porcelain                              # only the files each task owns
bash -n "$REPO/bin/osv-daily" "$REPO/bin/strict-mode" "$REPO/bin/hiveguard" "$REPO/tests/run.sh"   # syntax
zsh -n "$REPO/bin/hiveguard-strict.zsh" "$REPO/bin/hiveguard-hook.zsh"
grep -n 'timeout\|declare -A' "$REPO"/tests/* "$REPO"/bin/strict-mode "$REPO"/bin/hiveguard-strict.zsh   # no output
sed -e 's/#.*$//' "$REPO/bin/hiveguard-strict.zsh" | grep -nE '\$\(|`|\bawk\b|\bjq\b|\bgrep\b|\bdate\b|\bpython3?\b|\bsed\b' | grep -v '\$(<'   # no output: no forks in the strict file (comments stripped first; $(<file) allowed; zsh/datetime is not matched by \bdate\b)
```

Commit wave 1 as: `feat(strict): guard hook, strict-mode CLI, osv-daily coverage + --probe, test runner`.

### Wave 2

```bash
# fresh scaffold (2.3)
# T5 — doctor, never --fix
"$REPO/bin/doctor" | grep -c 'strict mode: off'                         # 1
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"; "$REPO/bin/doctor" | grep -c 'not sourced in ~/.zshrc — nothing is being blocked'   # 1
# + the rest of T5's block
# T6 — installer, always --no-agent
"$REPO/install.sh" --no-agent </dev/null | grep -c 'strict mode left off'   # 1
"$REPO/install.sh" --no-agent --strict </dev/null | grep -c 'Strict mode on' # 1
ruby -c "$REPO/packaging/hiveguard.rb"                                       # Syntax OK
ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c hiveguard              # 0
# T7 — the full story (network, ~2–4 min)
bash "$REPO/tests/strict-integration.test.sh"; echo "rc=$?"                  # rc=0
# T8 — docs
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$REPO/CHANGELOG.md" | grep -c strict   # ≥3
grep -c '^### Strict mode' "$REPO/README.md"                                 # 1
# whole suite + no real-state leakage
bash "$REPO/tests/run.sh"; echo "rc=$?"                                      # rc=0
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"   # must be the SAME value as before the whole run (record it first)
stat -f %m ~/.hiveguard/osv-markers.tsv ~/.hiveguard/config ~/.hiveguard/osv-last-scan.json 2>/dev/null   # unchanged vs. values recorded before the run
```

Commit wave 2 as: `feat(strict): doctor section, installer prompt, formula caveats, docs + integration test`.

### Final manual smoke (maintainer's real shell, optional, after both commits)

`hiveguard strict status` (off), `hiveguard doctor` (strict line present, no ✖ from
strict), open a new terminal and confirm `type npm` is unchanged while strict is off.

---

## 5. Out of scope / follow-ups (open as issues, do not implement here)

- Gating `hiveguard add` inside a red project (spec exempts hiveguard subcommands).
- Letting stale red markers fall through after N days (decision 1.9; one-line change
  if the maintainer wants it).
- Pruning `osv-coverage.tsv` / `strict-attempts.tsv` rows for folders that no longer
  exist (harmless growth; one row per probed root).
- A `--probe` that also records advisory ids for scoped acks of never-scheduled
  projects.

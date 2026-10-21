# Strict mode: target-aware gate + agent-directed refusal — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-21
Previous plan (conventions, scaffold): `docs/superpowers/plans/2026-09-14-strict-mode-plan.md`

This document is the design for implementers. Agents are dispatched straight from it and
must not redesign. Section 1 fixes the behaviour; section 2 is the shared contract every
task must match byte-for-byte (message text, resolution rules, test scaffold); section 3
is the task list in waves with the executor model per task; section 4 the orchestrator's
verification and commit boundaries.

Conventions:

- `HG` = the worktree `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/strict-target-aware`,
  branch `worktree-strict-target-aware`, based on `main` = `bc19c21` (1.8.3). Work
  format 2: built-in Read/Edit with absolute worktree paths, no Serena symbolic edits.
- Parallel tasks in one wave never write the same file. Each task's **Owns** list is
  exhaustive and exclusive. Agents never run git; the orchestrator does.
- The hot path of `bin/hiveguard-strict.zsh` stays **zsh-builtins-only**: no `$(cmd)`, no
  pipes, no external command, no subshell. Allowed: parameter expansion and modifiers
  (`:A`, `:h`, `:t`, `#`, `(P)`), `[[ -e ]]`, `$commands` and `$functions` from
  zsh/parameter, `$(<file)`. The existing `ulimit -u 1` test pattern (section I of
  `tests/strict-hook.test.zsh`) is the fork detector; every new path gets a check there.
- Every test runs in the **isolated scaffold** of the existing tests (`HOME=$(mktemp -d)`
  canonicalised with `pwd -P`, every `HIVEGUARD_*` override, stubs on `PATH`,
  `HIVEGUARD_BIN` stubbed). Never the real `~/.hiveguard`.
- bash 3.2 for the bash-side tests (no associative arrays, `"${arr[@]+"${arr[@]}"}"`,
  no `timeout`). Shell-text probes go in files, never `zsh -c '…'` (the worktree hook
  refuses inline zsh text).
- Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

Probed facts the design relies on (verified on this machine, zsh 5.9, `zsh -f`):
`${commands[x]}` resolves a never-executed name through `PATH` in-process, is empty for an
unknown name and ignores a shell function of the same name; for a venv-style symlink
`proj/.venv/bin/python -> /opt/…/python`, `${exe:A}` leaves the project while
`${exe:h:A}` stays in `proj/.venv/bin`; `--prefix=~/x` reaches the function with the
tilde unexpanded while a bare `~/y` arrives expanded; `${rel:A}` of a nonexistent relative
path is `$PWD/rel` (absolute, no error); `${commands[…]}`, `:A` and `[[ -e ]]` all run
under `ulimit -u 1`.

---

## 1. Design (resolved)

### 1.1 What the gate decides on: locations, not just the cwd

The gate evaluates a short list of **locations** and refuses if any of them lies in an
`active` marker root that is not paused. The list, in evaluation order:

1. `${PWD:A}` — the current directory (today's rule, unchanged).
2. **Arguments that are existing paths** (§1.2) — in command-line order.
3. **The executable** the bare name resolves to (§1.3).
4. **The activated environment** — `$VIRTUAL_ENV`, then `$CONDA_PREFIX` (§1.4).

Per location the rule is exactly today's cwd rule: the **innermost** (longest) marker root
that equals or contains the location; `active` → blocks unless a still-running pause row
exists for that **exact** root; `acked` → does not block; no root → does not block. The
first location that blocks decides the message (§2.1); its root's summary is printed.
"Innermost per location" means an argument into an acked sub-project inside an active
monorepo passes, and an argument into the active outer project from an acked inner cwd is
refused — each location is judged on its own.

Refusal is terminal: no coverage check, no background scan, exit 77.

Today's rules 3 and 4 (coverage freshness, debounced background scan — rules 4 and 5 in
the renumbered header of §2.3) apply to **the cwd only**, after no location blocked. Targets are matched against markers and nothing else. Why:
(a) the thing being scanned should be where the user works, and the cwd already is;
(b) a target can be anywhere — `python /tmp/x.py` or `pip install -r ~/Downloads/req.txt`
would kick scans of `/tmp` or of a protected folder that a background agent cannot read
(CLAUDE.md: silent 0, never whole-home); (c) the `.git`-ancestor walk for an arbitrary
target can climb into `~`; (d) it keeps the hot path to one marker-file read.
Consequence, documented in README: a target inside a never-scanned project is not
refused and does not get it scanned — only working *in* that project does.

Order of locations is cheapest-first-visible-first: cwd (unchanged behaviour and
message), then the argument the user can see, then the resolved executable, then the
environment variables. All four are a handful of parameter expansions and `[[ -e ]]`
tests; there is no cap on the number of arguments (a cap would be a bypass and `[[ -e ]]`
costs microseconds).

### 1.2 Argument resolution rule

For every argument after the command name:

- Candidates: the argument itself; **and**, if it contains `=`, the part after the first
  `=` (`--prefix=/x`, `PREFIX=/x`, `DESTDIR=../proj`). Both go through the same steps.
- Skip a candidate that is empty or starts with `-` (a bare option; its value, if any,
  is the next argument and is handled on its own).
- Tilde: a candidate equal to `~` or starting with `~/` becomes `$HOME` + the rest
  (the shell already expanded a bare `~/x`; this covers the glued `--opt=~/x` form).
  `~user` forms are not expanded (they fall through and will not exist as typed).
- Resolve: `p=${cand:A}` — absolute, relative to the cwd, symlinks resolved.
- **Must exist**: `[[ -e $p ]] || continue`. Rationale: a path that is not there is not
  the project's data, the command would fail on it anyway, and the test keeps strings
  that merely look like paths (`-c "code"`, URLs, `pkg==1.0`, `@scope/pkg`) from ever
  matching anything but the cwd's own verdict (a relative string resolves under
  `$PWD`, whose root is already judged). Both directories and files count
  (`pip install -e ../proj`, `npm --prefix ../proj`, `pytest ../proj/tests`,
  `-r ../proj/requirements.txt`, `node ../proj/server.js`).
- Containment is upward only: the argument inside a root. A command pointed at a
  *parent* of a red project (`pytest ~/Projects`) is not refused.

### 1.3 Executable resolution rule

`exe=${commands[$cmd]}` (zsh/parameter; empty when the name is not on `PATH` → skip).
Two locations are checked: `${exe:h:A}` (the canonical **directory** the name was found
in) and `${exe:A}` (the fully resolved file). The directory form is the one that matters:
a venv's `python` is a symlink to the base interpreter outside the project, so `:A`
alone would miss `.venv/bin/python`; `node_modules/.bin/*` are symlinks into
`node_modules/<pkg>/…` (same root either way); direnv's `.direnv/python-*/bin` and any
per-project `bin/` on `PATH` are plain directories. The `:A` form additionally catches
a shim outside the project that symlinks to a script inside it. asdf/mise shims live
under `~/.asdf` / `~/.local/share/mise` and resolve to the shim script — not caught,
documented.

The reason line prints `${exe:h:A}/${exe:t}`.

### 1.4 Environment rule

Exactly two variables, checked for all intercepted commands: `VIRTUAL_ENV` (venv,
virtualenv, `uv venv`, poetry in-project, pipenv — all set it when activated), then
`CONDA_PREFIX` (an in-project `conda create -p ./env`; a `~/miniconda3/envs/…` prefix
simply never lies in a project root). Value canonicalised with `:A`; no existence test
(the variable being set is the signal). Not checked, and why: `PIPENV_ACTIVE` (pipenv
sets `VIRTUAL_ENV` too), `PYTHONPATH`/`NODE_PATH`/`GOFLAGS`/`BUNDLE_GEMFILE` (niche, not
"an environment is activated"), `PATH` entries (covered by the executable rule where it
matters: the activated venv's `bin` is on `PATH`, so `python`/`pip`/`pytest` already hit
§1.3; `VIRTUAL_ENV` adds the global managers that honour it — `uv`, `poetry`, `pipenv`).

Checked for all commands, not a python-only subset: the intercepted set is user-
extensible, and a shell with project A's environment activated while running `npm` in
project B is itself the problem the message names (`VIRTUAL_ENV=… is that project's
environment`); the fix is `deactivate`, the pause, or working in one project at a time.

### 1.5 Message: the agent line and the reason line

The agent-directed text is a labelled `agents:` entry, last, three lines (label + two continuations), present on
**every** refusal (cwd or target). A `because:` line is inserted right after the headline
on a **target** refusal only (a cwd refusal needs no explanation — the headline already
names the directory you are in). The `proceed:` line now carries the quoted root
(`hiveguard strict pause "<root>"`): on a target refusal the cwd is somewhere else, so a
bare `hiveguard strict pause` would pause the *wrong* project; printing the path makes
the command correct from anywhere and copy-pasteable (same form as the CLI's own
`lift early: hiveguard strict resume "<root>"`). Exact text in §2.1.

### 1.6 Honest scope after this change

Catches now, in addition to cwd-in-red: a command typed elsewhere whose argument path
points into a red project (`cd /tmp && python ~/Projects/app/tools/x.py`,
`pip install -r …/app/requirements.txt`, `npm --prefix …/app install`, `pip install -e
…/app`); a command whose binary lives in a red project (an activated `.venv/bin`,
`node_modules/.bin` on `PATH`, direnv layouts); a red project's activated environment
(`VIRTUAL_ENV`, `CONDA_PREFIX`), e.g. `cd /tmp && uv pip install --upgrade certifi`.

Still cannot catch: a script copied out of the project that reaches back in through
paths **hardcoded inside it** (the gate reads the command line, never file contents);
an absolute or `./`-relative path to a binary (`/opt/homebrew/bin/python`, `./gradlew`,
`./node_modules/.bin/x` typed as a path); `sudo …`, `env …`, `xargs …`, `sh -c '…'`;
`pip --target`/`PYTHONPATH`-style indirections; version-manager shims (asdf, mise); an
IDE Run button, a double-click, Docker Desktop, cron, launchd, `zsh -c`, a process
already running; an alias defined after the hook. It is a discipline tool, not a sandbox.

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 Refusal message

`SUMMARY`, `ROOT` = the blocking root's marker row; `CMD` = the intercepted name; `BQ` =
a backtick. Line 1 is coloured red when stderr is a tty (as today); nothing else is.
Everything goes to stderr via `print -u2 -r --`. Exit code 77.

cwd refusal (6 lines):

```
⛔ hiveguard strict: SUMMARY in ROOT — refusing to run `CMD`.
   detail:   hiveguard daily --open
   proceed:  fix it, or pause this project:  hiveguard strict pause "ROOT"   (1h; e.g. --for 2h)
   agents:   AI coding agents: do not work around this block — no cd elsewhere, no copying files out,
             no other path, interpreter or environment. Stop and report it to the user, or ask them
             to run `hiveguard strict pause`.
```

target refusal (7 lines): the same with one line inserted after line 1:

```
   because:  REASON
```

`REASON`, one of:

| trigger | text |
|---|---|
| argument | `the argument ARG points into that project (ABS)` — `ARG` as typed (the whole argument, e.g. `--prefix=../app`), `ABS` = the resolved existing path |
| executable | `` `CMD` resolves to EXE, inside that project `` — `EXE` = `${exe:h:A}/${exe:t}` |
| environment | `VAR=VALUE is that project's environment` — `VAR` ∈ `VIRTUAL_ENV`, `CONDA_PREFIX`; `VALUE` as set, not canonicalised |

Column alignment: label padded so the text starts at column 14 (`   detail:   `,
`   because:  `, `   proceed:  `, `   agents:   `, continuation lines 13 spaces).

### 2.2 Gate algorithm (what T1 implements; names are for comments and tests)

```
_hiveguard_strict_gate cmd args…
  rule 1  strict off → return 0 (nothing else read)
  read markers ONCE into three parallel arrays (roots / statuses / summaries), skipping
    blank and malformed rows exactly as today
  locations, in order:
    cwd        ${PWD:A}
    args       per §1.2 (candidates → skip -*/empty → ~ → :A → [[ -e ]])
    executable ${commands[$cmd]:h:A} then ${commands[$cmd]:A}   (skip when empty)
    env        ${VIRTUAL_ENV:A}, ${CONDA_PREFIX:A}               (skip when empty)
  for each location: innermost root containing it; status active → read pauses
    (_hiveguard_strict_col2 … exact) → paused → next location; else REFUSE (§2.1), 77
  no location blocked:
    cwd has a marker root (acked) → return 0
    rule 3 coverage for cwd, rule 4 background scan for cwd — byte-for-byte as today
```

Helper shape is the implementer's call, with two constraints: markers are read once per
gate call, and the pauses file is read only when a location would otherwise block.
`emulate -L zsh` stays at the top of the gate (so an unset `VIRTUAL_ENV` is fine under a
user's `nounset`); use `${VAR:-}` anyway. Globals, if any, follow the
`_hiveguard_strict_*` naming so the snapshot re-source (Claude Code) recreates them.

### 2.3 Header comment of `bin/hiveguard-strict.zsh` (replace these paragraphs)

HONEST SCOPE paragraph →

```
# HONEST SCOPE: a terminal-level guard. It intercepts a BARE command name resolved
# by a shell that sourced this file, and judges WHERE the command is typed and WHERE
# it points (argument paths, the binary it resolves to, an activated VIRTUAL_ENV /
# CONDA_PREFIX). It cannot see paths hardcoded inside a script that was copied out
# of the project, an absolute path to a binary, `./gradlew`, `sudo npm …`, `env`,
# `xargs`, `sh -c`, version-manager shims, an alias defined later, `zsh -c`, an IDE
# Run button, a double-click, Docker Desktop, cron, launchd, or a process that is
# already running. It is a discipline tool, not a sandbox.
```

Rules paragraph →

```
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
```

The gate's own comment (`$2… are deliberately IGNORED`) → `$2… are the command's own
arguments, read only as candidate paths (rule 2) — never as verbs`. The "zsh-builtins-
only" paragraph gains `$commands` to its list of zsh/parameter uses.

### 2.4 Test scaffold additions (`tests/strict-hook.test.zsh`)

Add to the scaffold (after the existing `mkdir -p … "$T/loose/dir"` block):

```
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
```

Every new section starts from a known state: `cfg 'mark_finder=0\nstrict=1'`, marker
`"$T/proj/app<TAB>active<TAB>12 active vulnerabilities (2 critical)"`, no pauses, a
coverage row `"$T<TAB>$(now)"` (so an unknown cwd under `$T` never kicks a background
scan and the `bgcalls`/attempts files can be asserted absent), `rm -f` of
`$HIVEGUARD_STRICT_ATTEMPTS` and `$T/bgcalls`. `zrun` as today. The new messages contain
`(`, `)` and backticks, and `is`/`contains`/`lacks` compare with an unquoted pattern on
the right-hand side — change them to literal comparison (`[[ $2 == "$3" ]]`,
`[[ $2 == *"$3"* ]]`, `[[ $2 != *"$3"* ]]`); every existing use is a literal compare, so
nothing else changes. `PATH`, `VIRTUAL_ENV` and `CONDA_PREFIX` for a check are set
**inside** the `zrun` string (each `zrun` is a fresh `zsh -f`), never exported by the
test file itself.

---

## 3. Tasks

### Wave 1 (parallel; no shared files)

#### T1 — the gate: locations, resolution rules, message, header comment — model: **opus**

Owns: `bin/hiveguard-strict.zsh` (only).

Do:

1. Implement §2.2 in `_hiveguard_strict_gate`, keeping rule 1, the marker parsing
   style, `_hiveguard_strict_col2`, and rules 3–4 (coverage, `.git` walk, home guard,
   debounce, the one permitted fork) byte-for-byte in behaviour.
2. Resolution rules §1.2–§1.4 exactly (candidates incl. post-`=`, `-*` skip, `~`/`~/`,
   `:A`, `[[ -e ]]`; `${commands[$cmd]:h:A}` then `:A`; `VIRTUAL_ENV` then `CONDA_PREFIX`).
3. Message §2.1 byte-for-byte, including the quoted root in `proceed:` and the three-line
   `agents:` entry on every refusal; `because:` only on a target refusal. Keep the
   backtick as `$_HIVEGUARD_STRICT_BQ` (the file must still contain nothing that looks
   like a command substitution).
4. Header comment §2.3 and the gate's argument comment.
5. No new state files, no new env overrides, no new fork. `zsh -n bin/hiveguard-strict.zsh`
   clean.

Acceptance (orchestrator runs; T2 provides the tests):

```bash
cd "$HG" && bash tests/run.sh strict-hook      # all checks pass, incl. the new N–S sections
grep -n '\$([^<]' bin/hiveguard-strict.zsh      # only the header-comment mention (today line 61); no code hit
grep -n 'commands\[' bin/hiveguard-strict.zsh   # the executable rule is there
```

#### T2 — hook tests for the new behaviour — model: **opus**

Owns: `tests/strict-hook.test.zsh` (only).

Add the scaffold of §2.4 and these sections (names as given; `A`=`$T/proj/app`):

- **N. Message.** cwd refusal in `A/sub` with `npm install left-pad`: `$ZERR` **equals**
  the 6-line §2.1 text with `SUMMARY`=`12 active vulnerabilities (2 critical)`,
  `ROOT`=`A`, `CMD`=`npm` (exact `is`, after stripping nothing — no colour because stderr
  is a file). Target refusal from `$T/tmp` with `python A/tools/x.py`: `$ZERR` equals the
  7-line text with `because:  the argument A/tools/x.py points into that project (A/tools/x.py)`
  and `CMD`=`python`; stdout `rc=77`, no `REAL python`.
- **O. Argument targets** (cwd `$T/tmp`, all → `rc=77`, stub never runs, `because:` as
  stated):
  - relative: `python ../proj/app/tools/x.py` → `the argument ../proj/app/tools/x.py points into that project (A/tools/x.py)`
  - option value as its own arg: `pip install -r A/requirements.txt` → names `A/requirements.txt`
  - glued: `npm --prefix=A install` → `the argument --prefix=A points into that project (A)`
  - env-style glued: `npm DESTDIR=A test` → `the argument DESTDIR=A points into that project (A)`
  - tilde glued, unexpanded by the shell: add the marker row `$T/home/red<TAB>active<TAB>home red`;
    `npm --prefix='~/red' test` (single quotes inside the `zrun` string) → 77, headline
    `home red in $T/home/red`, reason ends `(…/home/red)`; remove the row afterwards
  - directory target: `pip install -e A` → names `A`
  - and these **run** (`rc=0`, `REAL …` on stdout, empty `$ZERR`): `python A/nope.py`
    (nonexistent path inside the red root), `pip install requests` (bare word),
    `npm install @scope/pkg`, `pip install pkg==1.0`, `python -c 'print(1)'`
  - acked target: marker `A acked` → `python A/tools/x.py` runs
  - paused target: `A active` + pause row `A<TAB>now+3600` → runs; expired row → 77
  - innermost per location: markers `$T/proj active outer is red` + `A acked inner acked`;
    cwd `A/sub`: `npm test` runs (unchanged); `python ../../tools/y.py` → 77 with
    `outer is red in $T/proj` in the headline
  - cwd and target disagree: create `$T/elsewhere/x/f.py`; markers `A active` +
    `$T/elsewhere/x active elsewhere red`, pause row for `A` only; cwd `A`: `npm test`
    runs; `python $T/elsewhere/x/f.py` → 77 naming `elsewhere red in $T/elsewhere/x`
  - no scan for targets: `: > markers`, coverage `$T/tmp` fresh only, `$T/elsewhere/x` has
    no row and no coverage: cwd `$T/tmp`, `python $T/elsewhere/x/f.py` → runs; `sleep 1`;
    no attempts file, no `bgcalls`. Then cwd `$T/loose/dir` (unknown, would scan) with
    `A active` and `python A/tools/x.py` → 77 **and** still no attempts file / `bgcalls`
    (refusal is terminal).
- **P. Executable targets** (cwd `$T/tmp`, marker `A active`):
  - `PATH=A/.venv/bin:$T/stubs:/usr/bin:/bin`, `python -c 'print(1)'` → 77,
    `because:  \`python\` resolves to A/.venv/bin/python, inside that project`
    (proves `:h:A`: the symlink itself resolves to `$T/stubs/python`)
  - `PATH=A/node_modules/.bin:…`, `npm test` → 77, reason names `A/node_modules/.bin/npm`
  - same PATH, `A acked` → runs; `A active` + pause → runs
  - `strict_commands_extra=foo`, `foo` not on PATH, cwd `$T/tmp`: `foo` → `rc=127`,
    `$ZERR` lacks `hiveguard` (empty `$commands[foo]` is harmless)
- **Q. Environment targets** (cwd `$T/tmp`, default PATH, marker `A active`):
  - `export VIRTUAL_ENV=A/.venv`; `npm test` → 77, `because:  VIRTUAL_ENV=A/.venv is that project's environment`
  - `export CONDA_PREFIX=A/.conda` (dir need not exist); `pip install x` → 77, reason
    names `CONDA_PREFIX=A/.conda`
  - `VIRTUAL_ENV=A/.venv` with `A acked` → runs; with a pause → runs
  - `VIRTUAL_ENV=$T/elsewhere/x/.venv` (no marker) → runs, no scan files
- **R. Snapshot** (append to section M, same `snapshot` helper, `A active`): from the
  snapshot shell, cwd `$T/tmp`, `python A/tools/x.py` → `rc=77`; `$ZERR` lacks
  `command not found`.
- **S. No-fork** (append to section I, each under `ulimit -u 1`, `print alive` after):
  argument refusal (`_hiveguard_strict_gate python A/tools/x.py` from `$T/tmp` → `rc=77`),
  executable refusal (PATH with `A/.venv/bin`), environment refusal (`VIRTUAL_ENV`), and a
  clean run with many arguments
  (`_hiveguard_strict_gate npm test a b c --x=y --prefix=$T/tmp . .. ~ $T/tmp/nope` ×
  enough to make 40 args → `rc=0`, `alive`).

Acceptance: `bash tests/run.sh strict-hook` passes against T1. The orchestrator also
proves the new checks bite: after C2 is committed, `git show main:bin/hiveguard-strict.zsh
> bin/hiveguard-strict.zsh`, run `bash tests/run.sh strict-hook` (sections N–S fail, the
pre-existing sections still pass), then `git checkout -- bin/hiveguard-strict.zsh`.

#### T3 — README and CHANGELOG — model: **sonnet**

Owns: `README.md`, `CHANGELOG.md`.

README (section "Strict mode", ≈ lines 463–541, and "Limitations" ≈ lines 709–713):

1. Replace the **Honest scope** paragraph with:

   > **Honest scope: it's a terminal-level guard, not a sandbox.** It intercepts a bare
   > command name resolved by a shell that sourced the hook, and judges both *where the
   > command is typed* and *where it points*: argument paths, the binary the name
   > resolves to, and an activated environment (`VIRTUAL_ENV`, `CONDA_PREFIX`). It cannot
   > see paths hardcoded inside a script, an absolute path to a binary, `sudo`, an IDE
   > Run button, a double-click, Docker Desktop, or a process that's already running.

2. Replace the sample refusal block with the 6-line cwd text of §2.1
   (`SUMMARY`=`12 active vulnerabilities (2 critical)`, `ROOT`=`/Users/mh/Projects/app`,
   `CMD`=`npm`), then add one sentence and the 7-line target sample:

   > When the block comes from where the command *points* rather than where it is
   > typed, a `because:` line says which argument, binary or environment triggered it:

   with `CMD`=`python`, `because:  the argument /Users/mh/Projects/app/tools/x.py points into that project (/Users/mh/Projects/app/tools/x.py)`.

3. In "Rules, in order", after the **Acked** bullet add:

   > - **Target-aware.** The gate also refuses when the command *points into* a red
   >   project from somewhere else: an argument that is an existing path inside it
   >   (`python ~/Projects/app/tools/x.py`, `pip install -r ../app/requirements.txt`,
   >   `npm --prefix=../app install`, `pip install -e ../app`), a binary that lives in it
   >   (an activated `.venv/bin`, `node_modules/.bin` on `PATH`), or its activated
   >   environment (`VIRTUAL_ENV`, `CONDA_PREFIX` — `cd /tmp && uv pip install …` with
   >   the project's venv active). Each location is judged on its own by the same
   >   innermost-root rule; a pause for the *target* project releases it. Targets are
   >   only ever compared against markers — pointing at a never-scanned project does not
   >   refuse and does not scan it; only working in it does.

   Rewrite the **No repair exemption** bullet's clause "the gate never looks at a
   command's arguments" → "the gate reads arguments only as paths, never as verbs".
   In the **Unknown or stale** bullet append "(judged for the current directory only)".

4. In the "Only a bare command name" paragraph (≈ line 531) replace
   `./gradlew`, `./node_modules/.bin/x`, `sudo npm …` with: "`./gradlew`,
   `./node_modules/.bin/x` typed as a path (on `PATH` it *is* caught), `sudo npm …`,
   `env`/`xargs`/`sh -c`, version-manager shims (asdf, mise)," and add a final sentence:
   "A script copied out of the project that reaches back in through paths hardcoded
   inside it is invisible to the gate, which reads the command line, not file contents.
   The refusal carries an `agents:` line telling AI coding agents not to work around
   the block and to report it to you instead."

5. Limitations: replace the two strict bullets with one:

   > - Strict mode is a **terminal-level** guard only. It judges where a command is
   >   typed and where it points (argument paths, the resolved binary, `VIRTUAL_ENV` /
   >   `CONDA_PREFIX`) — not paths hardcoded inside scripts, absolute paths to binaries,
   >   `sudo`, shims, an IDE Run button, a double-click, Docker Desktop, cron, launchd,
   >   `zsh -c`, or a process that's already running.

CHANGELOG, under `## [Unreleased]`:

```
### Added
- **Strict mode is target-aware.** The gate used to judge only the directory a command
  was typed in, so `cd /tmp && python ~/Projects/app/tools/x.py` or
  `cd /tmp && pip install --upgrade certifi` with the project's venv active went through.
  It now also refuses when the command *points into* a red project: an argument that is
  an existing path inside it (`--opt=path` and `~/` forms included), a binary that lives
  in it (an activated `.venv/bin`, `node_modules/.bin` on `PATH`), or its activated
  environment (`VIRTUAL_ENV`, `CONDA_PREFIX`). Each location is judged by the same
  innermost-root rule; a pause for the target project releases it. Targets are compared
  against markers only — they never start a background scan.

### Changed
- The refusal message: a `because:` line names the argument, binary or environment that
  triggered a target refusal; the `proceed:` line quotes the project path
  (`hiveguard strict pause "/…/app"`) so it is right from any directory; and a closing
  `agents:` entry tells AI coding agents not to work around the block (no cd elsewhere,
  no copying files out, no other path, interpreter or environment) and to report it to
  the user or ask them to pause.
```

Acceptance:

```bash
cd "$HG" && grep -c 'agents:   AI coding agents' README.md      # 2 (both samples)
grep -c 'hiveguard strict pause "/Users/mh/Projects/app"' README.md   # 2
grep -n 'never looks at a command' README.md                     # nothing
grep -c 'Strict mode is target-aware' CHANGELOG.md               # 1
```

#### T4 — integration test additions — model: **sonnet**

Owns: `tests/strict-integration.test.sh` (only).

Add a helper next to `npm_try`:

```bash
# Like npm_try, but with explicit npm arguments; $1 = directory, $2… = arguments.
npm_try_args() {
  local d="$1"; shift
  HG_DIR="$d" PATH="$T/stubs:$PATH" zsh -f -c '
    source "$HG_HOOK"
    cd "$HG_DIR" || { print "rc=cd-failed"; exit 9 }
    npm "$@"
    print rc=$?
  ' _ "$@" 2>"$ERR"
}
```

Then, in step 2 after the existing checks (the project is red; the cwd is `$HOME`, which
rule 5 never scans, so no probe is started):

- `out="$(npm_try_args "$HOME" --prefix "$T/proj/app" test)"` → `rc` 77; `lacks "REAL npm"`;
  `contains` `because:  the argument $T/proj/app points into that project ($T/proj/app)`
  on `$ERR` line 2 (`sed -n 2p`); `contains` `hiveguard strict pause "$T/proj/app"` and
  `AI coding agents: do not work around this block` in `$ERR`.
- `contains` the agents line in the **cwd** refusal's `$ERR` too (reuse the step-2 `$ERR`
  before it is overwritten — place this check before the new `npm_try_args` call).

In step 3 (paused) add: `npm_try_args "$HOME" --prefix "$T/proj/app" test` → `rc` 0 and
`REAL npm --prefix $T/proj/app test` on stdout. Update the header comment's step list
("2 … also when pointed at from elsewhere", "3 … the target form too"). No other step
changes; the test must still never start a scan outside steps 1, 5, 6, 7.

Acceptance: `bash -n tests/strict-integration.test.sh`; the orchestrator runs the full
file once at the end (network, ~3 min) and it passes.

### Wave 2 (orchestrator)

`bash tests/run.sh` (all files); on a mismatch between T1 and T2 the contract (§2) wins
over both. Then the independent checks of §4 and the integration test.

---

## 4. Verification and commits

Independent verification before the feature commit (not the agents' word):

```bash
cd "$HG"
zsh -n bin/hiveguard-strict.zsh && bash -n tests/strict-integration.test.sh
bash tests/run.sh                                   # every file PASS
grep -n '\$([^<]' bin/hiveguard-strict.zsh          # only the header-comment mention; every code `$(` is a `$(<file)` read
grep -nE '[^|]\|[^|]' bin/hiveguard-strict.zsh      # only the TSV format comment (today line 48): no pipeline
grep -nE 'whence|command -v|realpath|readlink' bin/hiveguard-strict.zsh   # nothing
```

Manual probe, isolated (write it as a file, run via `bash` → `zsh -f`; never `zsh -c`
inline): `HOME=$(mktemp -d)`, all `HIVEGUARD_*` overrides, config `strict=1`, a marker
`"$T/app<TAB>active<TAB>probe"`, a stub `python` on `PATH`, a venv-style symlink
`$T/app/.venv/bin/python -> stub`. Expect:

| command (cwd `$T/tmp`) | expected |
|---|---|
| `python $T/app/x.py` (file exists) | 77, line 2 `because:  the argument … points into that project (…)` |
| `python $T/app/nope.py` | runs, empty stderr |
| `PATH=$T/app/.venv/bin:$PATH python -c 1` | 77, `` `python` resolves to $T/app/.venv/bin/python, inside that project `` |
| `VIRTUAL_ENV=$T/app/.venv npm test` | 77, `VIRTUAL_ENV=$T/app/.venv is that project's environment` |
| pause row for `$T/app`, then any of the above | runs |
| `ulimit -u 1` + any refusal path | `rc=77` then `alive` |

Also run the maintainer's real-shell smoke **read-only**: `zsh -f` sourcing the repo's
`bin/hiveguard-hook.zsh` with the real `~/.hiveguard` (no overrides), cwd `/tmp`,
`type npm` shows the wrapper, `npm --version` (no red project pointed at) runs.

| Commit | Contents | Gate |
|---|---|---|
| C1 `docs(strict): target-aware gate — design and plan` | this plan | — |
| C2 `feat(strict): target-aware gate (argument paths, resolved binary, VIRTUAL_ENV/CONDA_PREFIX); agent-directed refusal line` | T1, T2, T4 | `bash tests/run.sh` all pass; §4 greps; integration test passes |
| C3 `docs(strict): README and CHANGELOG for the target-aware gate` | T3 | §T3 acceptance greps |

Out of scope (open issues, do not implement): reading script contents for hardcoded
paths; intercepting absolute-path invocations; `sudo`/`env`/`xargs` passthrough;
version-manager shim resolution; a `hiveguard strict status` line listing the
environment variables the gate watches.

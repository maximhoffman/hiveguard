# Menu bar app — design

Status: approved (product), ready for task breakdown
Date: 2026-10-07
Revision (same day): the app moves to its own repository
(`/Users/mh/Projects/Develop/hiveguard-menubar`); `hiveguard status --json` becomes
an explicitly versioned cross-repo contract owned by hiveguard (`docs/status-json.md`).
Product decisions are unchanged.

## Problem

hiveguard's signals are all pull or one-shot: a notification at scan time (easy
to miss, gone a second later), a Finder tag, a `cd` reminder, a report you have
to open. There is no always-visible answer to "is my protection working, and did
anything new appear?" — and no one-click way to act on it (open, ack, pause).

A native macOS menu bar app gives that answer as an icon, and puts the handful
of daily actions one click away. hiveguard stays the engine; the app is a view
with buttons.

## Goals

- One glance tells the state: **calm**, **new findings (count)**, **protection
  broken**, **scanning**.
- Act without the terminal: open the report (to a finding), mark a finding as
  known, pause / resume strict mode per project, toggle strict, scan now, run
  the health check.
- Confirmations only where a wrong click costs something (criticals, strict off).
- While the app runs, it is the only thing that notifies, and it notifies only on
  the two transitions that matter.
- Launches at login. Behaves honestly when the engine is broken, missing, or of an
  incompatible version.
- hiveguard remains the single source of truth: every mutation goes through the
  `hiveguard` CLI; the app never edits a state file the CLI owns.
- Two repositories, one contract: the app lives in its own repo
  (`/Users/mh/Projects/Develop/hiveguard-menubar`, a sibling of the hiveguard
  checkout) and talks to hiveguard only through the CLI. The one machine-readable
  interface between them (`hiveguard status --json`) is explicitly versioned and
  owned by hiveguard (section 2.5).

## Non-goals (explicitly out of scope)

- Apple Developer signing / notarization, Homebrew cask or formula distribution,
  any machine other than the maintainer's. Built from source, ad-hoc signed.
- SwiftBar / xbar plugins (decided: native app).
- Reproducing the report inside the app (counts and new findings only; detail
  lives in the HTML report).
- Changing scan semantics (what is "new", what an ack covers, strict's rules).
- Driving `doctor --fix`, `schedule on/off`, or `ack --remove` from the app.
- Showing strict-mode *probe* scans as activity (they do not change the daily
  state; see judgment calls).

## Approved product decisions (locked)

1. Native SwiftUI app, personal use, built and run on the maintainer's Mac.
2. Icon states: **calm**; **red + count** = the last scan found *new*
   vulnerabilities, stays red until the report is opened or those findings are
   acked; **yellow** = protection not working (last scan older than 36 h, last
   scan failed, or the schedule is off); **animated** = a scan is running.
   Known/old findings never turn the icon red.
3. Menu: last-scan summary; new findings grouped by project with per-finding
   *Open in report* and *Mark as known*; strict section (on/off, paused projects
   with expiry, pause 1 h / 2 h, unpause, toggle); *Open report* / *Check now* /
   *Check installation health*.
4. A confirmation dialog only when an action touches critical vulnerabilities
   (ack or pause of a project with criticals) or turns strict mode off entirely.
5. While the app runs it owns notifications (sent only when the icon turns red or
   protection stops working); the per-scan `osv-daily` notification is suppressed
   while the app runs; with the app not running hiveguard behaves exactly as today.
6. Launches automatically at login.

---

## 1. State model

The app derives one of four icon states from a single JSON document produced by
the new `hiveguard status --json` (section 2.5) plus the current time. Every
rule below is a pure function of that input, so it is unit-testable with
fixtures.

### 1.1 Inputs (facts)

| Fact | Source (via `status --json`) |
|---|---|
| `scan.running` | `~/.hiveguard/osv-daily.pid` exists **and** that pid is alive |
| `scan.last` (`ok`, `finished_epoch`, `error`, counts) | `~/.hiveguard/osv-run.json` (new, section 2.1); `null` when the file is absent |
| `attention[]` — unseen new findings not covered by an ack, with per-id severity | `osv-run.json.unseen` filtered through `osv-acks.json` |
| `report.opened_epoch` | `~/.hiveguard/osv-report-opened` (new, section 2.3); `null` when absent |
| `schedule.configured`, `schedule.loaded`, hour/minute, folders | the launchd plist + `launchctl print` |
| `strict.enabled`, `strict.hook_sourced`, `strict.blocked[]`, `strict.paused[]` | config, `~/.zshrc`, markers, pauses |
| `cli_ok` (app-local) | the `status --json` call succeeded, parsed, and its `schema` is in the app's supported range |
| `hiveguard.version` | `hiveguard version` (shown in the menu footer; makes a version mismatch visible) |

### 1.2 Icon state (evaluated in this order; first match wins)

1. **CLI broken or incompatible** → **yellow**, with one of these reasons
   (protection state is unknown; unknown is reported as not working):
   - `hiveguard not found` — no binary at any of the lookup paths (section 4.3);
   - `hiveguard is too old` — the installed hiveguard has no `status` subcommand
     (the dispatcher exits 2 with `unknown command: status`); the menu names the
     minimum version (the release that ships `status`);
   - `unsupported status format N` — the document's `schema` is missing or outside
     the range the app supports (section 2.5); the menu says whether to update
     hiveguard or the app;
   - `cannot read hiveguard status` — any other non-zero exit, timeout, or
     unparsable output.
2. **Scanning** → **animated**: `scan.running` is true, or the app's own
   *Check now* process is still running.
3. **Red** → `attention` is non-empty **and**
   (`report.opened_epoch` is null **or** `report.opened_epoch <
   scan.last.finished_epoch`). Count shown = total number of advisory ids across
   `attention` entries (the same unit as the report's "new since last scan" tile).
4. **Yellow** (protection not working) when any of:
   - `schedule.configured` is false, or `schedule.loaded` is false;
   - `scan.last` is null (no scan has ever completed) ;
   - `scan.last.ok` is false (the last scan failed);
   - `now − scan.last.finished_epoch > 36 h`.
5. **Calm** otherwise.

Red is evaluated before yellow on purpose: a new finding is actionable *now*;
the protection problem is still shown as a warning line at the top of the menu
(section 3), and the yellow notification still fires (section 5). When red clears
and a yellow condition holds, the icon becomes yellow.

### 1.3 How red clears

Red clears when **either**:

- the report is opened through hiveguard — `hiveguard daily --open [--at …]`
  writes the opened stamp (section 2.3); the app only ever opens the report via
  that command, so the stamp is written for app clicks and terminal opens alike; or
- every advisory id in `attention` becomes covered by an ack (the app's *Mark as
  known* calls `hiveguard ack …`, which `status` reflects immediately).

Red also shrinks: acking some of the findings lowers the count; the rest stay red.

### 1.4 What "new" means across days (carry-over)

hiveguard's diff is scan-to-scan: today's new ids are tomorrow's baseline, so a
red the user never looked at would silently go calm after the next scheduled
scan. To honour "stays red until opened or acked", `osv-daily` keeps an
**unseen** list in `osv-run.json` (section 2.1): this run's new ids, plus the
previous run's unseen ids that are still present in the current findings — but
only when the report was not opened after that previous run. Opening the report
(stamp ≥ latest `finished_epoch`) therefore resets the carry-over at the next
scan, and acked ids are filtered out live by `status`. The report's own "new
since last scan" number is unchanged.

### 1.5 Edge cases (normative)

| Situation | State |
|---|---|
| Fresh machine: no `osv-run.json`, no report | yellow — "no scan has completed yet"; *Open report* disabled |
| Schedule just enabled, first scan not yet run | yellow until the first successful run writes `osv-run.json` |
| App launches at login while the `RunAtLoad --if-due` scan is running | animated (pid alive); when the run ends the file watcher re-reads and the icon settles |
| `--if-due` decided the report is fresh and exited early | nothing changes: the pid file is written only right before `osv-scanner` starts |
| Stale pid file (power loss, kill -9) | pid not alive → not running; the next run overwrites the file |
| Scan failed (scanner rc > 1 or no JSON) | yellow — "last scan failed: …"; report, baseline, markers, coverage are **not** overwritten (section 2.6); `unseen` carried unchanged |
| Last scan ok but > 36 h ago (laptop closed for days) | yellow — "last scan N h ago"; the 60 s timer flips this without any file change |
| New findings in the last scan, report opened via terminal `hiveguard daily --open` | stamp written by osv-daily → red clears on the next refresh |
| Partial acks | red with a smaller count; count 0 ⇒ not red |
| New findings exist but the app was not running when the scan ran | at launch the app computes red and sends the red notification once (the terminal-notifier alert was not suppressed, so the user may get both — accepted) |
| Scan finished and found nothing new while red (user never opened) | still red (carry-over) until opened/acked, provided those ids are still present |
| A carried-over finding disappears (dependency fixed) | dropped from `unseen` by the next run → no longer counted |
| Strict pause expires while the menu is open | pauses are filtered by `now` on every `status` call; the 60 s refresh updates the list |
| `strict on` but hook not sourced | strict section shows "on, but the terminal hook is not loaded" with the line to add (text from `strict status`); not a yellow condition (strict is optional) |
| hiveguard installed via brew later | the CLI lookup order (section 4.3) finds the brew binary; nothing else changes |
| hiveguard updated to a release that bumps the `status` schema | yellow "unsupported status format" naming both versions, until the app is rebuilt from a matching app-repo commit |
| app rebuilt against a newer schema than the installed hiveguard emits | same yellow, worded the other way ("update hiveguard") |
| hiveguard rolled back to a version without `status` | yellow "hiveguard is too old" |

---

## 2. Data sources and new hiveguard-side interfaces

Everything the app reads comes through `hiveguard status --json`; everything it
changes goes through an existing or new `hiveguard` subcommand. The additions
below are the minimum needed. All new paths follow the house convention: default
under `~/.hiveguard`, env override for tests.

### 2.1 `~/.hiveguard/osv-run.json` — outcome of the last daily run (new)

Override: `HIVEGUARD_RUN`. Written by `osv-daily` at the end of **every
non-probe run that reached the scan step** (`--open` and an early `--if-due` exit
do not write it), success or failure, atomically (tmp + `mv`). Probes never write
it.

```json
{
  "schema": 1,
  "ok": true,
  "rc": 1,
  "error": null,
  "started_epoch": 1791342000,
  "finished_epoch": 1791342043,
  "stamp": "2026-10-07 10:00",
  "target": "/Users/mh/Projects",
  "counts": { "active": {"projects": 23, "pkgs": 183, "vulns": 480, "crit": 19},
              "acked":  {"projects": 18, "pkgs": 528, "vulns": 2060, "crit": 111},
              "new_vulns": 6, "resolved_vulns": 0 },
  "roots": { "/Users/mh/Projects/x/app": {"status": "active", "active_vulns": 12, "crit_pkgs": 1, "acked_vulns": 0} },
  "new":    [ { "src": "/Users/mh/Projects/x/app/pnpm-lock.yaml", "root": "/Users/mh/Projects/x/app",
                "pkg": "fast-uri", "version": "3.0.1", "eco": "npm", "sev": 7.5, "fix": "3.0.6",
                "ids": ["GHSA-…"], "anchor": "f-3f2a9c1d0b7e", "project_anchor": "p-9a1b2c3d4e5f" } ],
  "unseen": [ "…same shape as new…" ]
}
```

- `ok` = the existing `SCAN_OK` (JSON produced and scanner rc ∈ {0,1}). On
  failure: `ok=false`, `rc` = scanner exit code, `error` = last 5 non-progress
  lines of the scanner's stderr (captured in both interactive and
  non-interactive modes — today non-interactive runs discard stderr), `counts`
  and `roots` = `null`, `new` = `[]`, `unseen` = previous `unseen` unchanged.
- `roots` = the per-root aggregate python already computes for the Finder
  markers (`root_agg`), with `status` (`active` when any active finding).
- `new` = every active package fragment with non-empty `new_ids` (ids = the new
  ones only), `sev` = the fragment severity already computed, `root` =
  `finding_root(src)`, anchors per section 2.7.
- `unseen` (carry-over, section 1.4): let `prev` = the previous `osv-run.json`
  if readable, `opened` = the opened stamp (section 2.3) or 0.
  `carry = prev.unseen if prev and opened < prev.finished_epoch else []`, keep
  only `(src, pkg, id)` triples present in this run's `cur_findings`, then merge
  with `new` by `(src, pkg)` (union of ids, this run's metadata wins). Acks are
  **not** applied here — `status` applies them live so an ack takes effect
  without a rescan.

### 2.2 `~/.hiveguard/osv-daily.pid` — scan in progress (new)

Override: `HIVEGUARD_SCAN_PID`. `osv-daily` writes its own `$$` to this file
immediately before launching `osv-scanner` (non-probe runs only) and removes it
in the existing `EXIT` trap. "Running" = file exists **and** `kill -0 <pid>`
succeeds; a stale file is ignored and overwritten by the next run.

### 2.3 `~/.hiveguard/osv-report-opened` — report opened stamp (new)

Override: `HIVEGUARD_REPORT_OPENED`. Contains one integer (Unix seconds).
Written by `osv-daily` every time it opens the report: the `--open` path, the
interactive open-or-rescan path, and the new `--at` form. Only `osv-daily`
writes it; the app opens the report exclusively via `hiveguard daily --open`.

### 2.4 `~/.hiveguard/menubar.pid` — app presence; notification handoff (new)

Override: `HIVEGUARD_APP_PID`. The app writes its pid at launch and deletes the
file on normal quit. In `osv-daily`, immediately before the `terminal-notifier`
call: if the file exists and `kill -0 <pid>` succeeds, **skip** the
notification (the log line and the done-line are unchanged). A stale pid after
an app crash fails `kill -0`, so hiveguard falls back to notifying — exactly
today's behaviour. No config key: presence is live, never a flag that can be
left behind.

### 2.5 `hiveguard status [--json]` — machine-readable facts (new subcommand)

New script `bin/status`, dispatched by `bin/hiveguard` (`status) exec
"$BIN/status"`), listed in the dispatcher's help block (parsed by `help.awk`)
under Management, and in the formula's `libexec.install "bin"` automatically.
bash 3.2 + `jq` only (jq is already required). **Read-only**: it never prunes
pauses, never touches launchd, never writes. Finishes in well under a second; no
network. Exit 0 whenever it produced output, 2 on bad arguments.

Reads: `osv-run.json`, `osv-acks.json`, the opened stamp, the scan pid file, the
schedule plist (`HIVEGUARD_SCHED_PLIST`), `launchctl print gui/<uid>/<label>`
(label `com.hiveguard.osv-daily`), config, `~/.zshrc` (hook line, same grep as
`strict-mode`), markers, pauses, the report path.

**This document is the cross-repo contract.** hiveguard owns it; the normative,
versioned description lives in the hiveguard repo at `docs/status-json.md` (field
table, compatibility rule, schema history) and is kept in step with `bin/status`
in the same commit. The app repo never redefines it — it links to that file.

Compatibility rule:

- `schema` is an integer. **Additive** changes (a new key anywhere, a new value in
  an existing field) keep the number. **Breaking** changes (a key removed,
  renamed, retyped, or a change of meaning) bump it.
- The app declares the schema range it supports (initially exactly `1`). A
  document whose `schema` is missing or outside that range is **not** interpreted:
  the app shows yellow "unsupported status format" (section 1.2) and tells the
  user which side to update. The app ignores keys it does not know.
- A hiveguard without the `status` subcommand is detected by the dispatcher's
  `unknown command: status` on stderr with exit 2 → yellow "hiveguard is too old".
- `hiveguard.version` in the document is what the menu shows in its footer
  (`hiveguard v1.6.0 (git)`), so a mismatch is visible at a glance.

`--json` emits exactly (schema 1):

```json
{
  "schema": 1,
  "hiveguard": { "version": "v1.5.0-3-gabc1234", "method": "git" },
  "now_epoch": 1791400000,
  "scan": { "running": false, "pid": null,
            "last": { "ok": true, "rc": 1, "error": null, "started_epoch": 0, "finished_epoch": 0,
                      "stamp": "2026-10-07 10:00", "target": "/Users/mh/Projects",
                      "counts": { "...": "verbatim from osv-run.json" } } },
  "attention": [ { "src": "…", "root": "…", "project": "x/app", "pkg": "fast-uri", "version": "3.0.1",
                   "eco": "npm", "sev": 7.5, "crit": false, "fix": "3.0.6",
                   "ids_open": ["GHSA-…"], "ids_acked": [], "anchor": "f-…", "project_anchor": "p-…" } ],
  "attention_ids": 6,
  "report": { "path": "/Users/mh/.hiveguard/osv-projects.html", "exists": true, "opened_epoch": null },
  "schedule": { "configured": true, "loaded": true, "hour": 10, "minute": 0, "folders": ["/Users/mh/Projects"] },
  "strict": { "enabled": true, "hook_sourced": true, "hook_hint": null,
              "blocked": [ { "root": "…", "summary": "12 active vulnerabilities (1 critical)", "crit_pkgs": 1 } ],
              "paused":  [ { "root": "…", "until_epoch": 1791403600 } ] },
  "app": { "running": true }
}
```

- `attention` = `osv-run.json.unseen` with each id classified by the **same
  rule as the report** (`id_suppressed`): an id is acked iff
  `acks.projects[src]` exists and (`ids == null` or `ids[pkg]` contains it), or
  `acks.packages[src][pkg]` exists and (`ids == null` or `ids` contains it).
  Entries whose `ids_open` is empty are dropped. `crit` = `sev >= 9`.
  `project` = `root` with `$HOME/Projects/` stripped, else `$HOME` → `~`.
- `strict.blocked` = marker rows with status `active`; `crit_pkgs` from
  `osv-run.json.roots[root].crit_pkgs`, else parsed from the summary's
  `(N critical)`, else 0. `strict.paused` = pause rows with `until_epoch > now`
  (filtered in output only). `hook_hint` = the `source "…"` line when the hook is
  not sourced (same resolution as `strict-mode`'s `hook_script_path`).
- `schedule.loaded` = `launchctl print` succeeds for the label. `app.running` =
  menubar pid alive. `hiveguard.version`/`method` = what `hiveguard version` and
  `install_method` print (`git` | `brew` | `unknown`).
- Plain `hiveguard status` prints a short human summary (last scan line, new
  findings count, protection status, strict on/off + pauses). Not used by the app.

### 2.6 Failure behaviour of `osv-daily` (change)

Today a scanner failure in a non-interactive run silently becomes a "0 results"
report **and overwrites the diff baseline, the markers and the report**, so the
next successful scan reports every finding as new (and the markers were cleared
meanwhile). With the app this would paint the icon red with hundreds of "new"
the morning after any transient failure. Change, for non-probe runs:

- when `SCAN_OK=0`: write `osv-run.json` with `ok=false` (section 2.1), append
  `[$STAMP] FAILED rc=<n> (<first error line>)` to `osv-daily.log`, print the
  existing warning, **skip** the report, state, markers, coverage (already
  skipped) and the notification; exit 0 (launchd must not treat it as a crash
  loop).
- when `SCAN_OK=1`: unchanged, plus `osv-run.json`.
- the probe path keeps its current behaviour.

### 2.7 Report anchors and `hiveguard daily --open --at <anchor>` (change)

- Each project card gets `id="p-<h12(src)>"` and each package row
  `id="f-<h12(src + "\0" + pkg)>"`, where `h12` = first 12 hex chars of SHA-1,
  computed in the report python and emitted into `osv-run.json` (`anchor`,
  `project_anchor`). A small script in the report, on load and on `hashchange`:
  find the element for `location.hash`, open every enclosing `<details>`
  (project card and, if needed, the Acknowledged wrapper), `scrollIntoView`,
  and add a transient highlight class.
- `osv-daily --open --at <anchor>`: valid only with `--open`; the anchor must
  match `^[pf]-[0-9a-f]{12}$` (else exit 2). Opens
  `file://<report>#<anchor>` with `osascript -e 'open location "<url>"'` —
  `open(1)` drops URL fragments on `file:` URLs, AppleScript's `open location`
  does not — falling back to `open "$REPORT"` if osascript fails. Writes the
  opened stamp either way. Without `--at`, behaviour is today's `open "$REPORT"`
  plus the stamp.

### 2.8 `HIVEGUARD_TOOL_PATH` — stubbing external tools in tests (new, tests only)

`osv-daily` and `status` build their PATH as
`"${HIVEGUARD_TOOL_PATH:+$HIVEGUARD_TOOL_PATH:}/opt/homebrew/bin:…:$PATH"`.
Tests prepend a directory of stubs (`osv-scanner`, `terminal-notifier`,
`osascript`, `open`, `launchctl`) without touching the real tools. Unset in
production, the PATH is byte-for-byte today's.

### 2.9 Existing interfaces the app uses unchanged

| Action | Command (non-interactive, already) |
|---|---|
| Mark finding as known | `hiveguard ack <src> <pkg>` |
| Mark project as known | `hiveguard ack <src>` (once per distinct `src` under that root) |
| Pause strict for a project | `hiveguard strict pause <root> --for 1h` / `--for 2h` |
| Unpause | `hiveguard strict resume <root>` |
| Strict on / off | `hiveguard strict on` / `hiveguard strict off` |
| Scan now | `hiveguard daily --rescan` (falls back to the scheduled folders; never prompts) |
| Health check | `hiveguard doctor` (plain text when stdout is not a TTY; never `--fix`) |
| Open report | `hiveguard daily --open [--at <anchor>]` |

Note `ack <src> <pkg>` snapshots **all** currently-known ids of that package
(hiveguard semantics: "I know about this package's findings"), not only the new
ones. The menu wording says "Mark as known", matching that.

---

## 3. Menu structure and actions

Native pull-down menu (`MenuBarExtra` with `.menu` style). Items are rebuilt from
the latest `status --json` each time the menu opens. Disabled items stay visible
with the reason in their title where useful.

```
[protection warning line — only when a yellow condition holds while red]
Last scan: today 10:00 · 23 projects with problems · 19 critical        (disabled, informational)
  ↳ when failed: "Last scan FAILED 10:00 — <first error line>"
  ↳ when never:  "No scan has completed yet"
Next scheduled: 10:00 daily  |  "Daily scan is OFF"  |  "Scheduled but not loaded (loads at next login)"
──────────────
New findings (6)                                                  ▸  (hidden when attention is empty)
   x/app  (3 new · 1 critical)                                    ▸
      Open project in report
      Mark all as known…                                             (… = confirmation, criticals present)
      Pause strict 1 h / 2 h                                          (only when strict.enabled and root is blocked)
      ──
      fast-uri 3.0.1 · HIGH 7.5 · 2 new                            ▸
         Open in report
         Mark as known
      lodash 4.17.20 · CRIT 9.1 · 1 new                            ▸
         Open in report
         Mark as known…
   y/svc  (3 new)                                                  ▸ …
──────────────
Strict mode: ON  (or OFF; or "ON — terminal hook not loaded")
   Paused: x/app until 12:40 (54 min left)  ▸  Unpause             (one row per running pause)
   Pause a project ▸  <each strict.blocked root>  ▸  1 hour / 2 hours   (… when crit_pkgs > 0)
   Turn strict mode off…   |   Turn strict mode on
──────────────
Open report                     (disabled when the report file does not exist)
Check now                       (disabled while a scan is running: "Scanning…")
Check installation health…
──────────────
Launch at login  ✓
Quit HiveGuard
```

Action → command mapping is section 2.9. Every action runs on a serial queue
(one CLI process at a time), then triggers a status refresh. *Check now* is the
exception: it spawns `hiveguard daily --rescan` detached (stdin `/dev/null`,
stdout/stderr to `~/.hiveguard/menubar.log`) and returns; the pid file makes the
icon animate within a second.

*Check installation health…* opens a plain window with the monospaced output of
`hiveguard doctor` (exit code shown as a coloured verdict line, a *Run again*
button, and the text selectable for copy). It never runs `--fix`; the remedies
doctor prints are instructions for the terminal.

Project and finding rows are ordered as the report orders them: by severity,
descending.

---

## 4. The app

### 4.1 Location, build, run

- The app is its **own git repository**: `/Users/mh/Projects/Develop/hiveguard-menubar`
  (local, branch `main`, no remote unless asked later), a sibling of the hiveguard
  checkout. Nothing of the app — sources, Makefile, fixtures, ignore rules — lives in
  the hiveguard repo, and nothing in the app assumes the hiveguard repo is next to
  it at runtime (only the tests do, via an env var, section 9). Layout:
  `Package.swift` (library target `HiveGuardCore` with the pure logic, executable
  target `HiveGuard`, one test target, no third-party dependencies), `Sources/…`,
  `Tests/HiveGuardCoreTests/Fixtures/*.json`, `Resources/Info.plist`, `Makefile`,
  `tests/e2e.test.sh`, `README.md`, `.gitignore` (`.build/`, `dist/`, `.DS_Store`).
- The design spec and the implementation plan stay in the hiveguard repo
  (`docs/superpowers/specs/2026-10-07-menubar-app-design.md`,
  `docs/superpowers/plans/2026-10-07-menubar-app-plan.md`) because they span both
  repos; the app's README points to them and to the contract (`docs/status-json.md`)
  by sibling path (`../hiveguard/docs/…`).
- SwiftUI + SPM, Swift 6 toolchain from Xcode (present: Xcode 26.3, Swift 6.2),
  deployment target macOS 14. Build via `swift build -c release`.
- An `.app` bundle is mandatory, not optional: `UNUserNotificationCenter`
  aborts the process when run outside a bundle, and `SMAppService` registers a
  bundle. SPM does not produce bundles, so `make app` assembles
  `dist/HiveGuard.app` (`Contents/MacOS/HiveGuard`, `Contents/Info.plist`
  with `CFBundleIdentifier com.hiveguard.menubar`, `LSUIElement true`,
  `CFBundleVersion` from `git describe` of the app repo), then ad-hoc signs it
  (`codesign --force --sign - --deep`). `make install` copies it to
  `~/Applications/HiveGuard.app` (a stable path: the login-item registration is
  tied to the bundle's location) and relaunches it. `make run` runs the
  installed bundle; `make test` runs `swift test`; `make e2e` builds the bundle
  and runs the end-to-end test against a hiveguard checkout (section 9).
- `swift` and `make` are strict-intercepted names. The app repo sits under the
  scheduled `~/Projects`, so strict treats it as known-clean and the build runs;
  should it ever go red, `make app` is refused like any build — pause it
  (`hiveguard strict pause`) as for any project. Document this in the README.
- hiveguard's Homebrew formula and `install.sh` are unaffected: the app is never
  shipped by hiveguard.

### 4.2 Architecture

- **One model object** (`@Observable`) holds the last `Status` (decoded from
  `status --json`), the derived `IconState`, the in-flight action, and
  notification bookkeeping. The icon rules (section 1.2), confirmation rules
  (section 6) and notification rules (section 5) are **pure functions**
  `(Status, Date) → …` in their own file, with no I/O, so they are tested with
  fixtures.
- **Refresh triggers**: a `DispatchSource` file-system watch on `~/.hiveguard`
  (directory fd; writes are atomic renames so a directory event fires), debounced
  500 ms; a 60 s timer (for the 36 h threshold and pause expiry); after every
  action completes; when the menu is about to open. A refresh = run
  `hiveguard status --json` off the main thread, decode, publish.
- **CLI runner**: `Process` with `stdin = /dev/null`, a 30 s timeout for status/
  ack/strict/doctor (doctor may take a few seconds), environment = the app's
  plus `PATH` prepended with `/opt/homebrew/bin:/usr/local/bin:$HOME/bin` and
  every `HIVEGUARD_*` variable passed through untouched (that is how the test
  harness isolates the app).
- **Icon**: a template-style vector drawn in code (hexagon/"hive" mark) rendered
  in three tints — monochrome (calm), system red with the count as adjacent
  text (red), system yellow (yellow) — and a 4-frame animation at ~4 fps while
  scanning. The label view is a function of `IconState`, so SwiftUI redraws it
  when the state changes.
- **Confirmations** use `NSAlert` (sheet-less, app-modal; the menu is already
  closed when the action fires).
- **Launch sequence**: write `menubar.pid` → register notification categories →
  first refresh → ensure login item (section 7). **Quit**: remove `menubar.pid`.
  A crash leaves a stale pid; section 2.4 makes that harmless.
- `HiveGuard --dump-state` (hidden flag): runs one refresh, prints the derived
  state (`icon`, `count`, `reasons`, notification decision) as one JSON line to
  stdout and exits without creating a status item. This is the end-to-end test
  hook (section 9).

### 4.3 Finding the CLI

Lookup order, first existing wins: `$HIVEGUARD_BIN` (existing override, tests);
`~/bin/hiveguard`; `/opt/homebrew/bin/hiveguard`; `/usr/local/bin/hiveguard`.
The app never looks relative to its own location or to any source checkout — it
must work whether hiveguard was installed from source or via brew, and wherever
the app bundle sits. Nothing found → icon state 1 (yellow, "hiveguard not
found"), menu shows the paths tried and an *Open README* item; all actions
disabled. Found but too old / incompatible → the corresponding yellow reason of
section 1.2, with *Open report* still offered when the report file exists (it is
a plain file; opening it needs no contract).

---

## 5. Notifications — ownership handoff

- **Suppression** (engine side, section 2.4): `osv-daily` skips
  `terminal-notifier` while `menubar.pid` is alive. Nothing else in hiveguard
  changes; app not running ⇒ today's behaviour, byte for byte.
- **The app notifies on exactly two transitions**, via `UNUserNotificationCenter`
  (permission requested on first launch; if denied, the app shows "notifications
  off" in the menu footer and does nothing else):
  1. **Enters red, or red count increases** — title "N new vulnerabilities",
     body = up to three project names with their new-id counts, "+k more".
     Clicking opens the report (`hiveguard daily --open`).
  2. **Enters yellow, or the yellow reason changes** — title "hiveguard
     protection is not working", body = the reason ("daily scan is off", "last
     scan failed: …", "last scan was 41 h ago", "hiveguard unavailable").
     Clicking opens the health-check window.
- **No notification** for scanning, calm, red→smaller count, or yellow→calm.
- **Dedupe**: a notification key `(state, reason-or-count)`; the same key is not
  re-sent within the app's lifetime. Keys are not persisted: an app relaunch (login)
  re-sends the current red/yellow once, by design (the user may have missed it).
- One notification per transition per status refresh; a refresh that moves
  straight from calm to red with 6 is one notification, not six.

---

## 6. Confirmation rules

Confirm (an `NSAlert` with a default *Cancel*) **only** for:

| Action | Condition | Dialog says |
|---|---|---|
| Mark finding as known | that finding's `crit` is true | package, version, project, the critical ids, "this also covers the package's other known advisories" |
| Mark project as known | any attention entry under that root has `crit` | project, number of packages and ids, how many critical |
| Pause strict 1 h / 2 h | `strict.blocked[root].crit_pkgs > 0` | project, summary line from the marker, "runs/builds will be allowed until HH:MM" |
| Turn strict mode off | always | "every flagged project runs again in every terminal at its next prompt" |

Everything else (non-critical acks, pause of a non-critical project, unpause,
strict on, check now, open, doctor) acts immediately. Dialog buttons name the
action ("Mark as known", "Pause 2 hours", "Turn off"); Escape cancels.

---

## 7. Launch at login

- On first launch, if `SMAppService.mainApp.status` is `.notRegistered` or
  `.notFound`, call `register()`. On every launch, re-read `.status` and show it
  in the *Launch at login* checkbox (never trust the app's own memory).
- `.requiresApproval` → checkbox unchecked with the hint "approve in System
  Settings › General › Login Items"; the menu item opens that pane.
- Ad-hoc re-signing on every build can invalidate a registration; `make install`
  therefore installs to the fixed path `~/Applications/HiveGuard.app` and the
  app re-registers at launch when status is not `.enabled` (and not
  `.requiresApproval`). Unchecking the item calls `unregister()`.
- Preference stored by the system, not by the app.

---

## 8. Error handling

| Failure | Behaviour |
|---|---|
| `hiveguard` not found | yellow "hiveguard not found"; actions disabled; paths tried in a submenu |
| `status` subcommand missing (exit 2, `unknown command: status`) | yellow "hiveguard is too old — needs the release that ships `hiveguard status`"; only *Open report* and *Quit* enabled |
| `schema` missing or unsupported | yellow "unsupported status format N (app supports 1)"; the menu says "update hiveguard" when N < supported, "rebuild the app" when N > supported; only *Open report* and *Quit* enabled |
| `status --json` exit ≠ 0 (other) or invalid JSON | yellow "cannot read hiveguard status"; last good status kept for the menu with a "stale" marker; stderr tail logged to `~/.hiveguard/menubar.log` |
| `status --json` times out (30 s) | same as above; process killed |
| An action (ack/strict/open/doctor) exits ≠ 0 | `NSAlert` titled with the action, informative text = stderr (or stdout) tail; status refreshed anyway |
| `daily --rescan` exits 2 (no folders) | alert "No folders to scan — set up the schedule: hiveguard schedule on --hour 10 ~/Projects" |
| `daily --rescan` started but pid file never appears (e.g. osv-scanner missing: osv-daily exits 1 at once) | the detached process' exit ≠ 0 surfaces as the alert above with its stderr |
| Report missing | *Open report* and per-finding opens disabled |
| Notification permission denied | footer line; notifications silently skipped |
| `~/.hiveguard` missing | created by hiveguard on the first run; the watcher is re-armed when the directory appears (retry every 60 s) |
| Two app instances | the second finds a live `menubar.pid` that is not its own and quits immediately |
| Unparsable epoch / future `finished_epoch` | treat as "now" (never negative ages) |

The app never deletes, edits or rewrites any `~/.hiveguard` file other than
`menubar.pid` and `menubar.log`.

---

## 9. Testing strategy

Nothing may touch the real `~/.hiveguard`, the real `~/.zshrc`, the real
launchd label, the real Login Items or the real notification center.

**Engine side (bash, in `tests/`, run by `tests/run.sh`; bash 3.2 idioms;
isolated `HOME=$(mktemp -d)` canonicalised with `pwd -P`; every `HIVEGUARD_*`
override set including the new `HIVEGUARD_RUN`, `HIVEGUARD_SCAN_PID`,
`HIVEGUARD_REPORT_OPENED`, `HIVEGUARD_APP_PID`; `HIVEGUARD_SCHED_PLIST` points at
a plist under the temp HOME; `HIVEGUARD_TOOL_PATH` points at a stub dir):**

- `osv-run.test.sh` — with a stub `osv-scanner` that emits a fixed JSON
  (two runs with different ids): `ok`, `new`, `unseen` carry-over with and
  without an opened stamp between runs, dropping of disappeared ids, anchors
  present and matching the report's `id=` attributes; a stub exiting 128 with no
  output: `ok=false`, `error` captured, report/state/markers unchanged
  (md5 before/after), `FAILED` log line, exit 0; pid file present during the scan
  (stub sleeps 2 s while the test polls) and absent after; no pid/run file
  written for `--probe` or an early `--if-due`.
- `notify-handoff.test.sh` — stub `terminal-notifier` that appends its args to
  a file: fires with no pid file, fires with a dead pid (`99999`), does **not**
  fire with `$$` in the pid file.
- `status.test.sh` — seeded fixtures (run.json, acks v1 and v2, markers, pauses
  with one expired row, plist, stub `launchctl` that exits 0/1, config, a fake
  `~/.zshrc`): `jq` assertions on every field of section 2.5, including the ack
  classification (project-level `ids:null`, package-level listed ids, pierced
  mix), expired pauses filtered but the file **not** rewritten (md5), read-only
  (no new files in HOME), runtime < 1 s.
- `report-open.test.sh` — stub `osascript` and `open`: `--open` writes the stamp
  and calls `open`; `--open --at f-…` calls `osascript` with the exact URL;
  invalid anchor exits 2; osascript failure falls back to `open`.
- Existing `strict-integration.test.sh` keeps passing (adds the new env
  overrides to its scaffold so nothing leaks).

**App side (`swift test` in the app repo):**

- Pure-function tests for `IconState` from fixture JSON + injected `Date`: every
  row of the section 1.5 table, the red-before-yellow precedence, the 36 h
  boundary (35 h 59 min vs 36 h 01 min), count arithmetic with partial acks, the
  three compatibility failures (not found / too old / unsupported schema).
- Confirmation-rule tests for each row of section 6 and the no-confirm cases.
- Notification-rule tests: transitions that fire / don't fire, dedupe key,
  count-increase fires, count-decrease does not.
- Decoder tests: the section 2.5 document, `null` `scan.last`, unknown fields
  ignored, `schema` 0 / 2 / missing rejected with the specific error.

**Keeping the app's fixtures honest (the two repos version separately):** the
fixtures are hand-written JSON and would drift silently from the real CLI. The
app repo's end-to-end test (`tests/e2e.test.sh`, also `make e2e`) therefore runs
against a **real hiveguard checkout** given by `HIVEGUARD_REPO` (default: the
sibling `../hiveguard` of the app repo; the test fails loudly if
`$HIVEGUARD_REPO/bin/status` is missing). It seeds a temp HOME with hiveguard's
stub-scanner scaffold, produces `osv-run.json` with the real `osv-daily`, calls
the real `hiveguard status --json`, and asserts (a) `schema` equals the one every
fixture carries, and (b) the set of key paths of the real document equals the set
in the richest fixture (`red-6.json`, which has attention, blocked and paused
entries) — structural equality, values may differ. A fixture that goes stale
fails this test. The same test drives `HiveGuard --dump-state` (built by `make
app`) with `HIVEGUARD_BIN=$HIVEGUARD_REPO/bin/hiveguard` and the overrides, and
asserts the one-line JSON (`red 1`, `calm` after opening, `yellow` with the
agent stub down, `scanning` with a live pid, `yellow` on `STUB_FAIL`, red clears
after a real `hiveguard ack`, rc 3 and yellow with `HIVEGUARD_BIN=/nonexistent`).
No status item, no notifications, no login item are created in this mode.

The hiveguard repo's own suite never needs the app: its tests cover the engine
side (run file, pid files, stamp, handoff, `status`, anchors). The contract doc
`docs/status-json.md` is the hinge: a change to `bin/status` that alters the
document must update that file and, if breaking, bump `schema` — and the app's
e2e test will go red until the app's fixtures and supported range follow.

**Manual checklist (once, by the maintainer, after `make install`):** icon in
all four states (force each by editing files in a *temp* HOME and launching the
app with that HOME), a deep link lands on and highlights the row in the default
browser, the login item appears in System Settings, the terminal-notifier alert
is suppressed while the app runs and returns after *Quit*.

---

## 10. Docs and housekeeping (part of the work, not optional)

hiveguard repo:

- README: `hiveguard status` in the subcommand table; the new files in "Where
  hiveguard keeps its data"; the failed-scan behaviour in the `daily` section;
  a short "Companion menu bar app" paragraph: separate repository
  (`hiveguard-menubar`, built from source, personal), what it reads (`hiveguard
  status --json`), that notifications hand over while it runs.
- `docs/status-json.md` (new): the normative contract — field table, types,
  null-ability, the compatibility rule, schema history (`1 — initial`).
- `CHANGELOG.md` under `## [Unreleased]`: **hiveguard-side changes only** —
  `status` subcommand + contract doc, `osv-run.json`, scan pid file, opened stamp,
  notification handoff, `--open --at`, report anchors, failed-scan no longer
  overwrites report/baseline/markers — plus one line that a companion menu bar app
  exists in its own repository and consumes `status --json`.
- Dispatcher help block (`bin/hiveguard`) gains the `status` line; `bin/osv-daily`
  header documents `--at` and the new files.

app repo:

- `README.md`: what it is and what it is not (personal build, ad-hoc signed, not
  distributed), build/install/run/test/e2e, the `HIVEGUARD_REPO` variable, the
  strict-intercepts-`swift` note, the ad-hoc-signing caveat for Login Items, the
  supported `status` schema range, and links by sibling path to the spec, the
  plan and the contract in the hiveguard repo.

## Implementation notes for the breakdown

- Engine changes are small and surgical: `bin/osv-daily` (pid file, run.json,
  unseen, anchors + hash script, `--at`, failure path, notifier gate,
  `HIVEGUARD_TOOL_PATH`), new `bin/status` + `docs/status-json.md`, one `case`
  line in `bin/hiveguard`. No change to `osv-ack`, `strict-mode`,
  `daily-schedule`, `doctor`, the zsh hooks, or any state file format that
  exists today.
- Two repos: hiveguard work on a feature branch of the hiveguard checkout; the
  app in the new sibling repo on `main`. Tasks in different repos never conflict
  on files. The hiveguard side must land first in each wave that the app's
  end-to-end test depends on, since that test runs against the sibling checkout.
- bash 3.2: no associative arrays; guard empty arrays under `set -u`; BSD `date`
  (`date -r`), `awk`, `sed`. No `timeout` in tests — poll with `sleep 1`.
- `status` must stay read-only even where `strict status` is not (it prunes
  pauses); copy the filtering, not the pruning.
- The app must compile with zero warnings under Swift 6 strict concurrency; all
  UI state on the main actor; the CLI runner is the only off-main code.

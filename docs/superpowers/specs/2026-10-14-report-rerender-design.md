# Report re-render after an acknowledgement — design addendum

Status: product decision approved (maintainer, 2026-10-14: option 2 — re-render from the
last scan's saved results, no rescan); technical design resolved; tasks in
`docs/superpowers/plans/2026-10-14-report-rerender-plan.md`
Date: 2026-10-14
Extends: `2026-10-09-report-app-actions-design.md` ("links §n") and
`2026-10-07-menubar-app-design.md` ("base §n"). Section numbers here are local.
Baseline: hiveguard `main` at `9e5df56` (1.6.3 + report action buttons + the new-tab fix),
worktree `feat/report-rerender`; the app at `71e3804` on `worktree-menubar-app`.

## Problem

The report (`~/.hiveguard/osv-projects.html`) is written only by a scan. When the
maintainer clicks *mark as known* / *mark project as known* in the report, the app runs
`hiveguard ack …` successfully — the ack store changes, the menu's count drops — but a
reload of the page shows the row unchanged, with the same button, until the next scan.
The same happens after an ack from the menu or from the terminal. The report, the Finder
tag and the strict-mode block all say "still red" about a project the user just declared
known.

## Approved product decision (locked, maintainer 2026-10-14)

**Option 2:** right after a successful ack, re-render the report from the last scan's
saved results — no new scan, no network — so that a page reload shows the change within
about a second. Rejected: triggering a full rescan (minutes, network); leaving it as is.

## Goals

- After any change to the acknowledgements (`hiveguard ack <src> [pkg]`, `--remove`,
  `--clear`; from the report, the menu or the terminal) the report reflects it as soon as
  the command returns: the row sits in its new section, the tiles and counts follow, the
  `NEW` badges and the acknowledged section are what a scan with those acks would have
  produced.
- Nothing that only a scan can know changes: the "new since last scan" baseline, the
  run outcome file, the scan coverage, the notification, the opened stamp, the report's
  timestamp. The re-rendered report is **byte-identical** to the one the scan would have
  written with the same acks.
- The report's modification time stays the scan's (`--if-due` and the open-or-rescan gate
  key off it; a re-render must never make the scheduler think a scan ran today).
- One code path renders the report (scan and re-render), so the two cannot drift.
- Works for every entry path with zero app-side logic: the engine owns the refresh.

## Non-goals (explicitly out of scope)

- Re-rendering after `strict on/off` (that changes the pause buttons; the app refuses a
  stale pause link anyway, and the `copy` button covers a missing one) — follow-up.
- Re-rendering after `pause` / `resume` — nothing in the report depends on pauses (§4).
- Auto-reloading the page in the browser (static page; the user reloads).
- Refreshing `osv-run.json` (`counts`, `roots`) — it records what the scan found; the
  app already classifies acks live from `status --json`.
- Any change to the link grammar, the status schema, ack semantics or the ack store
  format.

---

## 1. Feasibility — what the engine persists today vs what the report needs

The report python (`bin/osv-daily`) consumes the raw osv-scanner JSON (a multi-MB
temporary file deleted by the EXIT trap) plus the ack store, the previous state file (diff
baseline), the canonical scan targets, the stamp, and the app/strict gates. What it needs
per vulnerable package and where that lives after the scan:

| The report needs | `osv-last-scan.json` | `osv-run.json` | raw scanner JSON |
|---|---|---|---|
| every advisory id per `(src, pkg)`, active **and** acked, in scanner order | `findings` ✓ | `active[].ids` — uncovered ids only; acked fragments absent | deleted |
| version, ecosystem | ✗ | active entries only | ✓ |
| per-id severity (the active fragment's severity after a *partial* ack is the max over its **remaining** ids) | ✗ | ✗ (fragment max only) | `groups[]` |
| fixed-in version | ✗ | active only | ✓ |
| project root (markers, pause links) | ✗ | active only | computed by a filesystem walk |
| ids new vs the previous scan (`NEW +n`, the "new" tile) | ✗ — the baseline is **overwritten** by the scan that used it | `new[]` — active fragments only, at scan time | computed |
| resolved count, stamp, target | `counts.resolved_vulns`, `stamp`, `target` ✓ | ✓ | — |
| canonical scan targets (the "root that is a scan target" rule, `folder-mark --target`) | ✗ | ✗ | from argv |

**Conclusion: not feasible as is.** Neither file holds versions, per-id severities,
fixes, roots or the acked fragments. Persisting the raw scanner JSON is the wrong fix
(megabytes of advisory prose, and the render would have to repeat the merge/baseline
logic). The minimal change is to **persist the normalised package records the report is
built from** — the output of the first half of the python, right after merging results,
with the baseline comparison already applied — as an additive block of the state file
(§2.1). On the maintainer's data (27 manifests, 664 vulnerable packages, 2 598 ids) that
is roughly 0.4–0.6 MB with the file's `indent=2`; its readers (`osv-ack` via jq, the next
scan's baseline load, `print_last_summary`) are millisecond-level.

---

## 2. Engine changes (hiveguard)

### 2.1 `osv-last-scan.json` — `render` block (additive; the file's `schema` stays 1)

Written by every successful **non-probe** scan, in the same atomic write as the rest of
the state, right next to `findings`:

```json
"render": {
  "schema": 1,
  "scan_targets": ["/Users/mh/Projects"],
  "packages": [
    {"src": "/Users/mh/Projects/x/app/package-lock.json", "root": "/Users/mh/Projects/x/app",
     "pkg": "fast-uri", "version": "3.0.1", "eco": "npm",
     "ids": ["GHSA-AAAA-0001", "GHSA-AAAA-0002", "GHSA-AAAA-0003"],
     "id_sev": {"GHSA-AAAA-0001": 7.5, "GHSA-AAAA-0002": 7.5, "GHSA-AAAA-0003": 7.5},
     "maxsev": 7.5, "fix": "3.0.6", "new_ids": ["GHSA-AAAA-0003"]}
  ]
}
```

- One record per vulnerable package after `merge_results`, in **scan iteration order**
  (results order, packages in order; a src's packages are contiguous). The order matters:
  the report's severity sorts are stable, so ties resolve by this order.
- `ids` = every advisory id of the package (active and acked), scanner order — the same
  list as `findings[src][pkg]`. `id_sev` = severity per id from the scanner's groups (ids
  not in any group fall back to `maxsev`). `fix` = the computed fixed-in version (`""`
  when none). `root` = `finding_root(src)` at scan time. `new_ids` = the ids absent from
  the previous scan's baseline (`[]` when the baseline was not valid — first scan or a
  different target set); the fragment-level `new_ids` the report shows are the uncovered
  ids that are in this list, which is exactly today's rule.
- `render.schema` is the block's own version: `hiveguard daily --render` refuses a block
  it does not understand instead of guessing. A probe never writes the state, so a probe
  never persists render data. A failed scan leaves the state untouched (as today).
- Older engines ignore the key (they read `findings`, `target`, `counts`); `osv-ack`
  keeps reading `.findings` for ack scoping — unchanged.

### 2.2 `hiveguard daily --render` (`bin/osv-daily --render`)

A new mode next to `--open`, `--rescan`, `--if-due`, `--probe`; exclusive with all of
them and takes no path (exit 2 otherwise). It rebuilds the daily report from
`render.packages` and the **current** ack store, through the **same python** the scan
uses (the report python becomes a function both paths call; mode flag `RENDER=1`).

Behaviour:

- Reads: the state file (`HIVEGUARD_STATE`), the ack store, the config (strict), the app
  pid file, the scan pid file. No network, no osv-scanner (it need not be installed), no
  bumblebee pull, no schedule plist (targets come from `render.scan_targets`).
- The gates are evaluated **at render time**, exactly as a scan evaluates them: links
  iff the app's pid is alive; pause links iff `strict=1` and the root is one strict would
  block. So a terminal ack while the app is not running yields a report without buttons,
  and an ack while it is running yields one with — the report always reflects the app's
  presence at the moment it was last written.
- The stamp in the header is the **scan's** (`state.stamp`), the lede's target is the
  scan's; the "new since last scan" tile and `NEW` badges come from the persisted
  `new_ids` (filtered to the now-uncovered ids), the resolved footer line from
  `counts.resolved_vulns`. A render right after a scan is therefore byte-identical to
  that scan's report, stamp included.
- Writes **exactly**: the report (tmp + `os.replace`, so a browser reload during the
  write never sees a half page; the scan path gains the same atomic write), with its
  **modification time restored** to the previous report's (or, if the report was missing,
  the state file's — the scan wrote it at scan end); the markers (§2.4) through the same
  `folder-mark sync --target <scan_targets…>` call the scan makes; one line in
  `osv-daily.log` with the scan's log format and the prefix `render ` (like probes use
  `probe `). Nothing else — see §2.5.
- Never: the state file, `osv-run.json`, the coverage file, the opened stamp, the scan
  pid file, the probe report, a notification, the ack store (an open-ended ack — `ids:
  null` — is treated as cover-all for the render, as the scan does, but the scan-only
  backfill that rewrites the store does not run).
- Exit codes: `0` rendered; `1` the render failed (python error, unwritable report);
  `2` usage; `3` nothing to render from — no state file (`no saved scan to render from —
  run: hiveguard daily <folder>`) or a state without a supported `render` block (`the
  saved scan predates report re-rendering — run: hiveguard daily`); `4` a scan is in
  progress (the scan pid file names a live process: `a scan is in progress (pid N); it
  writes a fresh report itself`). Codes 3 and 4 print one line on stderr, nothing on
  stdout, and leave every file untouched; the caller (§2.3) treats them as "note, not an
  error". Why refuse during a scan: the scan's python runs in its last second and reads
  the ack store then, so the scan's own report almost always carries the ack; rendering
  concurrently could instead overwrite the fresh report with the previous scan's data.
- Done line: `✅ report refreshed (scan of <stamp>): N active vulnerabilities across M
  projects (K acknowledged) → <report>`.

### 2.3 Who triggers it: `osv-ack`, not the app — decision

`hiveguard ack` runs `osv-daily --render` (sibling by path) **synchronously after every
successful store write** — mute, `--remove`, `--clear` — when the state file exists.

- On success it appends `  report and folder markers refreshed (reload the report if it is
  open)` to its output. On any non-zero render it appends `  (report not refreshed:
  <render's last stderr line without the "osv-daily: " prefix>)` to stderr. The ack's
  own exit code is **0 in both cases**: the acknowledgement was recorded; a refresh
  failure is a note. With no state file (nothing scanned yet) it does not call the render
  at all — the existing "no scan data for this path yet" line already says it.
- Why the engine and not the app: (1) every entry path refreshes — report link, menu,
  terminal, and the toolbar's bulk `hiveguard ack a && hiveguard ack b …` — the app alone
  would fix only its own two; (2) no version negotiation anywhere: an app of any version
  running `hiveguard ack` gets the refresh for free, an engine without it simply does not
  refresh; (3) one code path, one test surface; (4) the app's action pipeline is
  unchanged — the ack already runs on the serial queue with a 30 s timeout and is followed
  by a status refresh; the render adds well under a second inside that same call, so
  "awaited vs fire-and-forget" and "coalescing" do not arise (one render per ack; the
  bulk command is N sequential acks → N renders of ~0.2–0.5 s each).
- Cost: `ack` now depends on python3 as the scan does (under brew the wrapper puts
  `python@3.14` on PATH for every subcommand; the `ack` verb is only reachable through
  the dispatcher). `strict pause/resume` and the probe path are untouched.

### 2.4 Folder markers refresh on a re-render — decision (the maintainer will be told)

**Decision: yes.** A re-render re-syncs `osv-markers.tsv` and the Finder tags from the
same desired set the report was computed from, with the same `folder-mark sync --target`
call and the persisted scan targets. After `hiveguard ack <src>` the project's marker
flips `active → acked` at once: the Finder tag turns yellow, strict mode stops refusing
it at the next prompt, `status --json` `strict.blocked` no longer lists it, the menu's
"blocked" section follows. `ack --remove` flips it back just as immediately.

Why:

1. The markers are, like the report, a pure function of (last scan's findings × current
   acks) — the same python computes both from the same records. Letting one lag the other
   is precisely the contradiction the maintainer observed, moved to the Finder/strict
   surface: "I marked it as known and it is still red and still blocked".
2. No new policy. The desired set is exactly what the next scan would write; a project is
   unblocked iff it has no active finding, which is the strict design's own rule
   (`acked → not blocked`, "falls out of the ack model"). The delay was an artefact
   ("Markers refresh on the next scan, not instantly" — README) that the feature removes.
3. Roots outside the scan targets (strict's probe roots) are preserved by `sync`'s
   target rule, as during a scan.

Accepted cost: `osv-run.json` `roots[].crit_pkgs` is not refreshed (the run file stays
scan-only), so `status --json` `strict.blocked[].crit_pkgs` can overstate the critical
count for a *partially* acked root until the next scan; the marker summary — what the app
shows in the pause dialog — is fresh. Flipping this decision is one bash line (skip the
sync under `--render`) plus one test block.

### 2.5 What never changes without a scan (normative)

| File / effect | Owner | On `--render` |
|---|---|---|
| `osv-last-scan.json` (`findings`, `counts`, `stamp`, `target`, `render`) | scan | read only |
| `osv-run.json` (every key, incl. `new`, `unseen`, `active`, `counts`, `roots`) | scan | untouched |
| `osv-coverage.tsv` | scan | untouched |
| notification (terminal-notifier / app handoff) | scan | never |
| `osv-report-opened` | `--open` | never |
| `osv-daily.pid` | scan | never created; a live one refuses the render (rc 4) |
| `osv-acks.json` | ack verbs (+ the scan's one-time backfill) | read only, no backfill |
| `strict-pauses.tsv`, `config`, `strict-attempts.tsv`, `strict.log` | strict | untouched |
| `osv-probe.html` | probe | untouched |
| `osv-projects.html` | scan **and render** | rewritten atomically; mtime preserved |
| `osv-markers.tsv` + Finder tags | scan **and render** | re-synced (§2.4) |
| `osv-daily.log` | scan, probe, **render** | one `render` line appended |

### 2.6 Unchanged

`status` (and `docs/status-json.md`), `strict-mode`, `folder-mark`, `daily-schedule`,
`doctor`, the zsh hooks, the link grammar, the anchors, the jump page, `--open --at`, the
notifier handoff, the scan's `osv-run.json` content, the ack store format and semantics,
the probe path. The scan path's report stays byte-identical to the `9e5df56` renderer for
the same inputs (links on or off); only the write becomes atomic.

---

## 3. App changes (hiveguard-menubar)

### 3.1 No new call, no capability flag

The app never calls `--render`: it already runs `hiveguard ack …` for `ackFinding`,
`ackProject`, `ackSource`, `ackSourceProject` (menu and link), and the engine refreshes
inside that call. There is no `followUpArguments(for:)`, no coalescing, no timeout
question (the existing 30 s action timeout covers the extra < 1 s), no version check:
with an engine that lacks the feature the ack behaves exactly as today. `status --json`
needs no capability flag — the app has nothing to decide on it; `schema` stays 1 and
`docs/status-json.md` is untouched.

### 3.2 Texts

The two link confirmations (links §3.4) end with "The report itself updates at the next
scan." That sentence becomes **`The report updates right away — reload it in the
browser.`** (both `ack` and `ack-project`). Nothing else in the dialogs changes; the menu
confirmations (base §6) do not mention the report.

### 3.3 Version mixes

| Engine | App | After an ack |
|---|---|---|
| new | new | report + markers refresh for every entry path; the link dialog says "updates right away" |
| new | previous (links, old sentence) | refresh happens; the old dialog merely says "next scan" — pessimistic, harmless |
| 1.6.x or a 1.7 without this feature | new | no refresh (no `--render`, nothing calls it); the dialog overstates; the report is stale until the next scan — today's behaviour |
| new, last scan predates the update | any | `ack` prints `(report not refreshed: the saved scan predates …)`; the first scan after the update enables it |

Release-order assumption: report links (already in `[Unreleased]`) and this feature ship
in the **same** hiveguard release, so `minimumHiveguardVersionForLinks` (1.7.0) implies
the refresh. If links were tagged alone first, the sentence would overstate for that one
version — text only, accepted.

---

## 4. Pause / resume / strict on-off — confirmed

- `strict pause` / `resume` change `strict-pauses.tsv` only. The report's pause links are
  gated by `strict=1` and "root in `root_agg`"; pauses are not an input of the report
  anywhere. **Nothing to do.**
- `strict on` / `off` would add/remove the pause links of an already-rendered report.
  Not triggered here (non-goal); the app refuses a stale pause link ("strict mode is
  off"), and a missing button leaves the `copy` fallback. Follow-up if wanted: one
  `osv-daily --render` call in `strict-mode`'s `on`/`off` verbs.

---

## 5. Edge cases (normative)

| Situation | Behaviour |
|---|---|
| Ack right after a scan, no other change | render identical to the scan's report, stamp and mtime included; only the acked row moves |
| Report deleted | `--render` recreates it; mtime = the state file's |
| App not running at ack time (terminal ack) | the re-rendered report has no buttons (gate at render time); the next scan with the app running brings them back; `copy` buttons remain |
| App running at ack time but not at scan time | the re-rendered report gains buttons |
| Ack while a scan is running | render refused (rc 4), ack prints the note, exit 0; the scan's report carries the ack if the store was written before the scan's python started (practically always) |
| Two acks within ~0.2 s (menu + terminal) | each renders from the store it read; last writer wins; an ack can be missing from the report until the next ack or scan. Accepted (no lock) |
| Last scan predates the update (no `render` block) | rc 3; ack prints the note; the next scan fixes it |
| Last scan failed | the state is the previous good scan's (unchanged by a failed run) — the render shows that scan, which is what the report shows anyway |
| Open-ended ack (`ids: null`, v1 store or no scan at ack time) | cover-all for the render; the store is not rewritten (the scan backfills it, as today) |
| Partial package ack (some ids covered) | the package appears in both sections exactly as after a scan: active fragment with the remaining ids, its severity the max over **those** ids (`id_sev`), `muted` badge and `re-ack`; acked twin with the `-k` id suffix |
| `--probe` | never persists render data; `--render` never writes the probe report; a probe's marker rows outside the daily targets survive a render's sync |
| `--render` with a path, or with `--open/--rescan/--if-due/--probe/--at` | exit 2, usage |
| `--if-due` / open-or-rescan gate the morning after an ack | unaffected: the report's mtime is still the scan's |
| `hiveguard update` then `hiveguard daily --render` | the new layout appears without a scan, provided the last scan already wrote a `render` block |
| Bulk toolbar command (`ack a && ack b && …`) | N renders, sequential, each ~0.2–0.5 s |
| `status --json` `scan.last.counts` after an ack | still the scan's (as today — the app's red count comes from the live-classified `attention`/`active`) |

---

## 6. Security considerations

`--render` reads only local files it already read before (state, acks, config, pid files)
and writes files the scan already writes; no network, no new input surface, no new
privilege. `osv-ack` runs a sibling script by its own directory, never through PATH.
Nothing in the app changes except two strings.

---

## 7. Testing strategy

Nothing touches the real `~/.hiveguard`, launchd label, LaunchServices or notification
center. The isolated scaffold of the links plan (§2.5 there; base 2.4 + the links helpers)
is used verbatim, plus `render()`, `norm()`, `scan_sig()` and a split-severity fixture
(plan §2.5).

**Engine — `tests/report-render.test.sh` (new):**

- Identity: scan run1, run2 → `--render` → `cmp` byte-identical (stamp included); the
  report's mtime (set to a past date first) is preserved; state/run/coverage md5, opened
  stamp and scan pid unchanged; no notification; no `.tmp`; one `render` log line.
- State: `render.schema` 1, `scan_targets`, two packages with the documented keys, `ids`
  order, `id_sev`, `maxsev`, `fix`, `root`, `new_ids` (`GHSA-AAAA-0003` for fast-uri);
  `findings` unchanged; `osv-ack` still scopes acks from it ("3 known advisories").
- Acks: package ack → row in Acknowledged, tiles `1 / 1 / 1 (+3 muted) / 1 / 0 new`, the
  `-k` card id, markers `1 active vulnerabilities (1 critical)`; identical (stamp
  normalised) to a fresh scan pair with the same store; project ack → "everything found
  is acknowledged", markers `acked 4 acknowledged`, `status --json` `strict.blocked` empty;
  `--clear` → back to the scan's bytes and markers.
- Gates at render time: app running → links (and identical to a scan with the app
  running); strict on → pause links; app off → no links, identical to the plain report.
- Per-id severity: the split fixture (fast-uri ids in two groups, 9.3 and 5.0); a
  package ack of the 9.3 id → active fragment `MED 5.0`, pierced, acked twin `CRIT 9.3`,
  critical tile 1, markers `(1 critical)`; identical to a scan with that store.
- Open-ended ack: cover-all, store md5 unchanged.
- Refusals: scan pid live → rc 4 + message; no `render` block → rc 3 + "predates"; no
  state → rc 3 + "no saved scan"; the report is kept in all three; usage combos → rc 2;
  report deleted → recreated with the state's mtime; probe report untouched; `--help`
  documents `--render`; `time` < 1 s.
- Scan path unchanged: byte-identical (stamp normalised) to the `9e5df56` renderer, links
  off and on; run-file keys unchanged.
- `osv-ack` trigger (H9's section): the refreshed line; the report and markers change
  without an explicit render; scan state untouched; `--remove` and `--clear` refresh; the
  three failure paths print the note and still exit 0; no state → no render, no note.
- Existing suites keep passing, including `strict-integration.test.sh` (its ack → rescan
  → acked expectations remain true; the marker now flips at the ack already).

**App (`swift test`):** `LinkTests` / `ResolveLinkTests` verbatim texts updated; no new
tests needed (no new logic). The old sentence must not survive anywhere in `Sources/`.

**End-to-end (`Tests/e2e.test.sh`, real engine):** after the real `hiveguard ack "$SRC"
fast-uri` of section 3, the real report no longer carries the fast-uri `ack` link, the
fast-uri row sits in Acknowledged, lodash still has *mark as known*, the marker summary is
`1 active vulnerabilities (1 critical)`, the report's mtime is the scan's, `ls -A` is
unchanged; the successful `ack` resolution's `confirm.message` ends with the new
sentence. Section 2b (seed + ack without rescan) keeps its expectations.

**Real machine (once, gated, plan §6):** one real scan after the merge (the state needs
the block), then: `time hiveguard daily --render` < 2 s with the report's `stat -f %Sm`
unchanged; a terminal ack of a finding the maintainer names → reload → moved, Finder tag,
`hiveguard strict status`; the same through a report button (dialog shows the new
sentence); undo with `ack --remove` → reload → back.

---

## 8. Docs (part of the work)

hiveguard: `README.md` — `daily` flags (`--render`), the ack section ("every ack change
re-renders the report and refreshes the markers at once; reload"), the folder-markers
paragraph that says markers refresh only on the next scan (now: on every scan and
immediately after an ack change), the "changed report layout shows up on the next scan"
note in *Updating* (`daily --render` rebuilds it), the data-table row of
`osv-last-scan.json`; `CHANGELOG.md` `[Unreleased]` (`### Added`: `--render`, the
`render` block; `### Changed`: `ack` refreshes report + markers); `docs/report-links.md`
— the "report is static" bullet becomes the re-render rule, and the emission section
notes the gate also applies at render time; the header comments of `osv-daily` and
`osv-ack` (what `--help` prints). `docs/status-json.md` is untouched.

app: `README.md` "Report links" — one bullet: after a confirmed ack the engine re-renders
the report and refreshes the markers (no rescan); reload the page; `pause` leaves it as
is; needs an engine with `hiveguard daily --render` (same release as report links).

---

## 9. Risks and judgment calls

- **The report's mtime must be the scan's.** Without the restore, an ack at 09:00 would
  make `--if-due` skip the 10:00 scan ("report is today"). Normative in §2.2, tested with
  a past `touch -t` and a missing report.
- **State file size** grows to ~0.5 MB on the maintainer's data (indent=2). Readers are
  jq/python, milliseconds. Compacting the file was not worth losing its readability.
- **Markers refresh on ack (§2.4)** — the one call the maintainer may want to veto;
  cheap to flip. Note the stale `roots[].crit_pkgs` for partially acked roots.
- **Python restructure** (records → fragments) must keep the scan path byte-identical:
  the acceptance diffs against the `9e5df56` renderer, links off and on, and the
  run-file key list is pinned.
- **Concurrent acks** race (last writer wins, ~0.2 s window) — accepted, documented, no
  lock.
- **Judgment call — refuse during a scan** rather than render anyway: a stale overwrite
  of a fresh report is the worse failure; the scan carries the ack in practice.
- **Judgment call — one render per ack**, no coalescing: the bulk command is rare and
  each render is sub-second.
- **Judgment call — `ack` exits 0 when the refresh fails:** the acknowledgement is the
  command's job; the refresh is a courtesy and says so on stderr.

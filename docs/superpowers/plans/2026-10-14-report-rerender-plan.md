# Report re-render after an acknowledgement — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-14
Spec: `docs/superpowers/specs/2026-10-14-report-rerender-design.md` (addendum to the
links design `2026-10-09-report-app-actions-design.md` and the base
`2026-10-07-menubar-app-design.md`; product decision locked by the maintainer 2026-10-14)
Previous plan (conventions, scaffold, Swift API): `docs/superpowers/plans/2026-10-09-report-app-actions-plan.md`

This document is the design for implementers. Agents are dispatched straight from it and
must not redesign. Section 1 fixes the technical choices; section 2 is the shared contract
every task must match byte-for-byte (names, the state block, the CLI contract, the output
lines, the app texts, the test scaffold); section 3 is the task list in waves; section 4
the orchestrator's verification with commit boundaries; section 5 the gates; section 6 the
real-machine finish that runs only on an explicit go.

Conventions (unchanged from the previous plans unless stated):

- Two repositories, two paths:
  - `HG` = the engine **worktree**
    `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/report-rerender`, branch
    `feat/report-rerender`, based on `main` = `9e5df56` (1.6.3 + report action buttons +
    new-tab fix). Work format 2 (built-in Read/Edit with absolute worktree paths; no Serena
    symbolic edits). The main checkout `/Users/mh/Projects/Develop/hiveguard` stays on
    `main` (the real launchd agent, the `hiveguard` on PATH and the strict hook run from
    it) until gate G4.
  - `APP` = the app **worktree**
    `/Users/mh/Projects/Develop/hiveguard-menubar/.claude/worktrees/menubar-app`, branch
    `worktree-menubar-app` (A0–A10 committed, HEAD `71e3804`). Nothing of the app lives in
    `HG`; nothing of the engine lives in `APP`.
- Parallel tasks in one wave never write the same file; `H*` and `A*` tasks never share a
  file. Each task's **Owns** list is exhaustive and exclusive within its wave. Agents never
  run git; the orchestrator does.
- Every test and verification command runs in the **isolated scaffold** of section 2.5
  (fresh `HOME=$(mktemp -d)` canonicalised with `pwd -P`, every `HIVEGUARD_*` override,
  stubs on `HIVEGUARD_TOOL_PATH`). "App running" is simulated by writing `$$` to
  `$HIVEGUARD_APP_PID`. The app binary is only ever run in tests with `--dump-state` or
  `--resolve-link`. Never `make install`/`make run`/`lsregister` outside section 6.
  Never the real `~/.hiveguard`.
- bash 3.2 everywhere (no associative arrays; `"${arr[@]+"${arr[@]}"}"`), no `timeout`,
  BSD `date -r`, `stat -f %m`, `touch -t`, `awk`, `sed`, `shasum`, `md5 -q`. The report's
  rows are rendered on a **single line**, so counts use `grep -o … | wc -l`, never
  `grep -c`.
- `swift` and `make` are strict-intercepted names: `command swift …` / `command make …`.
  The acceptance blocks avoid python and use `jq`.
- Swift toolchain: Xcode 26.3 / Swift 6.2, zero warnings under strict concurrency.
- Commit trailer (both repos): `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## 1. Architecture decisions (resolved)

### 1.1 Persist the normalised package records in the state file (`render` block)

Spec §1–§2.1. The report is rebuilt from `osv-last-scan.json` `render.packages` (one
record per vulnerable package: ids in scanner order, per-id severity, max severity, fix,
version, ecosystem, root, new ids vs the previous baseline) plus `render.scan_targets`,
and the file's existing `stamp`, `target`, `counts.resolved_vulns`. Additive; the file's
`schema` stays 1; the block carries its own `schema: 1`. Written only by a successful
non-probe scan, in the existing atomic state write.

### 1.2 One python for both paths

The report python in `bin/osv-daily` moves into a bash function `report_python` (the same
heredoc, called with an env prefix). It has two entry modes: scan (`RENDER` unset: raw
JSON → `merge_results` → baseline → **records**) and render (`RENDER=1`: records read
from the state). Everything after the records — ack maps, fragments, root aggregation,
markers tsv, counts, HTML — is shared and unchanged in behaviour. The scan-only writes
(state, run file, ack backfill, `COUNTS` for the notifier) are gated; the report write is
atomic in both modes and restores the mtime in render mode.

### 1.3 `hiveguard daily --render`

Spec §2.2: a mode of `osv-daily`, exclusive with the others, no path; reads the state, the
ack store, config and the two pid files; writes the report (atomic, mtime preserved), the
markers (via `folder-mark sync --target <render.scan_targets…>`), one `render ` log line.
Exit 0 / 1 / 2 / 3 (nothing to render from) / 4 (scan in progress). Never the state, the
run file, coverage, the opened stamp, the scan pid, the probe report, a notification, the
ack store.

### 1.4 `osv-ack` triggers the render; the app does not

Spec §2.3: after every successful store write (mute, `--remove`, `--clear`) `osv-ack`
runs `"$here/osv-daily" --render` when `$STATE` exists; success → one stdout line; any
failure → one stderr line; the ack's exit code stays 0. The app has no new call, no
compatibility logic, no capability flag; `docs/status-json.md` is untouched (spec §3.1).

### 1.5 Markers refresh on a render

Spec §2.4: yes — same `folder-mark sync` call, same desired set, persisted targets. The
run file's `roots` is not refreshed (accepted). Flippable in one line if the maintainer
vetoes.

### 1.6 The report's mtime is the scan's

Spec §2.2 / §9: the render stats the old report (or the state file when the report is
missing) before writing and `os.utime`s the new file to it. `--if-due` and the
open-or-rescan gate must not see "today" because of an ack.

### 1.7 Decisions worth flagging (made, not deferred)

- A render while a scan is running is **refused** (rc 4), not raced.
- One render per ack; the toolbar's bulk command renders N times (sequential, sub-second
  each).
- The scan path's report must stay **byte-identical** to the `9e5df56` renderer (links
  off and on); the acceptance diffs it. The run file's content and key list are unchanged.
- The app's link confirmations say "The report updates right away — reload it in the
  browser." for every engine; the release-order assumption is recorded in the spec (§3.3).
- Existing engine tests that run `hiveguard ack` keep their expectations: none of them
  asserts the state *between* an ack and the next scan; the new test must not either
  (H8's checks call `render` explicitly; after H9 the ack renders by itself, and both
  orders give the same files).

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 Names

| Thing | Name |
|---|---|
| Engine branch / worktree | `feat/report-rerender` / `HG` |
| App branch / worktree | `worktree-menubar-app` / `APP` |
| New `osv-daily` mode flag | `--render` (bash variable `render_flag`; function `render_report`) |
| The report python as a function | `report_python` (bash function wrapping the existing heredoc) |
| Python mode env var | `RENDER` (`1` = render; unset/`0` = scan) |
| Python → bash targets hand-back (render only) | `TARGETS_OUT` — one canonical scan target per line |
| State block | `render` with keys `schema`, `scan_targets`, `packages` |
| Record keys (sorted) | `eco, fix, id_sev, ids, maxsev, new_ids, pkg, root, src, version` |
| Log line prefix for a render | `render ` (as `probe ` for probes) |
| New engine test | `HG/tests/report-render.test.sh` |
| `osv-ack` success line (stdout) | `  report and folder markers refreshed (reload the report if it is open)` |
| `osv-ack` failure line (stderr) | `  (report not refreshed: <reason>)` — `<reason>` = the render's last stderr line with a leading `osv-daily: ` stripped |
| App confirmation sentence (replaces "The report itself updates at the next scan.") | `The report updates right away — reload it in the browser.` |

### 2.2 State file format (exact)

`osv-last-scan.json` top-level keys (sorted): `counts, findings, render, schema, stamp,
target`. `render`:

- `schema`: `1`.
- `scan_targets`: the canonical (realpath'd) scan targets, in argv order — the python's
  `scan_targets` list.
- `packages`: records in scan iteration order (merged results order; a src's packages
  contiguous, in merged order). Record = `{src, root, pkg, version, eco, ids, id_sev,
  maxsev, fix, new_ids}`:
  `ids` = `[v["id"] for v in vulns]` (all ids, scanner order — identical to
  `findings[src][pkg]`); `id_sev` = `{id: float}` from the scanner's groups (max when an
  id spans groups; ids in no group are absent and fall back to `maxsev`); `maxsev` =
  float, the package max over groups (`0.0` when none); `fix` = the computed fixed-in
  version or `""`; `root` = `finding_root(src)`; `new_ids` = `[i for i in ids if i not in
  base_ids]` when the baseline is valid, else `[]`.
- Fragment rule (both modes): `uncovered`/`covered` partition `ids` in order by
  `id_suppressed`; fragment severity = `max(id_sev.get(i, maxsev) for i in frag)`;
  active fragment `new_ids` = `[i for i in uncovered if i in rec["new_ids"]]`. This is
  today's arithmetic, so the scan's output does not change.
- `cur_findings` (the state's `findings`, the run file's `all_keys`) is derived from the
  records: `{src: {pkg: ids}}`.

### 2.3 CLI contract — `osv-daily --render`

- Usage line in the header: `osv-daily --render     # rebuild the last report from the
  saved scan results + current acks (no scan)`.
- Argument rules: `--render` with any path, or with `--open`, `--rescan`, `--if-due`,
  `--probe` → stderr `osv-daily: --render takes no path and cannot be combined with
  --open, --rescan, --if-due or --probe`, exit 2 (`--at` already requires `--open`).
- Order of checks in `render_report` (before any temp file): (1) `[ -f "$STATE" ]` else
  stderr `osv-daily: no saved scan to render from — run: hiveguard daily <folder>`, rc 3;
  (2) scan pid live (`[ -f "$SCAN_PID" ] && kill -0 "$(cat "$SCAN_PID")"`) → stderr
  `osv-daily: a scan is in progress (pid <pid>); it writes a fresh report itself`, rc 4;
  (3) python exit 3 (no `render` block, or `render.schema != 1`) → python prints
  `osv-daily: the saved scan predates report re-rendering — run: hiveguard daily` on
  stderr, bash returns 3; any other non-zero python exit → `osv-daily: render failed
  (python exit N)`, rc 1.
- Env for `report_python` in render mode: `RENDER=1 STATE OUT=$REPORT ACKS COUNTS MARKS
  TARGETS_OUT APP_RUNNING STRICT_ON PROBE=0`; `JSON`, `RUN`, `OPENED`, `SCAN_TARGETS`,
  `STAMP`, `TARGET`, `STARTED`, `SCAN_RC` unset or empty. In the python: `stamp`/`target`
  variables come from the state in render mode and from the env in scan mode (the page
  f-string uses the variables, not `ig(...)`).
- After the python: source `COUNTS`; read `TARGETS_OUT` line by line into the
  `--target` list; `folder-mark sync … < MARKS 2>/dev/null || true` (skip when the list is
  empty); log line = the scan's line with `log_kind="render "`; stdout
  `✅ report refreshed (scan of <state stamp>): $ACTIVE_VULNS active vulnerabilities across
  $ACTIVE_PROJECTS projects ($ACKED_VULNS acknowledged) → $REPORT`; exit 0.
- The report write (both modes): `tmp = OUT + ".tmp"`, write, `os.replace(tmp, OUT)`. In
  render mode only: before writing, `st = os.stat(OUT)` if it exists else `os.stat(STATE)`;
  after the replace, `os.utime(OUT, (st.st_atime, st.st_mtime))`.
- Render mode never: writes the state or the run file (`if sf and not render:` around
  both blocks), calls `backfill_open_ended` (`if not render:`), reads `OPENED`, creates the
  scan pid file, runs the bumblebee pull or `command -v osv-scanner`, prompts, opens
  anything. `REPORT` is always the daily report (`--probe` is excluded by the argument
  rules).

### 2.4 `osv-ack` contract

- `here="$(cd "$(dirname "$0")" && pwd)"` at the top (reused by `usage`).
- `refresh_report()`: `[ -f "$STATE" ] || return 0`; `err="$(mktemp)"`;
  `if "$here/osv-daily" --render >/dev/null 2>"$err" </dev/null; then echo "  report and
  folder markers refreshed (reload the report if it is open)"; else reason="$(tail -n1
  "$err" | sed 's/^osv-daily: //')"; [ -n "$reason" ] || reason="osv-daily --render
  failed"; echo "  (report not refreshed: $reason)" >&2; fi; rm -f "$err"; return 0`.
  (`set -e` safe: the render runs inside `if`.)
- Called as the **last** statement of the `--clear`, `--remove`, and mute branches (after
  the existing output lines). Not for `--list`, help, unknown flags.
- Existing lines, exit codes and store semantics unchanged.

### 2.5 Isolated scaffold — the links plan's §2.5 verbatim, plus these helpers

Copy the links plan's 2.5 block unchanged (base 2.4 + `links_on`, `links_off`,
`strict_on`, `strict_off`, `reset_scan`, `enc`, `count`), then add:

```bash
render()   { "$HG/bin/osv-daily" --render >/dev/null 2>&1 </dev/null; }          # rc = osv-daily's
mtime()    { stat -f %m "$1"; }
norm()     { sed 's/osv-daily · [^<]*/STAMP/' "$1"; }                            # stamp-normalised report (cross-scan diffs only)
scan_sig() { md5 -q "$HIVEGUARD_STATE"; md5 -q "$HIVEGUARD_RUN"; md5 -q "$HIVEGUARD_COVERAGE"
             [ -e "$HIVEGUARD_REPORT_OPENED" ] && echo opened || echo no-opened
             [ -e "$HIVEGUARD_SCAN_PID" ] && echo pid || echo no-pid; }            # the scan-only state, as one string
mk_fixture_split() {  # $1=out: run1, but fast-uri's two ids in SEPARATE groups (9.3 / 5.0) — per-id severity
  cat > "$1" <<EOF
{"results":[{"source":{"path":"$SRC","type":"lockfile"},"packages":[
 {"package":{"name":"fast-uri","version":"3.0.1","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-AAAA-0001","affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"3.0.6"}]}]}]},{"id":"GHSA-AAAA-0002","affected":[]}],
  "groups":[{"ids":["GHSA-AAAA-0001"],"max_severity":"9.3"},{"ids":["GHSA-AAAA-0002"],"max_severity":"5.0"}]},
 {"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-BBBB-0001","affected":[{"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}],
  "groups":[{"ids":["GHSA-BBBB-0001"],"max_severity":"9.1"}]}]}]}
EOF
}
mk_fixture_split "$T/split.json"
TAB="$(printf '\t')"
```

Expected from the standard fixtures after `scan run1; scan run2` (links off, no acks):
tiles `1 / 2 / 4 / 1 / 1 new`; markers `$T/proj/app<TAB>active<TAB>4 active
vulnerabilities (1 critical)`; `render.packages[0]` = fast-uri with `new_ids
["GHSA-AAAA-0003"]`, `[1]` = lodash. From `split.json` twice: fast-uri `CRIT 9.3` first,
lodash `CRIT 9.1`; markers `3 active vulnerabilities (2 critical)`.

**Baseline renderer for byte-identity** (H8 acceptance): `mkdir -p "$T/base" && git -C
"$HG" archive 9e5df56 bin | tar -x -C "$T/base"`;
`scan_base() { STUB_JSON="$1" "$T/base/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }`.

### 2.6 App texts (verbatim)

`Links.swift`, both confirmations: the trailing sentence `The report itself updates at the
next scan.` → `The report updates right away — reload it in the browser.` Full messages:

- `ack`: `Requested by a report link.\n\(project) · \(severityLabel(sev)) \(sev %.1f) · \(n) advisory id(s): \(ids)\n\nThis covers every advisory currently known for \(pkg); a new one still alerts. The report updates right away — reload it in the browser.`
- `ack-project`: `Requested by a report link.\n\(src)\n\(p) package(s), \(i) advisory id(s), \(c) critical.\n\nThe report updates right away — reload it in the browser.`

---

## 3. Tasks

Task ids continue the previous plans: `H8`–`H10` (hiveguard, `HG`), `A11`–`A12` (app,
`APP`). Model tiers: `sonnet` = mechanical, fully specified; `opus` = stateful/subtle.
Every task is test-first: write the failing test from its acceptance block first, run it
red, implement, run it green, then run the whole suite of its repo.

### Wave 1 (parallel: H8 · A11)

---

#### H8 — `osv-daily`: persist the render block; `--render`; one python for scan and render

- **Model:** opus — the report python is restructured around persisted records and must
  stay byte-identical on the scan path; a new mode with its own write set, mtime rule and
  refusal ladder.
- **Owns:** `HG/bin/osv-daily`, `HG/tests/report-render.test.sh` (new)
- **Depends on:** nothing

**Do:**

1. **Argument parsing.** `render_flag=0`; `--render) render_flag=1 ;;`. Add `render_flag`
   to the exclusivity checks: `--open` with `--render` → the existing "cannot be combined"
   message gains `--render`; `--probe` with `--render` → its message gains `--render`; and
   a new check right after the probe block: `render_flag=1` with `rescan_flag`,
   `ifdue_flag`, `open_flag`, `probe_flag` or `${#TARGETS[@]} -gt 0` → section 2.3's
   message, exit 2.
2. **Bash — `report_python`.** Move the whole `python3 <<'PYEOF' … PYEOF` block into a
   function `report_python() { python3 <<'PYEOF' … PYEOF }` defined before the mode gate;
   the scan path calls it with the same env prefix it uses today (`APP_RUNNING=… …
   report_python`). Behaviour of the scan path is unchanged.
3. **Bash — `render_report`.** A function (defined next to `open_report`) implementing
   section 2.3 in that order: state check (rc 3), scan-pid check (rc 4), `ACKS` default
   as the scan sets it, `COUNTS`/`MARKS`/`TARGETS_OUT` via `mktemp` with its own
   `trap 'rm -f …' EXIT`, `mkdir -p "$LOGDIR"`, `STRICT_ON`/`APP_RUNNING` computed as the
   scan does, the python call with the render env, rc mapping (3 → 3, other → 1 with the
   message), `. "$COUNTS"`, targets from `TARGETS_OUT`, `folder-mark sync`, the log line
   (`log_kind="render "`, same format, `new=` only when > 0), the done line, exit 0. Wire
   it into the mode gate as `elif [ "$render_flag" = 1 ]; then render_report; exit $?`
   placed right after the `--open` branch (before anything scans, checks osv-scanner or
   pulls bumblebee).
4. **Python — records.** After `merge_results` and the baseline load, build `records`
   (section 2.2) from `d["results"]`: the per-package arithmetic that today lives at the
   top of the fragment loop (ids, `id2sev`, `maxsev`, `fix`, version, eco) plus
   `root: finding_root(src)` and `new_ids`. In render mode (`render = os.environ.get
   ("RENDER", "0") == "1"`): load the state; `blk = state.get("render")`; if it is not a
   dict with `schema == 1` → print the "predates" message to stderr, `sys.exit(3)`;
   `records = blk["packages"]`, `scan_targets = blk["scan_targets"]`, `stamp = state
   ["stamp"]`, `target = state["target"]`, `resolved_vulns = state["counts"]
   ["resolved_vulns"]`; write `scan_targets` to `TARGETS_OUT` one per line; skip `d`, the
   merge, the baseline. In scan mode `stamp`/`target` come from the env and `scan_targets`
   from `SCAN_TARGETS` as today.
5. **Python — shared tail.** Rewrite the fragment loop to iterate `records` grouped by
   consecutive `src` (fragment rule of section 2.2 — same partition, same severities,
   same `new_ids`, same `muted`/`reack_project`); derive `cur_findings` from records;
   `root_agg` uses `rec["root"]`; everything else (sorting, `-k` ids, markers tsv, tally,
   counts file, HTML, CSS, links gate) unchanged. Replace `ig("STAMP")`/`ig("TARGET")` in
   the page with `stamp`/`target`. Gate the scan-only pieces: `backfill_open_ended` →
   `if not render:`; the state write and the run-file block → `if sf and not render:`;
   `new_vulns`/`resolved_vulns`: in scan mode computed as today, in render mode
   `new_vulns` from the fragments and `resolved_vulns` from the state. The state write
   adds `"render": {"schema": 1, "scan_targets": scan_targets, "packages": records}`.
6. **Python — report write.** Replace `open(os.environ["OUT"], "w").write(page)` with
   the atomic write of section 2.3, plus the mtime restore in render mode.
7. **Header comment.** The usage line; a paragraph "Re-rendering" (what `--render` reads
   and writes, what it never touches, mtime stays the scan's, markers refresh, exit
   codes, that `hiveguard ack` runs it); one sentence in the `osv-last-scan.json`
   paragraph ("… and, under `render`, the normalised findings the report is built from").
   `help.awk` rendering intact.
8. **`tests/report-render.test.sh`** (new; header in the house style: what it covers,
   fully offline, isolated HOME; scaffold 2.5 inline including `mk_fixture_split`): the
   checks of the acceptance block below, sections A–I. Leave a clearly marked place for
   H9's section ("# --- J. osv-ack refreshes by itself (H9) ---"). Never assert the
   files *between* a `hiveguard ack` and the following `render` (after H9 the ack renders
   by itself).

**Acceptance criteria** (orchestrator, fresh 2.5 scaffold):

```bash
# --- A. render right after a scan: byte-identical (stamp included), mtime kept, scan state untouched ---
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/run1.json"; scan "$T/run2.json"
cp "$REPORT" "$T/scan.html"; S0="$(scan_sig)"; rm -f "$T_LOG_NOTIFY"; touch -t 202601010000 "$REPORT"
render; echo "rc=$?"                                                                                   # rc=0
cmp "$T/scan.html" "$REPORT" && echo identical                                                         # identical
date -r "$(mtime "$REPORT")" '+%Y%m%d%H%M'                                                             # 202601010000
[ "$S0" = "$(scan_sig)" ] && echo scan-state-untouched                                                 # scan-state-untouched
ls "$HOME/.hiveguard" | grep -c '\.tmp$'; [ -e "$T_LOG_NOTIFY" ] && echo notified || echo silent        # 0 / silent
tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '^\[[^]]*\] render projects=1 pkgs=2 vulns=4 crit=1 new=1 (acked: vulns=0 pkgs=0) markers=R1,Y0 → '   # 1
"$HG/bin/osv-daily" --render </dev/null | tail -n1                                                     # ✅ report refreshed (scan of <stamp>): 4 active vulnerabilities across 1 projects (0 acknowledged) → $REPORT
# --- B. the render block ---
jq -r 'keys|join(",")' "$HIVEGUARD_STATE"                                                              # counts,findings,render,schema,stamp,target
jq -r '.render.schema, (.render.scan_targets|join(",")), (.render.packages|length), (.render.packages[0]|keys|join(","))' "$HIVEGUARD_STATE" | paste -sd' ' -   # 1 $T/proj 2 eco,fix,id_sev,ids,maxsev,new_ids,pkg,root,src,version
jq -r '.render.packages[0] | .pkg, .version, .eco, .fix, .maxsev, (.ids|join(",")), (.new_ids|join(",")), .id_sev["GHSA-AAAA-0003"], .root' "$HIVEGUARD_STATE" | paste -sd' ' -   # fast-uri 3.0.1 npm 3.0.6 7.5 GHSA-AAAA-0001,GHSA-AAAA-0002,GHSA-AAAA-0003 GHSA-AAAA-0003 7.5 $T/proj/app
jq -r '.render.packages[1] | .pkg, .maxsev, (.new_ids|length), .src' "$HIVEGUARD_STATE" | paste -sd' ' -   # lodash 9.1 0 $SRC
jq -c '.findings' "$HIVEGUARD_STATE"                                                                   # {"$SRC":{"fast-uri":["GHSA-AAAA-0001","GHSA-AAAA-0002","GHSA-AAAA-0003"],"lodash":["GHSA-BBBB-0001"]}}
# --- C. a package ack: the row moves; same bytes as a scan with that store ---
"$HG/bin/hiveguard" ack "$SRC" fast-uri </dev/null | head -n1                                          # ✔ muted package: fast-uri  (in $SRC) — 3 known advisories acknowledged; NEW future advisories will still alert.
render; echo "rc=$?"                                                                                   # rc=0
count '>mute</button>'; count '>unmute</button>'; count '>unmute all</button>'; count 'class="mutedbadge"'; count 'NEW +'   # 1 / 1 / 1 / 0 / 0
count '<div class="n">1</div><div class="l">projects affected</div>'; count '<div class="n">1</div><div class="l">vulnerabilities · +3 muted</div>'; count '<div class="n">0</div><div class="l">new since last scan</div>'   # 1 / 1 / 1
grep -c "id=\"p-$(h12 "$SRC")-k\"" "$REPORT"; grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT"   # 1 / 1
cat "$HIVEGUARD_MARKERS"                                                                               # $T/proj/app<TAB>active<TAB>1 active vulnerabilities (1 critical)
[ "$S0" = "$(scan_sig)" ] && echo scan-state-untouched                                                 # scan-state-untouched
cp "$REPORT" "$T/render-ack.html"; scan "$T/run1.json"; scan "$T/run2.json"
diff <(norm "$T/render-ack.html") <(norm "$REPORT") && echo same-as-a-scan                             # same-as-a-scan
# --- D. whole project, then clear: markers follow, strict stops blocking ---
"$HG/bin/hiveguard" ack "$SRC" >/dev/null </dev/null; render
count '✅ No active vulnerabilities — everything found is acknowledged.'; count 'id="copySel"'; count '>unmute all</button>'; count 'whole project'   # 1 / 0 / 1 / 1
cat "$HIVEGUARD_MARKERS"; "$HG/bin/hiveguard" status --json | jq -c '[(.strict.blocked|length), .active_ids]'   # $T/proj/app<TAB>acked<TAB>4 acknowledged / [0,0]
"$HG/bin/hiveguard" ack --clear >/dev/null </dev/null; render
diff <(norm "$T/scan.html") <(norm "$REPORT") && echo back-to-the-scan-report; cat "$HIVEGUARD_MARKERS"   # back-to-the-scan-report / $T/proj/app<TAB>active<TAB>4 active vulnerabilities (1 critical)
# --- E. the gates apply at render time ---
links_on; render; echo "rc=$?"; count 'class="act-link'; count 'class="cp cp-alt"'; count 'hiveguard://pause'   # rc=0 / 3 / 3 / 0
cp "$REPORT" "$T/render-on.html"; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
diff <(norm "$T/render-on.html") <(norm "$REPORT") && echo same-as-a-scan-with-the-app                 # same-as-a-scan-with-the-app
strict_on; render; count 'hiveguard://pause'; count 'class="act-link'                                  # 2 / 5
links_off; strict_off; render; count 'hiveguard://'; diff <(norm "$T/scan.html") <(norm "$REPORT") && echo identical   # 0 / identical
# --- F. per-id severity: a partial package ack re-rates the active fragment ---
reset_scan; scan "$T/split.json"; scan "$T/split.json"; count 'CRIT 9.3'; count '(2 critical)' "$HIVEGUARD_MARKERS"   # 2 / 1   (card head + fast-uri row)
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":["GHSA-AAAA-0001"],"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"; A0="$(md5 -q "$HIVEGUARD_ACKS")"
render; count 'MED 5.0'; count 'class="mutedbadge"'; count '>re-ack</button>'; count '<div class="n">1</div><div class="l">critical</div>'   # 1 / 1 / 1 / 1
sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o 'CRIT 9.3' | wc -l | tr -d ' '; cat "$HIVEGUARD_MARKERS"   # 2 / $T/proj/app<TAB>active<TAB>2 active vulnerabilities (1 critical)   (acked card head + its fast-uri row; the active card now says CRIT 9.1)
[ "$A0" = "$(md5 -q "$HIVEGUARD_ACKS")" ] && echo ack-store-untouched                                  # ack-store-untouched
cp "$REPORT" "$T/render-split.html"; scan "$T/split.json"; scan "$T/split.json"
diff <(norm "$T/render-split.html") <(norm "$REPORT") && echo same-as-a-scan                           # same-as-a-scan
# --- G. open-ended ack: cover-all, never backfilled by a render ---
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":null,"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"; A0="$(md5 -q "$HIVEGUARD_ACKS")"
render; count '>unmute</button>'; count 'class="mutedbadge"'; [ "$A0" = "$(md5 -q "$HIVEGUARD_ACKS")" ] && echo not-backfilled   # 1 / 0 / not-backfilled
rm -f "$HIVEGUARD_ACKS"
# --- H. refusals, recreation, probe, timing, help ---
R0="$(md5 -q "$REPORT")"
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"; echo "rc=$? $out"; rm -f "$HIVEGUARD_SCAN_PID"   # rc=4 osv-daily: a scan is in progress (pid NNNN); it writes a fresh report itself
cp "$HIVEGUARD_STATE" "$T/state.bak"; jq 'del(.render)' "$T/state.bak" > "$HIVEGUARD_STATE"
out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"; echo "rc=$? $out"                   # rc=3 osv-daily: the saved scan predates report re-rendering — run: hiveguard daily
jq '.render.schema = 2' "$T/state.bak" > "$HIVEGUARD_STATE"; render; echo "rc=$?"                       # rc=3
rm -f "$HIVEGUARD_STATE"; out="$("$HG/bin/osv-daily" --render 2>&1 >/dev/null </dev/null)"; echo "rc=$? $out"   # rc=3 osv-daily: no saved scan to render from — run: hiveguard daily <folder>
cp "$T/state.bak" "$HIVEGUARD_STATE"; [ "$R0" = "$(md5 -q "$REPORT")" ] && echo report-kept             # report-kept
for a in "--render $T/proj" "--render --open" "--render --rescan" "--render --if-due" "--render --probe $T/proj/app"; do "$HG/bin/osv-daily" $a >/dev/null 2>&1 </dev/null; printf '%s ' "$?"; done; echo   # 2 2 2 2 2
rm -f "$REPORT"; render; echo "rc=$?"; [ -s "$REPORT" ] && echo recreated; [ "$(mtime "$REPORT")" = "$(mtime "$HIVEGUARD_STATE")" ] && echo mtime-of-the-state   # rc=0 / recreated / mtime-of-the-state
STUB_JSON="$T/run2.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1 </dev/null; P0="$(md5 -q "$HOME/.hiveguard/osv-probe.html")"
render; [ "$P0" = "$(md5 -q "$HOME/.hiveguard/osv-probe.html")" ] && echo probe-untouched               # probe-untouched
time render                                                                                            # real < 1.0s
"$HG/bin/osv-daily" --help | grep -c -- '--render'; "$HG/bin/osv-daily" --help | grep -c 'modification time\|mtime'   # ≥2 / ≥1
ls -A "$HOME/.hiveguard" | sort | tr '\n' ' '                                                           # no *.tmp, no osv-daily.pid, no osv-report-opened
# --- I. the scan path is unchanged: identical to the 9e5df56 renderer (links off and on); run file keys ---
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; cp "$REPORT" "$T/new.html"
mkdir -p "$T/base" && git -C "$HG" archive 9e5df56 bin | tar -x -C "$T/base"
scan_base() { STUB_JSON="$1" "$T/base/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }
reset_scan; scan_base "$T/run1.json"; scan_base "$T/run2.json"
diff <(norm "$T/new.html") <(norm "$REPORT") && echo identical                                          # identical
links_on; strict_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; cp "$REPORT" "$T/new-on.html"
reset_scan; scan_base "$T/run1.json"; scan_base "$T/run2.json"
diff <(norm "$T/new-on.html") <(norm "$REPORT") && echo identical-with-links                            # identical-with-links
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
jq -r 'keys|join(",")' "$HIVEGUARD_RUN"; jq -r '.active[0]|keys|join(",")' "$HIVEGUARD_RUN"            # active,counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen / anchor,eco,fix,ids,pkg,project_anchor,root,sev,src,version
ls "$HOME/.hiveguard" | grep -c '\.tmp$'                                                               # 0
# --- suites, syntax ---
bash "$HG/tests/report-render.test.sh"; echo "rc=$?"                                                    # rc=0
for t in report-actions osv-run report-open notify-handoff osv-coverage osv-exclude status strict-cli; do bash "$HG/tests/$t.test.sh" >/dev/null || echo "FAIL $t"; done; zsh -f "$HG/tests/strict-hook.test.zsh" >/dev/null || echo "FAIL strict-hook"; echo suites-done   # suites-done (no FAIL)
bash -n "$HG/bin/osv-daily" && echo syntax-ok; grep -n 'declare -A\|\btimeout\b' "$HG/bin/osv-daily" "$HG/tests/report-render.test.sh"   # syntax-ok / no output
git -C "$HG" status --porcelain                                                                        # bin/osv-daily tests/report-render.test.sh only
```

**Do not:** touch `osv-ack`, `status`, `strict-mode`, `folder-mark`, any doc; change the
scan's output, the run file, the markers tsv format or the link gate; write the state,
the run file, coverage, the opened stamp or the ack store from a render; notify from a
render; let a render touch `osv-probe.html`; add a `jq` dependency to `osv-daily`; use
`declare -A` or `timeout`.

---

#### A11 — App: link confirmations say the report updates right away; README

- **Model:** sonnet — two strings, their verbatim tests, one README bullet.
- **Owns:** `APP/Sources/HiveGuardCore/Links.swift`,
  `APP/Tests/HiveGuardCoreTests/LinkTests.swift`,
  `APP/Tests/HiveGuardCoreTests/ResolveLinkTests.swift`, `APP/README.md`
- **Depends on:** nothing (contract in section 2.6)

**Do:**

1. `Links.swift`: in `resolveLink`, both messages — replace `The report itself updates at
   the next scan.` with `The report updates right away — reload it in the browser.`
   Nothing else changes.
2. `LinkTests.swift` (four verbatim messages) and `ResolveLinkTests.swift` (two): the same
   replacement. Keep every other assertion.
3. `README.md`, section "Report links (`hiveguard://`)": one new bullet after the
   validation bullet: after a confirmed `ack` / `ack-project` the engine re-renders the
   report from the last scan's saved results and refreshes the folder markers — no rescan;
   reload the page (the dialog says so); `pause` leaves the report as it is; this needs a
   hiveguard with `hiveguard daily --render` (shipped with report links; an older engine
   updates the report at its next scan as before). The app itself never calls the verb.

**Acceptance criteria:**

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1          # 0 / 0 failures
grep -c 'The report itself updates at the next scan' Sources/HiveGuardCore/Links.swift Tests/HiveGuardCoreTests/LinkTests.swift Tests/HiveGuardCoreTests/ResolveLinkTests.swift README.md   # 0 for each
grep -c 'The report updates right away — reload it in the browser.' Sources/HiveGuardCore/Links.swift   # 2
grep -c 'The report updates right away' Tests/HiveGuardCoreTests/LinkTests.swift Tests/HiveGuardCoreTests/ResolveLinkTests.swift   # 4 / 2
grep -rc 'daily --render\|followUp' Sources/ | grep -v ':0$'                                              # no output (the app never calls the verb)
grep -c 'daily --render' README.md; grep -c 'reload' README.md                                            # ≥1 / ≥1
git -C "$APP" status --porcelain                                                                          # the four owned files only; no .build/ dist/
```

**Do not:** add any call, flag, constant or model field; touch `Rules.swift`, `AppModel`,
`Status.swift`, `Sources/HiveGuard/*`, fixtures, `Tests/e2e.test.sh`; change
`minimumHiveguardVersionForLinks`.

---

### Wave 2 (parallel: H9 · H10) — after wave 1 is verified and committed in both repos

---

#### H9 — `osv-ack`: refresh the report and markers after every store write; test section J

- **Model:** sonnet — one function, three call sites, exact lines; fully specified.
- **Owns:** `HG/bin/osv-ack`, `HG/tests/report-render.test.sh` (section J only — append
  after H8's sections, before the summary line)
- **Depends on:** H8

**Do:**

1. `bin/osv-ack`: section 2.4 verbatim — `here` at the top (and `usage` uses it),
   `refresh_report()`, called last in the `--clear`, `--remove` and mute branches.
2. Header comment: one paragraph "After every change (mute, --remove, --clear) the report
   and the folder markers are refreshed from the last scan's saved results — no new scan;
   reload the report. A refresh that cannot happen (no saved scan, scan in progress, a
   scan older than this feature) is reported on stderr and never fails the ack."
3. `tests/report-render.test.sh`, section J: the checks of the acceptance block below
   (success line, report and markers change without an explicit `render`, scan state
   untouched, `--remove`/`--clear` refresh, log-line count, the three failure paths with
   exit 0, no state → no render and no note).

**Acceptance criteria** (fresh 2.5 scaffold):

```bash
links_off; strict_off; reset_scan; rm -f "$REPORT"; scan "$T/run1.json"; scan "$T/run2.json"
cp "$REPORT" "$T/scan.html"; S0="$(scan_sig)"; rm -f "$T_LOG_NOTIFY"; L0="$(wc -l < "$HOME/.hiveguard/osv-daily.log" | tr -d ' ')"; touch -t 202601010000 "$REPORT"
"$HG/bin/hiveguard" ack "$SRC" fast-uri </dev/null; echo "rc=$?"                                          # ✔ muted package: … / undo: … /   report and folder markers refreshed (reload the report if it is open) / rc=0
count '>unmute</button>'; count '>mute</button>'; cat "$HIVEGUARD_MARKERS"                                # 1 / 1 / $T/proj/app<TAB>active<TAB>1 active vulnerabilities (1 critical)
date -r "$(mtime "$REPORT")" '+%Y%m%d%H%M'; [ "$S0" = "$(scan_sig)" ] && echo scan-state-untouched; [ -e "$T_LOG_NOTIFY" ] && echo notified || echo silent   # 202601010000 / scan-state-untouched / silent
tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c '] render projects=1 pkgs=1 vulns=1 crit=1 (acked: vulns=3 pkgs=1) markers=R1,Y0 → '   # 1
"$HG/bin/hiveguard" ack "$SRC" </dev/null | tail -n1; cat "$HIVEGUARD_MARKERS"                           #   report and folder markers refreshed (reload the report if it is open) / $T/proj/app<TAB>acked<TAB>4 acknowledged
count '✅ No active vulnerabilities — everything found is acknowledged.'                                   # 1
"$HG/bin/hiveguard" ack --remove "$SRC" </dev/null | tail -n1; cat "$HIVEGUARD_MARKERS"                  #   report and folder markers refreshed … / $T/proj/app<TAB>active<TAB>4 active vulnerabilities (1 critical)
cmp "$T/scan.html" "$REPORT" && echo back-to-the-scan-report                                             # back-to-the-scan-report
"$HG/bin/hiveguard" ack "$SRC" lodash >/dev/null </dev/null; count '>unmute</button>'                     # 1
"$HG/bin/hiveguard" ack --clear </dev/null | tail -n1; cmp "$T/scan.html" "$REPORT" && echo clear-refreshes   #   report and folder markers refreshed … / clear-refreshes
echo $(( $(wc -l < "$HOME/.hiveguard/osv-daily.log" | tr -d ' ') - L0 ))                                  # 5
# --- failure paths: the ack is applied, the note is on stderr, exit 0 ---
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; out="$("$HG/bin/hiveguard" ack "$SRC" lodash 2>&1 >/dev/null </dev/null)"; echo "rc=$? $out"; rm -f "$HIVEGUARD_SCAN_PID"   # rc=0   (report not refreshed: a scan is in progress (pid NNNN); it writes a fresh report itself)
"$HG/bin/hiveguard" ack --list | grep -c 'lodash'                                                         # 1   (the ack itself went through)
R0="$(md5 -q "$REPORT")"; cp "$HIVEGUARD_STATE" "$T/state.bak"; jq 'del(.render)' "$T/state.bak" > "$HIVEGUARD_STATE"
out="$("$HG/bin/hiveguard" ack --remove "$SRC" lodash 2>&1 >/dev/null </dev/null)"; echo "rc=$? $out"; cp "$T/state.bak" "$HIVEGUARD_STATE"   # rc=0   (report not refreshed: the saved scan predates report re-rendering — run: hiveguard daily)
[ "$R0" = "$(md5 -q "$REPORT")" ] && echo report-kept; "$HG/bin/hiveguard" ack --list | grep -c 'lodash'   # report-kept / 0
rm -f "$HIVEGUARD_STATE" "$REPORT"; out="$("$HG/bin/hiveguard" ack "$SRC" lodash 2>&1 </dev/null)"; echo "rc=$?"; printf '%s\n' "$out" | grep -c 'no scan data'; printf '%s\n' "$out" | grep -c 'refreshed'; [ -e "$REPORT" ] && echo report-written || echo no-report   # rc=0 / 1 / 0 / no-report
"$HG/bin/osv-ack" --help | grep -c -i 'refresh'                                                           # ≥1
bash "$HG/tests/report-render.test.sh"; echo "rc=$?"                                                       # rc=0
for t in report-actions osv-run report-open notify-handoff osv-coverage osv-exclude status strict-cli; do bash "$HG/tests/$t.test.sh" >/dev/null || echo "FAIL $t"; done; zsh -f "$HG/tests/strict-hook.test.zsh" >/dev/null || echo "FAIL strict-hook"; echo suites-done   # suites-done
bash -n "$HG/bin/osv-ack" && echo syntax-ok; git -C "$HG" status --porcelain                              # syntax-ok / bin/osv-ack tests/report-render.test.sh only
```

**Do not:** change the ack semantics, the store format, any existing output line or exit
code; call the render when `$STATE` is absent; let a render failure (any rc) fail the
ack; touch `osv-daily`, `status`, `strict-mode`, docs.

---

#### H10 — hiveguard docs: README, CHANGELOG, report-links contract

- **Model:** sonnet
- **Owns:** `HG/README.md`, `HG/CHANGELOG.md`, `HG/docs/report-links.md`
- **Depends on:** H8, H9 (semantics fixed; textual work only)

**Do:**

1. `README.md`:
   - *Updating* (the "A changed report layout shows up on the **next scan**" note, ~line
     161): add that `hiveguard daily --render` rebuilds the report from the last scan's
     saved results without scanning (once a scan after the update has run).
   - `hiveguard daily` flags block (~line 272): a line `hiveguard daily --render   # rebuild
     the report from the last scan's saved results + current acks (no scan)` and a short
     paragraph after the `--at` one: what `--render` reads and writes, that the report
     keeps the scan's timestamp and modification time, that the "new since last scan"
     comparison, `osv-run.json` and the coverage are untouched, that it refuses during a
     scan and needs a scan made with this version, and that `hiveguard ack` runs it.
   - *Muting old projects*: after "Acknowledgements persist in `~/.hiveguard/osv-acks.json`,
     so the next scan and the scheduled agent both honour them." add: every `hiveguard
     ack` change (mute, `--remove`, `--clear`) re-renders the report and refreshes the
     folder markers at once — reload the report to see the row move; no rescan.
   - *Folder markers*: replace the paragraph "Markers refresh on the **next scan**, not
     instantly — …" with: markers refresh on every scan **and immediately after every
     `hiveguard ack` change** (the red→yellow flip happens the moment you ack; strict mode
     stops refusing the project at the next prompt); keep the sentence that markers only
     ever appear for projects the daily scan covers.
   - Data table: the `osv-last-scan.json` row gains "… and, under `render`, the saved
     findings the report is rebuilt from by `hiveguard daily --render`".
2. `CHANGELOG.md` `## [Unreleased]`: `### Added` — `hiveguard daily --render` (one entry:
   rebuilds the report from the last scan's saved results and the current
   acknowledgements; no scan, no network, no notification; the diff baseline,
   `osv-run.json` and the coverage stay as the scan left them; the report keeps the scan's
   timestamp and modification time); `osv-last-scan.json` now saves the findings the
   report is built from (`render`, additive). `### Changed` (new heading) — `hiveguard
   ack` (mute, `--remove`, `--clear`) refreshes the report and the folder markers right
   away, so a reload shows the row in its new section and a fully acknowledged project is
   no longer blocked by strict mode at the next prompt; before, both changed only at the
   next scan. Keep the existing entries.
3. `docs/report-links.md`: in "When links are emitted" add a bullet that the same gate
   applies when the report is re-rendered after an acknowledgement (`hiveguard daily
   --render`, run by `hiveguard ack`): links appear iff the app is running at render time.
   In "What the app does with a link" replace "The report is static: it does not update
   after an action, only at the next scan." with: after a confirmed `ack` / `ack-project`
   the engine re-renders the report from the last scan's saved results and refreshes the
   folder markers (no rescan); reload the page. `pause` leaves the report unchanged.

**Acceptance criteria:**

```bash
grep -c 'daily --render' "$HG/README.md"; grep -c 'not instantly' "$HG/README.md"; grep -c 'immediately after every' "$HG/README.md"   # ≥3 / 0 / 1
grep -c 'modification time' "$HG/README.md"                                                                   # ≥1
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -c '^### Changed'              # 1
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -c -- '--render\|folder markers\|render'   # ≥3
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -ci 'swift\|Links.swift\|Makefile'       # 0
grep -c 'static' "$HG/docs/report-links.md"; grep -c 'daily --render' "$HG/docs/report-links.md"              # 0 / ≥2
git -C "$HG" status --porcelain                                                                               # README.md CHANGELOG.md docs/report-links.md only
```

**Do not:** cut a version section; touch `docs/status-json.md` or any script or test.

---

### Wave 3 (A12) — after wave 2 is verified and committed in `HG`

---

#### A12 — e2e: the real engine re-renders the report after an ack

- **Model:** sonnet
- **Owns:** `APP/Tests/e2e.test.sh`
- **Depends on:** H8, H9 (in `HG`), A11. Runs against `HIVEGUARD_REPO=$HG` before gate
  G4 and against the main checkout after it.

**Do:**

1. Section 3 (report links): right after `scan "$T/run1.json"; scan "$T/run2.json"` record
   `REP_M0="$(stat -f %m "$REPORT")"` and `HG_LS0="$(ls -A "$HOME/.hiveguard" | sort)"`.
2. After the successful `resolve "$ack_href"` checks, add
   `check "re-render: ack message says the report updates right away" "yes" "$(case "$(jq -r .confirm.message <<<"$RL_OUT")" in *"The report updates right away — reload it in the browser."*) echo yes;; *) echo no;; esac)"`.
3. Right after the existing real `"$HG/bin/hiveguard" ack "$SRC" fast-uri` (the "really
   acked" block), before `resolve "$ack_href"`, add a block **"re-render"** (every check
   named `re-render: …`):
   - fast-uri `ack` href gone from the report: `grep -o '&amp;pkg=fast-uri"' "$REPORT" |
     wc -l` → `0`;
   - fast-uri in Acknowledged: `sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o
     '>unmute</button>' | wc -l` → `1`;
   - lodash still actionable: `grep -o '>mark as known</a>' "$REPORT" | wc -l` → `1`;
   - markers: `grep -c "^$T/proj/app${TAB}active${TAB}1 active vulnerabilities (1 critical)$"
     "$HIVEGUARD_MARKERS"` → `1`;
   - mtime: `stat -f %m "$REPORT"` equals `REP_M0`;
   - no new files: `ls -A "$HOME/.hiveguard" | sort` equals `HG_LS0`; no `*.tmp`.
   Keep the existing refusal checks after it unchanged.
4. Keep every existing check; the final summary line counts the new ones.

**Acceptance criteria:**

```bash
cd "$APP" && HIVEGUARD_REPO="$HG" command make e2e 2>&1 | tee "$T/e2e.log" | tail -n1; grep -c 're-render:' "$T/e2e.log"; grep -c '^FAIL' "$T/e2e.log"   # e2e: N ok, 0 FAIL / ≥7 (6 checks + the message check) / 0
HIVEGUARD_REPO=/Users/mh/Projects/Develop/hiveguard HIVEGUARD_APP_BIN=dist/HiveGuard.app/Contents/MacOS/HiveGuard bash Tests/e2e.test.sh >/dev/null 2>&1; echo "rc=$?"   # rc≠0 before gate G4 (main has no --render: the re-render checks fail), rc=0 after
HIVEGUARD_REPO=/nonexistent bash Tests/e2e.test.sh >/dev/null 2>&1; echo "rc=$?"                             # rc=2
git -C "$APP" status --porcelain                                                                              # Tests/e2e.test.sh only
```

**Do not:** build inside the test; write under `HG`; change the seed or any fixture.

---

## 4. Verification plan (orchestrator) and commit boundaries

Before wave 1, record the real machine's state (nothing below may change it):

```bash
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"
stat -f '%m %N' ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/osv-last-scan.json ~/.hiveguard/osv-projects.html ~/.hiveguard/config
ls -A ~/.hiveguard | sort > /tmp/hg-before.txt; md5 -q ~/.hiveguard/osv-projects.html > /tmp/hg-report-before.txt
git -C /Users/mh/Projects/Develop/hiveguard status --porcelain; git -C /Users/mh/Projects/Develop/hiveguard rev-parse --abbrev-ref HEAD   # clean / main
git -C "$HG" rev-parse --abbrev-ref HEAD; git -C "$APP" rev-parse --abbrev-ref HEAD                      # feat/report-rerender / worktree-menubar-app
```

The spec and this plan are committed to `HG` on `feat/report-rerender` **before** dispatch
(`docs: report re-render after ack — design addendum and plan`), so the plan the agents
read is the committed one.

Run each task's acceptance block verbatim in a **fresh** 2.5 scaffold. Per wave:

### Wave 1

```bash
bash "$HG/tests/report-render.test.sh" && echo hg-wave1-ok
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac >/dev/null || echo "FAIL $t"; done   # no FAIL lines
bash -n "$HG/bin/osv-daily"; grep -n 'declare -A\|\btimeout\b' "$HG/bin/osv-daily" "$HG/tests/report-render.test.sh"   # no output
git -C "$HG" status --porcelain                                      # bin/osv-daily tests/report-render.test.sh
(cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1)   # 0 / 0 failures
git -C "$APP" status --porcelain                                     # A11's four files only; no .build/ dist/
```

Commits:
- `HG` #1 `feat(daily): save the scan's findings in osv-last-scan.json; --render rebuilds the report and markers from them` — `bin/osv-daily`, `tests/report-render.test.sh`
- `APP` #8 `feat: link confirmations say the report updates right away` — A11's files

### Wave 2

```bash
# H9 + H10 blocks, then:
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *.zsh) zsh -f "$t";; *) bash "$t";; esac >/dev/null || echo "FAIL $t"; done   # no FAIL lines — INCLUDING strict-integration (network; H9 changes what it covers)
git -C "$HG" status --porcelain                                      # bin/osv-ack tests/report-render.test.sh README.md CHANGELOG.md docs/report-links.md
```

Commits:
- `HG` #2 `feat(ack): refresh the report and folder markers right after every acknowledgement change` — `bin/osv-ack`, `tests/report-render.test.sh`
- `HG` #3 `docs: report re-render after ack — README, CHANGELOG, report-links` — H10's files

### Wave 3

```bash
(cd "$APP" && HIVEGUARD_REPO="$HG" command make e2e); echo "rc=$?"   # rc=0
# non-leakage, whole effort:
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"   # as recorded
stat -f '%m %N' ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/osv-last-scan.json ~/.hiveguard/osv-projects.html ~/.hiveguard/config   # unchanged (the real 10:00 scan may have refreshed report/state/markers — note it)
ls -A ~/.hiveguard | sort | diff /tmp/hg-before.txt -               # empty (or only what the real scheduled scan writes)
```

Commit `APP` #9 `test: e2e — the real engine re-renders the report after an ack`.

Then stop every agent of the wave (session hygiene) and move to the gates.

---

## 5. Gates

- **G3 (amended for this plan):** `strict-integration.test.sh` (network) runs at the end
  of wave 2 — the one existing test that exercises ack → markers → strict end to end —
  and once more before G4 if anything in `HG` changed after wave 2.
- **G4 — engine merge:** after wave 3 is green, merge `feat/report-rerender` into `main`
  in the main checkout (fast-forward), remove the worktree. From then on the real
  `hiveguard ack` refreshes the real report and markers — but only once a real scan made
  with this version has written the `render` block (until then it prints the "predates"
  note). Release tagging is the maintainer's call; the CHANGELOG `[Unreleased]` carries
  the entries next to the report-links ones (spec §3.3 assumes they ship together).
- **G5 — real-machine finish (section 6):** STOP and ask the maintainer before the first
  real scan and before any real ack; proceed only on an explicit "go".
- **G6 — app branch:** `worktree-menubar-app` → `main` in the app repo is the maintainer's
  call; the app needs a `make install` to show the new dialog sentence (text only — the
  refresh itself works with the installed app as is).

**Execution split:** engine tasks (H*) from the Claude session in the hiveguard worktree;
app tasks (A*) from the session in the app worktree. A11 needs only the contract; A12
needs H8 + H9 (via `HIVEGUARD_REPO=$HG` before G4).

---

## 6. Real-machine finish (orchestrator, ONLY after gate G5 is opened)

The only steps that touch the real `~/.hiveguard` and may run real `hiveguard ack` on
real data. Every mutation has its undo line; every ack re-renders the real report and
re-tags real folders, and its undo does the same in reverse.

1. **Seed the block (maintainer's call — a real scan of `~/Projects`, several minutes):**
   `hiveguard daily --rescan` (or wait for the scheduled run). Verify:
   `jq -r '.render.schema, (.render.packages|length)' ~/.hiveguard/osv-last-scan.json` →
   `1 <≈660>`; `ls -la ~/.hiveguard/osv-last-scan.json` (expect ~0.5 MB).
2. **Render is a no-op on identical input:** `M0=$(stat -f %m ~/.hiveguard/osv-projects.html);
   md5 -q ~/.hiveguard/osv-projects.html; time hiveguard daily --render; md5 -q
   ~/.hiveguard/osv-projects.html; stat -f %m ~/.hiveguard/osv-projects.html` → same md5
   (if the app's running state equals the scan's), same mtime, `real` < 2 s; `tail -n1
   ~/.hiveguard/osv-daily.log` shows the `render` line; `hiveguard mark status` unchanged.
3. **Terminal ack (a low finding the maintainer names, `<src> <pkg>`):** `hiveguard ack
   "<src>" <pkg>` → prints the refreshed line → reload the report in the browser → the
   row sits in Acknowledged; `hiveguard mark status` / the Finder tag reflect it if the
   project had nothing else active; `hiveguard strict status` likewise. Undo: `hiveguard
   ack --remove "<src>" <pkg>` → reload → back.
4. **Report button (app running, installed from G6 or the current install):** click *mark
   as known* on the same finding → the dialog ends with "The report updates right away —
   reload it in the browser." (old text with the previously installed app — fine) →
   confirm → reload → moved. Undo as above.
5. **Whole project (optional, a project the maintainer names and is willing to unblock):**
   *mark project as known* → `hiveguard strict status` no longer lists it; a guarded
   command runs at the next prompt. Undo: `hiveguard ack --remove "<src>"` → blocked again.
6. **Scheduler sanity (next morning):** `osv-daily.log` has the scheduled scan line after
   the `render` lines (the report's mtime stayed the scan's, so `--if-due` scanned).
7. **Rollback (always available):** check out the previous `main` in the main checkout
   (or `brew` switch): older versions ignore the `render` key; `ack` returns to "next
   scan" behaviour; nothing else to undo.
8. Record the outcome; no ad-hoc patches — a defect becomes a task.

---

## 7. Out of scope / follow-ups (open as issues, do not implement here)

- Re-render after `strict on` / `off` (pause buttons appear/disappear) — one call in
  `strict-mode`.
- Refreshing `osv-run.json` `roots[].crit_pkgs` / `counts` on a render (today stale for
  partially acked roots until the next scan).
- A lock around concurrent renders (menu + terminal within ~0.2 s).
- Auto-reload of the report page (would need JavaScript polling a file: URL — not
  possible from `file:`).
- Compacting `osv-last-scan.json` if it ever grows beyond a few MB.

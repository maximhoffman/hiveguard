# Report advisory details — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-20
Spec: `docs/superpowers/specs/2026-10-20-report-advisory-details-design.md`
Previous plan (conventions, scaffold): `docs/superpowers/plans/2026-10-14-report-rerender-plan.md`

This document is the design for implementers. Agents are dispatched straight from it and
must not redesign. Section 1 fixes the technical choices; section 2 is the shared contract
every task must match byte-for-byte (state fields, markup, class names, labels, the
fixture); section 3 is the task list in waves with the executor model per task; section 4
the orchestrator's verification and commit boundaries.

Conventions (as in the previous plans):

- `HG` = the worktree `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/report-advisory-details`,
  branch `worktree-report-advisory-details`, based on `main` = `0958bce` (1.7.0). Work
  format 2: built-in Read/Edit with absolute worktree paths, no Serena symbolic edits.
  The main checkout stays on `main`.
- Parallel tasks in one wave never write the same file. Each task's **Owns** list is
  exhaustive and exclusive within its wave. Agents never run git; the orchestrator does.
- Every test runs in the **isolated scaffold** of the existing tests (fresh
  `HOME=$(mktemp -d)` canonicalised with `pwd -P`, every `HIVEGUARD_*` override, stubs on
  `HIVEGUARD_TOOL_PATH`, osv-scanner stubbed to replay a JSON fixture). Never the real
  `~/.hiveguard`.
- bash 3.2 (no associative arrays; `"${arr[@]+"${arr[@]}"}"`), no `timeout`, BSD `stat`,
  `date -r`, `shasum`, `md5 -q`. Report rows are rendered on **one line**: counts use
  `grep -o … | wc -l`, never `grep -c`. Acceptance blocks use `jq`, not python.
- Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## 1. Architecture decisions (resolved)

### 1.1 One python, four changes, no new files in `bin/`

Everything lands in the report python of `bin/osv-daily` (`report_python`): the version
comparator and the per-advisory fix (spec §2), the advisory table and `id_fix` in the
records (spec §1.1), the "no score" badge and rank (spec §3), the Advisory column, the
list row, the JSON table and the script additions (spec §1.2–1.5), the renamed button
(spec §4). The scan and `--render` share it, so both paths change together.

### 1.2 Presence, not a schema bump

`render.schema` stays 1. The new layout is used iff the render block has an `advisories`
key (every scan by this version writes it, `{}` when the scan found nothing). A 1.7.0
state renders the legacy IDs column. `id_fix` missing from a record reads as `{}`.

### 1.3 Affected-entry matching is strict about the package

An `affected[]` entry with no `package` never matches (spec §2.1). The existing test
fixtures (four files, inline) therefore gain `"package":{"name":…,"ecosystem":"npm"}` on
every entry — a deliberate fixture update, task T3. A range with a missing `type` is
used (only `GIT` is excluded).

### 1.4 The 9e5df56 byte-identity checks are retired

`tests/report-render.test.sh` section I diffs the scan's report against the 1.6.3+links
renderer. The report changes by design (column, badges, order); those two diff checks
go, the run-file / state / key-list checks of section I stay.

### 1.5 Details text once, filled by script

The per-advisory full text is emitted once in a JSON `<script>` table and copied into
the opened `<details>` through `textContent` (spec §1.5). Summaries, aliases, badges and
fixes are rendered server-side per row.

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 State file (`osv-last-scan.json`, `render` block)

```
render.schema         1 (unchanged)
render.scan_targets   unchanged
render.packages[]     unchanged keys + "id_fix": {"<id>": "<fixed version>"}  (only ids with a fix)
render.advisories     {"<id>": {"summary": str, "aliases": [str], "details": str, "truncated": bool}}
```

Key order of a package record (jq `keys`): `eco,fix,id_fix,id_sev,ids,maxsev,new_ids,pkg,root,src,version`.
Key order of the render block: `advisories,packages,scan_targets,schema`.
`details` cap: 4000 characters; cut at the last whitespace at or before index 4000
(`text[:4000].rsplit(None, 1)[0]` when the text is longer, else the whole text; if no
whitespace, a hard cut at 4000); `truncated` true iff cut. `summary` → `""` when the
scanner has none, `aliases` → `[]`.

### 2.2 Python helpers (names, so the tests and the comments agree)

```
vkey(v)                 -> (release_tuple, rank, tokens) | None       spec §2.3
vcmp(a, b)              -> -1/0/1, raises nothing; None for an unparsed side
pkg_match(aff, name, eco) -> bool                                       spec §2.1 step 1
advisory_fix(vuln, name, eco, version) -> str ("" = none)               spec §2.1
sev_rank(s)             -> 5 crit / 4 high / 3 unscored (s <= 0) / 2 med / 1 low
sev_key(s)              -> (sev_rank(s), s)          — every severity sort uses this, reverse=True
sev_bucket(s)           -> (cls, lbl): ("crit","CRIT") ("high","HIGH") ("med","MED") ("low","LOW") ("na","no score")
sev_badge(s)            -> '<span class="sev {cls}">{lbl} {s:.1f}</span>' for s > 0, '<span class="sev na">no score</span>' otherwise
desc_of(id)             -> summary | first sentence of details (≤ 160 chars, split at the first ". ", ".\n" or "\n") | "no description"
```

### 2.3 Report markup

Package row, Advisory cell (new layout). `LEAD` = the lead id, `N` = number of ids of the
fragment, `DESC` = `html.escape(desc_of(LEAD))`, `FID` = the row's `f-…` id (with `-k`
for the acked twin), `NEWCLS` = `new` iff the lead is in the fragment's `new_ids`
(active section), else empty — same `class="…"` attribute form as today's id links:

```
<td class="ids"><a class="NEWCLS" href="https://osv.dev/LEAD" target="_blank" rel="noopener">LEAD</a> <button class="advt" type="button" aria-expanded="false" aria-controls="a-FID" title="DESC">DESC<span class="more">+K more</span></button></td>
```

`<span class="more">+K more</span>` only when N > 1, with K = N − 1. Column header
`<th>Advisory</th>` (legacy layout: `<th>IDs</th>` and the 1.7.0 cell, unchanged).

The list row, emitted right after the package row's `</tr>`, one `<li>` per id in lead
order (`sorted(ids, key=lambda i: sev_key(id_sev.get(i, maxsev)), reverse=True)`):

```
<tr class="adv" id="a-FID" hidden><td colspan="6"><ul class="advl">
<li><a class="NEWCLS" href="https://osv.dev/ID" target="_blank" rel="noopener">ID</a><span class="alias">CVE-…</span>…<span class="sev CLS">LBL</span><span class="newbadge">NEW</span><span class="sum">DESC</span><span class="afix">fixed in FIX</span><details class="advd"><summary>details</summary><pre class="advtext" data-adv="ID"></pre></details></li>
</ul></td></tr>
```

(no newlines inside — the whole `<tr>` is one line, like the package row). Optional
parts: one `alias` span per alias starting with `CVE-`, in the scanner's order; `NEW`
badge only when the id is in the fragment's `new_ids` (active section); `afix` only when
`id_fix` has the id. The severity badge is `sev_badge(id_sev.get(id, maxsev))`.

Package-row severity badge and card-head badge: `sev_badge(sev)` (identical bytes to
today for a scored item). Card head of a project = `sev_badge` of its top row.

The description table, emitted once right before the page's main `<script>` (only in
the new layout; absent in the legacy layout):

```
<script type="application/json" id="advdb">{"ID": "DETAILS…", …}</script>
```

`DETAILS` = stored `details` + (`… (truncated — full text on osv.dev)` when
`truncated`). Serialised with `json.dumps(table, ensure_ascii=False)`, then
`.replace("</", "<\\/").replace("<!--", "<\\!--")`.

Script additions (inside the existing main script's IIFE, before `sync();`):

```js
document.addEventListener('click',function(e){
  var b=e.target.closest('button.advt'); if(!b) return;
  e.preventDefault(); e.stopPropagation();
  var r=document.getElementById(b.getAttribute('aria-controls')); if(!r) return;
  var show=r.hasAttribute('hidden');
  if(show) r.removeAttribute('hidden'); else r.setAttribute('hidden','');
  b.setAttribute('aria-expanded',show?'true':'false');
});
var advdb=null;
document.addEventListener('toggle',function(e){
  var d=e.target; if(!d.classList||!d.classList.contains('advd')||!d.open) return;
  var pre=d.querySelector('pre.advtext'); if(!pre||pre.textContent) return;
  if(advdb===null){ try{ advdb=JSON.parse(document.getElementById('advdb').textContent); }catch(err){ advdb={}; } }
  pre.textContent=advdb[pre.getAttribute('data-adv')]||'(see osv.dev)';
},true);
```

CSS (class names fixed; values are the builder's, in the report's existing style —
mono small type, `--faint` / `--muted`, chips like `.whole`):

```
.sev.na{background:var(--surface-2);color:var(--muted)}
.advt  — the toggle: unstyled button look (no border/background), inherits .ids font, color var(--text); max-width:34ch; one line, overflow hidden, text-overflow ellipsis; cursor pointer; hover → color var(--accent)
.advt .more — faint, margin-left 6px
tr.adv[hidden]{display:none}
tr.adv>td{background:var(--surface-2);padding:6px 12px 8px 28px}
.advl{list-style:none;margin:0;padding:0;font-family:var(--mono);font-size:11.5px}
.advl li{padding:4px 0;display:flex;flex-wrap:wrap;align-items:center;gap:6px}
.alias — chip like .whole
.sum{color:var(--muted)}  .afix{color:var(--low)}
.advd summary{cursor:pointer;color:var(--accent);font-size:11px}
.advtext{white-space:pre-wrap;font-family:var(--sans);font-size:12.5px;color:var(--text);margin:6px 0 2px;max-width:72ch}
```

### 2.4 Labels and tooltips (spec §4)

| Row | App running | App not running |
|---|---|---|
| ordinary active | `mark as known` link, title `Mark this finding as known via the HiveGuard app (asks for confirmation)` (unchanged) | `mute` copy button (unchanged) |
| pierced (muted badge) | `mark as known` link, title **`A new advisory appeared in a package you had muted. Mark it as known too (asks for confirmation).`**, href `ack` or `ack-project` as today | **`mute`** copy button (same command as today) |

The string `re-ack` must not appear in `bin/osv-daily`, `README.md` or any test after
this work (`grep -rn 're-ack' bin README.md tests` → nothing).

### 2.5 The regression fixture

`tests/fixtures/advisory-details.json` (committed, trimmed real osv-scanner output):
three results with placeholder source paths `__SRC_GO__` (golang.org/x/net 0.57.0, five
Go advisories, `max_severity` `""`), `__SRC_NPM__` (@vitest/mocker 3.2.7, nanoid 3.3.16,
vitest 3.2.7). A test copies it and replaces the placeholders with real paths under its
`$T` (`sed "s|__SRC_GO__|$T/proj/go/go.mod|; s|__SRC_NPM__|$T/proj/web/package-lock.json|"`),
creating those files and `.git` dirs so roots resolve. Expected after the change:

| package | `fix` | `id_fix` | severity |
|---|---|---|---|
| golang.org/x/net 0.57.0 | `0.60.0` | all five ids → `0.60.0` | `no score` (sev 0) |
| vitest 3.2.7 | `4.1.11` | GHSA-82fw-gwwq-j7x9 → `4.1.11` | `MED 5.9` |
| @vitest/mocker 3.2.7 | `4.1.11` | same | `MED 5.9` |
| nanoid 3.3.16 | `3.3.18` | GHSA-2v37-7h3g-55p8 → `3.3.18` | `HIGH 8.2` |

GO-2026-6603: summary `HTTP/2 server memory exhaustion due to Trailer headers in net/http`,
aliases `["BIT-golang-2026-78659","CVE-2026-78659"]`, details ≈ 1 KB, not truncated.

### 2.6 Existing-fixture update (T3)

In `tests/report-render.test.sh`, `tests/report-actions.test.sh`, `tests/osv-run.test.sh`,
`tests/notify-handoff.test.sh` (the inline `mk_fixture` / `mk_fixture_split` heredocs and
any other inline advisory), every `"affected":[{"ranges":…` becomes
`"affected":[{"package":{"name":"<that package>","ecosystem":"npm"},"ranges":…`
(fast-uri for GHSA-AAAA-*, lodash for GHSA-BBBB-*). Entries that are `"affected":[]`
stay. Expected fixes stay `3.0.6` / `4.17.21`.

---

## 3. Tasks

### Wave 1 (parallel; no shared files)

#### T1 — engine: fix, advisories, no score, label, report markup — model: **opus**

Owns: `bin/osv-daily` (only).

Do, in the report python and the header comment:

1. Add `vkey`, `vcmp`, `pkg_match`, `advisory_fix` (spec §2, contract §2.2); delete
   `vtuple`. Compute per record `id_fix` (dict, only non-empty fixes) and `fix` = the
   maximum of `id_fix.values()` under `vcmp` (an unparsed fix loses to any parsed one;
   among only unparsed fixes keep the first). Order of ids/entries as in the scanner
   output.
2. Build `adv_table` on a scan from every vulnerability seen (dedup by id, first
   occurrence wins): summary, aliases, details capped per §2.1, truncated. Write it as
   `render.advisories`; on `--render` read `blk.get("advisories")` (None → legacy
   layout) and each record's `id_fix` with `rec.get("id_fix") or {}`.
3. `sev_rank`, `sev_key`, `sev_badge`; `sev_bucket(0)` → `("na", "no score")`. Replace
   every `sort(key=lambda x: x["sev"]…)` / `x["maxsev"]` with `sev_key`; a project's
   `maxsev` becomes its top row's `sev` (`pkgs[0]["sev"]` after the sort). Use
   `sev_badge` for the package row, the card head and the advisory list. Counting
   (`>= 9`), markers, run file and state values stay numeric and unchanged.
4. The Advisory cell, the list row, the JSON table, the CSS and the script additions —
   contract §2.3, byte for byte. Legacy layout when `adv_table is None`. The acked twin's
   list row id gets the `-k` suffix with the row.
5. Labels per §2.4. Update the header comment (the "Report action buttons" and
   "Acknowledgements" paragraphs: `mark as known`; a short paragraph on the Advisory
   column, the saved descriptions and "no score"; note the 4 000-character cap) and the
   code comments that say `re-ack`.
6. Escape everything that comes from the scanner with `html.escape` (ids, summaries,
   aliases, fixes, versions); the JSON table per §2.3.

Acceptance (the orchestrator runs these; T2/T3 provide the files):

```bash
cd "$HG" && bash -n bin/osv-daily && grep -c 're-ack' bin/osv-daily   # → 0 (grep exits 1)
bash tests/report-advisories.test.sh          # after T2
bash tests/run.sh                             # after T2 + T3, everything passes
```

#### T2 — new test `tests/report-advisories.test.sh` — model: **sonnet**

Owns: `tests/report-advisories.test.sh` (new).

Copy the scaffold of `tests/report-render.test.sh` (header comment style, `check`,
`count`, stubs, env, `h12pkg`, `scan`, `render`, `links_on/off`). Fixture: §2.5 (copy +
sed; create `$T/proj/go/.git`, `$T/proj/go/go.mod`, `$T/proj/web/.git`,
`$T/proj/web/package-lock.json`). Sections and checks (each `check` with exact expected
strings per §2):

- **A. fixes (regression):** `render.packages[]` `fix` and `id_fix` for the four
  packages (jq); the report cells `<td class="mono fix">0.60.0</td>`, `4.1.11` ×2,
  `3.3.18`; `osv-run.json` `active[].fix` for the four; `hiveguard status --json`
  `.active[] | select(.pkg=="golang.org/x/net") | .fix` → `0.60.0`.
- **B. comparator and matching (synthetic inline fixture, one result, several packages):**
  RubyGems `rails 6.0.0.beta2` with range `[6.0.0.beta1, 6.0.0.beta3)` → `6.0.0.beta3`
  (a pre-release tag compares below its release, tokens `beta`,`2` < `beta`,`3`);
  RubyGems `rails 6.0.1` with that range only → `—` (not contained; the fallback finds
  no fix above 6.0.1); PyPI `Django 2.2.0` with ranges `[2.0a1, 2.0.13)` and
  `[2.2a1, 2.2.4)` → `2.2.4`; npm `x 1.0.0` with `[0, last_affected 1.0.0]` → `—`;
  npm `y 1.0.0` whose only entry has no `package` → `—`; npm `z 1.0.0` with a `GIT`
  range only → `—`; Go `golang.org/x/text 0.3.7` with entries `stdlib [0, 1.20)` and
  `golang.org/x/text [0, 0.3.8)` → `0.3.8`; npm `w 2.0.0` with two advisories, fixes
  `2.0.5` and `2.1.0` → `fix` `2.1.0`, `id_fix` holds both; npm `pre 5.0.0-rc.1` with
  `[5.0.0-beta.1, 5.0.0-rc.2)` → `5.0.0-rc.2`; npm `q 4.1.11` with `[2.1.0, 4.1.11)` and
  `[5.0.0-beta.1, 5.0.0-rc.2)` → `5.0.0-rc.2` (no span contains 4.1.11, so the
  fallback — the lowest fix above the version, same package — applies; name the check
  "fallback").
- **C. no score:** count of `<span class="sev na">no score</span>` in the x/net card =
  1 head + 1 row + 5 list badges = 7; `LOW 0.0` count 0; critical tile `0`; marker line
  for the go root has no `critical`; ordering with a synthetic fixture holding rows
  `HIGH 7.5`, unscored, `MED 5.0`, `CRIT 9.1` in one manifest → the `<tr id="f-…">` order
  in the HTML is CRIT, HIGH, no score, MED (compare the sequence of package names via
  `grep -o '<td class="pk">[^<]*'`); card ordering across two manifests (one headed
  `no score`, one `MED 5.0`) → the unscored card first; a card with HIGH + unscored is
  headed `HIGH`.
- **D. descriptions:** state `render.advisories` keys count 7 and the GO-2026-6603
  entry (summary, aliases, truncated false, details length > 500); a synthetic advisory
  with 6 000-character details → stored length ≤ 4 000, `truncated` true, and the advdb
  text ends with `… (truncated — full text on osv.dev)`; the x/net Advisory cell exactly
  per §2.3 (lead GO-2026-6603 — ties → first in scanner order; `+4 more`); the list row
  `id="a-f-<h12>"` with 5 `<li>`, 5 `class="alias">CVE-`, 0 `BIT-golang` in the HTML
  outside advdb, 5 `fixed in 0.60.0`, 5 `data-adv=`; the advdb `<script>` parses with
  `jq` (extract with `sed -n 's/.*<script type="application\/json" id="advdb">\(.*\)<\/script>.*/\1/p'`
  on the matching line — the table is on its own line) and has the 7 ids; a synthetic
  advisory whose details contain `</script><b>x</b>` and whose summary contains `<b>` →
  the page contains `<\/script>` and `&lt;b&gt;`, not `</script><b>`; a synthetic
  advisory with an empty summary and details `First sentence. Second.` → the cell text
  `First sentence.`; one with neither → `no description`; the column header
  `<th>Advisory</th>`.
- **E. legacy:** `jq 'del(.render.advisories)'` on the state → `--render` rc 0,
  `<th>IDs</th>`, 0 `class="advt"`, 0 `id="advdb"`, the saved fixes still shown; restore.
- **F. sections:** after `hiveguard ack <npm src> nanoid`, the acked section has the
  Advisory cell and a list row `id="a-f-<h12>"` (plain id — no active twin); after a
  partial ack (synthetic two-id package, one id acked) the acked twin's list row is
  `a-f-<h12>-k`; a `--probe` report has the Advisory column.
- **G. label:** pierced row with the app off → `>mute</button>` and `class="mutedbadge"`;
  app on → `>mark as known</a>` with `title="A new advisory appeared in a package you had
  muted. Mark it as known too (asks for confirmation)."`; `re-ack` absent from the page.
- **H. render parity:** `--render` right after the scan is byte-identical (`cmp`) to the
  scan's report; the state's `render.packages[0]|keys` and `render|keys` per §2.1.

The test must pass against T1's engine; where the plan leaves a byte undefined, read
`bin/osv-daily` (T1 may finish first) and prefer its bytes only if they match §2.3.

#### T3 — existing tests: fixtures, labels, retired checks — model: **sonnet**

Owns: `tests/report-render.test.sh`, `tests/report-actions.test.sh`,
`tests/osv-run.test.sh`, `tests/notify-handoff.test.sh`, `tests/status.test.sh` (if it
needs anything — expected no).

1. Fixture `package` entries per §2.6 in all four files.
2. `tests/report-render.test.sh`: B "render block shape" → the new key lists (§2.1);
   F `>re-ack</button>` → `>mute</button>` with the count recomputed (the pierced
   fast-uri row **and** the lodash row now both read `mute` → 2); retire the two diff
   checks of section I named "links off → identical to 9e5df56 (card heads aside)" and
   "links + strict on → identical to 9e5df56 (reload script aside)" together with the
   helpers only they use (`legacy_names`, `strip_reload`, the `scan_base` runs that feed
   them, the "I: 9e5df56 renderer extracted" check and the `git archive`); keep the run
   file / state / key-list checks of section I. Update the file's header comment
   accordingly.
3. `tests/report-actions.test.sh`: `>re-ack</a>` → `>mark as known</a>` (counts: the
   pierced row plus the ordinary lodash row = 2); the title check → the new tooltip; the
   project-mute variant likewise; `title=\"Fold` → the new title's start.
4. Any check that counted id links in the IDs column (e.g. `osv.dev/` counts) — adjust to
   the new cell (one lead link per row + one per `<li>`).

Acceptance: `bash tests/run.sh` with T1 in place — every file passes;
`grep -rn 're-ack' tests` → nothing.

#### T4 — docs — model: **sonnet**

Owns: `README.md`, `CHANGELOG.md`.

1. README: the ack section sentence (line ≈ 377) and the worked example (≈ 388) — the
   button is **mark as known** (with the app) / **mute** (without), badged `muted`; say
   in one sentence that the row's Advisory column describes the advisory and expands to
   the list. The report description (wherever README describes the report's columns:
   search `Fixed in`, `IDs`, `LOW`) — the Advisory column, "no score", and that "Fixed
   in" is the fix for the installed version line.
2. CHANGELOG `## [Unreleased]`: **Added** — advisory descriptions in the report (the
   Advisory column, the expandable list with CVE aliases, per-advisory severity and fix,
   full text on click; stored in `osv-last-scan.json` `render.advisories`, 4 000-char
   cap; a scan by this version is needed before `--render` shows them). **Fixed** —
   "Fixed in" is the fix for this package on its own version line (was the highest fix
   of any package or line named by the advisories: `1.27.2` for `golang.org/x/net
   0.57.0`, `5.0.0-rc.2` for vitest 3.2.7; now `0.60.0`, `4.1.11`); unknown severity
   shows `no score` instead of `LOW 0.0` and ranks after HIGH (was: last). **Changed** —
   the pierced row's button reads `mark as known` / `mute` (was `re-ack`).

Acceptance: `grep -n 're-ack' README.md` → nothing; the CHANGELOG section renders.

### Wave 2 (orchestrator)

Run `bash tests/run.sh`; fix mismatches between T1 and T2/T3 by reading the contract
(§2) — the contract wins over both; render the fixture report and screenshot it
(playwright, `python3 -m http.server` in `$T`) to eyeball density; measure the state
size on a real scan into an isolated `HOME` (`HOME=$(mktemp -d) HIVEGUARD_STATE=… bin/osv-daily
~/Projects`, network) — must be < 5 MB; note the number in the final report.

---

## 4. Verification and commits

| Commit | Contents | Gate |
|---|---|---|
| C1 `docs: report advisory details — design addendum, plan, regression fixture` | spec, plan, `tests/fixtures/advisory-details.json` | — |
| C2 `feat(daily): advisory descriptions in the report; Fixed in per version line; "no score"; mark as known` | T1, T2, T3 | `bash tests/run.sh` all pass; `grep -rn re-ack bin tests` empty |
| C3 `docs: advisory details — README, CHANGELOG` | T4 | `grep -n re-ack README.md` empty |

Independent verification before C2 (not the agents' word): the orchestrator runs the
suite itself, opens the rendered fixture report, checks the four fixes and the `no score`
badge in the HTML with `grep`, and checks `--render` on a copy of the maintainer's real
1.7.0 state (`cp ~/.hiveguard/osv-last-scan.json` into an isolated `HOME`, read-only on
the original) exits 0 with the legacy column.

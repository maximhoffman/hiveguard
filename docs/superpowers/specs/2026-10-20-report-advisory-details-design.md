# Report: advisory descriptions, correct "Fixed in", "no score", "mark as known" — design addendum

Status: product decision made (maintainer, 2026-10-20: all four items of the brief are in
scope); technical design resolved; tasks in
`docs/superpowers/plans/2026-10-20-report-advisory-details-plan.md`
Date: 2026-10-20
Brief: `~/Projects/Develop/hiveguard-tasks/2026-10-20-report-advisory-details.md`
Extends: `2026-10-14-report-rerender-design.md` (the `render` block, `--render`),
`2026-10-09-report-app-actions-design.md` (links). Section numbers here are local.
Baseline: hiveguard `main` at `0958bce` (1.7.0), worktree `report-advisory-details`,
branch `worktree-report-advisory-details`.

## Problem

The 2026-10-19 scan alerted on `golang.org/x/net 0.57.0` in `admosphere-prod` with five
new Go advisories. The card said `LOW 0.0 · NEW +5 · Fixed in 1.27.2` and nothing about
what the advisories are. All three facts were wrong or useless:

- osv-scanner's JSON carries `summary`, `details` and `aliases` per advisory; the engine
  drops them, so the only way to learn what an advisory is, is a click per id to osv.dev.
- "Fixed in" is the maximum `fixed` event over **every** `affected[]` entry of every
  advisory of the package — including entries of *other* packages (`stdlib` 1.27.2 for an
  `x/net` finding) and other major lines (`5.0.0-rc.2` for vitest 3.2.7, `5.1.6` for
  nanoid 3.3.16). The real fixes are 0.60.0, 4.1.11 and 3.3.18.
- The Go database publishes no CVSS score; osv-scanner reports an empty `max_severity`,
  the report renders `LOW 0.0`, sorts the card to the bottom and never counts it.
- The button on a muted row that a new advisory pierced reads `re-ack`, which the
  maintainer did not recognise.

Verified against the raw scanner output on copies of the maintainer's manifests
(`tests/fixtures/advisory-details.json` is that output, trimmed).

## Goals

1. Every package row says in words what its worst advisory is, without a click; expanding
   it lists every advisory of the row with id, CVE aliases, its own severity, its own fix,
   its summary and, on a further click, the full description as plain text.
2. "Fixed in" is the fix of **this** package on **its** version line: `x/net 0.57.0 →
   0.60.0`, `vitest 3.2.7 → 4.1.11`, `nanoid 3.3.16 → 3.3.18`. Never a value taken from
   another package or another line. The corrected value flows everywhere the old one did
   (report rows, `osv-run.json`, `status --json` `fix`).
3. Severity 0 / unknown reads **"no score"**, never `LOW 0.0`, and ranks after HIGH and
   before MED; it is never counted as critical.
4. The pierced-row button is labelled like the ordinary rows; its tooltip says what it
   does; README and tests follow.
5. A saved scan from before this change still renders (`--render`), with no
   descriptions and the fixes it saved; nothing exits 3 because of the new fields.
6. The report keeps its collapsed-card density: a card with 14 packages stays scannable.

## Non-goals (explicitly out of scope)

- Network calls during the daily run (osv.dev lookups for scores or texts).
- Changes to the ack semantics, the notification wording, the folder markers (beyond the
  corrected fix they already carry), the link grammar, the `status --json` contract
  (`sev` stays `0` when unknown, `fix` keeps its meaning and just becomes correct).
- Exposing summaries in `status --json` for the app's dialog — a separate decision later.
- The menu bar app's own `LOW 0.0` (its `severityLabel` / `severityBucket`) — brief §5,
  done from the app's session with the same rule as §3 here.
- Markdown rendering of advisory texts: they are untrusted input and are shown as plain
  text only.

---

## 1. Advisory descriptions

### 1.1 What the scan keeps (state file, `render` block — additive, `render.schema` stays 1)

Every non-probe scan writes, next to `render.packages`:

```json
"advisories": {
  "GO-2026-6603": {
    "summary": "HTTP/2 server memory exhaustion due to Trailer headers in net/http",
    "aliases": ["BIT-golang-2026-78659", "CVE-2026-78659"],
    "details": "When \"Trailer\" headers are sent by a client, …",
    "truncated": false
  }
}
```

- One entry per **distinct advisory id** seen in the scan (ids repeat across projects —
  nanoid appears in eight manifests — so the text is stored once, not once per row).
- `summary` and `aliases` as the scanner gives them (`""` / `[]` when absent).
- `details` is the scanner's text cut to **4 000 characters** at the last whitespace
  before the cap, `truncated: true` when it was cut. Measured on 191 real advisories:
  mean 1.3 KB, median 1 KB, p90 2.6 KB, max 6.7 KB — the cap touches about one in twenty.
- Every record of `render.packages` gains `id_fix`: `{advisory id → fixed version}` for
  the advisories whose fix is known (§2); absent ids have no fix.
- Expected size on the maintainer's data (652 vulnerable packages, ~900 distinct
  advisories): the state file grows from ~0.5 MB to roughly 2 MB. Its readers are
  `osv-ack` (`jq`, reads `.findings` only), the next scan's baseline load and
  `--render` — all well under a second. The acceptance measures it on a real scan and
  requires < 5 MB.
- A state whose `render` block has **no** `advisories` key (a scan by 1.7.0) renders in
  the **legacy layout** (§1.4) with the fixes it saved. Not a refusal: `--render` exits 0.

### 1.2 The row (collapsed card) — the "Advisory" column

The IDs column becomes **Advisory** and holds, per package fragment:

1. the **lead advisory**'s id as a link to osv.dev (bold + underlined when it is new, as
   today). The lead is the fragment's id with the highest per-id severity; ties go to the
   first id in scanner order. (Unscored ids rank as §3 says: after HIGH, before MED.)
2. a **toggle button** carrying the lead's one-line description: `summary`; when empty,
   the first sentence of `details` (up to the first `. `, `.\n` or newline, at most 160
   characters); when both are empty, `no description`. CSS clamps it to one line with an
   ellipsis; the full sentence is in the button's `title`.
3. `+N more` (N = the fragment's ids − 1) when the fragment has several ids — inside the
   button, as a faint suffix, so the same click reveals them.

Clicking the button toggles the fragment's **advisory list row** (§1.3) and flips
`aria-expanded`. Nothing else in the row changes: package, version, severity badge,
badges, "Fixed in" and the action button keep their cells. The list row is closed by
default, so a 14-package card is exactly as tall as today.

### 1.3 The advisory list row (expanded)

Directly after the package row, a second `<tr class="adv" id="a-<fid>" hidden>` whose single
cell spans the table and holds one `<li>` per id of the fragment, in the same order as
the lead rule (severity descending, ties in scanner order):

- the id as an osv.dev link (class `new` when it is new, active section only);
- each `CVE-…` alias as a small `alias` chip (database mirrors such as `BIT-…`,
  `PYSEC-…` are kept in the state but not rendered — noise);
- the id's own severity badge (§3's badge: `CRIT 9.1` … `no score`);
- `NEW` badge when the id is new (active section only);
- the summary (or the first-sentence fallback; `no description` when none);
- `fixed in <version>` when `id_fix` has an entry for the id — so a row whose advisories
  have different fixes shows each one;
- a `<details>` element labelled **details** whose body is the advisory's full text. The
  body is filled by the page's script on first open from a JSON table (§1.5) through
  `textContent` — never parsed as HTML or Markdown. A truncated text ends with
  `… (truncated — full text on osv.dev)`; an id missing from the table (never for a scan
  by this version) shows `(see osv.dev)`.

Applies to the Active and the Acknowledged sections and to the probe report (same
python, same cells). The `-k` DOM-id rule of the acked twin applies to `a-<fid>` as it
does to `f-<fid>`: `a-<fid>-k`.

### 1.4 Legacy layout

When the render block has no `advisories` (a saved scan by 1.7.0), the column stays
**IDs** and shows up to four id links plus `+N`, exactly as 1.7.0 — no toggle, no list
row, no JSON table. The rest of this design (fixes as saved, "no score", ordering, the
renamed button) applies to that report too, since it is presentation only.

### 1.5 The description table in the page

`<script type="application/json" id="advdb">` emitted once before the page's script, a
JSON object `{id: text}` where `text` is the stored `details` with the truncation
suffix already appended. JSON inside a `<script>` element: the serialised string has
every `</` replaced by `<\/` (a text containing `</script>` must not end the element),
and `<!--` by `<\!--`. The page's script reads it with `JSON.parse` once, lazily, on the
first `toggle` of any details element, and sets the `<pre>`'s `textContent`.

### 1.6 Why not …

- Rendering every advisory's full text into every row: the text repeats per occurrence
  (eight nanoid rows); the table keeps the page at roughly +1.3 MB instead of +3.4 MB.
- A tooltip on the id: no keyboard, no mobile, no way to read a paragraph.
- Markdown rendering: untrusted input; osv texts use GitHub-flavoured Markdown that a
  renderer would turn into live HTML. Plain text with preserved line breaks reads fine.

---

## 2. "Fixed in" — the fix for this package on its version line

### 2.1 Per advisory

For one advisory and the scanned package `(name, ecosystem, version)`:

1. **Candidate entries** = the advisory's `affected[]` entries whose `package.name` and
   `package.ecosystem` match the scanned package. Ecosystem: the part before `:`
   compared case-insensitively (`Debian:12` → `Debian`). Name: case-insensitive; for
   PyPI additionally runs of `-`, `_`, `.` collapse to `-` (PEP 503). An entry without a
   `package` never matches. (This is the whole of the `stdlib` fix: its entries are not
   candidates for `golang.org/x/net`.)
2. **Spans** = for each candidate entry, each range of type `SEMVER` or `ECOSYSTEM`
   (`GIT` ranges ignored), the events walked in order: an `introduced` opens a span, the
   next `fixed` or `last_affected` closes it; a range whose first event is not
   `introduced` opens at `0`. Each span is `(introduced, fixed | None,
   last_affected | None)`.
3. **The containing span** is the first span with `introduced ≤ version` and
   (`fixed` is None or `version < fixed`) and (`last_affected` is None or
   `version ≤ last_affected`). Its `fixed` is **the advisory's fix**; a containing span
   with no `fixed` (only `last_affected`, or open-ended) means **no fix** from this
   advisory.
4. **Fallback** when no span contains the version (the version did not parse, or the
   database's ranges do not cover the installed version although the scanner matched
   it, e.g. through `affected[].versions`): the **lowest `fixed` among the candidate
   entries' spans that is greater than the version**; none → no fix. Never from a
   non-candidate entry, so never from another package.
5. Fixes of non-candidate entries are ignored entirely.

### 2.2 Per package

`fix` = the **highest** of the per-advisory fixes (§2.1) under the comparison of §2.3 —
the one upgrade that clears every advisory with a known fix. `""` when no advisory has a
fix. `id_fix` keeps every per-advisory fix (§1.1). The same `fix` flows into the report's
"Fixed in" cell, `render.packages[].fix`, `osv-run.json` `new[].fix` / `active[].fix`
and therefore `status --json` `fix`.

Results on the real cases (`tests/fixtures/advisory-details.json`):

| package | before | after | why |
|---|---|---|---|
| golang.org/x/net 0.57.0 (5 Go advisories) | 1.27.2 | **0.60.0** | the `stdlib` entries are not candidates |
| vitest 3.2.7, @vitest/mocker 3.2.7 | 5.0.0-rc.2 | **4.1.11** | the span `[2.1.0, 4.1.11)` contains 3.2.7; `[5.0.0-beta.1, 5.0.0-rc.2)` does not |
| nanoid 3.3.16 | 5.1.6 | **3.3.18** | `[0, 3.3.18)` contains 3.3.16; `[4.0.0, 5.1.6)` does not |

### 2.3 Version comparison

One comparator for every ecosystem the scanner reports here (npm, Go, PyPI, RubyGems,
crates.io, Packagist, …), good for the forms OSV ranges actually carry (`5.0.0-rc.2`,
`1.27.0-0`, `6.0.0.beta3`, `2.0a1`, `v0.0.0-20230101-abcdef`, `1.0.post1`):

- Strip one leading `v`/`V`; drop a `+build` suffix.
- **Release** = the leading `\d+(\.\d+)*`, as a tuple of ints with trailing zeros
  removed (`1.0` = `1.0.0`). A version without a leading digit does not parse.
- **Tag** = what follows the release, with a leading `-`/`.`/`_` removed:
  - empty → the release itself (rank 1);
  - starts with `post` (PEP 440) → after the release (rank 2);
  - anything else (`rc.2`, `0`, `beta3`, `a1`, `alpha`, `20230101-abcdef`, `dev1`) →
    before the release (rank 0), so `5.0.0-rc.2 < 5.0.0`, `1.27.0-0 < 1.27.0`,
    `6.0.0.beta3 < 6.0.0`, `2.0a1 < 2.0`, and a Go pseudo-version sits before its base.
- Tags of equal rank compare token by token: tokens are the digit and letter runs
  (`rc.2` → `rc`, `2`; `beta3` → `beta`, `3`); a numeric token compares numerically and
  sorts before a letter token (semver); letter tokens compare case-insensitively
  (`alpha < beta < pre < rc`, PEP's `a < b < rc`); a shorter tag that is a prefix of a
  longer one sorts first.
- The key is `(release, rank, tokens)`; two versions compare by key. A version that
  does not parse compares with nothing: no span contains it, and it is skipped by the
  fallback and by the per-package maximum (a parsed fix always wins over an unparsed one).

This replaces `vtuple` (the first four digit groups), which ordered `5.0.0-rc.2` above
`4.1.11` and could not tell a pre-release from its release. Stated limits, accepted: no
epochs (`1:2.0`), no PEP 440 `dev` below `a` (lexical `a < dev`), no RubyGems `~>`
(not an OSV event form).

---

## 3. "No score"

- **Badge.** A severity of 0 or unknown renders `<span class="sev na">no score</span>` —
  grey (`--surface-2` on `--muted`), no number — on package rows, on the project card
  head, and on the per-advisory badges of §1.3. `LOW` is only ever rendered for a score
  in (0, 4).
- **Rank.** Items order by `(rank, score)` descending with rank 5 = CRIT (≥ 9),
  4 = HIGH (≥ 7), **3 = no score**, 2 = MED (≥ 4), 1 = LOW. So an unscored row sits
  after every HIGH and before every MED, inside a card and between cards, in both
  sections. Scores within a rank order as today (ties keep scanner order — stable sort).
- **A card's head** shows the severity of its top row (the row with the highest rank):
  a card whose rows are `no score` and `MED 5.0` is headed `no score` and sorts among
  the unscored; one with `HIGH 7.5` and `no score` is headed `HIGH 7.5`.
- **Counts** are untouched: the critical tile, the `crit` counts, the marker's
  `(N critical)` and the run file's `crit` stay CVSS ≥ 9. The state's `maxsev`, the run
  file's `sev` and `status --json` `sev` stay `0` for unknown — the contract is unchanged.
- **Alias scores.** osv-scanner already computes `groups[].max_severity` across every
  id of a group, aliases included — a Go advisory whose GHSA alias carries a CVSS score
  arrives scored. There is nothing offline left to fall back to; no extra logic.

---

## 4. "mark as known" instead of "re-ack"

- With the app running, the pierced row's link reads **mark as known** (the ordinary
  rows' wording) and its tooltip is: `A new advisory appeared in a package you had muted.
  Mark it as known too (asks for confirmation).` Same href (`ack` or `ack-project`), same
  `copy` button, same command.
- With the app not running, the pierced row's copy button reads **mute** like the
  ordinary rows (its tooltip is the copy button's). The `muted` badge keeps telling the
  row apart in both cases.
- `README.md` (the "re-ack" sentences at the ack section and the worked example),
  the header comment and the code comments of `bin/osv-daily`, and the tests that count
  `>re-ack<` are updated to the new label; `docs/report-links.md` does not name the label.
- No behaviour change: the verbs, the links, the ack semantics are as they were.

---

## 5. Compatibility and what each reader sees

| Reader | Change |
|---|---|
| `--render` on a 1.7.0 state | works, legacy IDs column, old fix values, new badge/order/label |
| `--render` on a new state | full layout |
| `osv-ack` | none (reads `.findings`) |
| `status --json` | `fix` correct, `sev` unchanged |
| run file | `fix` correct; keys unchanged |
| probe report | full layout, no links (as today) |
| `osv-last-scan.json` | `render.advisories` and `render.packages[].id_fix` added; `render.schema` 1 |
| CHANGELOG | Added: descriptions; Fixed: "Fixed in", `LOW 0.0`; Changed: button label |

The 1.7.0 tests that diff the scan path against the `9e5df56` renderer are retired on
purpose: the report changes by design (column, badges, ordering). They are replaced by
checks on the exact cells and on the regression fixture.

## Open to the builder

- The exact CSS for the one-line clamp, the chips and the list row (the plan fixes the
  class names and the markup, not the pixels).
- Whether the lead's description button and the `+N more` suffix share one button
  (the design assumes yes).

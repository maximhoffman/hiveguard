# Report shows strict pause state; pause/resume re-render — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-22
Previous plans (conventions, scaffold): `docs/superpowers/plans/2026-10-14-report-rerender-plan.md`
(`--render`, `osv-ack` refresh), `docs/superpowers/plans/2026-10-09-report-app-actions-plan.md`
(links, `root_agg` gate), `docs/superpowers/plans/2026-10-21-strict-target-aware-plan.md` (format).

This document is the design for implementers. Agents are dispatched straight from it and
must not redesign. Section 1 fixes the behaviour; section 2 is the shared contract every
task must match byte-for-byte (markup, CSS, JS, CLI text, test helpers); section 3 is the
task list in waves with the executor model per task; section 4 the orchestrator's
verification and commit boundaries.

Conventions:

- `HG` = the worktree `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/report-pause-state`,
  branch `worktree-report-pause-state`, based on `main` = `3a73378` (1.9.0). Work format 2:
  built-in Read/Edit with absolute worktree paths, no Serena symbolic edits.
- Parallel tasks in one wave never write the same file. Each task's **Owns** list is
  exhaustive and exclusive. Agents never run git; the orchestrator does.
- bash 3.2 for all bash (no associative arrays, `"${arr[@]+"${arr[@]}"}"`, no `timeout`).
  The report python stays stdlib-only (python 3.14 under brew; nothing version-specific).
- Every test runs in the **isolated scaffold** of the existing tests (`HOME=$(mktemp -d)`
  canonicalised with `pwd -P`, every `HIVEGUARD_*` override, stubs on
  `HIVEGUARD_TOOL_PATH`). Never the real `~/.hiveguard`.
- **Byte-identity rule:** with no pause shown, every report (scan, `--render`, probe) is
  byte-identical to 1.9.0's. The existing `cmp -s` / `diff <(norm …)` checks in
  `tests/report-render.test.sh` (A, C–F, J) and `tests/report-advisories.test.sh` (E, H)
  enforce this — nothing new is emitted unless a badge is shown (§2.1).
- Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

Facts the design relies on (verified in the code at `3a73378`):

- `bin/osv-daily`: `report_python` is one heredoc for scan and `--render`; both call sites
  pass `APP_RUNNING`/`STRICT_ON` (lines ≈285 and ≈1820). `proj_card()` (≈1101) emits the
  pause links iff `links_on and strict_on and root in root_agg`; `root_agg` is complete
  before any card renders (≈857). `links_css` / `links_js` are appended only with links on
  (`.hl{{…}}{links_css}` then `</style>`; `{links_js}` after the main script). The
  renderer never opens the pauses file.
- `bin/strict-mode`: `pause` / `resume` / `resume --all` write `$PAUSES`
  (`HIVEGUARD_PAUSES`, rows `root<TAB>until_epoch`, every write prunes expired rows) and
  never re-render. `bin/osv-ack` has `refresh_report()` (`osv-daily --render`, note on
  stderr on failure, never fatal, silent when `$STATE` is missing) — the pattern to copy.
- `bin/status`: a pause row counts iff `split("\t") | length >= 2`, field 2 matches
  `^[0-9]+$` and `tonumber > now`. The renderer adopts exactly this rule.
- The companion app (`~/Projects/Develop/hiveguard-menubar`, read-only for us) refuses
  unknown link actions (`Links.swift` `unknownAction`), refuses `pause` for an already
  paused root, and has its own unpause menu item (`Rules.swift` `.resume(root:)` →
  `strict resume <root>`). It does not parse `strict pause` stdout.
- All `tests/*.test.sh` export an isolated `HOME`; the default pauses path therefore
  never leaks to the real file even in tests that do not set `HIVEGUARD_PAUSES`.

---

## 1. Design (resolved)

### 1.1 The defect and the fix in one paragraph

A project card strict mode blocks offers "pause strict 1 h / 2 h". After a confirmed
pause the report was not re-rendered and, even if it had been, the renderer did not know
about pauses — so the reloaded page looked unchanged and offered the same buttons; the next
click was refused by the app ("already paused"). Fix: (a) the renderer reads the pauses
file at render time; a card whose root has a running pause shows an orange **strict paused
until HH:MM** badge and a **resume strict** copy button instead of the pause links;
(b) `hiveguard strict pause` / `resume` / `resume --all` re-render the report exactly the
way `hiveguard ack` does; (c) if the pause runs out while the page sits open, a few lines of
JS flip the badge to "strict pause ended" and drop the resume button.

### 1.2 When the pause state is shown

On an **Active**-section project card, iff all of:

- strict mode is on at render time (`STRICT_ON=1`, as for the pause links);
- not a `--probe` report (probe reports stay exactly as today);
- the card's root is a key of `root_agg` (a root strict mode would actually block — the
  same gate as the pause links; a root that is itself a scan target has no marker, so a
  pause for it is meaningless and is not shown);
- the pauses file has a running row for that exact root (§1.4).

**Independent of the app** (`links_on`): a pause is strict-mode state, made from the
terminal as often as from the app, and the badge is information, not an app action. With
the app off the card keeps its "mute project" copy button and gains the badge and the
resume copy button. Acknowledged cards never show it (strict does not block acked roots).

### 1.3 What is shown

- The badge sits in the card head right after the project name block (the slot the
  "whole project" pill uses on acked cards), coloured like the pause links
  (`--high` / `--high-s`, the same palette as `.mutedbadge`), so "pause" is orange
  throughout. Text: `strict paused until WHEN`, where `WHEN` is `HH:MM` when the pause ends
  on the render day (local time) and `YYYY-MM-DD HH:MM` otherwise (the CLI's own long
  format). `data-until` carries the epoch for the JS.
- The pause links are **not emitted** for a paused root. In their slot (between the
  "mark project as known" link and the small "copy") a **resume strict** button appears:
  a plain `.cp` copy button (the existing copy handler), command
  `hiveguard strict resume "<root>"`. With the app off the same button follows
  "mute project".
- **No `hiveguard://resume` link.** The app refuses unknown actions, so such a link would
  be a dead button that pops an error until the app ships support; the app already has an
  unpause in its menu; and `strict resume` needs no confirmation dialog (it restores
  protection). `resume` is recorded in `docs/report-links.md` as a **reserved, additive**
  action (not emitted; app support pending) so a later engine can add it under `v=1`.
- CSS and JS for the badge are emitted **only when at least one badge is shown**
  (`paused_css` / `paused_js`, the `links_css` / `links_js` pattern) — the byte-identity
  rule.

### 1.4 Reading the pauses file

The shell passes the path as `PAUSES` (from `HIVEGUARD_PAUSES`, default
`$HOME/.hiveguard/strict-pauses.tsv`) at **both** `report_python` call sites, so a scan and
`--render` behave the same; `--render` reads the file fresh on every call (that is the
whole point). Python: missing or unreadable file → no pauses; a row counts iff it has ≥2
tab-separated fields, a non-empty field 1, field 2 is `[0-9]+`, and `int(field 2) > now`
(`int(time.time())` at render start); other rows are ignored. The file is never written by the renderer.
Later rows for the same root win (the CLI never writes duplicates).

### 1.5 Expiry while the page is open

A pause is time-based; the renderer filters rows already expired, but a page can sit open
across the end of a pause (or be opened a day later). `paused_js`: on load, every 30 s, and
when the tab becomes visible again, each badge whose `data-until` has passed is flipped:
text `strict pause ended`, class `ended` (muted colours), a title telling the user to
reload for the current buttons; the `resume strict` button in the same card head is
removed. Nothing else changes client-side — the pause links are not rebuilt in JS (that
would duplicate the server gate); a reload (or the next `--render`) shows them. Plain
`setInterval`, no `setTimeout` to the exact instant (a `--for 30d` pause overflows the
32-bit timer and would fire at once).

### 1.6 `strict pause` / `resume` re-render

`bin/strict-mode` gains `refresh_report()` copied from `osv-ack` (same shape, same
failure handling): silent when `$STATE` (`HIVEGUARD_STATE`, default
`$HOME/.hiveguard/osv-last-scan.json`) does not exist — pausing before any scan prints
exactly what it prints today; otherwise runs `"$BINDIR/osv-daily" --render` and prints the
one-line confirmation on stdout, or the refusal reason on stderr (`rc 3` "predates", `rc 4`
"scan in progress", any other failure) — never failing the pause/resume itself. Called
after `pause` (always), after `resume <path>` **only when a pause was lifted** (nothing
changed otherwise), and after `resume --all` (always). The CLI's exit codes and every
existing output line are unchanged; the confirmation is always the **last** line.
`strict on` / `off` do not re-render (unchanged; a follow-up as before).

### 1.7 Honest scope

The report is current at render time plus the JS expiry flip. A pause made in a terminal
while the page is open is reflected after the re-render it triggers — the user still has
to reload (the reload-on-return mechanism fires only after a link click). The report
cannot poll a `file:` URL. A pause for a root with no card (clean project, acked project,
scan-target root) is recorded by the CLI but has nowhere to show in the report; `hiveguard
strict status` and the app menu list it.

---

## 2. Shared contracts (every task must match these exactly)

Notation: `ROOT` = the realpath'd project root (the `root` of the record / `root_agg`
key); `ROOTQ` = `shlex.quote(ROOT)`; `ROOTH` = `html.escape(ROOTQ)` (quote=True, the
default — the same escaping `cp_btn` applies to its command); `UNTIL` = the until-epoch
(int); `WHEN` = §1.3 format; `SRC`, `ENC` as in `tests/report-actions.test.sh`.

### 2.1 Report markup, CSS, JS (`bin/osv-daily`, `report_python`)

Shell (both call sites, scan ≈1820 and render ≈285, plus the variable block ≈206):

```bash
PAUSES="${HIVEGUARD_PAUSES:-$HOME/.hiveguard/strict-pauses.tsv}"   # next to CONFIG=
…  PAUSES="$PAUSES" … report_python                                   # both invocations
```

Python, right after `strict_on = …` (≈417):

```python
# Running strict pauses (strict-pauses.tsv: root<TAB>until_epoch) — the card of a
# paused root shows the pause instead of offering one. Same row rule as `status`:
# ≥2 fields, an all-digit until, still in the future; anything else is ignored.
# Read fresh on every render, never written here.
paused_until = {}
_now = int(time.time())
try:
    with open(os.environ.get("PAUSES", "")) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and re.fullmatch(r"[0-9]+", parts[1]) and int(parts[1]) > _now:
                paused_until[parts[0]] = int(parts[1])
except Exception:
    paused_until = {}

def pause_when(until):
    # HH:MM when the pause ends on the render day (local time), else the CLI's long form
    t = time.localtime(until)
    n = time.localtime(_now)
    return time.strftime("%H:%M", t) if (t.tm_year, t.tm_yday) == (n.tm_year, n.tm_yday) \
        else time.strftime("%Y-%m-%d %H:%M", t)
```

Gate (one expression, used by `proj_card` and for the CSS/JS flags), evaluated after
`root_agg` is complete:

```python
def shown_pause(pr):   # UNTIL or None — Active cards only (callers pass active cards)
    r = pr["root"]
    if strict_on and not probe and r in root_agg and r in paused_until:
        return paused_until[r]
    return None
any_paused = any(shown_pause(pr) is not None for pr in active)
```

`proj_card(pr, muted)`, `muted == False` branch, `until = shown_pause(pr)`:

- Badge (`pbadge`; `''` when `until is None`), emitted in the summary **directly after
  `{whole}`** (the f-string becomes `…{whole}{pbadge}<span class="cnt">…`; for an active
  card `whole` is `''`):

  ```
  <span class="pausedbadge" data-until="UNTIL" title="Strict mode is paused for this project until WHEN. It lifts on its own then, or earlier with “resume strict”.">strict paused until WHEN</span>
  ```

- Resume button (`rbtn`; `''` when `until is None`):

  ```
  <button class="cp res" type="button" data-cmd="hiveguard strict resume ROOTH" title="Copy the command that lifts the pause now, then paste it in your terminal">resume strict</button>
  ```

- Head buttons:
  - `links_on`: `<span class="actg">{ack-project link}{PAUSE}{cp_alt(ack cmd)}</span>`
    where `PAUSE` = the two pause links exactly as today when `until is None` and
    `strict_on and root in root_agg`; = `rbtn` when `until is not None`; = `''` otherwise.
  - app off: `cp_btn("hiveguard ack " + shlex.quote(src), "mute project") + rbtn`.
- Acked cards (`muted == True`): unchanged.

CSS (`paused_css`, `""` unless `any_paused`; appended right after `{links_css}` so the
`<style>` tail reads `.hl{{…}}{links_css}{paused_css}\n</style>`):

```
\n.pausedbadge{font-family:var(--mono);font-size:10px;font-weight:600;padding:1px 6px;border-radius:5px;white-space:nowrap;background:var(--high-s);color:var(--high);letter-spacing:.02em}
\n.pausedbadge.ended{background:var(--surface-2);color:var(--muted)}
```

JS (`paused_js`, `""` unless `any_paused`; appended right after `{links_js}` at the end
of `page`; a raw string like `links_js`, so no doubled braces):

```
<script>
(function(){
  // a pause is time-based: when it runs out while this page sits open, say so and
  // drop the resume button (the pause links come back with the next reload/render)
  function tick(){
    var now=Date.now()/1000;
    [].forEach.call(document.querySelectorAll('.pausedbadge[data-until]'), function(b){
      if(+b.getAttribute('data-until')>now) return;
      b.textContent='strict pause ended'; b.classList.add('ended'); b.removeAttribute('data-until');
      b.title='The pause ran out while this page was open. Reload the report for the current buttons.';
      var s=b.closest('summary'), r=s&&s.querySelector('button.res'); if(r) r.parentNode.removeChild(r);
    });
  }
  tick(); setInterval(tick, 30000);
  document.addEventListener('visibilitychange', function(){ if(!document.hidden) tick(); });
})();
</script>
```

Header comment of `bin/osv-daily` (what `--help` prints). In the "Report action buttons"
paragraph, after the sentence ending `… "pause strict 1 h / 2 h" (strict pause).` insert:

```
# A project whose root has a running strict pause (~/.hiveguard/strict-pauses.tsv,
# override: HIVEGUARD_PAUSES; read fresh at every render, expired and malformed rows
# ignored) shows "strict paused until HH:MM" and a "resume strict" copy button
# (hiveguard strict resume <root>) instead of the pause buttons — with or without
# the app; a pause that runs out while the page is open is flagged by the page.
```

In the "Re-rendering" paragraph: `… the config and the app/scan pid files;` →
`… the config, the strict pauses file and the app/scan pid files;` and
`` `hiveguard ack` (mute, --remove, --clear) runs it after every change.`` →
`` `hiveguard ack` (mute, --remove, --clear) and `hiveguard strict pause` / `resume` run it after every change.``

### 2.2 `bin/strict-mode` contract

Header: usage lines for `pause` and `resume` end with `; re-renders the report`
(fit within the existing column); state-file list gains
`#   HIVEGUARD_STATE   → ~/.hiveguard/osv-last-scan.json  # read only: is there a report to refresh?`;
the "A pause is time-based…" paragraph gains the sentence
`Every pause/resume re-renders the daily report (no scan) so an open report shows the pause after a reload.`

Variables: `STATE="${HIVEGUARD_STATE:-$HOME/.hiveguard/osv-last-scan.json}"` next to
`PAUSES=`.

Function (new section `# --- report refresh ---` after the pauses helpers), verbatim:

```bash
# Re-render the daily report from the saved scan so an open report shows the pause
# state after a reload (same mechanism as `hiveguard ack`). Never fails the verb: a
# refresh that cannot happen is a note on stderr; no saved scan at all → silent.
refresh_report() {
  [ -f "$STATE" ] || return 0
  local err reason; err="$(mktemp)"
  if "$BINDIR/osv-daily" --render >/dev/null 2>"$err" </dev/null; then
    echo "  report refreshed (reload it if it is open)"
  else
    reason="$(tail -n1 "$err" | sed 's/^osv-daily: //')"
    [ -n "$reason" ] || reason="osv-daily --render failed"
    echo "  (report not refreshed: $reason)" >&2
  fi
  rm -f "$err"
  return 0
}
```

Calls: `pause)` — last statement of the case (after the "not currently flagged" note);
`resume --all` — after `echo "✔ All pauses lifted."`, before its `exit 0`;
`resume)` — inside `if [ "$lifted" = 1 ]; then echo "✔ Pause lifted for $root."; refresh_report; …`
(not on "No pause active"). Exit codes unchanged (0 in all three).

Resulting stdout, state present and renderable (`R` = `  report refreshed (reload it if it is open)`):

| command | stdout |
|---|---|
| `strict pause ROOT --for 1h` (flagged) | headline · `  lift early: …` · `R` |
| `strict pause ROOT` (not flagged) | headline · lift early · `  (note: … recorded anyway)` · `R` |
| `strict resume ROOT` (lifted) | `✔ Pause lifted for ROOT.` · `R` |
| `strict resume ROOT` (nothing) | `No pause active for ROOT.` (no render) |
| `strict resume --all` | `✔ All pauses lifted.` · `R` |

Failure notes (stderr, rc still 0): `  (report not refreshed: a scan is in progress (pid N); it writes a fresh report itself)`,
`  (report not refreshed: the saved scan predates report re-rendering — run: hiveguard daily)`.
No `$STATE` file → stdout exactly as 1.9.0, nothing on stderr.

### 2.3 Test helpers (add to `tests/report-actions.test.sh` and `tests/report-render.test.sh`)

```bash
PAUSES="$HIVEGUARD_PAUSES"
pause_row()   { printf '%s\t%s\n' "$1" "$2" >> "$PAUSES"; }        # root until_epoch (append)
when_of()     { if [ "$(date -r "$1" +%Y-%m-%d)" = "$(date +%Y-%m-%d)" ]; then date -r "$1" '+%H:%M'; else date -r "$1" '+%Y-%m-%d %H:%M'; fi; }
badge_of()    { printf '<span class="pausedbadge" data-until="%s" title="Strict mode is paused for this project until %s. It lifts on its own then, or earlier with “resume strict”.">strict paused until %s</span>' "$1" "$(when_of "$1")" "$(when_of "$1")"; }
RES_BTN="<button class=\"cp res\" type=\"button\" data-cmd=\"hiveguard strict resume $T/proj/app\" title=\"Copy the command that lifts the pause now, then paste it in your terminal\">resume strict</button>"
```

(`$T/proj/app` contains no shell-special characters, so `shlex.quote` leaves it bare and
`html.escape` changes nothing — `RES_BTN` is exact.) `render()` and `norm()` exist in
`report-render.test.sh`; `report-actions.test.sh` gets
`render() { "$HG/bin/osv-daily" --render >/dev/null 2>&1 </dev/null; }`. Pauses in these
tests are written with `pause_row` (never the real CLI, except in render §L which tests
the CLI on purpose); `reset_scan` already removes `$HIVEGUARD_PAUSES`.

---

## 3. Tasks

### Wave 1 (parallel; no shared files)

#### T1 — renderer: read pauses, badge + resume button, CSS/JS, header — model: **opus**

Owns: `bin/osv-daily` (only).

Do:

1. §2.1 shell: `PAUSES=` variable; pass `PAUSES="$PAUSES"` at both `report_python` call
   sites (scan and `render_report`).
2. §2.1 python: `paused_until`, `pause_when`, `shown_pause`, `any_paused`; `proj_card`
   changes (`pbadge` slot after `{whole}`, `rbtn` in place of the pause links, app-off
   form); `paused_css` after `{links_css}`; `paused_js` after `{links_js}`. Markup, CSS
   and JS byte-for-byte as §2.1.
3. Header comment §2.1 (two paragraphs).
4. Nothing else changes: with no badge shown every emitted byte is as before (no new
   whitespace, no reordered attributes). The renderer never writes the pauses file.
   `bash -n bin/osv-daily` clean; `python3 -c 'import ast'` is not applicable (heredoc) —
   run a render in the isolated scaffold instead.

Acceptance (orchestrator runs; T2 provides the tests):

```bash
cd "$HG" && bash tests/run.sh report          # report-actions, report-render, report-advisories, report-open all PASS
grep -c 'PAUSES="\$PAUSES"' bin/osv-daily      # 2 (both call sites)
grep -c 'class="pausedbadge"' bin/osv-daily    # 1
"$HG/bin/osv-daily" --help | grep -c 'strict paused until'   # 1
```

#### T2 — renderer tests — model: **opus**

Owns: `tests/report-actions.test.sh`, `tests/report-render.test.sh` (only).

Add the helpers of §2.3 to both files. `A` = `$T/proj/app`, `NOW=$(date +%s)`.

`tests/report-actions.test.sh` — new section **3b. a paused root** after section 3
(keep `strict_on; links_on`; start from `reset_scan; scan run2`; copy the report to
`$T/strict.html` before any pause row — it is the strict-on, no-pause baseline; use
`render` for every state change so `cmp` works, the stamp being kept):

- `pause_row A $((NOW+3600)); render` → `count "$(badge_of $((NOW+3600)))"` = 1;
  `count 'hiveguard://pause'` = 0; `count 'class="act-link'` = 3; `count "$RES_BTN"` = 1;
  resume button sits in the pause slot:
  `count "mark project as known</a>${RES_BTN}<button class=\"cp cp-alt\""` = 1;
  badge sits after the name block: `count "</span></span><span class=\"pausedbadge\""` = 1;
  CSS once: `count '\.pausedbadge{'` = 1, `count '\.pausedbadge\.ended{'` = 1;
  JS once: `count "b.textContent='strict pause ended'"` = 1, `count 'setInterval(tick, 30000)'` = 1;
  the pause CSS is the last rule of the style block:
  `grep -A1 '^\.pausedbadge\.ended{' "$REPORT" | grep -c '^</style>$'` = 1;
  the acked section / pierced rows untouched: `count 'class="mutedbadge"'` = 0 here.
- long form: `: > "$PAUSES"; pause_row A $((NOW+3*86400)); render` →
  `count "$(badge_of $((NOW+3*86400)))"` = 1 (its `WHEN` is `YYYY-MM-DD HH:MM`).
- expired row: `: > "$PAUSES"; pause_row A $((NOW-5)); render; cmp -s "$T/strict.html" "$REPORT"` → 0.
- malformed rows, each alone then all together: `A` with no tab, `A<TAB>abc`,
  `A<TAB>` (empty until), `<TAB>$((NOW+3600))` (empty root), a blank line, `A<TAB>12.5`
  → every render `cmp` equal to `$T/strict.html`; `count 'pausedbadge'` = 0.
- missing file: `rm -f "$PAUSES"; render` → `cmp` equal.
- another root paused: `pause_row "$T/elsewhere" $((NOW+3600)); render` → `cmp` equal.
- strict off + running pause: `strict_off; : > "$PAUSES"; render; cp "$REPORT" "$T/off.html"`
  (same state → `cmp` is valid); `pause_row A $((NOW+3600)); render` →
  `count 'pausedbadge'` = 0, `count 'hiveguard://pause'` = 0, `cmp -s "$T/off.html" "$REPORT"` = 0.
- app off + strict on + pause: `links_off; strict_on; : > "$PAUSES"; render; cp "$REPORT" "$T/appoff.html"`;
  `pause_row A $((NOW+3600)); render` → `count 'pausedbadge'` = 1, `count 'act-link'` = 0,
  `count 'class="cp"'` = 3 (mute ×2, mute project — the resume button is `class="cp res"`),
  `count 'class="cp res"'` = 1, `count "mute project</button>${RES_BTN}"` = 1;
  then `: > "$PAUSES"; render` → `cmp -s "$T/appoff.html" "$REPORT"` = 0.
  Restore `links_on; strict_off`.
- never cross-scan `cmp`: every baseline is taken from the same saved state as the
  render it is compared with (a scan rewrites the stamp; `render` keeps it).
- probe: `links_on; strict_on; pause_row A $((NOW+3600))`;
  `STUB_JSON=run2 osv-daily --probe A` → probe report `count 'pausedbadge' probe.html` = 0.
- acked root: `reset_scan; scan run1; hiveguard ack "$SRC"; pause_row A $((NOW+3600)); render`
  → `count 'pausedbadge'` = 0 (clean body, acked card unchanged).
- the scan path shows it too: `reset_scan; strict_on; links_on; pause_row A $((NOW+3600)); scan run2`
  → `count 'pausedbadge'` = 1, `count 'hiveguard://pause'` = 0.
- pauses file never written: `md5 -q "$PAUSES"` before/after a render equal; also in
  section 7 add `check "pauses file untouched by a scan"` the same way.
- `--help`: `count 'strict paused until' <(osv-daily --help)`-style check = 1.

`tests/report-render.test.sh` — new sections:

- **L. pauses are read at render time** (after K; `links_on; strict_on; reset_scan;
  scan run1; scan run2; cp "$REPORT" "$T/strict.html"; S0="$(scan_sig)"; touch -t 202601010000 "$REPORT"`):
  `pause_row A $((NOW+3600)); render` → rc 0, `count "$(badge_of …)"` = 1,
  `count 'hiveguard://pause'` = 0, mtime kept `202601010000`, `scan_sig` = `S0`,
  log tail line matches `] render projects=1 …`; `: > "$PAUSES"; render` →
  `cmp -s "$T/strict.html" "$REPORT"` = 0 (back to the exact bytes);
  a scan with the pause row then a render: `pause_row A $((NOW+3600)); scan run2; cp … $T/scan-p.html; render; cmp` = 0
  (scan and render agree with a pause too).
- **M. `strict pause` / `resume` refresh by themselves** (mirrors J; `SM="$HG/bin/strict-mode"`;
  state from the L scans; `rm -f "$PAUSES"; render; cp "$REPORT" "$T/strict.html"` is the
  no-pause baseline of this state; `S0="$(scan_sig)"`; `touch -t 202601010000 "$REPORT"`;
  `L0` = log line count; `rm -f "$T_LOG_NOTIFY"`):
  - `OUT="$("$SM" pause A --for 1h </dev/null)"` → rc 0; last line
    `  report refreshed (reload it if it is open)`; `count 'pausedbadge'` = 1;
    `count 'hiveguard://pause'` = 0; `count '>resume strict</button>'` = 1; mtime kept;
    `scan_sig` = `S0`; no notification; one pause row in `$PAUSES`;
    the badge's `WHEN` equals `when_of "$(cut -f2 "$PAUSES")"`.
  - `OUT="$("$SM" resume A </dev/null)"` → `✔ Pause lifted for A.` then the `R` line
    (exactly 2 lines); `cmp -s "$T/strict.html" "$REPORT"` = 0.
  - `"$SM" resume A` again → `No pause active for A.` only (1 line); log line count
    unchanged by this call.
  - `"$SM" pause A --for 2h >/dev/null; OUT="$("$SM" resume --all </dev/null)"` →
    `✔ All pauses lifted.` then `R`; `cmp` baseline = 0.
  - render log lines added by M so far: 4 (`pause`, `resume`, `pause`, `resume --all`).
  - scan running: `printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; OUT="$("$SM" pause A 2>&1 >/dev/null </dev/null)"; RC=$?; rm -f …`
    → rc 0; `OUT` = `  (report not refreshed: a scan is in progress (pid $$); it writes a fresh report itself)`;
    the pause is recorded (`wc -l < "$PAUSES"` = 1); report bytes unchanged (md5 before/after).
    `"$SM" resume --all >/dev/null`.
  - predates: `jq 'del(.render)' state.bak > "$HIVEGUARD_STATE"`; `"$SM" pause A` stderr =
    `  (report not refreshed: the saved scan predates report re-rendering — run: hiveguard daily)`,
    rc 0, pause recorded; restore the state; `"$SM" resume --all >/dev/null`.
  - no state: `rm -f "$HIVEGUARD_STATE"; OUT="$("$SM" pause A --for 1h 2>&1 </dev/null)"` →
    rc 0, exactly 2 lines (headline, lift early), no `refreshed`, no `not refreshed`;
    `"$SM" resume A 2>&1` → exactly `✔ Pause lifted for A.`; restore the state.
  - the acked-markers side effect of a render is unchanged by a pause:
    `cat "$HIVEGUARD_MARKERS"` after a `pause` equals its value before.

Acceptance: `bash tests/run.sh report` passes against T1 + T3. The orchestrator proves
the checks bite: after C2, `git show main:bin/osv-daily > bin/osv-daily` → the new
sections fail and the old ones pass; `git checkout -- bin/osv-daily`; likewise
`git show main:bin/strict-mode > bin/strict-mode` → section M fails.

#### T3 — `strict pause` / `resume` re-render; CLI tests — model: **sonnet**

Owns: `bin/strict-mode`, `tests/strict-cli.test.sh` (only).

Do: §2.2 exactly (header, `STATE=`, `refresh_report`, the three call sites). Nothing else
in the file changes; `bash -n bin/strict-mode` clean.

`tests/strict-cli.test.sh` additions (no scan is ever run here; `HIVEGUARD_STATE` is
already exported and absent):

- In the existing pause/resume sections nothing changes (no state file → silent). Add,
  right after `resume --all: empties the file`:
  - `check "pause: no saved scan → no refresh line, 2 lines"`: `out="$("$SM" pause "$T/proj/app" --for 1h 2>&1)"`
    → `printf '%s\n' "$out" | wc -l` = 2 and `grep -c refresh` = 0; `"$SM" resume --all >/dev/null`.
  - predates: `printf '{"schema":1}\n' > "$HIVEGUARD_STATE"`;
    `err="$("$SM" pause "$T/proj/app" --for 1h 2>&1 >/dev/null)"; rc=$?` → rc 0 and
    `err` = `  (report not refreshed: the saved scan predates report re-rendering — run: hiveguard daily)`;
    stdout still has the headline and `lift early` lines (2 lines); the pause row exists.
  - `err="$("$SM" resume "$T/proj/app" 2>&1 >/dev/null)"` → the same note; stdout
    `✔ Pause lifted for $T/proj/app.` first line.
  - `"$SM" resume "$T/proj/app" 2>&1` (nothing to lift) → exactly `No pause active for $T/proj/app.`
    (no note: no render attempted).
  - `err="$("$SM" resume --all 2>&1 >/dev/null)"` → the note; stdout `✔ All pauses lifted.`.
  - scan in progress: `printf '%s' "$$" > "$HOME/.hiveguard/osv-daily.pid"`; `pause` →
    stderr `  (report not refreshed: a scan is in progress (pid $$); it writes a fresh report itself)`,
    rc 0; `rm -f` the pid; `rm -f "$HIVEGUARD_STATE"`; `"$SM" resume --all >/dev/null`.
  - `--help` mentions `re-renders the report` (`grep -c` ≥ 1).

Acceptance: `bash tests/run.sh strict-cli` passes; `bash tests/run.sh report` section M
(T2) passes against this file.

#### T4 — docs: report-links, README, CHANGELOG — model: **sonnet**

Owns: `docs/report-links.md`, `README.md`, `CHANGELOG.md`.

`docs/report-links.md`:

1. "When links are emitted", the `pause` bullet →
   `- `pause` links only when strict mode is on, the project root is one strict would actually block, **and no pause is running for that root**. A paused root shows "strict paused until HH:MM" and a "resume strict" copy button (`hiveguard strict resume <root>`) instead — the engine re-renders on every `strict pause` / `resume`.`
2. Grammar: after the table add
   `Reserved (additive, not emitted today, no app support yet): `resume` with `root=<project root>` → `hiveguard strict resume <root>`. A consumer that does not know it refuses it, per the versioning rule.`
3. "What the app does with a link": replace the last bullet's final sentence
   `` `pause` leaves the report unchanged.`` with a new bullet:
   `- After a confirmed `pause` the engine re-renders the report too (`hiveguard strict pause` runs `daily --render`): the project card shows "strict paused until HH:MM" and a "resume strict" copy button instead of the pause buttons; reload the page (it reloads itself when you come back from the dialog). Lifting the pause from the app's menu (`strict resume`) re-renders as well.`
4. History table: add `| 1 | 2026-10 | additive: no `pause` link for a paused root (badge + resume copy button instead); `resume` reserved |`.

`README.md`:

1. Report section (≈ line 416–421, "**With the companion app running**…"): after
   `*pause strict 1 h* / *2 h*.` add: `While a pause runs, the card says *strict paused
   until HH:MM* and offers *resume strict* (copies `hiveguard strict resume …`) instead;
   the badge flips to "strict pause ended" if the page outlives the pause.`
2. Same section, the sentence `Every `hiveguard ack` change (mute, `--remove`,
   `--clear`) re-renders the report …` → add `; so do `hiveguard strict pause` and
   `resume`` before ` — reload the report`.
3. Strict section verb block (≈ 491–495): the `pause` and `resume` comment columns get
   `(re-renders the report)` appended where it fits; add a sentence after the block:
   `A pause or resume also refreshes the daily report, so a reloaded report shows the
   paused project as paused instead of offering the pause again.`

`CHANGELOG.md`, under `## [Unreleased]`:

```
### Fixed
- **The report now shows a running strict pause.** Clicking *pause strict* used to leave
  the project card exactly as it was — the report never read the pauses file and
  `hiveguard strict pause` never re-rendered — so the reloaded page offered the same
  buttons and the next click was refused as "already paused". A paused project's card now
  carries an orange *strict paused until HH:MM* badge and a *resume strict* copy button
  (`hiveguard strict resume "<root>"`) in place of the pause buttons, with or without the
  menu bar app; if the pause runs out while the page is open the badge turns into
  *strict pause ended* and the resume button goes.

### Changed
- `hiveguard strict pause`, `resume` and `resume --all` re-render the daily report from
  the last scan's saved results (no scan), the way `hiveguard ack` does; a refresh that
  cannot happen (scan in progress, a scan older than re-rendering) is a note, never a
  failure, and before any scan nothing is printed. `docs/report-links.md`: no `pause` link
  is emitted for a paused root; a `resume` action is reserved (not emitted, app support
  pending).
```

Acceptance:

```bash
cd "$HG" && grep -c 'and no pause is running for that root' docs/report-links.md   # 1
grep -c 'leaves the report unchanged' docs/report-links.md                        # 0
grep -c 'Reserved (additive' docs/report-links.md                                 # 1
grep -c 'strict paused until HH:MM' README.md                                     # ≥1
grep -c 'The report now shows a running strict pause' CHANGELOG.md                # 1
```

### Wave 2 (orchestrator)

`bash tests/run.sh` (every file). On a mismatch between T1/T3 and T2 the contract (§2)
wins over both. Then §4.

---

## 4. Verification and commits

Independent verification before the feature commit (not the agents' word):

```bash
cd "$HG"
bash -n bin/osv-daily bin/strict-mode tests/report-actions.test.sh tests/report-render.test.sh tests/strict-cli.test.sh
bash tests/run.sh                                   # every file PASS
# byte-identity evidence: report-render A/J and report-advisories E/H `cmp` checks (scan vs
# render, no pause) still pass, plus the new 3b / L / M baselines (pause row removed → cmp 0)
git diff main --stat                                # only the files the tasks own
```

Manual probe, isolated (`HOME=$(mktemp -d)`, every `HIVEGUARD_*` override, osv-scanner
stub + `run2.json` fixture from the tests, `strict=1`, app pid = `$$`):

| step | expected |
|---|---|
| scan, then `strict pause "$T/proj/app" --for 1h` | stdout ends `  report refreshed (reload it if it is open)`; report has 1 `pausedbadge`, 0 `hiveguard://pause`, 1 `resume strict` |
| `strict resume "$T/proj/app"` | `✔ Pause lifted …` + refreshed line; report byte-identical to the pre-pause one (`cmp`) |
| `rm` state, `strict pause …` | exactly today's 2 lines, empty stderr, rc 0 |
| pause row `until=now+40`, render, serve `python3 -m http.server` in `$HOME/.hiveguard`, open in a browser | badge orange in light and dark (`prefers-color-scheme`); after ~40–70 s the badge reads "strict pause ended" (muted) and the resume button is gone; reload shows the pause links again |

Screenshot (optional, for the maintainer): same served page, Playwright/`claude-in-chrome`
at 1100 px width, sed the temp paths to `~/…` first (CLAUDE.md), light + dark.

Also run `bash tests/strict-integration.test.sh` once (network, ~3 min): step 3's
`strict pause` now re-renders against the real stubbed state — it must still pass.

| Commit | Contents | Gate |
|---|---|---|
| C1 `docs(report): pause state in the report — design and plan` | this plan | — |
| C2 `feat(report): show a running strict pause on the project card; strict pause/resume re-render the report` | T1, T2, T3 | `bash tests/run.sh` all pass; §4 probe; bite-check of §T2 |
| C3 `docs(report): README, report-links and CHANGELOG for the pause badge` | T4 | §T4 acceptance greps |

Out of scope (follow-ups, do not implement): a `hiveguard://resume` link once the app
implements the action (grammar row reserved); re-render after `strict on` / `off`; a
pause badge for roots with no card (clean/acked/scan-target roots); client-side rebuild
of the pause links on expiry; a lock around concurrent renders.

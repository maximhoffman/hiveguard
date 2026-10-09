# Report → app actions — design addendum

Status: product decisions approved (maintainer, 2026-10-09); technical design resolved;
tasks in `docs/superpowers/plans/2026-10-09-report-app-actions-plan.md`
Date: 2026-10-09
Extends: `2026-10-07-menubar-app-design.md` (referred to below as "base §n"). Section
numbers here are local to this addendum.
Baseline: hiveguard `main` at 1.6.0 + `14a05c1` (jump page for `--open --at`); the app
repo with A0–A6 done (`worktree-menubar-app`).

## Problem

The report's only way to act today is "copy the command, paste it in a terminal": every
active row has a `mute` button, every project card a `mute project` button, a pierced row
a `re-ack` button — all of them copy a `hiveguard ack …` line to the clipboard (`cp_btn`
in `bin/osv-daily`). There is no strict-pause control in the report at all. With the
menu bar app installed the natural flow is: read the report in the browser, click,
confirm in the app, done — no terminal.

The report is static HTML opened from `file://`. The one thing a static page can do
towards a native app is open a URL, so the handoff is a custom URL scheme the app
registers. Any web page can fire such a URL; the design treats every incoming link as
untrusted input.

## Goals

- In the report, three actions become buttons that hand off to the app: **mark a finding
  (package) as known**, **mark a whole project as known**, **pause strict mode for a
  project for 1 h / 2 h**.
- Every link action is confirmed in the app, with the exact scope shown (project,
  package/version, advisory ids or counts), even where the menu would not confirm.
- Every link is validated against hiveguard's *current* state before the dialog appears;
  an unknown or unsafe link is refused with an explanation and nothing runs.
- The report is **byte-identical to today's** when the app is not running at report time;
  when it is, the copy-command stays one click away as a small secondary control.
- No new dependency, no new JavaScript: the buttons are plain anchors; the page works
  without JS exactly as far as it does today.
- The engine keeps owning every mutation (`hiveguard ack`, `hiveguard strict pause`); the
  app still never reads or edits a hiveguard state file.

## Non-goals (explicitly out of scope)

- Links for strict on/off, unmute (`ack --remove`), bulk mute, scan, doctor, open —
  never, not even behind a confirmation.
- Updating the report page after an action (it refreshes at the next scan; the app's menu
  reflects the change immediately).
- Any change to scan semantics, ack semantics, report anchors, the jump page, `--open
  --at`, the notifier handoff, or any existing state-file format beyond the additive keys
  in section 2.
- Signing/notarization (an ad-hoc signed bundle registers a URL scheme fine for a personal
  install).

## Approved product decisions (locked, maintainer 2026-10-09)

1. In the report, three actions become clickable buttons that hand off to the app: mark a
   finding (package) as known, mark a whole project as known, pause strict mode for a
   project for 1 h / 2 h. Nothing else — in particular never strict off/on via a link.
2. Every action arriving by link requires a confirmation dialog in the app, showing exactly
   what will be affected, even where the menu would not confirm. Reason: any web page could
   fire such a link.
3. If the app is running when the report is generated (presence pid file alive — the same
   check `osv-daily` already uses for the notifier handoff), show the buttons and tuck the
   copy-command into a small secondary affordance; if the app is not running, the report
   looks exactly as today.

---

## 1. Link contract (`hiveguard://`, version 1)

Owner: hiveguard (it emits the links; `bin/osv-daily` and the normative file change in the
same commit). Normative description: `docs/report-links.md` (new). The app repo never
redefines it — it links to that file, exactly like `docs/status-json.md`.

### 1.1 Grammar

```
hiveguard://<action>?v=1&<params>
```

| Action (URL host) | Parameters (in this order) | Meaning | Engine verb the app runs |
|---|---|---|---|
| `ack` | `src` = manifest/lockfile path, `pkg` = package name | mark one finding (package) as known | `hiveguard ack <src> <pkg>` |
| `ack-project` | `src` = manifest/lockfile path | mark every finding of that manifest as known | `hiveguard ack <src>` |
| `pause` | `root` = project root (strict's root), `for` ∈ {`1h`, `2h`} | pause strict mode for that project | `hiveguard strict pause <root> --for <for>` |

- `src` is the same string the report's copy buttons put into `hiveguard ack` (the
  manifest path, the key of the ack store). `root` is `finding_root(src)` — the realpath'd
  project root the Finder marker and strict mode use, i.e. the string in `status --json`
  `strict.blocked[].root`. Both are absolute paths.
- `v` is the link-format version, an integer, `1` here. The report always emits it first.
- Parameter values are percent-encoded per RFC 3986 with **no safe characters** beyond the
  unreserved set (`A–Z a–z 0–9 - _ . ~`): python `urllib.parse.quote(value, safe="")`.
  `/` becomes `%2F`, a space `%20`, non-ASCII its UTF-8 bytes; `+` is never emitted and
  never means space. In an HTML attribute the whole href is HTML-escaped (`&` → `&amp;`).
- Decoding (app): `URLComponents(url:resolvingAgainstBaseURL:false)` → `host` (lower-cased)
  is the action, `queryItems` are the percent-decoded parameters. Unknown parameters are
  ignored (additive growth). A parameter given twice is an error.

### 1.2 Versioning and unknown links

- The app declares `supportedLinkVersions = 1...1`. A link with `v` absent is treated as
  version 1 (so a hand-typed link works); `v` present and outside the range → refused
  with "link format N is not supported — app supports 1…1; rebuild the app".
- An action the app does not know → refused with "this link asks for `<action>`, which
  this app does not know; if the report came from a newer hiveguard, rebuild the app".
- A link that does not parse (wrong scheme, no action, duplicate or missing parameter,
  relative path, `for` outside {`1h`,`2h`}) → refused with the specific reason. Nothing
  runs in any refusal.
- A link-format change that is not additive bumps `v`, and `docs/report-links.md` records
  it in a history table. Additive changes (a new action, a new optional parameter) keep
  `v`; an older app refuses what it does not know, by the rules above.

### 1.3 Examples

```
hiveguard://ack?v=1&src=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp%2Fpackage-lock.json&pkg=lodash
hiveguard://ack-project?v=1&src=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp%2Fpackage-lock.json
hiveguard://pause?v=1&root=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp&for=2h
```

---

## 2. Engine changes (hiveguard)

### 2.1 `osv-run.json` — `active[]` (additive, file schema stays 1)

The report shows **every** active finding, not only the new/unseen ones, so the app must be
able to validate a link against the full active set. `osv-daily` adds `active` to the run
file: one entry per active package fragment (exactly the rows of the report's Active
section), same shape as `new`/`unseen` entries — `{src, root, pkg, version, eco, sev, fix,
ids, anchor, project_anchor}` with `ids` = the advisory ids **not** covered by an ack at
scan time (the fragment's uncovered ids), sorted by `sev` desc, `src`, `pkg`. On a failed
run `active` = the previous run's `active` unchanged (the report is kept, so the active
set the user sees is the previous one). Probe runs never write the run file (unchanged).

### 2.2 `hiveguard status --json` — `active[]`, `active_ids` (additive, schema stays 1)

- `active` = the run file's `active` entries with every id classified against the ack
  store **exactly like `attention`** (same jq rule, same `project` label, same sort,
  entries with an empty `ids_open` dropped). An ack made after the scan therefore takes
  effect live: the entry disappears (or shrinks) without a rescan. Entry shape = the
  `attention[]` entry shape (`ids_open`, `ids_acked`, `crit`, anchors …). `[]` when there
  is no run file, or the run file predates this field (a 1.6.0 run file has no `active`).
- `active_ids` = Σ `ids_open` over `active`.
- Compatibility rule (base §2.5 / `docs/status-json.md`): a new key anywhere is additive →
  `schema` stays `1`; the schema history gains a row saying so. The app decodes `active`
  as **optional**: an engine without it yields `nil`, and link validation then refuses with
  "hiveguard is too old for report links" instead of guessing. The app's other behaviour
  is unchanged with either engine.

### 2.3 Report rendering

**Gate.** `osv-daily` computes, right before the report python runs, `APP_RUNNING` (the
existing `app_running()` — presence pid file alive, the notifier-handoff check, moved
above the python block and reused by the notifier) and `STRICT_ON` (`strict=1` in the
config, same `config_get` as `strict-mode`). Links are rendered iff `APP_RUNNING=1` and
the run is not a `--probe` (probe reports are internal to strict mode). Pause links
additionally require `STRICT_ON=1` and a root strict would actually block (the finding's
root is a key of `root_agg`, i.e. not a scan target).

**Where the buttons go** (Active section only; the Acknowledged section is untouched):

| Element | Today | With the app running |
|---|---|---|
| active package row, plain | `mute` copy button | `mark as known` link (`ack`) + small `copy` button with today's command |
| active package row, pierced (muted badge) | `re-ack` copy button (project or package form) | `re-ack` link (`ack-project` or `ack`, same form rule) + small `copy` button |
| active project card head | `mute project` copy button | `mark project as known` link (`ack-project`); when strict is on and the root is blockable: `pause strict 1 h`, `pause strict 2 h` links (`pause`); + small `copy` button with today's `hiveguard ack <src>` |
| acknowledged rows and cards | `unmute` / `unmute all` copy buttons | unchanged |
| toolbar (select + "Copy mute command (N)") | copy | unchanged |

**Exact HTML** (python; the plan has the code):

```html
<span class="actg"><a class="act-link" href="hiveguard://ack?v=1&amp;src=…&amp;pkg=…" title="Mark this finding as known via the HiveGuard app (asks for confirmation)">mark as known</a><button class="cp cp-alt" type="button" data-cmd="hiveguard ack … …" title="Copy the terminal command instead" aria-label="Copy command: hiveguard ack … …">copy</button></span>
```

- The link is a plain anchor: it works without JavaScript, is keyboard-focusable, and its
  own activation behaviour (navigate) means a click inside a `<summary>` does not toggle
  the card. The existing click handler only intercepts `.cp` buttons and `.selp`
  checkboxes, so **no JavaScript changes**; the secondary button keeps class `cp` and so
  keeps today's copy behaviour and "✓ copied" feedback.
- The secondary button has visible text (`copy`), a `title`, and an `aria-label` carrying
  the full command — the fallback is as accessible as today's button.
- Extra CSS (`.actg`, `.act-link`, `.act-link.pause`, `.cp.cp-alt`) and the footer sentence
  ("Buttons act through the HiveGuard menu bar app (it asks before changing anything);
  “copy” gives the terminal command instead.") are emitted **only** when links are on, so
  a report generated with the app not running is byte-identical to today's (the stamp
  aside). The plan's acceptance compares against a report produced by the 14a05c1
  `bin/osv-daily` under the same fixtures.
- Anchors (`p-…`, `f-…`), the hash-jump script, the jump page `osv-open-at.html` and
  `--open --at` are untouched; links carry no fragment and never interact with them.

### 2.4 Unchanged

`osv-ack`, `strict-mode`, `daily-schedule`, `doctor`, `folder-mark`, the zsh hooks, the
notifier handoff, the opened stamp, the scan pid file, the state file, the ack store, the
markers, the pauses file. The `strict pause` verb already canonicalises its path
(`resolve_root`), so the `root` the report emits (already realpath'd) round-trips.

---

## 3. App changes (hiveguard-menubar)

### 3.1 Registering the scheme

- `Resources/Info.plist` gains `CFBundleURLTypes` with `CFBundleURLName
  com.hiveguard.menubar.report-link`, `CFBundleURLSchemes [hiveguard]`, `LSHandlerRank
  Owner`. LaunchServices reads it from the **bundle**, so the raw `swift build` binary
  never handles links (consistent with "UI only from the bundle").
- LaunchServices registration is a side effect of opening a bundle, which makes it
  implicit and path-dependent. `make install` makes it explicit: after copying to
  `~/Applications/HiveGuard.app` it runs `lsregister -f` on the installed bundle and
  `lsregister -u` on `dist/HiveGuard.app` (best effort) so a dev copy opened by `make run`
  does not compete for the scheme; `make uninstall` runs `lsregister -u` before removing
  the bundle, so a dangling registration never points at nothing.
  (`lsregister` lives at `/System/Library/Frameworks/CoreServices.framework/Frameworks/
  LaunchServices.framework/Support/lsregister`.)

### 3.2 Receiving URLs in a window-less `MenuBarExtra` app — decision

**`NSApplicationDelegate.application(_:open:)` on the existing `AppDelegate`** (attached
with `@NSApplicationDelegateAdaptor` in `HiveGuardApp.swift`).

- Not `.onOpenURL`: it is a view modifier that needs a live view in an open window scene;
  a `.menu`-style `MenuBarExtra` has no window, and the known macOS pitfall is exactly that
  `MenuBarExtra` apps never attach the handler. It also cannot be unit-tested.
- Not a raw `NSAppleEventManager` `kAEGetURL` handler as the primary path: SwiftUI's
  lifecycle installs its own `GetURL` handler and forwards to the delegate; replacing it
  works only if ours is installed later than SwiftUI's, which is a timing detail that has
  moved between macOS versions. The delegate method is the documented AppKit hook, is what
  SwiftUI forwards to, and is the forum-confirmed route for SwiftUI apps without a
  `WindowGroup`.
- Fallback, if the real-machine check shows the delegate method is not invoked on this
  macOS/Xcode combination: register the Apple Event handler in
  `applicationWillFinishLaunching` (so it is in place before the launch URL is dispatched).
  That is a task, not an ad-hoc patch (plan section 6).

**Cold launch.** When the app is not running, LaunchServices launches the registered
bundle and delivers the URL after `applicationDidFinishLaunching`. Nothing may be lost or
acted upon before the model has a status, so: the delegate hands every URL to the
controller, which appends it to a queue; the queue is drained only once the launch
sequence (base §4.2: pid → notifications → first refresh started → login item) has
completed, one link at a time; and handling a link **always begins with a status refresh**
(coalesced with any in flight) and validates against that fresh document, never against
a stale `lastGood`.

**Single instance.** LaunchServices routes a URL to the running process with the bundle
id, so the normal case is the warm path. Should a second instance nonetheless be launched,
it exits at the pid-presence check before its run loop starts (base §8) and that link is
dropped; the user clicks again. Accepted: rare, harmless, documented.

### 3.3 Validation (before any dialog; pure, unit-tested)

| Link | Checked against | Refused when (reason shown) |
|---|---|---|
| `ack(src, pkg)` | `status.active` | `active` is `nil` → "hiveguard is too old for report links"; no entry with that `src` and `pkg` → "not an active finding in the last scan — already marked as known, fixed, or the report is older than the last scan. Nothing was changed." |
| `ack-project(src)` | `status.active` | `active` nil → too old; no entry with that `src` → "no active findings in the last scan …" |
| `pause(root, for)` | `status.strict` | `enabled` false → "strict mode is off — nothing to pause"; `root` not in `blocked` → "not blocked by strict mode right now — nothing to pause"; `root` in `paused` → "already paused until HH:MM; unpause it from the menu first" |
| any | the refresh | status unavailable (CLI missing/too old/unreadable) → "cannot check the link against hiveguard: <reason>" |

The `src`/`root` must equal a known value byte for byte; the app never derives a path
from a link, never globs, never canonicalises. Arguments reach `hiveguard` as argv
elements (no shell), and only the three verbs above exist in the mapping. A malformed
link that merely *looks* like one of these is refused by the parser (section 1.2).

### 3.4 Confirmation — always, link-specific builder

A new pure builder produces the dialog for a link (`LinkPlan` = the menu action to run +
the `ConfirmationSpec`); it does not go through base §6's `confirmation(for:status:)`,
whose job is "confirm only when costly" for menu clicks. Texts (first line tells the user
why a dialog appears that the menu would not show):

| Link | Title | Message | Button |
|---|---|---|---|
| `ack` | `Mark <pkg> <version> as known?` | `Requested by a report link.` ⏎ `<project> · <CRIT/HIGH/MED/LOW> <sev> · <n> advisory id(s): <ids_open>` ⏎⏎ `This covers every advisory currently known for <pkg>; a new one still alerts. The report itself updates at the next scan.` | `Mark as known` |
| `ack-project` | `Mark <project> as known?` | `Requested by a report link.` ⏎ `<src>` ⏎ `<p> package(s), <i> advisory id(s), <c> critical.` ⏎⏎ `The report itself updates at the next scan.` | `Mark as known` |
| `pause` | `Pause strict mode for <project>?` | `Requested by a report link.` ⏎ `<blocked summary>` ⏎ `Runs and builds will be allowed for <1 hour / 2 hours>.` | `Pause <1 hour / 2 hours>` |

Counts come from `active` (packages = entries under that `src`, ids = Σ `ids_open`,
critical = entries with `crit`). `<project>` = the entry's `project` label (`active`
first, then `attention`, then the scheduled-folder-relative path, as the menu does).
Dialog mechanics as base §6: `NSAlert`, Cancel is default and Escape, the app activates
so the dialog comes above the browser.

### 3.5 Execution, errors, refresh

- On confirm: the plan's menu action goes through the existing serial action queue
  (`cliArguments` mapping, 30 s timeout). Two new menu actions exist only for links —
  `ackSource(src:pkg:)` → `ack <src> <pkg>`, `ackSourceProject(src:)` → `ack <src>`; the
  pause reuses the menu's `pause(root:duration:)`. The menu never offers the two new
  actions and `confirmation(for:)` returns nil for them (the link path always confirmed).
- Non-zero exit → the existing "<action> failed" alert with the stderr tail; status is
  refreshed either way, so the icon/count update at once (an ack of an unseen finding
  clears red exactly like the menu's *Mark as known*).
- A refusal shows an `NSAlert` titled `Report link ignored` with the reason text and
  runs nothing.
- The report stays as rendered until the next scan; the confirmation text says so.

### 3.6 `HiveGuard --resolve-link <url>` (hidden flag, tests only)

Like `--dump-state`: one status fetch, parse + validate + build the confirmation, print
one JSON line, exit — never runs the action, never shows UI, never touches the pid file:
`{"ok":true,"action":"ack|ack-project|pause","argv":[["ack","<src>","<pkg>"]],"confirm":{"title":"…","message":"…","confirmLabel":"…"}}`
or `{"ok":false,"error":"<reason text>"}`. Exit 0 when ok, 4 when refused, 3 when the
status could not be obtained. This is the end-to-end hook: the app's e2e test extracts a
real link from a report the real engine rendered and checks that it round-trips through
the app's parser and validation against the real `status --json`.

### 3.7 Version mixes

| Engine | App | Result |
|---|---|---|
| new | new | buttons + confirmations as designed |
| new (buttons rendered) | old (no URL type) or app not installed | the browser reports no application for `hiveguard://`; the `copy` button remains → terminal, as today |
| 1.6.0 (no `active`) | new | menu unchanged; the report has no buttons (1.6.0 renders none); a hand-typed `ack` link is refused "too old"; a `pause` link still validates (uses `strict` only) |
| new | new, running from `dist/` only | links reach the running instance (bundle id); if not running, LaunchServices launches whichever copy it registered — `make install` makes the installed copy the registered one |

---

## 4. Edge cases (normative)

| Situation | Behaviour |
|---|---|
| App started after the scan; report has no buttons | copy buttons as today; next scan renders buttons |
| App quit after the scan; report has buttons | clicking launches the installed app (cold path, section 3.2); the dialog appears once the status is read |
| Report is from yesterday; the finding was fixed/acked since | validation against the current status refuses with the "not an active finding … Nothing was changed." text |
| Same link clicked twice (two dialogs?) | links are handled one at a time; the second waits for the first dialog, then is validated afresh — after a confirmed ack it is refused as already known |
| Link for a pierced row (`re-ack`) | same verbs (`ack <src> [pkg]`); validation finds the fragment in `active` (its open ids are the new ones); confirmation shows those ids |
| `pause` link while strict is off | refused ("strict mode is off") — the report never renders pause links in that case, so this is a stale report or a hand-typed link |
| `pause` link for a root already paused | refused ("already paused until HH:MM; unpause from the menu first") — the CLI would silently extend; the menu does not offer it either |
| `pause` for a root with critical packages | confirmed like everything else (the dialog shows the summary line, as the menu's confirmation would) |
| Link with an unknown extra parameter | ignored |
| Link with `v=2`, unknown action, duplicate/missing parameter, relative path, `for=3h` | refused with the specific reason; nothing runs |
| Browser asks "Allow this page to open HiveGuard?" | expected (file: pages, custom scheme); allow — the app's own confirmation still follows |
| Status cannot be read when the link arrives (CLI missing, too old, unreadable) | refused "cannot check the link against hiveguard: <reason>" |
| Second app instance launched for a link | exits before handling (base §8); link dropped; click again |
| `--probe` report | never has buttons |
| App running but the presence pid is stale (crash) | `kill -0` fails → no buttons (same as the notifier handoff) |
| Many active findings (hundreds) | `active[]` adds tens of KB to `status --json`; still well under the 1 s budget (jq), decoded once per refresh |

---

## 5. Security considerations

- Any page can open `hiveguard://…`; therefore: (1) every link confirms, (2) the parser
  accepts only three actions with fixed parameter names and `for ∈ {1h, 2h}`, (3) every
  path must match an existing entry of the current status byte for byte, (4) arguments
  are argv, never a shell string, (5) the mapping contains no `--remove`, no `strict
  on/off`, no `--fix`, (6) refusals and dialogs show the full values so a spoofed link is
  visible as such. The worst a malicious page can achieve is a confirmation dialog for an
  action the user could have taken from the menu anyway.
- The report emits links only while the app's pid file names a live process; a stale pid
  file cannot turn links on.

---

## 6. Testing strategy

Nothing may touch the real `~/.hiveguard`, `~/.zshrc`, the real launchd label, the real
Login Items, LaunchServices registrations or the notification center. The isolated
scaffold of the base plan (section 2.4 there, reproduced in the new plan with additions)
is used verbatim; "app running" is simulated with `printf '%s' "$$" > "$HIVEGUARD_APP_PID"`.

**Engine (bash, `tests/`, bash 3.2):**

- `report-actions.test.sh` (new): app not running → zero `hiveguard://`, `act-link`,
  `cp-alt`; copy buttons as before; byte-identical (stamp aside) to the 14a05c1 renderer's
  output for the same fixtures (orchestrator acceptance; the test itself checks the
  markers). App running → exact hrefs for both rows and the card (percent-encoding checked
  with `jq @uri`, which matches `quote(safe="")` for these paths); no pause links with
  strict off; 1 h and 2 h pause links with strict on, `root` = the realpath'd project root;
  the `copy` buttons carry today's exact commands; pierced row → `re-ack` link; acked
  section unchanged; `--probe` and a dead pid → no links; anchors and hash script intact.
- `osv-run.test.sh` (extended): `active` present with the documented key set, ids are the
  uncovered ids, sorted, drops a package once fully acked, carried on a failed run.
- `status.test.sh` (extended): `active`/`active_ids` present, entry keys, live ack
  classification (package-scoped and open-ended project ack), a run file without `active`
  → `[]`/`0`, no run → `[]`/`0`, top-level key list.
- Existing tests keep passing; `strict-integration.test.sh` is unchanged (no new files).

**App (`swift test`):**

- `LinkTests`: parser matrix (three valid forms; percent-decoding of `/`, space,
  non-ASCII; `+` literal; `v` absent/1/2/non-integer; unknown action; wrong scheme;
  missing/empty/duplicate parameter; relative path; `for` outside the set; unknown
  parameter ignored; host case-insensitive) and validation matrix (every row of 3.3
  against fixtures, including `compat-no-active.json` → too old), confirmation texts
  verbatim, argv mapping of the two new menu actions, `confirmation(for:)` nil for them.
- `ResolveLinkTests`: the `--resolve-link` line for ok / refused / status unavailable
  with a fake `hiveguard` script.
- `StatusDecodingTests`: `active` decodes; absent → `nil`.

**End-to-end (`tests/e2e.test.sh`, app repo, real engine):** the fixture-honesty check
now includes `active` (the seed gains `active` entries; `red-6.json` gains the keys); a
report rendered by the real `osv-daily` with the app "running" yields links that
`--resolve-link` accepts with the expected argv (`ack`, `ack-project`, `pause` after the
real scan wrote the markers), refuses after a real `hiveguard ack` / `strict pause`, and
refuses tampered links; hygiene unchanged.

**Real machine (once, gated, plan section 6):** scheme registered by `make install`; a
hand-typed refusal link shows the alert without running anything; a real report button
(real scan — maintainer's call) opens the dialog, Cancel runs nothing, confirm runs it and
the menu reflects it; cold launch via a link; strict pause via link; rollback via `make
uninstall` unregisters the scheme.

---

## 7. Docs (part of the work)

hiveguard: `docs/report-links.md` (new, normative link contract: grammar, encoding,
version rule, when links are emitted, what the app does); README — the `ack` section
("with the companion app running at scan time, each active row and project card shows
buttons that act through the app; the terminal command stays behind `copy`; pause strict
buttons when strict mode is on"), the companion-app section, the `osv-run.json` row of the
data table; `docs/status-json.md` — field rows for `active`/`active_ids` and a schema
history row ("1 — additive"); `CHANGELOG.md` `[Unreleased]`.

app: README — "Report links (`hiveguard://`)": the scheme, where the grammar lives,
always-confirm, validation, LaunchServices registration by `make install` (and the
`make run` caveat), the minimum hiveguard for links, `--resolve-link`.

---

## 8. Risks and judgment calls

- **Delegate URL delivery under SwiftUI** (section 3.2): the one piece that cannot be
  verified without the installed bundle. Mitigation: the real-machine check runs a
  refusal link first (no side effects); the documented fallback is the Apple Event handler.
- **Two registered copies** (`dist/` and `~/Applications`): `make install` unregisters
  `dist/`; `make run` re-registers it — documented; links while developing may land in
  the dev copy, which is the same code.
- **Browser prompt per click** ("Allow this page to open HiveGuard?"): inherent to custom
  schemes from `file:` pages; it is a second confirmation, not a defect.
- **`active[]` size**: tens of KB for the maintainer's ~200 active packages; measured by the
  existing `< 1 s` status check.
- **Judgment call — already paused → refuse** rather than extend (the CLI would extend,
  the menu does not offer it). Easy to flip later (one validation rule, one text).
- **Judgment call — pierced rows get a `re-ack` link** (same verbs; the product decision
  names "mark a finding as known", and re-ack is that verb on a muted package). Easy to
  drop (one branch in the renderer).
- **Judgment call — pause links only when strict is on at report time** (a pause button on
  a report while strict is off would be noise; the app refuses such a link anyway).

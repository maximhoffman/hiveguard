# Report → app actions — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-09
Spec: `docs/superpowers/specs/2026-10-09-report-app-actions-design.md` (addendum to
`2026-10-07-menubar-app-design.md`; product decisions locked by the maintainer 2026-10-09)
Base plan (conventions, scaffold, Swift API): `docs/superpowers/plans/2026-10-07-menubar-app-plan.md`

This document is the design for implementers. Agents are dispatched straight from it and
must not redesign. Section 1 fixes the remaining technical choices; section 2 is the shared
contract every task must match byte-for-byte (names, link grammar, file formats, Swift
API, the test scaffold and seed, fixtures); section 3 is the task list in waves, split by
repository; section 4 is the orchestrator's verification per wave with commit boundaries;
section 5 the gates; section 6 the real-machine finish that runs only on an explicit go.

Conventions (unchanged from the base plan unless stated):

- Two repositories, two paths:
  - `HG` = the engine **worktree**
    `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/report-app-actions`, branch
    `feat/report-app-actions`, based on `main` = 1.6.0 + `14a05c1`. Work format 2
    (built-in Read/Edit with absolute worktree paths; no Serena symbolic edits). The main
    checkout `/Users/mh/Projects/Develop/hiveguard` stays on `main` (the real launchd agent,
    the `hiveguard` on PATH and the strict hook run from it) until gate G4 merges.
  - `APP` = the app **worktree**
    `/Users/mh/Projects/Develop/hiveguard-menubar/.claude/worktrees/menubar-app`, branch
    `worktree-menubar-app` (A0–A6 committed there). Nothing of the app lives in `HG`;
    nothing of the engine lives in `APP`.
- Parallel tasks in one wave never write the same file; `H*` and `A*` tasks never share a
  file. Each task's **Owns** list is exhaustive and exclusive. Agents never run git; the
  orchestrator does.
- Every test and verification command runs in the **isolated scaffold** of section 2.5
  (fresh `HOME=$(mktemp -d)` canonicalised with `pwd -P`, every `HIVEGUARD_*` override,
  stubs on `HIVEGUARD_TOOL_PATH`). "App running" is simulated by writing `$$` to
  `$HIVEGUARD_APP_PID`. The app binary is only ever run in tests with `--dump-state` or
  `--resolve-link` (no status item, no notification center, no login item, no pid file).
  Never `make install`/`make run`/`lsregister` outside section 6. `doctor` never with
  `--fix`.
- bash 3.2 everywhere (no associative arrays; `"${arr[@]+"${arr[@]}"}"`), no `timeout`,
  BSD `date -r`, `awk`, `sed`, `shasum`, `md5 -q`. The report's rows are rendered on a
  **single line**, so counts use `grep -o … | wc -l`, never `grep -c`.
- `swift` and `make` are strict-intercepted names: `command swift …` / `command make …`
  where the hook loaded partially. In the Bash tool the strict gate may also wrap
  `python3`; the acceptance blocks below avoid python and use `jq` instead.
- Swift toolchain: Xcode 26.3 / Swift 6.2, zero warnings under strict concurrency; all UI
  state on the main actor; `HiveGuardCore` never imports AppKit/SwiftUI/UserNotifications/
  ServiceManagement.
- Commit trailer (both repos): `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## 1. Architecture decisions (resolved)

### 1.1 Link contract is owned by hiveguard, versioned, documented next to the status contract

`docs/report-links.md` (new, task H7) is the normative grammar (spec §1). `bin/osv-daily`
emits it; the app parses it; `supportedLinkVersions = 1...1` in the app. Additive growth
(new action, new optional parameter) keeps `v=1`; the app refuses what it does not know.

### 1.2 Validation data: additive `active[]` in `osv-run.json` and `status --json`, schema stays 1

Spec §2.1–2.2. The app decodes `active` and `active_ids` as **optional** so a 1.6.0 engine
still works for everything except `ack`/`ack-project` links (refused as "too old for
report links"). `tests/osv-run.test.sh` and `tests/status.test.sh` pin exact key lists and
are updated by the tasks that add the keys. The app's fixture-honesty e2e check compares
key paths, so the Swift fixtures and the e2e seed both gain `active` (A7, A10).

### 1.3 Report rendering gate and shape

Spec §2.3. `APP_RUNNING` (existing `app_running()`, moved above the python block, still
used by the notifier) and `STRICT_ON` (`config_get strict 0`, copied from `strict-mode`)
are exported into the python environment. `links_on = APP_RUNNING == "1" and not probe`.
Only the Active section changes; CSS and footer sentence are emitted only when `links_on`.
No JavaScript changes.

### 1.4 URL reception: `application(_:open:)` on the existing `AppDelegate`

Spec §3.2. The delegate is already attached with `@NSApplicationDelegateAdaptor`; the
method hops to the main actor and hands the URLs to `AppController`, which queues them
until `launch()` has finished and then handles them one at a time, each starting with
`await model.refresh()` and validating against `model.status` (fresh), never `lastGood`.
Fallback (only if section 6 step 1 shows the method is not invoked): register
`NSAppleEventManager` `kInternetEventClass/kAEGetURL` in `applicationWillFinishLaunching`
— a new task, not an inline patch.

### 1.5 Two new menu actions for links; the menu never offers them

`MenuAction.ackSource(src:pkg:)` → `["ack", src, pkg]`; `MenuAction.ackSourceProject(src:)`
→ `["ack", src]`; the pause reuses `.pause(root:duration:)`. `confirmation(for:)` returns
`nil` for the two new cases (links are always confirmed by the link builder, spec §3.4);
`AppController.title(of:)` gains their titles.

### 1.6 LaunchServices registration is explicit on install

`make install`: `lsregister -f "$INSTALLED"` then `lsregister -u "$CURDIR/dist/HiveGuard.app"`
(both `|| true`). `make uninstall`: `lsregister -u "$INSTALLED"` before `rm -rf`. `make app`,
`make test`, `make e2e` never call `lsregister`.

### 1.7 `--resolve-link` is the e2e hook

Spec §3.6. Implemented in `HiveGuardCore` (`ResolveLink.swift`, mirrors `DumpState`),
dispatched in `main.swift` before any `NSApplication` exists. Exit 0 ok / 4 refused / 3
status unavailable / 2 usage. Never runs the action.

### 1.8 Decisions worth flagging (made, not deferred)

- A `pause` link for a root that is already paused is **refused** (the CLI would extend
  the pause; the menu does not offer it). One rule, one text — easy to flip.
- Pierced (muted-badge) rows get a `re-ack` **link** with the same verb form as today's
  copy button (`ack <src>` when the mute was project-level, else `ack <src> <pkg>`).
- Pause links render only when `strict=1` at report time and the root is a key of
  `root_agg` (not a scan target) — the roots strict would block.
- The link confirmation does **not** show a clock ("until HH:MM") to keep the pure builder
  clock-free; the "already paused" refusal does show `until HH:mm` (formatted in the UI
  text helper, local time).
- The report is static after an action; every ack confirmation says "The report itself
  updates at the next scan."
- `--resolve-link` and `--dump-state` never write the pid file (A9 keeps the argv dispatch
  before `PidPresence`).
- `Tests/e2e.test.sh` is referenced by the Makefile as `tests/e2e.test.sh` (case-insensitive
  filesystem); left as is.

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 Names

| Thing | Name |
|---|---|
| Engine branch / worktree | `feat/report-app-actions` / `HG` (conventions) |
| App branch / worktree | `worktree-menubar-app` / `APP` (conventions) |
| Link contract document (owner: hiveguard) | `HG/docs/report-links.md` |
| URL scheme | `hiveguard` |
| Link actions (URL host) | `ack`, `ack-project`, `pause` |
| Link parameters | `v`, `src`, `pkg`, `root`, `for` |
| Pause durations in links | `1h`, `2h` (verbatim to `strict pause --for`) |
| Supported link versions (app constant) | `supportedLinkVersions: ClosedRange<Int> = 1...1` |
| Minimum hiveguard for `ack` links (app constant, shown in the refusal) | `minimumHiveguardVersionForLinks = "1.7.0"` (the release that ships `active[]`; update if the number differs) |
| `CFBundleURLTypes` entry | `CFBundleURLName com.hiveguard.menubar.report-link`, `CFBundleURLSchemes [hiveguard]`, `LSHandlerRank Owner` |
| `lsregister` | `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister` |
| Hidden app flag | `--resolve-link <url>` |
| Refusal alert title | `Report link ignored` |
| New engine test | `HG/tests/report-actions.test.sh` |
| New Swift files | `APP/Sources/HiveGuardCore/Links.swift`, `APP/Sources/HiveGuardCore/ResolveLink.swift`, `APP/Tests/HiveGuardCoreTests/LinkTests.swift`, `APP/Tests/HiveGuardCoreTests/ResolveLinkTests.swift` |
| New fixture | `APP/Tests/HiveGuardCoreTests/Fixtures/compat-no-active.json` |
| Python env vars into the report block | `APP_RUNNING` (`1`/`0`), `STRICT_ON` (`1`/`0`) |
| Report CSS classes (new) | `actg`, `act-link`, `act-link pause`, `cp cp-alt` |

### 2.2 Link grammar (normative text for `docs/report-links.md` and for `Links.swift`)

```
hiveguard://<action>?v=1&<params>
  ack          src=<manifest path>  pkg=<package name>       → hiveguard ack <src> <pkg>
  ack-project  src=<manifest path>                           → hiveguard ack <src>
  pause        root=<project root>  for=1h|2h                → hiveguard strict pause <root> --for <for>
```

- Emission (python): `"&".join(k + "=" + urllib.parse.quote(v, safe="") for k, v in params)`
  with `params` an ordered list `[("src", src), ("pkg", pkg)]` / `[("src", src)]` /
  `[("root", root), ("for", d)]`; `href = "hiveguard://" + action + "?v=1&" + q`; in the
  attribute `html.escape(href)`.
- Parsing (Swift, `parseLink(_ url: URL) -> Result<LinkAction, LinkError>`), checks in
  this order:
  1. `URLComponents(url:resolvingAgainstBaseURL:false)` exists and `scheme?.lowercased()
     == "hiveguard"`, else `.badURL("not a hiveguard:// link")`.
  2. `action = (host ?? "").lowercased()`; empty → `.badURL("no action")`.
  3. `queryItems` → `[String: String]`; a name seen twice → `.badURL("duplicate parameter
     <name>")`; a nil value counts as empty.
  4. `v` present: not an integer → `.badURL("v is not an integer")`; integer outside
     `supportedLinkVersions` → `.unsupportedVersion(Int)`. Absent → version 1.
  5. `ack` → `src`, `pkg`; `ack-project` → `src`; `pause` → `root`, `for`; any other
     action → `.unknownAction(action)`.
  6. A required parameter absent or empty → `.missingParameter(name)` (first missing in
     the order above). `src`/`root` not starting with `/` → `.badURL("<name> must be an
     absolute path")`. `for` not in {`1h`,`2h`} → `.badDuration(value)`.
  7. Unknown parameters ignored.

### 2.3 File formats (exact)

- `osv-run.json` keys (sorted): `active, counts, error, finished_epoch, new, ok, rc, roots,
  schema, stamp, started_epoch, target, unseen`. `active[]` entry = `{src, root, pkg,
  version, eco, sev (number), fix (string, "" when none), ids [string] (uncovered ids at
  scan time), anchor, project_anchor}`, sorted by `(-sev, src, pkg)` (the existing
  `order()`), one per active package fragment (`for pr in active: for p in pr["pkgs"]`).
  Failed run: `active` = previous run's `active` (or `[]`), exactly like `unseen`.
- `status --json` (schema 1) top-level keys (sorted): `active active_ids app attention
  attention_ids hiveguard now_epoch report scan schedule schema strict`. `active[]` entry
  keys = the `attention[]` entry keys (`anchor crit eco fix ids_acked ids_open pkg project
  project_anchor root sev src version`). `active = []` and `active_ids = 0` when there is
  no run file, or the run object has no `active` key.
- Report HTML (Active section, `links_on`):
  - package row action cell:
    `<span class="actg"><a class="act-link" href="hiveguard://ack?v=1&amp;src=<enc>&amp;pkg=<enc>" title="Mark this finding as known via the HiveGuard app (asks for confirmation)">mark as known</a><button class="cp cp-alt" type="button" data-cmd="<cmd>" title="Copy the terminal command instead" aria-label="Copy command: <cmd>">copy</button></span>`
    where `<cmd>` is today's command for that row (`hiveguard ack <src> <pkg>` shell-quoted
    as today). Pierced row: label `re-ack`, title `Fold the new advisory into this
    package's mute via the HiveGuard app (asks for confirmation)`, href `ack-project?…src`
    when `reack_project` else `ack?…src…pkg`, `<cmd>` = today's re-ack command.
  - project card head (replaces today's `head_btn`):
    `<span class="actg"><a class="act-link" href="hiveguard://ack-project?v=1&amp;src=<enc>" title="Mark every finding of this project as known via the HiveGuard app (asks for confirmation)">mark project as known</a>[<a class="act-link pause" href="hiveguard://pause?v=1&amp;root=<enc>&amp;for=1h" title="Pause strict mode for this project for 1 hour via the HiveGuard app (asks for confirmation)">pause strict 1 h</a><a class="act-link pause" href="…&amp;for=2h" title="… for 2 hours …">pause strict 2 h</a>]<button class="cp cp-alt" type="button" data-cmd="hiveguard ack <src>" title="Copy the terminal command instead" aria-label="Copy command: hiveguard ack <src>">copy</button></span>`
    — the bracketed pause links only when `strict_on and root in root_agg`.
  - CSS appended to the `<style>` block only when `links_on` (inside the f-string: braces
    doubled):
    ```
    .actg{display:inline-flex;align-items:center;gap:6px;flex:none}
    .act-link{font-family:var(--mono);font-size:11px;color:var(--accent);background:var(--surface);border:1px solid var(--accent);border-radius:6px;padding:3px 8px;text-decoration:none;white-space:nowrap}
    .act-link:hover{background:var(--accent);color:#fff}
    .act-link.pause{color:var(--high);border-color:var(--high)}
    .act-link.pause:hover{background:var(--high);color:#fff}
    .cp.cp-alt{font-size:10px;padding:2px 6px;opacity:.7}
    .cp.cp-alt:hover{opacity:1}
    ```
  - footer, only when `links_on`: the sentence `Mute an old project with the “mute” button
    (→ hiveguard ack).` becomes `Buttons act through the HiveGuard menu bar app (it asks
    before changing anything); “copy” gives the terminal command instead.`
  - everything else byte-identical to 14a05c1 output for the same inputs.
- `--resolve-link` output: one JSON line, keys in this order:
  `{"ok":true,"action":"ack|ack-project|pause","argv":[[…]],"confirm":{"title":"…","message":"…","confirmLabel":"…"}}`
  or `{"ok":false,"error":"<linkErrorText>"}`; exit 0 / 4 / 3 (status unavailable) / 2
  (no url argument; usage on stderr).

### 2.4 Swift API contract (`HiveGuardCore`, additions)

```swift
// Status.swift (A7) — in `Status`:
public let active: [AttentionEntry]?     // nil when the engine predates active[] (absent key)
public let activeIds: Int?               // "active_ids"
// CodingKeys gain: active, activeIds = "active_ids"

// Links.swift (A8)
public let supportedLinkVersions: ClosedRange<Int> = 1...1
public let minimumHiveguardVersionForLinks = "1.7.0"
public enum LinkAction: Equatable, Sendable { case ack(src: String, pkg: String), ackProject(src: String), pause(root: String, duration: String) }
public enum LinkError: Error, Equatable, Sendable {
  case badURL(String), unknownAction(String), unsupportedVersion(Int), missingParameter(String), badDuration(String)
  case engineTooOld, statusUnavailable(String)
  case unknownFinding(src: String, pkg: String), unknownProject(src: String)
  case strictOff, notBlocked(root: String), alreadyPaused(root: String, untilEpoch: Int)
}
public struct LinkPlan: Equatable, Sendable { public let action: MenuAction; public let confirmation: ConfirmationSpec }
public func parseLink(_ url: URL) -> Result<LinkAction, LinkError>                      // section 2.2
public func resolveLink(_ action: LinkAction, status: Status) -> Result<LinkPlan, LinkError>   // spec §3.3 + §3.4
public func linkErrorText(_ e: LinkError) -> String                                     // section 2.4.1
public func severityLabel(_ sev: Double) -> String                                      // "CRIT" ≥9, "HIGH" ≥7, "MED" ≥4, else "LOW"

// Rules.swift (A8) — `MenuAction` gains:
case ackSource(src: String, pkg: String)        // report link → ["ack", src, pkg]
case ackSourceProject(src: String)              // report link → ["ack", src]
// confirmation(for:) returns nil for both; projectName(root:status:) also searches status.active

// ResolveLink.swift (A8)
public enum ResolveLink {
  public static func run(env: [String: String], url: String, timeout: TimeInterval) async -> Int32   // prints the 2.3 line; 0/4/3
  static func line(for result: Result<Status, StatusError>, url: String) -> (line: String, rc: Int32)   // pure, tested
}
```

#### 2.4.1 Texts (verbatim)

`resolveLink` confirmations (`\n` = newline):

- `ack`: title `Mark \(pkg) \(version) as known?`; message
  `Requested by a report link.\n\(project) · \(severityLabel(sev)) \(String(format: "%.1f", sev)) · \(idsOpen.count) advisory id(s): \(idsOpen.joined(separator: ", "))\n\nThis covers every advisory currently known for \(pkg); a new one still alerts. The report itself updates at the next scan.`;
  confirm `Mark as known`; action `.ackSource(src:pkg:)`.
- `ack-project`: title `Mark \(project) as known?`; message
  `Requested by a report link.\n\(src)\n\(entries.count) package(s), \(idCount) advisory id(s), \(critCount) critical.\n\nThe report itself updates at the next scan.`;
  confirm `Mark as known`; action `.ackSourceProject(src:)`.
- `pause`: title `Pause strict mode for \(projectName(root:status:))?`; message
  `Requested by a report link.\n\(blocked.summary)\nRuns and builds will be allowed for \(1 hour|2 hours).`;
  confirm `Pause \(1 hour|2 hours)`; action `.pause(root:duration:)`.

`linkErrorText`:

| Case | Text |
|---|---|
| `.badURL(d)` | `This is not a valid HiveGuard report link (\(d)).` |
| `.unknownAction(a)` | `This link asks for “\(a)”, which this app does not know. If the report came from a newer hiveguard, rebuild the app (make install).` |
| `.unsupportedVersion(v)` | `Link format \(v) is not supported — this app supports \(supportedLinkVersions). Rebuild the app from a matching hiveguard-menubar commit.` |
| `.missingParameter(p)` | `The link is missing “\(p)”.` |
| `.badDuration(d)` | `“\(d)” is not an allowed pause length (1h or 2h).` |
| `.engineTooOld` | `hiveguard is too old to check report links — needs \(minimumHiveguardVersionForLinks) or newer (status --json without “active”).` |
| `.statusUnavailable(r)` | `Cannot check the link against hiveguard: \(r).` |
| `.unknownFinding(src, pkg)` | `\(pkg) in \(src) is not an active finding in the last scan — already marked as known, fixed, or the report is older than the last scan. Nothing was changed.` |
| `.unknownProject(src)` | `\(src) has no active findings in the last scan — already marked as known, or the report is older than the last scan. Nothing was changed.` |
| `.strictOff` | `Strict mode is off — there is nothing to pause.` |
| `.notBlocked(root)` | `\(root) is not blocked by strict mode right now — nothing to pause.` |
| `.alreadyPaused(root, until)` | `\(root) is already paused until \(HH:mm local of until). Unpause it from the menu first if you want a different length.` |

`AppController.title(of:)`: `.ackSource(_, pkg)` → `Mark \(pkg) as known`;
`.ackSourceProject` → `Mark project as known`.

### 2.5 Isolated scaffold — the base plan's section 2.4 verbatim, plus these helpers

Copy the base plan's 2.4 block unchanged (HOME, overrides, stubs, `mk_fixture`, plist,
`h12`, `h12pkg`, `scan`), then add:

```bash
links_on()  { printf '%s' "$$" > "$HIVEGUARD_APP_PID"; }      # "app running" at report time
links_off() { rm -f "$HIVEGUARD_APP_PID"; }
strict_on() { printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"; }
strict_off(){ printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"; }
reset_scan(){ rm -f "$HIVEGUARD_STATE" "$HIVEGUARD_RUN" "$HIVEGUARD_MARKERS" "$HIVEGUARD_COVERAGE" "$HIVEGUARD_ACKS" "$HIVEGUARD_PAUSES" "$HIVEGUARD_REPORT_OPENED"; }
enc()   { jq -rn --arg s "$1" '$s|@uri'; }                     # = python quote(safe="") for these paths (no "~")
count() { grep -o -- "$1" "${2:-$REPORT}" | wc -l | tr -d ' '; }  # rows are on one line: never grep -c
```

**Seed v2 — a "red" status without a scan** (H2's seed plus `active`; used by H6, A9, A10
`seed_red`):

```bash
seed_red() {
NOW=$(date +%s); cat > "$HIVEGUARD_RUN" <<EOF
{"schema":1,"ok":true,"rc":1,"error":null,"started_epoch":$((NOW-7230)),"finished_epoch":$((NOW-7200)),"stamp":"x","target":"$T/proj",
 "counts":{"active":{"projects":1,"pkgs":2,"vulns":4,"crit":1},"acked":{"projects":0,"pkgs":0,"vulns":0,"crit":0},"new_vulns":4,"resolved_vulns":0},
 "roots":{"$T/proj/app":{"status":"active","active_vulns":4,"crit_pkgs":1,"acked_vulns":0}},
 "new":[],
 "unseen":[
  {"src":"$SRC","root":"$T/proj/app","pkg":"fast-uri","version":"3.0.1","eco":"npm","sev":7.5,"fix":"3.0.6","ids":["GHSA-AAAA-0001","GHSA-AAAA-0002","GHSA-AAAA-0003"],"anchor":"f-000000000001","project_anchor":"p-000000000002"},
  {"src":"$SRC","root":"$T/proj/app","pkg":"lodash","version":"4.17.20","eco":"npm","sev":9.1,"fix":"4.17.21","ids":["GHSA-BBBB-0001"],"anchor":"f-000000000003","project_anchor":"p-000000000002"}],
 "active":[
  {"src":"$SRC","root":"$T/proj/app","pkg":"lodash","version":"4.17.20","eco":"npm","sev":9.1,"fix":"4.17.21","ids":["GHSA-BBBB-0001"],"anchor":"f-000000000003","project_anchor":"p-000000000002"},
  {"src":"$SRC","root":"$T/proj/app","pkg":"fast-uri","version":"3.0.1","eco":"npm","sev":7.5,"fix":"3.0.6","ids":["GHSA-AAAA-0001","GHSA-AAAA-0002","GHSA-AAAA-0003"],"anchor":"f-000000000001","project_anchor":"p-000000000002"}]}
EOF
printf '%s\tactive\t4 active vulnerabilities (1 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
printf '%s\t%s\n%s\t%s\ngarbage\n' "$T/proj/app" "$((NOW+600))" "$T/other" "$((NOW-600))" > "$HIVEGUARD_PAUSES"
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
}
```

Expected from this seed: `status --json` → `active|length` 2, `active_ids` 4,
`active[0].pkg` lodash; `$T/proj/app` is blocked **and currently paused** (so a `pause`
link is refused until `: > "$HIVEGUARD_PAUSES"`).

**Baseline renderer for byte-identity** (H5 acceptance): `mkdir -p "$T/base" && git -C
"$HG" archive 14a05c1 bin | tar -x -C "$T/base"` → `"$T/base/bin/osv-daily"` is the
released report generator with its sibling tools (`folder-mark`, `help.awk`).
`scan_base() { STUB_JSON="$1" "$T/base/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }`.
Normalise the stamp with `sed 's/osv-daily · [^<]*/STAMP/'` before `diff`.

### 2.6 Status fixtures (`APP/Tests/HiveGuardCoreTests/Fixtures/`, task A7)

Every **positive** fixture gains `"active": […]` and `"active_ids": N` (placed after
`attention_ids`); the three `bad-*` fixtures are untouched; one new fixture:

- `red-6.json`: `active` = the two attention entries verbatim (lodash, fast-uri) **plus**
  `{"src":"/Users/mh/Projects/y/svc/pnpm-lock.yaml","root":"/Users/mh/Projects/y/svc","project":"y/svc","pkg":"qs","version":"6.5.2","eco":"npm","sev":7.5,"crit":false,"fix":"6.5.3","ids_open":["GHSA-CCCC-0001"],"ids_acked":[],"anchor":"f-5e6f7a8b9c0d","project_anchor":"p-0d1e2f3a4b5c"}`
  and `{"src":"/Users/mh/Projects/x/app/package-lock.json","root":"/Users/mh/Projects/x/app","project":"x/app","pkg":"minimist","version":"1.2.5","eco":"npm","sev":5.6,"crit":false,"fix":"1.2.6","ids_open":["GHSA-DDDD-0001"],"ids_acked":["GHSA-DDDD-0000"],"anchor":"f-6f7a8b9c0d1e","project_anchor":"p-9a1b2c3d4e5f"}`,
  in this order (lodash, fast-uri, qs, minimist — sev desc, project, pkg); `active_ids` 8.
- `red-partially-acked.json`, `red-opened.json`, `red-and-schedule-off.json`,
  `strict-on-hook-missing.json`: `active` = that fixture's `attention` entries verbatim,
  `active_ids` = its `attention_ids`.
- `calm.json`, `yellow-*.json`, `scanning.json`: `active: []`, `active_ids: 0`.
- `compat-no-active.json` (new): `red-6.json` **without** `active` and `active_ids`
  (a 1.6.0 engine's document). Decodes; `active == nil`.

Fixture count becomes 16.

---

## 3. Tasks

Task ids continue the base plan: `H5`–`H7` (hiveguard, `HG`), `A7`–`A10` (app, `APP`).
Model tiers: `sonnet` = mechanical, fully specified; `opus` = stateful/subtle or
cross-cutting. Every task is test-first: write the failing test from its acceptance block
first, run it red, implement, run it green, then run the whole suite of its repo.

### Wave 1 (parallel: H5, H6 · A7)

---

#### H5 — `osv-daily`: `active[]` in the run file; report action buttons when the app is running

- **Model:** opus — the renderer is touched in four places and must stay byte-identical
  when links are off; the run file gains a key that existing tests pin.
- **Owns:** `HG/bin/osv-daily`, `HG/tests/report-actions.test.sh` (new),
  `HG/tests/osv-run.test.sh`
- **Depends on:** nothing

**Do:**

1. Bash, before the report python call: add `CONFIG="${HIVEGUARD_CONFIG:-$HOME/.hiveguard/config}"`
   next to the other path vars; copy `config_get` from `strict-mode`; move the
   `app_running()` definition up next to `write_opened()` (delete the late duplicate; the
   notifier keeps calling it); compute `STRICT_ON=0; [ "$(config_get strict 0)" = 1 ] &&
   STRICT_ON=1` and `APP_RUNNING=0; app_running && APP_RUNNING=1` immediately before the
   python line; add `APP_RUNNING="$APP_RUNNING" STRICT_ON="$STRICT_ON"` to that line's env.
2. Python: `import … urllib.parse`; after `probe` is known:
   `links_on = os.environ.get("APP_RUNNING", "0") == "1" and not probe`,
   `strict_on = os.environ.get("STRICT_ON", "0") == "1"`; add `app_link(action, params,
   label, title, extra="")` and `cp_alt(cmd)` per section 2.3; in `pkg_row` compute the
   command string first (today's three branches), then `btn = cp_btn(cmd, label)` as today,
   or — when `links_on and section == "active"` — the `actg` span of section 2.3; in
   `proj_card` for the active card when `links_on`: `root = finding_root(pr["src"])`, the
   `actg` span with the `ack-project` link, the two pause links iff `strict_on and root in
   root_agg`, and `cp_alt("hiveguard ack " + shlex.quote(pr["src"]))`. Acked rows/cards and
   the toolbar untouched. `links_css` / `footer_hint` variables empty unless `links_on`;
   emitted in the `<style>` block (after `.hl{…}`) and the footer sentence respectively.
3. Run file: in the success block build `active_entries` = one dict per `(pr, p)` of
   `active` with `{src, root: finding_root(src), pkg, version, eco, sev, fix: p["fix"] or
   "", ids: list(p["ids"]), anchor, project_anchor}` sorted with `order`; add
   `"active": active_entries` to `run_doc`. Failure block: `"active": (prev.get("active")
   if isinstance(prev, dict) else None) or []`.
4. Header comment: a paragraph "Report action buttons" (spec §2.3 gate, the three
   actions, `copy` fallback, probe never, `docs/report-links.md`) and one sentence in the
   `osv-run.json` paragraph for `active`. `help.awk` rendering intact.
5. `tests/osv-run.test.sh`: the documented-keys check gains `active,` (first); add checks:
   `active` has 2 entries after `scan run2`, `.active[1].ids` are the three fast-uri ids,
   `.active[0].pkg` lodash, root/anchors as the `new` entry; after `hiveguard ack "$SRC"
   fast-uri` + rescan → 1 entry (lodash); failed scan carries `active` unchanged.
6. `tests/report-actions.test.sh` (new; header in the house style: what it covers, fully
   offline, isolated HOME; scaffold 2.5 inline): the checks of the acceptance block below
   (markers of byte-identity, exact hrefs, counts, strict gate, pierced row, acked section
   unchanged, probe, dead pid, anchors + hash script intact).

**Acceptance criteria** (orchestrator, fresh 2.5 scaffold):

```bash
# --- app NOT running → report identical to the 14a05c1 renderer (stamp aside) ---
links_off; strict_off; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; cp "$REPORT" "$T/new.html"
count 'hiveguard://' "$T/new.html"; count 'act-link' "$T/new.html"; count 'cp-alt' "$T/new.html"            # 0 / 0 / 0
count 'class="cp"' "$T/new.html"                                                                              # 3   (mute ×2, mute project)
mkdir -p "$T/base" && git -C "$HG" archive 14a05c1 bin | tar -x -C "$T/base"
scan_base() { STUB_JSON="$1" "$T/base/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }
reset_scan; scan_base "$T/run1.json"; scan_base "$T/run2.json"
diff <(sed 's/osv-daily · [^<]*/STAMP/' "$T/new.html") <(sed 's/osv-daily · [^<]*/STAMP/' "$REPORT") && echo identical   # identical
# --- app running, strict off → ack links on rows and card, copy tucked behind "copy", no pause ---
links_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"; ENC="$(enc "$SRC")"
count 'class="act-link'                                                                                       # 3
count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=fast-uri\""                                             # 1
count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=lodash\""                                               # 1
count "href=\"hiveguard://ack-project?v=1&amp;src=$ENC\""                                                      # 1
count 'hiveguard://pause'                                                                                     # 0
count '>mark as known</a>'; count '>mark project as known</a>'                                                # 2 / 1
count 'class="cp cp-alt"'; count 'class="cp"'                                                                  # 3 / 0
count "data-cmd=\"hiveguard ack $SRC fast-uri\""; count "data-cmd=\"hiveguard ack $SRC\""                     # 1 / 1
count 'aria-label="Copy command: hiveguard ack '                                                              # 3
count '\.act-link{'; count 'Buttons act through the HiveGuard menu bar app'                                    # 1 / 1
grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT"; grep -c "id=\"p-$(h12 "$SRC")\"" "$REPORT"; grep -c hashchange "$REPORT"   # 1 / 1 / ≥1
# --- strict on → pause links with the realpath'd root ---
strict_on; scan "$T/run2.json"; ROOTENC="$(enc "$T/proj/app")"
count "href=\"hiveguard://pause?v=1&amp;root=$ROOTENC&amp;for=1h\""; count "href=\"hiveguard://pause?v=1&amp;root=$ROOTENC&amp;for=2h\""   # 1 / 1
count '>pause strict 1 h</a>'; count '>pause strict 2 h</a>'; count 'class="act-link'                          # 1 / 1 / 5
# --- pierced row → re-ack link; acked section untouched ---
reset_scan; scan "$T/run1.json"; "$HG/bin/hiveguard" ack "$SRC" fast-uri >/dev/null </dev/null; scan "$T/run2.json"
count '>re-ack</a>'; count "href=\"hiveguard://ack?v=1&amp;src=$ENC&amp;pkg=fast-uri\""                        # 1 / 1
count '>unmute</button>'; count '>unmute all</button>'                                                         # 1 / 1
sed -n '/class="ackwrap"/,$p' "$REPORT" | grep -o 'act-link' | wc -l | tr -d ' '                               # 0
# --- probe and dead pid never render links ---
STUB_JSON="$T/run2.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1; count 'act-link' "$HOME/.hiveguard/osv-probe.html"   # 0
printf '99999' > "$HIVEGUARD_APP_PID"; scan "$T/run2.json"; count 'act-link'                                   # 0
# --- run file: active[] ---
links_on; reset_scan; scan "$T/run1.json"; scan "$T/run2.json"
jq -r 'keys|join(",")' "$HIVEGUARD_RUN"                                                                        # active,counts,error,finished_epoch,new,ok,rc,roots,schema,stamp,started_epoch,target,unseen
jq -r '(.active|length), .active[0].pkg, (.active[1].ids|join(",")), .active[1].root, .active[1].anchor, .active[1].fix' "$HIVEGUARD_RUN" | paste -sd' ' -   # 2 lodash GHSA-AAAA-0001,GHSA-AAAA-0002,GHSA-AAAA-0003 $T/proj/app f-$(h12pkg "$SRC" fast-uri) 3.0.6
jq -r '.active[0]|keys|join(",")' "$HIVEGUARD_RUN"                                                             # anchor,eco,fix,ids,pkg,project_anchor,root,sev,src,version
"$HG/bin/hiveguard" ack "$SRC" fast-uri >/dev/null </dev/null; scan "$T/run2.json"; jq -r '(.active|length), .active[0].pkg' "$HIVEGUARD_RUN" | paste -sd' ' -   # 1 lodash
STUB_FAIL=1 scan "$T/run1.json"; jq -r '.ok, (.active|length), .active[0].pkg' "$HIVEGUARD_RUN" | paste -sd' ' -   # false 1 lodash   (carried)
rm -f "$HIVEGUARD_RUN"; STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1; [ ! -e "$HIVEGUARD_RUN" ] && echo probe-no-run   # probe-no-run
# --- suites, help, syntax ---
bash "$HG/tests/report-actions.test.sh"; echo "rc=$?"                                                         # rc=0
bash "$HG/tests/osv-run.test.sh" && bash "$HG/tests/report-open.test.sh" && bash "$HG/tests/notify-handoff.test.sh" && echo green   # green
"$HG/bin/osv-daily" --help | grep -c 'hiveguard://'                                                            # ≥1
bash -n "$HG/bin/osv-daily" && echo syntax-ok                                                                  # syntax-ok
grep -n 'declare -A\|\btimeout\b' "$HG/bin/osv-daily" "$HG/tests/report-actions.test.sh"                       # no output
git -C "$HG" status --porcelain                                                                                # bin/osv-daily tests/osv-run.test.sh tests/report-actions.test.sh only
```

**Do not:** change any JavaScript in the report; touch the Acknowledged section, the
toolbar, anchors, the jump page, `--open`, the notifier text, the state file, `osv-ack`,
`strict-mode`, `folder-mark`; emit links on `--probe`; emit CSS/footer changes when links
are off; write the opened stamp.

---

#### H6 — `bin/status`: `active[]` and `active_ids`; contract document; status test

- **Model:** sonnet — a copy of the existing `attention` jq over another array, plus
  documentation rows; fully specified.
- **Owns:** `HG/bin/status`, `HG/docs/status-json.md`, `HG/tests/status.test.sh`
- **Depends on:** nothing (seed v2 is hand-written; H5 is not needed)

**Do:**

1. `bin/status` jq: factor the entry classification into a jq function
   `def classify($entries): [ $entries[] | . as $e | … exactly the existing attention body … ] | sort_by([-(.sev // 0), .project, .pkg]);`
   and use it for both `($run.unseen // [])` → `$attention` and `($run.active // [])` →
   `$active`. Object gains `active: $active, active_ids: ([$active[].ids_open | length] |
   add // 0)` right after `attention_ids`. Human output unchanged. Header comment: one
   sentence that `active` lists every active finding of the last run for the companion
   app's report-link validation.
2. `docs/status-json.md`: field rows for `active` (meaning per spec §2.2: every active
   finding of the last successful run — the report's Active rows — classified live like
   `attention`, entries with no open id dropped, same entry shape, same sort, `[]` when no
   run or the run predates the field, "used by the companion app to validate report
   action links"), `active[].*` ("same fields and meanings as `attention[].*`"),
   `active_ids`; update the example document; schema history row
   `| 1 | 2026-10 | additive: \`active[]\`, \`active_ids\` — report action links (same schema per the compatibility rule) |`.
3. `tests/status.test.sh`: top-level key list check becomes the 2.3 list; add the checks of
   the acceptance block (entry keys, counts, live classification, missing key, no run).

**Acceptance criteria** (fresh 2.5 scaffold; `seed_red`):

```bash
seed_red; S="$("$HG/bin/hiveguard" status --json)"; jq -e . <<<"$S" >/dev/null && echo valid-json             # valid-json
jq -r 'keys|join(" ")' <<<"$S"                                                                                   # active active_ids app attention attention_ids hiveguard now_epoch report scan schedule schema strict
jq -r '(.active|length), .active_ids, .active[0].pkg, .active[0].crit, (.active[1].ids_open|length), (.active[1].ids_acked|length)' <<<"$S" | paste -sd' ' -   # 2 4 lodash true 3 0
jq -r '.active[0]|keys|join(" ")' <<<"$S"                                                                        # anchor crit eco fix ids_acked ids_open pkg project project_anchor root sev src version
jq -r '.active[1] | .project, .anchor, .project_anchor, .root, .fix' <<<"$S" | paste -sd' ' -                    # $T/proj/app f-000000000001 p-000000000002 $T/proj/app 3.0.6
jq -r '.attention_ids, (.attention|length)' <<<"$S" | paste -sd' ' -                                             # 4 2   (unchanged)
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"],"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"
"$HG/bin/hiveguard" status --json | jq -r '.active_ids, (.active|length), (.active[]|select(.pkg=="fast-uri")|(.ids_open|join(",")), (.ids_acked|length))' | paste -sd' ' -   # 2 2 GHSA-AAAA-0003 2
printf '{"schema":2,"projects":{"%s":{"ids":null,"since":"x"}},"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
"$HG/bin/hiveguard" status --json | jq -r '.active_ids, (.active|length), .attention_ids' | paste -sd' ' -      # 0 0 0
printf '{"projects":["%s"],"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"; "$HG/bin/hiveguard" status --json | jq -r '.active_ids'   # 0   (v1 store)
rm -f "$HIVEGUARD_ACKS"
jq 'del(.active)' "$HIVEGUARD_RUN" > "$T/old.json" && cp "$T/old.json" "$HIVEGUARD_RUN"
"$HG/bin/hiveguard" status --json | jq -c '.active, .active_ids, .attention_ids' | paste -sd' ' -               # [] 0 4   (1.6.0 run file)
mv "$HIVEGUARD_RUN" "$T/r.bak"; "$HG/bin/hiveguard" status --json | jq -c '.active, .active_ids' | paste -sd' ' -; mv "$T/r.bak" "$HIVEGUARD_RUN"   # [] 0
"$HG/bin/hiveguard" status | wc -l | tr -d ' '                                                                  # 4   (human output unchanged: 4 lines, no scan running)
ls -A "$HOME/.hiveguard" | sort | tr '\n' ' '                                                                    # only the seed's files
time "$HG/bin/hiveguard" status --json >/dev/null                                                                # real < 1.0s
for k in $(jq -r 'keys[]' <<<"$S"); do grep -q "\`$k\`" "$HG/docs/status-json.md" || echo "MISSING $k"; done     # no output
awk '/^## Schema history/{f=1} f' "$HG/docs/status-json.md" | grep -c 'active'                                   # 1
grep -c 'active' "$HG/docs/status-json.md"                                                                       # ≥6
bash "$HG/tests/status.test.sh"; echo "rc=$?"                                                                   # rc=0
bash -n "$HG/bin/status" && echo syntax-ok                                                                       # syntax-ok
git -C "$HG" status --porcelain                                                                                  # bin/status docs/status-json.md tests/status.test.sh only
```

**Do not:** bump `schema`; change any existing field, the sort, the human output, or the
read-only guarantees; touch `osv-daily`, `osv-ack`, `strict-mode`.

---

#### A7 — App contract & scaffold: `active` decoding, fixtures, URL type, install registration, README

- **Model:** sonnet — fully specified structure; no behaviour.
- **Owns:** `APP/Sources/HiveGuardCore/Status.swift`,
  `APP/Tests/HiveGuardCoreTests/Fixtures/*` (all), `APP/Tests/HiveGuardCoreTests/StatusDecodingTests.swift`,
  `APP/Resources/Info.plist`, `APP/Makefile`, `APP/README.md`
- **Depends on:** nothing (contract in section 2)

**Do:**

1. `Status.swift`: add `active: [AttentionEntry]?` and `activeIds: Int?` (section 2.4) with
   coding keys; nothing else changes (`supportedSchemas` stays `1...1`).
2. Fixtures per section 2.6 (every positive fixture gains the two keys; new
   `compat-no-active.json`; `bad-*` untouched). Keep each fixture schema-complete and the
   key order `… attention, attention_ids, active, active_ids, report …`.
3. `StatusDecodingTests`: `red-6` → `active?.count == 4`, `activeIds == 8`,
   `active?[2].pkg == "qs"`; `calm` → `active == []`, `activeIds == 0`;
   `compat-no-active` → decodes, `active == nil`, `activeIds == nil`; unknown-key test
   still passes.
4. `Resources/Info.plist`: `CFBundleURLTypes` (section 2.1), placed before `LSUIElement`.
5. `Makefile`: `LSREGISTER := …` (section 2.1); `install`: after `cp -R`, before `open`:
   `$(LSREGISTER) -f "$(INSTALLED)" || true` and
   `$(LSREGISTER) -u "$(CURDIR)/$(BUNDLE)" >/dev/null 2>&1 || true`; `uninstall`: before
   `rm -rf "$(INSTALLED)"`: `$(LSREGISTER) -u "$(INSTALLED)" >/dev/null 2>&1 || true`.
   Header comment: one line that `install` registers the `hiveguard://` scheme with
   LaunchServices and `uninstall` unregisters it.
6. `README.md`: new section `## Report links (\`hiveguard://\`)` after "Commands": what the
   buttons in the report do (three actions, nothing else), every link opens a confirmation
   that shows the exact scope, links are validated against the current `hiveguard status
   --json` (`active`, `strict`) and refused with a reason otherwise, the grammar lives in
   `../hiveguard/docs/report-links.md` (link by sibling path), `make install` registers the
   scheme (`lsregister`) and `make uninstall` removes it, `make run` from `dist/` also
   registers a copy (the next `make install` unregisters it), the browser's own "Allow
   this page to open HiveGuard?" prompt is expected, the minimum hiveguard for `ack` links
   (`minimumHiveguardVersionForLinks`), and the hidden `--resolve-link <url>` test flag
   (prints one JSON line, never runs anything). Update the "Supported `status` schema"
   note: `active`/`active_ids` are optional (older engines).

**Acceptance criteria:**

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1                 # 0 / 0 failures
ls Tests/HiveGuardCoreTests/Fixtures | wc -l | tr -d ' '                                                       # 16
for f in Tests/HiveGuardCoreTests/Fixtures/*.json; do case "$(basename "$f")" in bad-*|compat-no-active.json) ;; *) jq -e '.schema==1 and (.active|type=="array") and (.active_ids|type=="number") and (.active_ids == ([.active[].ids_open|length]|add // 0))' "$f" >/dev/null || echo "BAD $f";; esac; done   # no output
jq -r '(.active|length), .active_ids, ([.active[].pkg]|join(","))' Tests/HiveGuardCoreTests/Fixtures/red-6.json | paste -sd' ' -   # 4 8 lodash,fast-uri,qs,minimist
jq -e '(has("active")|not) and (has("active_ids")|not) and .schema==1' Tests/HiveGuardCoreTests/Fixtures/compat-no-active.json >/dev/null && echo compat-ok   # compat-ok
plutil -lint Resources/Info.plist                                                                              # OK
plutil -p Resources/Info.plist | grep -c '"hiveguard"'; plutil -p Resources/Info.plist | grep -c 'com.hiveguard.menubar.report-link'   # 1 / 1
command make app >/dev/null && plutil -p dist/HiveGuard.app/Contents/Info.plist | grep -c CFBundleURLSchemes     # 1
codesign -dv dist/HiveGuard.app 2>&1 | grep -c 'Signature=adhoc'                                                # 1
grep -c 'lsregister' Makefile                                                                                   # ≥4
command make -n install 2>/dev/null | grep -c 'lsregister -f'; command make -n uninstall 2>/dev/null | grep -c 'lsregister -u'   # 1 / 1   (dry run; nothing installed)
grep -c 'hiveguard://' README.md; grep -c 'report-links.md' README.md; grep -c 'resolve-link' README.md          # ≥2 / ≥1 / ≥1
grep -c 'activeIds\|active_ids' Sources/HiveGuardCore/Status.swift                                              # ≥2
git -C "$APP" status --porcelain | grep -c '\.build\|dist/'                                                     # 0
ls -A "$HOME/.hiveguard" 2>/dev/null | grep -c menubar                                                           # 0
```

**Do not:** run `make install`/`make run`/`lsregister`; edit `Rules.swift`, `AppModel`,
anything under `Sources/HiveGuard/`; change `supportedSchemas`; touch `Tests/e2e.test.sh`.

---

### Wave 2 (parallel: H7 · A8, A9) — after wave 1 is verified and committed in both repos

---

#### H7 — hiveguard docs: link contract document, README, CHANGELOG

- **Model:** sonnet
- **Owns:** `HG/docs/report-links.md` (new), `HG/README.md`, `HG/CHANGELOG.md`
- **Depends on:** H5, H6

**Do:**

1. `docs/report-links.md`: title `Report action links — contract (version 1)`; owner line
   (hiveguard emits; consumed by the companion app, which links here); when links are
   emitted (app pid alive at report time, never in `--probe` reports, pause links only
   with strict on); the grammar table of section 2.2 with the engine verb per action;
   encoding rules (`quote(safe="")`, `%2F`, `%20`, UTF-8, no `+`, HTML-escaped in
   attributes); the version rule (`v`, additive vs breaking, unknown action/parameter
   handling); what the app does (always confirms, validates against `status --json`
   `active`/`strict`, refuses otherwise, never runs other verbs); the `copy` fallback;
   examples; `## History` table with `| 1 | 2026-10 | initial |`. Link the spec and
   `docs/status-json.md` by repo path.
2. `README.md`: in "Muting old projects (`hiveguard ack`)", after the "Every row in the
   report carries a mute / unmute button…" paragraph, a paragraph **With the companion
   app running** (at scan time the active rows and project cards show buttons that act
   through the app — *mark as known*, *mark project as known*, *pause strict 1 h / 2 h*
   when strict mode is on; the app always asks for confirmation and checks the request
   against the current state; the terminal command stays behind the small *copy* button;
   grammar in `docs/report-links.md`). In "Companion menu bar app": one sentence about
   the report buttons. In the data table: `osv-run.json` row gains "every active finding
   of the run".
3. `CHANGELOG.md` `## [Unreleased]` → `### Added`: report action buttons (when the
   companion app is running at scan time; three actions; `copy` fallback;
   `docs/report-links.md`); `active` in `osv-run.json`; `active[]`/`active_ids` in
   `hiveguard status --json` (additive, schema 1). Keep the existing `### Fixed` entry.
   Nothing about the app's own code.

**Acceptance criteria:**

```bash
grep -c '^## History' "$HG/docs/report-links.md"; grep -c 'hiveguard://ack?v=1' "$HG/docs/report-links.md"; grep -c 'ack-project\|for=1h\|safe=""' "$HG/docs/report-links.md"   # 1 / ≥1 / ≥3
grep -c 'report-links.md' "$HG/README.md"; grep -c 'With the companion app running' "$HG/README.md"                 # ≥1 / 1
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -c 'report-links\|active\|button'    # ≥3
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -ci 'swift\|Info.plist\|Makefile'   # 0
git -C "$HG" status --porcelain                                                                                     # docs/report-links.md README.md CHANGELOG.md only
```

**Do not:** cut a version section; edit any script or test.

---

#### A8 — Core: link parsing, validation, always-confirm builder, `--resolve-link` renderer

- **Model:** opus — the product's safety logic (refuse-by-default, exact texts), new
  `MenuAction` cases threaded through the rules, a second CLI renderer.
- **Owns:** `APP/Sources/HiveGuardCore/Links.swift` (new),
  `APP/Sources/HiveGuardCore/ResolveLink.swift` (new), `APP/Sources/HiveGuardCore/Rules.swift`,
  `APP/Tests/HiveGuardCoreTests/LinkTests.swift` (new),
  `APP/Tests/HiveGuardCoreTests/ResolveLinkTests.swift` (new),
  `APP/Tests/HiveGuardCoreTests/RulesTests.swift`, `APP/Tests/HiveGuardCoreTests/ConfirmationTests.swift`
- **Depends on:** A7 (fixtures with `active`; `Status.active`)

**Do** (section 2.4 signatures; pure; no `Date()`, no I/O in `Links.swift`):

1. `Links.swift`: `parseLink` exactly per section 2.2; `resolveLink` per spec §3.3/§3.4
   with the texts of 2.4.1 (`ack`/`ack-project` require `status.active != nil` →
   `.engineTooOld`; `pause` checks `strict.enabled`, `strict.blocked`, `strict.paused` in
   that order and needs no `active`); `linkErrorText` (the `alreadyPaused` clock uses a
   `DateFormatter` `HH:mm` in the current time zone — the only non-pure text, tested by
   prefix); `severityLabel`.
2. `Rules.swift`: the two `MenuAction` cases; `cliArguments` mapping; `confirmation(for:)`
   → `nil` for them; `projectName(root:status:)` searches `status.active` after
   `status.attention`. Existing behaviour untouched (every existing test still passes
   unchanged).
3. `ResolveLink.swift`: `run(env:url:timeout:)` → `CLIRunner(environment:).fetchStatus` →
   `line(for:url:)` → print → rc. `line`: `URL(string: url)` nil → refused line (rc 4);
   status failure → `{"ok":false,"error":"Cannot check the link against hiveguard: <reasonText of the yellow reason>"}` rc 3;
   parse/resolve failure → `{"ok":false,"error":<linkErrorText>}` rc 4; success → the 2.3
   line with `action` = `ack`/`ack-project`/`pause`, `argv` = `cliArguments(for: plan.action,
   status:)`, `confirm` = the spec; JSON strings via the same encoder as `DumpState.json`.
4. `LinkTests` (fixtures `red-6`, `calm`, `compat-no-active`, `red-6` modified so x/app is
   paused):
   - parse: the three valid forms → the expected `LinkAction` with decoded values;
     `src=%2FUsers%2Fmh%2FMy%20Projects%2F%C3%A9%2Fpackage.json` → `/Users/mh/My Projects/é/package.json`;
     `pkg=a+b` → `a+b`; `v` absent ok; `v=2` → `.unsupportedVersion(2)`; `v=x` →
     `.badURL`; `hiveguard://strict-off?v=1` → `.unknownAction("strict-off")`;
     `https://ack?src=…` → `.badURL`; `hiveguard://?v=1` → `.badURL`; missing `pkg` →
     `.missingParameter("pkg")`; `src=` empty → `.missingParameter("src")`; `src=x.json` →
     `.badURL`; duplicate `src` → `.badURL`; `for=3h` and `for=1H` → `.badDuration`;
     `HIVEGUARD://ACK?…` → parses; extra `&foo=bar` ignored.
   - resolve: lodash → plan action `.ackSource`, title/message/label verbatim (message:
     `Requested by a report link.\nx/app · CRIT 9.1 · 2 advisory id(s): GHSA-BBBB-0001, GHSA-BBBB-0002\n\nThis covers every advisory currently known for lodash; a new one still alerts. The report itself updates at the next scan.`);
     minimist (not in attention) → ok, `MED 5.6`, 1 id; unknown pkg → `.unknownFinding`;
     `ack-project` x/app src → message `Requested by a report link.\n/Users/mh/Projects/x/app/package-lock.json\n3 package(s), 7 advisory id(s), 1 critical.\n\nThe report itself updates at the next scan.`;
     unknown src → `.unknownProject`; `pause` x/app 2h → `.pause(root:duration:"2h")`,
     message `Requested by a report link.\n6 active vulnerabilities (1 critical)\nRuns and builds will be allowed for 2 hours.`,
     label `Pause 2 hours`; 1h → `Pause 1 hour`; y/svc → `.notBlocked`; x/app with a
     running pause → `.alreadyPaused(root:, untilEpoch:)`; `calm` (strict off) →
     `.strictOff`; `compat-no-active` + ack → `.engineTooOld`, + pause → still resolves
     (blocked list present in that fixture).
   - `cliArguments`: `.ackSource` → `[["ack", src, pkg]]`; `.ackSourceProject` →
     `[["ack", src]]`; `confirmation(for:)` nil for both; `linkErrorText` for every case
     non-empty and containing the key value; `severityLabel` buckets.
5. `ResolveLinkTests` (fake `hiveguard` script via `HIVEGUARD_BIN`, as `DumpStateTests`):
   `cat`s `red-6.json` + lodash link → line has `"ok":true`, `"action":"ack"`,
   `"argv":[["ack","/Users/mh/Projects/x/app/package-lock.json","lodash"]]`, rc 0; unknown
   pkg → `"ok":false`, rc 4; `strict-off` action → rc 4; script exits 2 with `unknown
   command: status` → `"ok":false`, error starts with `Cannot check the link against
   hiveguard:`, rc 3; `HIVEGUARD_BIN=/nonexistent` → rc 3; `url` not parseable by
   `URL(string:)` → rc 4.
6. `RulesTests`/`ConfirmationTests`: add the argv/nil cases above (keep every existing test).

**Acceptance criteria:**

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'                                                     # 0
command swift test --filter 'LinkTests|ResolveLinkTests|RulesTests|ConfirmationTests' 2>&1 | tail -n1          # Executed N tests, with 0 failures (N ≥ 70)
command swift test 2>&1 | tail -n1                                                                             # 0 failures
grep -cE '^import (AppKit|SwiftUI|UserNotifications|ServiceManagement)' Sources/HiveGuardCore/Links.swift Sources/HiveGuardCore/ResolveLink.swift   # 0 each
grep -c 'Date()' Sources/HiveGuardCore/Links.swift                                                             # 0   (the clock appears only inside linkErrorText's formatter of a given epoch)
grep -c '"--remove"\|"--fix"\|"off"\|"on"' Sources/HiveGuardCore/Links.swift                                    # 0
grep -c 'case ackSource\|case ackSourceProject' Sources/HiveGuardCore/Rules.swift                              # 2
grep -c 'supportedLinkVersions' Sources/HiveGuardCore/Links.swift                                              # ≥2
```

**Do not:** edit `Status.swift`, `AppModel.swift`, `CLIRunner.swift`, `DumpState.swift`,
anything under `Sources/HiveGuard/` (if a field is missing, stop and report); perform
I/O in `Links.swift`; weaken any existing rule.

---

#### A9 — UI: receive `hiveguard://` URLs, queue, validate, confirm, run; `--resolve-link` dispatch

- **Model:** opus — lifecycle ordering (cold launch vs first refresh), main-actor hops,
  modal alerts from a delegate callback.
- **Owns:** `APP/Sources/HiveGuard/HiveGuardApp.swift`, `APP/Sources/HiveGuard/main.swift`
- **Depends on:** A7; compiles against A8's signatures (same wave; the orchestrator builds
  at wave end)

**Do:**

1. `main.swift`: before the `--dump-state` block, `--resolve-link`: the next argument is
   the url (missing → `usage: HiveGuard --resolve-link <url>` on stderr, `exit(2)`); run
   `ResolveLink.run(env:url:timeout: 30)` through the same semaphore pattern; `exit(rc)`.
   No `NSApplication`, no `PidPresence`.
2. `AppDelegate`: `func application(_ application: NSApplication, open urls: [URL])` →
   `MainActor.assumeIsolated { AppController.current.handleIncoming(urls) }`.
3. `AppController`: `pendingLinks: [URL]`, `launched = false`, `handlingLink = false`;
   `handleIncoming(_:)` appends and calls `drainLinks()`; `launch()` sets `launched = true`
   as its last statement and calls `drainLinks()`; `drainLinks()` takes the first pending
   url only when `launched && !handlingLink`, sets `handlingLink`, and runs
   `handleLink(url)` in a main-actor `Task`, clearing the flag and draining again when done
   (`defer`). `handleLink`: `await model.refresh()`; `guard let status = model.status` else
   `Confirmations.showError(title: "Report link ignored", message: linkErrorText(.statusUnavailable(text)))`
   where `text` = `reasonText` of the current yellow reason (or `"unknown"`); then
   `parseLink(url).flatMap { resolveLink($0, status: status) }`: failure →
   `showError("Report link ignored", linkErrorText(e))`; success →
   `Confirmations.ask(plan.confirmation)` and, if confirmed, `await model.perform(plan.action)`
   (errors surface through the existing `lastActionError` observer). `title(of:)` gains
   the two cases (2.4.1).
4. No other UI changes (the menu does not list link actions; `MenuContent` untouched).

**Acceptance criteria** (wave end, fresh 2.5 scaffold with `seed_red`; the app session's
`HIVEGUARD_BIN` points at the engine worktree `$HG/bin/hiveguard`, which has H6):

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1                # 0 / 0 failures
BIN="$APP/.build/debug/HiveGuard"; ENC="$(enc "$SRC")"; ROOTENC="$(enc "$T/proj/app")"; before="$(ls -A "$HOME/.hiveguard" | sort | tr '\n' ' ')"
"$BIN" --resolve-link "hiveguard://ack?v=1&src=$ENC&pkg=fast-uri" | jq -c '.ok, .action, .argv, .confirm.title'; echo "rc=${PIPESTATUS[0]}"   # true "ack" [["ack","$SRC","fast-uri"]] "Mark fast-uri 3.0.1 as known?"  rc=0
"$BIN" --resolve-link "hiveguard://ack-project?v=1&src=$ENC" | jq -c '.ok, .argv, .confirm.message'            # true [["ack","$SRC"]] "Requested by a report link.\n$SRC\n2 package(s), 4 advisory id(s), 1 critical.\n\nThe report itself updates at the next scan."
"$BIN" --resolve-link "hiveguard://pause?v=1&root=$ROOTENC&for=2h" | jq -r '.ok, .error'; echo "rc=${PIPESTATUS[0]}"   # false / "$T/proj/app is already paused until HH:MM. …"  rc=4
: > "$HIVEGUARD_PAUSES"; "$BIN" --resolve-link "hiveguard://pause?v=1&root=$ROOTENC&for=2h" | jq -c '.ok, .argv, .confirm.confirmLabel'   # true [["strict","pause","$T/proj/app","--for","2h"]] "Pause 2 hours"
"$BIN" --resolve-link "hiveguard://ack?v=1&src=$ENC&pkg=nope" | jq -r '.ok, .error'; echo "rc=${PIPESTATUS[0]}"   # false / "nope in $SRC is not an active finding …"  rc=4
"$BIN" --resolve-link "hiveguard://strict-off?v=1" | jq -r .error; echo "rc=${PIPESTATUS[0]}"                   # This link asks for “strict-off”, which this app does not know. …  rc=4
"$BIN" --resolve-link "hiveguard://ack?v=2&src=$ENC&pkg=lodash" | jq -r .error                                   # Link format 2 is not supported — …
printf '#!/bin/sh\necho "unknown command: status (see: hiveguard help)" >&2; exit 2\n' > "$T/oldhg"; chmod +x "$T/oldhg"
HIVEGUARD_BIN="$T/oldhg" "$BIN" --resolve-link "hiveguard://ack?v=1&src=$ENC&pkg=lodash" | jq -r .error; echo "rc=${PIPESTATUS[0]}"   # Cannot check the link against hiveguard: hiveguard is too old …  rc=3
HIVEGUARD_BIN=/nonexistent "$BIN" --resolve-link "hiveguard://ack?v=1&src=$ENC&pkg=lodash" >/dev/null; echo "rc=$?"   # rc=3
"$BIN" --resolve-link 2>/dev/null; echo "rc=$?"                                                                   # rc=2
[ "$before" = "$(ls -A "$HOME/.hiveguard" | sort | tr '\n' ' ')" ] && echo nothing-written                        # nothing-written (no menubar.*, no ack/pause changes)
"$HG/bin/hiveguard" ack --list | grep -c 'No acknowledgements'                                                    # 1
command make app >/dev/null && dist/HiveGuard.app/Contents/MacOS/HiveGuard --resolve-link "hiveguard://ack?v=1&src=$ENC&pkg=lodash" | jq -r .ok   # true  (from the bundle too)
grep -c 'func application(_ application: NSApplication, open urls: \[URL\])' Sources/HiveGuard/HiveGuardApp.swift   # 1
grep -c 'onOpenURL\|NSAppleEventManager' Sources/HiveGuard/*.swift                                                 # 0 each
grep -c 'Report link ignored' Sources/HiveGuard/HiveGuardApp.swift; grep -c 'pendingLinks' Sources/HiveGuard/HiveGuardApp.swift   # ≥2 / ≥3
grep -c 'resolve-link' Sources/HiveGuard/main.swift                                                                # ≥1
ls -A "$HOME/.hiveguard" | grep -c menubar                                                                         # 0
```

**Do not:** run the UI from `dist/` against the real HOME in this task; add menu items for
link actions; handle a link without a fresh refresh; use `lastGood` for validation; touch
`Confirmations.swift`, `MenuContent.swift`, `Sources/HiveGuardCore/*`.

---

### Wave 3 (A10) — after wave 2 is verified and committed in both repos

---

#### A10 — e2e: report link round-trip against the real engine; fixture honesty with `active`

- **Model:** sonnet
- **Owns:** `APP/Tests/e2e.test.sh`
- **Depends on:** H5, H6 (in `HG`), A7, A8, A9. Runs against `HIVEGUARD_REPO=$HG` before
  gate G4 and against the main checkout after it.

**Do:**

1. `seed_red` gains the `active` block of seed v2 (so the fixture-honesty path set includes
   `active.0.*`).
2. New section **4. Report links** (app "running" = `$$` in `$HIVEGUARD_APP_PID`, strict
   on, `reset_scan`, `scan run1`, `scan run2` with the real engine):
   - `ack_href="$(grep -o 'hiveguard://ack?v=1&amp;src=[^"]*&amp;pkg=fast-uri' "$REPORT" | head -n1 | sed 's/&amp;/\&/g')"`
     → `"$APP_BIN" --resolve-link "$ack_href"` → `ok` true, rc 0, `.argv[0]` equals
     `jq -nc --arg s "$SRC" '["ack",$s,"fast-uri"]'`, `.confirm.title` =
     `Mark fast-uri 3.0.1 as known?`.
   - project href → argv `["ack",$SRC]`.
   - pause 1h href (markers written by the real scan's `folder-mark sync`) → argv
     `["strict","pause","$T/proj/app","--for","1h"]`.
   - real `"$HG/bin/hiveguard" strict pause "$T/proj/app" --for 1h` → same href → rc 4,
     error contains `already paused`; `strict resume "$T/proj/app"`.
   - real `"$HG/bin/hiveguard" ack "$SRC" fast-uri` → `ack_href` → rc 4, error contains
     `not an active finding`; `ack_href` with `v=1` replaced by `v=2` → rc 4; project href
     with host replaced by `strict-off` → rc 4.
   - hygiene: `ls -A "$HOME/.hiveguard"` identical before/after every `--resolve-link`;
     `$T_LOG_NOTIFY` still absent; no `menubar.*`.
3. Keep every existing check; final summary line counts the new ones.

**Acceptance criteria:**

```bash
cd "$APP" && HIVEGUARD_REPO="$HG" command make e2e; echo "rc=$?"                                                   # all ok incl. "report links" lines, rc=0
HIVEGUARD_REPO=/nonexistent bash Tests/e2e.test.sh; echo "rc=$?"                                                   # clear message, rc=2
cp Tests/HiveGuardCoreTests/Fixtures/red-6.json "$T/bk"; jq 'del(.active)' "$T/bk" > Tests/HiveGuardCoreTests/Fixtures/red-6.json
HIVEGUARD_REPO="$HG" HIVEGUARD_APP_BIN=dist/HiveGuard.app/Contents/MacOS/HiveGuard bash Tests/e2e.test.sh >/dev/null 2>&1; echo "rc=$?"; cp "$T/bk" Tests/HiveGuardCoreTests/Fixtures/red-6.json   # rc≠0 (honesty check bites on active)
command make e2e; echo "rc=$?"                                                                                       # rc=0 only after gate G4 (main checkout has active[]); before it the active checks fail — expected
```

**Do not:** build inside the test; write under `HG`; change the seed beyond `active`.

---

## 4. Verification plan (orchestrator) and commit boundaries

Before wave 1, record the real machine's state (same block as the base plan section 4,
plus the LaunchServices and report facts):

```bash
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"
stat -f '%m %N' ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/strict-pauses.tsv ~/.hiveguard/config ~/Library/LaunchAgents/com.hiveguard.osv-daily.plist
ls -A ~/.hiveguard | sort > /tmp/hg-before.txt; md5 -q ~/.hiveguard/osv-projects.html > /tmp/hg-report-before.txt
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null | grep -c 'hiveguard:'   # record (0 expected before section 6)
git -C /Users/mh/Projects/Develop/hiveguard status --porcelain; git -C /Users/mh/Projects/Develop/hiveguard rev-parse --abbrev-ref HEAD   # clean / main
git -C "$HG" rev-parse --abbrev-ref HEAD; git -C "$APP" rev-parse --abbrev-ref HEAD                             # feat/report-app-actions / worktree-menubar-app
```

The spec and this plan are committed to `HG` on `feat/report-app-actions` **before**
dispatch (`docs: report → app actions design addendum and plan`), so the plan the agents
read is the committed one.

Run each task's acceptance block verbatim in a **fresh** 2.5 scaffold. Per wave:

### Wave 1

```bash
bash "$HG/tests/report-actions.test.sh" && bash "$HG/tests/osv-run.test.sh" && bash "$HG/tests/status.test.sh" && echo hg-wave1-ok
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # no FAIL lines (network test skipped per wave, G3 rule)
bash -n "$HG/bin/osv-daily" "$HG/bin/status"; grep -n 'declare -A\|\btimeout\b' "$HG/bin/osv-daily" "$HG/bin/status" "$HG"/tests/report-actions.test.sh   # no output
git -C "$HG" status --porcelain                              # bin/osv-daily bin/status docs/status-json.md tests/{report-actions,osv-run,status}.test.sh
(cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1)   # 0 / 0 failures
git -C "$APP" status --porcelain                             # A7's files only; no .build/ dist/
```

Commits:
- `HG` #1 `feat(daily): active findings in osv-run.json; report action buttons while the menu bar app runs` — `bin/osv-daily`, `tests/report-actions.test.sh`, `tests/osv-run.test.sh`
- `HG` #2 `feat(status): active[] and active_ids for report-link validation (additive, schema 1)` — `bin/status`, `docs/status-json.md`, `tests/status.test.sh`
- `APP` #5 `feat: decode status active[], hiveguard:// URL type, LaunchServices registration on install` — A7's files

### Wave 2

```bash
# H7 doc greps; A8 + A9 blocks (A9's needs HIVEGUARD_BIN="$HG/bin/hiveguard" and seed_red)
(cd "$APP" && command swift build -c release 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1)   # 0 / 0 failures, N ≥ 110
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # no FAIL lines
git -C "$HG" status --porcelain; git -C "$APP" status --porcelain    # H7's three files / A8+A9's files only
```

Commits:
- `HG` #3 `docs: report action links contract (docs/report-links.md), README, CHANGELOG` — `docs/report-links.md`, `README.md`, `CHANGELOG.md`
- `APP` #6 `feat: report links — parse, validate against status, always confirm, --resolve-link` — A8 + A9 files

### Wave 3

```bash
(cd "$APP" && HIVEGUARD_REPO="$HG" command make e2e); echo "rc=$?"     # rc=0
# full engine suite including the network test, once, before the G4 merge (G3 rule):
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # no FAIL lines
# non-leakage, whole effort:
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"   # same as recorded
stat -f '%m %N' ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/strict-pauses.tsv ~/.hiveguard/config ~/Library/LaunchAgents/com.hiveguard.osv-daily.plist   # unchanged (markers/run/report may have been refreshed by the REAL 10:00 scan — note it)
ls -A ~/.hiveguard | sort | diff /tmp/hg-before.txt -         # empty (or only what the real scheduled scan writes)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null | grep -c 'hiveguard:'   # same as recorded (nothing registered by tests)
```

Commit `APP` #7 `test: e2e report-link round-trip against a hiveguard checkout; seed carries active[]`.

Then stop every agent of the wave (session hygiene) and move to the gates.

**Note on the real scheduled scan:** it runs from the main checkout on `main` until G4.
After G4 it renders buttons whenever the app is running at 10:00 — product behaviour.

---

## 5. Gates

- **G3 (unchanged):** skip `strict-integration.test.sh` at wave boundaries; run the full
  suite including it once at the end, before G4.
- **G4 — engine merge:** after wave 3 is green, merge `feat/report-app-actions` into `main`
  in the main checkout (fast-forward), remove the worktree. From then on
  `~/bin/hiveguard` (main checkout) emits buttons when the app runs, and the app's `make
  e2e` default target (`../hiveguard` via the worktree fallback) passes. Release tagging is
  the maintainer's call (the CHANGELOG `[Unreleased]` carries the entries; the app's
  `minimumHiveguardVersionForLinks` names `1.7.0` — adjust in A7's constant if the number
  differs before tagging).
- **G5 — real-machine finish (section 6):** STOP and ask the maintainer before `make
  install`; proceed only on an explicit "go". The reinstall re-registers the scheme and
  relaunches the app.
- **G6 — app branch:** `worktree-menubar-app` → `main` in the app repo is the maintainer's
  call (no remote; nothing to push).

**Execution split:** engine tasks (H*) from the Claude session in the hiveguard worktree;
app tasks (A*) from the session in the app worktree. A7 needs only the contract; A8/A9 need
A7; A10 needs H5+H6 (via `HIVEGUARD_REPO=$HG` before G4).

---

## 6. Real-machine finish (orchestrator, ONLY after gate G5 is opened)

The only steps that touch the real HOME, LaunchServices, `~/Applications`, and may run
real `hiveguard ack` / `strict pause` on real data. Every mutation below has its undo line.

1. **Install and register.** `cd $APP && command make install`. Verify: `pgrep -x HiveGuard`
   (one pid), `ps -o comm= -p "$(pgrep -x HiveGuard)"` is under `~/Applications`,
   `cat ~/.hiveguard/menubar.pid` equals the pid,
   `lsregister -dump | grep -c 'hiveguard:'` ≥ 1 and the matching bundle path is
   `~/Applications/HiveGuard.app` (not `dist/`).
2. **Delivery + refusal (no side effects).** `open 'hiveguard://ack?v=1&src=%2Fnope&pkg=x'`
   → the app comes to front with "Report link ignored — x in /nope is not an active
   finding …"; `hiveguard ack --list` unchanged. If **no dialog** appears within a few
   seconds: the delegate method is not invoked on this system → stop; open task A11
   (Apple Event handler in `applicationWillFinishLaunching`, spec §3.2 fallback); do not
   patch inline.
3. **Cold launch.** Quit HiveGuard from the menu → `menubar.pid` gone. `open
   'hiveguard://pause?v=1&root=%2Fnope&for=1h'` → the app launches (icon appears) and shows
   the refusal ("not blocked by strict mode"); it stays running.
4. **Real buttons (maintainer's call — a real scan of `~/Projects`, several minutes,
   refreshes the real report):** `hiveguard daily --rescan` with the app running → open the
   report: active rows show *mark as known* + *copy*; project cards *mark project as
   known* (+ *pause strict 1 h / 2 h* if strict is on). Click *copy* → clipboard has the
   `hiveguard ack …` line. Click *mark as known* on a finding the maintainer is willing to
   ack (preferably a low one) → browser prompt → app dialog with the exact package,
   version, project and ids → **Cancel** → `hiveguard ack --list` unchanged → click again →
   confirm → `ack --list` shows it, the menu's count drops if it was unseen. Undo:
   `hiveguard ack --remove "<src>" <pkg>`.
5. **Pause via link** (strict on, a blocked project the maintainer names): *pause strict
   1 h* → dialog shows the marker summary → confirm → `hiveguard strict status` lists the
   pause; the link again → "already paused until HH:MM". Undo: `hiveguard strict resume
   "<root>"`.
6. **Not running → report as today** (optional, another real scan): quit the app,
   `hiveguard daily --rescan` → `grep -c act-link ~/.hiveguard/osv-projects.html` → 0;
   relaunch via `open ~/Applications/HiveGuard.app`.
7. **Rollback (always available):** `cd $APP && command make uninstall` → `lsregister -dump
   | grep -c 'hiveguard:'` → 0, `open 'hiveguard://ack?v=1&src=%2Fx&pkg=y'` → LaunchServices
   reports no application; hiveguard's own notification and the plain report return on
   the next scan.
8. Record the outcome; no ad-hoc patches — a defect becomes a task.

---

## 7. Out of scope / follow-ups (open as issues, do not implement here)

- Extending a running pause from a link (currently refused by design).
- A "copy all selected" bulk action through the app.
- Unmute (`ack --remove`) from the report via the app — excluded by product decision 1.
- Refreshing the report page after an action (it would need a reload hook; the next scan
  does it).
- A `doctor` check that the `hiveguard://` scheme is registered to the installed bundle.

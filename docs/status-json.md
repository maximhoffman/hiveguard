# `hiveguard status --json` — contract (schema 1)

Owner: hiveguard; consumed by the companion menu bar app (separate repo).

This file is the normative description of the document printed by
`hiveguard status --json` (`bin/status`). It changes in the **same commit** as
`bin/status`. The app repository never redefines the format — it links here.
Background and rationale: `docs/superpowers/specs/2026-10-07-menubar-app-design.md`
(section 2.5).

## Compatibility rule

- `schema` is an integer. **Additive** changes (a new key anywhere, a new value in
  an existing field) keep the number. **Breaking** changes (a key removed,
  renamed, retyped, or a change of meaning) bump it.
- The app declares the schema range it supports (initially exactly `1`). A
  document whose `schema` is missing or outside that range is **not** interpreted:
  the app shows yellow "unsupported status format" and tells the user which side
  to update. The app ignores keys it does not know.
- A hiveguard without the `status` subcommand is detected by the dispatcher's
  `unknown command: status` on stderr with exit 2 → yellow "hiveguard is too old".

## Invocation

- `hiveguard status --json` prints one compact JSON object on one line, exit 0.
- `hiveguard status` prints a short human summary derived from the same document
  (not a contract; not used by the app). Bad arguments exit 2.
- Read-only: it never writes a file, never prunes expired strict pauses (it only
  filters them out of the output), and calls `launchctl` with `print` only.
- Absent inputs are reported as `null` (or an empty array / `false`, as listed
  below) — a key is never missing.

## Fields

Types: `int` = JSON integer, `number` = JSON number, `epoch` = int Unix seconds.
"Nullable" means the value may be `null`; the key itself is always present.

| Path | Type | Nullable | Meaning |
|---|---|---|---|
| `schema` | int | no | Format version of this document; `1` here. See the compatibility rule. |
| `hiveguard` | object | no | The installed engine. |
| `hiveguard.version` | string | no | What `hiveguard version` prints, without the ` (brew)` suffix (e.g. `v1.6.0`, `v1.5.0-3-gabc1234`). Empty string if it could not be determined. |
| `hiveguard.method` | string | no | Install method: `git` \| `brew` \| `unknown`. |
| `now_epoch` | epoch | no | The clock `status` used for every time comparison below. |
| `scan` | object | no | The daily scan. |
| `scan.running` | bool | no | A scan is in progress: the scan pid file (`HIVEGUARD_SCAN_PID`, default `~/.hiveguard/osv-daily.pid`) exists and names a live process. |
| `scan.pid` | int | yes | That pid when `running`, else `null`. |
| `scan.last` | object | yes | Outcome of the last daily run that reached the scan step, from `osv-run.json` (`HIVEGUARD_RUN`). `null` when the file is absent or not a JSON object (no scan has completed yet). |
| `scan.last.ok` | bool | no | The scan produced results (scanner exit 0 or 1 and JSON output). |
| `scan.last.rc` | int | no | The scanner's exit code (`1` = vulnerabilities found, not an error). |
| `scan.last.error` | string | yes | When `ok` is false: the last lines of the scanner's stderr (newline-separated, progress lines removed); `null` otherwise or when there was no output. |
| `scan.last.started_epoch` | epoch | no | When the scanner started. |
| `scan.last.finished_epoch` | epoch | no | When the run finished and wrote its outcome. |
| `scan.last.stamp` | string | no | Human timestamp of the run, as in the report (`YYYY-MM-DD HH:MM`). |
| `scan.last.target` | string | no | The scanned folder(s), as `osv-daily` printed them. |
| `scan.last.counts` | object | yes | Verbatim the `counts` of `osv-last-scan.json`: `active` and `acked` blocks of `{projects, pkgs, vulns, crit}` (ints), plus `new_vulns` and `resolved_vulns` (ints). `null` when `ok` is false. |
| `scan.last.counts.active` | object | no | Unacknowledged findings: `{projects, pkgs, vulns, crit}`. |
| `scan.last.counts.acked` | object | no | Acknowledged findings, same shape as `active`. |
| `scan.last.counts.active.projects` | int | no | Projects with findings in that block (same for `acked.projects`). |
| `scan.last.counts.active.pkgs` | int | no | Affected packages in that block (same for `acked.pkgs`). |
| `scan.last.counts.active.vulns` | int | no | Advisory ids in that block (same for `acked.vulns`). |
| `scan.last.counts.active.crit` | int | no | Critical packages in that block (same for `acked.crit`). |
| `scan.last.counts.new_vulns` | int | no | Advisory ids new since the previous scan (the report's "new since last scan"). |
| `scan.last.counts.resolved_vulns` | int | no | Advisory ids gone since the previous scan. |
| `attention` | array of object | no | Findings that need the user: the run's `unseen` entries (new findings carried over until the report is opened) with each advisory id classified against the ack store (`HIVEGUARD_ACKS`, v1 or v2) by the same rule as the report — see "Ack rule". Entries with no open id are dropped. Sorted by `sev` descending, then `project`, then `pkg`. `[]` when there is no run. |
| `attention[].src` | string | no | The manifest/lockfile path the finding came from. |
| `attention[].root` | string | no | The project root the finding belongs to. |
| `attention[].project` | string | no | Display label for `root`: `$HOME/Projects/` stripped, else `$HOME` shown as `~`, else the path unchanged. |
| `attention[].pkg` | string | no | Package name. |
| `attention[].version` | string | no | Installed version. |
| `attention[].eco` | string | no | Ecosystem (`npm`, `PyPI`, …). |
| `attention[].sev` | number | no | Highest CVSS-style severity of the package fragment (0 when unknown). |
| `attention[].crit` | bool | no | `sev >= 9`. |
| `attention[].fix` | string | no | First fixed version, `""` when none is known. |
| `attention[].ids_open` | array of string | no | Advisory ids not covered by an ack (never empty). |
| `attention[].ids_acked` | array of string | no | Advisory ids of this entry already covered by an ack. |
| `attention[].anchor` | string | no | Report anchor of the package row, `f-<12 hex>`; pass to `hiveguard daily --open --at`. |
| `attention[].project_anchor` | string | no | Report anchor of the project card, `p-<12 hex>`. |
| `attention_ids` | int | no | Sum of `ids_open` lengths over `attention` — the red count. |
| `report` | object | no | The HTML report. |
| `report.path` | string | no | `~/.hiveguard/osv-projects.html` (absolute). |
| `report.exists` | bool | no | The report file exists. |
| `report.opened_epoch` | epoch | yes | When the report was last opened through hiveguard, from `HIVEGUARD_REPORT_OPENED` (default `~/.hiveguard/osv-report-opened`); `null` when absent or not an integer. |
| `schedule` | object | no | The scheduled daily scan (launchd agent `com.hiveguard.osv-daily`). |
| `schedule.configured` | bool | no | The agent's plist exists (`HIVEGUARD_SCHED_PLIST`, default `~/Library/LaunchAgents/com.hiveguard.osv-daily.plist`). |
| `schedule.loaded` | bool | no | `launchctl print gui/<uid>/com.hiveguard.osv-daily` succeeds. |
| `schedule.hour` | int | yes | Scheduled hour (0–23) from the plist; `null` when not configured. |
| `schedule.minute` | int | yes | Scheduled minute (0–59); `null` when not configured. |
| `schedule.folders` | array of string | no | The scheduled folders, XML-unescaped; `[]` when not configured. |
| `strict` | object | no | Strict mode (terminal-level guard). |
| `strict.enabled` | bool | no | `strict=1` in the config (`HIVEGUARD_CONFIG`). |
| `strict.hook_sourced` | bool | no | `~/.zshrc` sources `hiveguard-hook.zsh`. |
| `strict.hook_hint` | string | yes | When the hook is not sourced: the line to add, `source "<path to hiveguard-hook.zsh>"` (same resolution as `hiveguard strict`); `null` when sourced. |
| `strict.blocked` | array of object | no | Projects strict mode currently refuses: marker rows (`HIVEGUARD_MARKERS`) with status `active`. |
| `strict.blocked[].root` | string | no | Project root. |
| `strict.blocked[].summary` | string | no | The marker summary, e.g. `12 active vulnerabilities (1 critical)`. |
| `strict.blocked[].crit_pkgs` | int | no | Critical packages: `osv-run.json` `roots[root].crit_pkgs`, else parsed from the summary's `(N critical)`, else `0`. |
| `strict.paused` | array of object | no | Running pauses (`HIVEGUARD_PAUSES`): rows whose until-epoch is still in the future. Expired and malformed rows are omitted (the file is not rewritten). |
| `strict.paused[].root` | string | no | Paused project root. |
| `strict.paused[].until_epoch` | epoch | no | When the pause ends. |
| `app` | object | no | The companion menu bar app. |
| `app.running` | bool | no | The app pid file (`HIVEGUARD_APP_PID`, default `~/.hiveguard/menubar.pid`) names a live process. |

### Ack rule

For an `unseen` entry `(src, pkg, ids)`, an id is acked iff

- `acks.projects[src]` exists and (its `ids` is `null`, or `ids[pkg]` contains the id), or
- `acks.packages[src][pkg]` exists and (its `ids` is `null`, or `ids` contains the id).

A v1 store (arrays) reads as v2 with every entry open-ended (`ids: null`). A
missing or unreadable store acks nothing. Acks apply live: `hiveguard ack …` is
reflected by the next `status` call, no rescan needed.

### Example

```json
{"schema":1,"hiveguard":{"version":"v1.6.0","method":"git"},"now_epoch":1791400000,
 "scan":{"running":false,"pid":null,"last":{"ok":true,"rc":1,"error":null,"started_epoch":1791392770,
   "finished_epoch":1791392800,"stamp":"2026-10-07 10:00","target":"/Users/mh/Projects",
   "counts":{"active":{"projects":1,"pkgs":2,"vulns":4,"crit":1},"acked":{"projects":0,"pkgs":0,"vulns":0,"crit":0},
             "new_vulns":4,"resolved_vulns":0}}},
 "attention":[{"src":"/Users/mh/Projects/x/app/package-lock.json","root":"/Users/mh/Projects/x/app","project":"x/app",
   "pkg":"lodash","version":"4.17.20","eco":"npm","sev":9.1,"crit":true,"fix":"4.17.21",
   "ids_open":["GHSA-…"],"ids_acked":[],"anchor":"f-3f2a9c1d0b7e","project_anchor":"p-9a1b2c3d4e5f"}],
 "attention_ids":1,
 "report":{"path":"/Users/mh/.hiveguard/osv-projects.html","exists":true,"opened_epoch":null},
 "schedule":{"configured":true,"loaded":true,"hour":10,"minute":0,"folders":["/Users/mh/Projects"]},
 "strict":{"enabled":true,"hook_sourced":true,"hook_hint":null,
   "blocked":[{"root":"/Users/mh/Projects/x/app","summary":"4 active vulnerabilities (1 critical)","crit_pkgs":1}],
   "paused":[]},
 "app":{"running":true}}
```

## Schema history

| Schema | Date | Change |
|---|---|---|
| 1 | 2026-10 | initial |

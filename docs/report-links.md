# Report action links — contract (version 1)

Owner: hiveguard; consumed by the companion menu bar app (separate repo), which links
here instead of redefining the format.

This file is the normative description of the `hiveguard://` links that the daily
report (`bin/osv-daily`) puts on its buttons. It changes in the **same commit** as
`bin/osv-daily`. Background and rationale:
`docs/superpowers/specs/2026-10-09-report-app-actions-design.md` (section 1). The state
the app validates links against is described in [`docs/status-json.md`](status-json.md).

## When links are emitted

- Only while the companion app is running at report time (its presence pid file is
  alive — the same check the notifier handoff uses).
- Never in `--probe` reports (those are internal to strict mode).
- `pause` links only when strict mode is on and the project root is one strict would
  actually block.
- Otherwise the report carries no links and looks exactly as it did before links existed.
- Only the Active section has link buttons; the Acknowledged section is unchanged.

## Grammar

```
hiveguard://<action>?v=1&<params>
  ack          src=<manifest path>  pkg=<package name>       -> hiveguard ack <src> <pkg>
  ack-project  src=<manifest path>                           -> hiveguard ack <src>
  pause        root=<project root>  for=1h|2h                -> hiveguard strict pause <root> --for <for>
```

| Action (URL host) | Parameters (in this order) | Meaning | Engine verb the app runs |
|---|---|---|---|
| `ack` | `src`, `pkg` | mark one finding (package) as known | `hiveguard ack <src> <pkg>` |
| `ack-project` | `src` | mark every finding of that manifest as known | `hiveguard ack <src>` |
| `pause` | `root`, `for` (`1h` or `2h`) | pause strict mode for that project | `hiveguard strict pause <root> --for <for>` |

- `src` is the manifest/lockfile path, the same string the report's copy buttons put
  into `hiveguard ack` (the key of the ack store). `root` is the realpath'd project
  root that Finder markers and strict mode use (the `strict.blocked[].root` of
  `status --json`). Both are absolute paths.
- `v` is the link-format version, an integer; always emitted first.
- Unknown parameters are ignored. A parameter given twice is an error.

## Encoding

- Values are percent-encoded per RFC 3986 with nothing safe beyond the unreserved set
  (`A-Z a-z 0-9 - _ . ~`): python `urllib.parse.quote(value, safe="")`.
- `/` becomes `%2F`, a space `%20`, non-ASCII characters their UTF-8 bytes. `+` is never
  emitted and never means a space.
- Emission: `"&".join(k + "=" + quote(v, safe="") for k, v in params)`, then
  `href = "hiveguard://" + action + "?v=1&" + q`.
- Inside an HTML attribute the whole href is HTML-escaped (`&` becomes `&amp;`).
- Decoding: scheme `hiveguard` (case-insensitive), the host (lower-cased) is the action,
  the query items are the percent-decoded parameters.

## Versioning

- The consumer declares the range of `v` it supports (initially exactly `1`). A link
  without `v` is treated as version 1; a `v` that is not an integer, or lies outside the
  supported range, is refused.
- **Additive** changes (a new action, a new optional parameter) keep `v`. A consumer
  refuses an action it does not know, and ignores a parameter it does not know.
- **Breaking** changes (a parameter removed, renamed or re-meant) bump `v` and add a row
  to the History table below.
- Anything that does not parse is refused with the specific reason: wrong scheme, no
  action, duplicate or missing parameter, a relative `src`/`root`, `for` outside
  `1h`/`2h`. Nothing runs in any refusal.

## What the app does with a link

Any web page can fire a custom-scheme URL, so every link is treated as untrusted input.

- It always asks for confirmation, showing the exact scope (project, package and
  version, advisory ids or counts), even where the menu would not ask.
- It validates the link against the current `hiveguard status --json` before the dialog
  appears: for `ack` / `ack-project` the finding or project must be in `active`; for
  `pause` strict must be on, the root must be in `strict.blocked`, and not already
  paused. Otherwise it refuses with an explanation and changes nothing.
- An engine whose status has no `active` key cannot validate `ack` links; they are
  refused as "hiveguard too old".
- It runs only the engine verb in the grammar table, never any other.
- The report is static: it does not update after an action, only at the next scan.

## The `copy` fallback

Next to every link button the report keeps a small `copy` button holding the terminal
command that does the same thing. It copies to the clipboard exactly as the plain
buttons did before links existed, and works without the app.

## Examples

```
hiveguard://ack?v=1&src=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp%2Fpackage-lock.json&pkg=lodash
hiveguard://ack-project?v=1&src=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp%2Fpackage-lock.json
hiveguard://pause?v=1&root=%2FUsers%2Fmh%2FProjects%2Fx%2Fapp&for=2h
```

## History

| Version | Date | Change |
|---|---|---|
| 1 | 2026-10 | initial |

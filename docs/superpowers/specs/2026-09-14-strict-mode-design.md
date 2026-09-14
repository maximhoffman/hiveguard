# Strict mode — design

Status: approved (product), ready for task breakdown
Date: 2026-09-14

## Problem

`hiveguard daily` already flags projects that have open vulnerabilities: it tags
the folder red in Finder and prints a one-line reminder when you `cd` into it.
Both signals are passive. Weeks later, having forgotten the notification, the
maintainer starts the project anyway.

Strict mode turns that passive reminder into a refusal: while a project is
flagged, the commands that would run or change it do not execute.

## Scope of protection (stated honestly)

Strict mode is a **terminal-level** guard. It cannot stop:

- an IDE "Run" button, a double-click, Docker Desktop,
- a process that is already running,
- anything outside the shell session where the guard is loaded.

It is a discipline tool ("don't run this by accident"), not a sandbox. The
README and the install prompt must say so in one line; overclaiming here is a
product bug.

## Behaviour

### Trigger

A project is blocked when it is **red** — exactly the signal that already drives
the Finder tag and the `chpwd` reminder: a marker row with status `active`
(unacknowledged findings). No new severity threshold, no new config knob.

- `acked` → not blocked.
- A new, not-yet-acknowledged advisory flips a project back to `active` → blocked
  again. This falls out of the existing advisory-scoped ack model; no new logic.
- Nesting: the innermost matching root wins (same rule the existing hook uses).

### What is intercepted

Everything that runs or mutates the project: run/build/test commands and package
manager commands (install, update, remove — **no repair exemption**, see below).

Not intercepted: `git`, editors, navigation, file inspection, and all `hiveguard`
/ `hvg` subcommands (the tool must always be able to scan, ack, pause, report).

**No exemption for repair commands.** The maintainer explicitly chose the simple
rule: everything is blocked; to fix the project you first take a pause. Do not
add a "but `npm update` is allowed" carve-out.

### What the refusal looks like

The command does not execute. In its place, a short message:

- what was found and how many (reuse the marker row's summary),
- where to see detail (`hiveguard daily --open`),
- the two ways forward: fix it, or pause this project.

No prompt, no waiting, no network on this path. Refusal is instant.

Exit status must be non-zero so a calling script stops rather than continues.

### Pause

One command releases **one project** for **one hour** by default; the duration is
overridable.

- Time-based, not shell-based: closing the terminal does not end the pause, and a
  new terminal honours the still-running pause.
- Expires on its own. Nothing to remember, nothing to switch back.
- Can be lifted early.
- Other projects stay protected for the whole pause.

### Unknown or stale projects

If there is no data for the project, or the data is older than 7 days: **do not
block and do not prompt.** The command runs immediately; a scan is kicked off in
the background; if it finds something, the usual notification fires and the
project turns red — so the *next* attempt is blocked.

Rationale: the hot path must never wait on a scan.

Suggested derivation, to be confirmed during implementation: the last-scan state
file already records the scanned `target` folders and a `stamp`. A project that
sits under a scanned target, with a stamp inside the freshness window, counts as
"known" — a clean project legitimately has no marker row. A project outside every
target, or under a stale stamp, counts as "unknown". This needs no new state file
if it holds; if it does not, add the minimum needed.

Background scans must be debounced: one project must not trigger repeated scans
on every command. Record the attempt and do not re-trigger for that project
within the freshness window.

### Visibility

A status view: whether strict mode is on, which projects are currently paused and
until when.

### Enabling

- Off by default. With it off, nothing about current behaviour changes.
- The installer asks once, explicitly, with a one-line explanation and the
  honest limitation; default answer is no.
- On/off by a single command at any time.
- `doctor` should report strict mode's health (enabled but shell integration not
  loaded is the obvious failure to catch).

## Implementation notes for the breakdown

These are constraints, not a design. The task breakdown owns the design.

- **Hot path is a shell hook.** The existing `bin/hiveguard-hook.zsh` is
  zsh-builtins-only by deliberate policy: no forks, no `jq`/`awk`/`python` on
  every prompt. Strict mode's check runs on every intercepted command and must
  hold the same bar.
- **Composition with the bumblebee guard is mandatory.** `bin/bumblebee-guard.sh`
  already defines shell functions shadowing `npm`/`pnpm`/`yarn`/`bun`/`pip`/`go`.
  Strict mode must layer with it in either load order and must not disable the
  supply-chain check. Whichever wrapper wins, both checks must run.
- **State.** Existing files: `~/.hiveguard/osv-markers.tsv` (root/status/summary),
  `~/.hiveguard/config` (key=value), `~/.hiveguard/osv-last-scan.json`. Pauses
  need somewhere to live; prefer the existing config/state conventions and the
  existing `HIVEGUARD_*` env overrides so tests can run in isolation.
- **Testability.** Every new state path needs an env override, following
  `HIVEGUARD_ACKS` / `HIVEGUARD_STATE` / `HIVEGUARD_MARKERS` / `HIVEGUARD_CONFIG`.
  Tests must never touch the real `~/.hiveguard` or the real launchd label.
- **bash 3.2.** No associative arrays; an empty array under `set -u` explodes.
- **Docs.** README subcommand table, the help text the dispatcher parses,
  CHANGELOG under `## [Unreleased]`.
- **Homebrew.** Any new file under `bin/` must ship in the formula's install list.

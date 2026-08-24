# Changelog

All notable changes to hiveguard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
adhere to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- `hiveguard mark hook` now prints a comment plus a ready-to-run append
  command, not just the bare `source` line.

## [1.1.0] - 2026-08-24

### Added
- **Folder markers** (`hiveguard mark`): each daily scan marks flagged project
  folders with a Finder tag (red for active vulnerabilities, yellow for
  acknowledged-but-still-present, cleared once a project is clean), plus an
  opt-in terminal reminder that warns when you `cd` into a flagged project.
  `hiveguard mark status|on|off|clear|hook` manages it; `mark clear` removes
  everything hiveguard placed (run it before uninstalling).

### Changed
- Release notes are now generated automatically from this changelog on each
  version tag (a GitHub Release is created by CI).

### Fixed
- Formula: the descriptive comment no longer swallows the `url`/`sha256`
  placeholders when the CI renders it.

## [1.0.1] - 2026-08-24

### Fixed
- The daily scan no longer defaults to the whole home folder. A background
  launchd agent on macOS cannot read protected folders (Documents / Desktop /
  Downloads) without Full Disk Access, so a whole-home scan silently found
  nothing and reported `0`. Both `hiveguard daily` and `hiveguard schedule on`
  now require at least one explicit folder and fail with a clear message instead
  of the broken silent fallback.
- Crash (`unbound variable` under `set -u`) when the target folder list was
  empty.

## [1.0.0] - 2026-08-21

Initial Homebrew release.

### Added
- Single `hiveguard` entry point: `add` / `scan` / `daily` / `brew` / `ack` /
  `schedule` / `doctor` / `update`, plus the short `hvg` alias.
- Homebrew distribution via the `maximhoffman/hiveguard` tap
  (`brew install maximhoffman/hiveguard/hiveguard`), with the formula published
  automatically on each release tag.
- `hiveguard daily`: OSV scan → HTML report + macOS notification. On a manual
  re-run it opens today's report and offers to rescan, and recovers the last
  scan's summary on demand.
- **New since last scan**: each scan diffs against the previous one and flags
  new advisories in the report, the notification, and the log.
- **Advisory-scoped acknowledgements** (`hiveguard ack`): muting accepts the
  advisories known at ack time; a genuinely new advisory still surfaces and
  alerts — *new pierces the mute*. Legacy mutes are grandfathered.
- `hiveguard schedule on|off|status`: user-configurable daily scan (time +
  folders) with boot/wake catch-up.
- `hiveguard doctor` (+ `--fix`): install/migration health checks and safe,
  reversible repairs.
- `hiveguard brew`: changelogs of outdated Homebrew formulae before upgrading,
  each with a package description and a copy-ready upgrade command.
- Two independent protection layers: the bumblebee install-time gate and OSV
  on-demand/scheduled scanning.

### Changed
- `hiveguard update` runs `brew upgrade` on a Homebrew install, and `git pull` +
  reinstall on a source checkout.

### Removed
- The `hg` short alias (it collided with Mercurial's `hg`); `hvg` remains.

[Unreleased]: https://github.com/maximhoffman/hiveguard/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/maximhoffman/hiveguard/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/maximhoffman/hiveguard/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/maximhoffman/hiveguard/releases/tag/v1.0.0

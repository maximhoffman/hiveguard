# 🐝 hiveguard

**Supply-chain safety for local dev on macOS** — two independent layers of protection
around the packages you install, behind one `hiveguard` command.

- **Install-time gate** ([bumblebee](#prerequisites)) — before a package is allowed to
  run its install scripts, it's checked against a known-compromised catalog.
- **On-demand & scheduled scanning** ([OSV](https://osv.dev)) — everything already on
  disk is scanned against the OSV database (vulnerabilities **and** malicious packages).

Neither replaces the other. bumblebee stops malware *at the moment of install*; OSV
catches *newly-disclosed* issues in what's already installed, using a *different*
database. hiveguard runs them together.

---

## Why two layers

Think in two axes — they're orthogonal:

| | bumblebee | osv-scanner |
|---|---|---|
| **Malicious packages** | ✅ own threat catalog | ✅ `MAL-` records from OSV |
| **Regular vulnerabilities (CVE)** | ❌ | ✅ |
| **Protects at install moment** | ✅ blocks install scripts | ❌ |
| **Scans what's already installed** | ❌ | ✅ |

The databases are **independent**, so something missing from one can be present in the
other. That's why running both — even on the same ecosystem — increases coverage.

Blind spot for **both**: a true zero-day not yet in any database.

---

## What's in the box

`hiveguard` is the single command. `hg` and `hvg` are short aliases (`hg brew` ==
`hiveguard brew`). Everything is a subcommand — there are no separate per-tool commands.

| Subcommand | What it does |
|---|---|
| `hiveguard add <mgr> <pkg>` | Install a package **only after** OSV clears it. Resolves the dependency tree *without installing*, scans it, then installs if clean. Layers on top of bumblebee. |
| `hiveguard scan [path]` | On-demand scan of a project (or global installs) for known vulnerabilities. Refreshes the bumblebee catalog too. |
| `hiveguard daily [path]` | The scheduled scan: one pass over `~/Projects` → compact HTML report + macOS notification on findings. Driven by a launchd agent at 10:00. |
| `hiveguard brew` | Before `brew upgrade`: one HTML page of changelogs for outdated formulae — **major** jumps highlighted, each formula with a one-line description and a copy-ready `brew upgrade` command. Changelogs are cached so re-runs skip the network. |
| `hiveguard ack <path> [pkg]` | Mute an old project (or a single finding) so it stops counting toward the report totals and the daily alert. Muted items move to a collapsed "Acknowledged" section — never dropped. |
| `hiveguard update` | Self-update: `git pull` the clone + re-run the installer (scripts **and** launchd agent). |

---

## Coverage by ecosystem

`hiveguard add`/`scan` cover what osv-scanner can read; bumblebee gates a subset at
install time.

| Ecosystem / manager | bumblebee (install-gate) | OSV (scan) | add mode |
|---|:---:|:---:|---|
| Node — npm / pnpm / yarn / bun | ✅ | ✅ | full tree |
| Python — pip | ✅ | ✅ | full tree |
| Python — uv / uv tool | ❌ | ✅ | full tree |
| Rust — cargo | ✅¹ | ✅ | coarse² |
| Go — go install | ✅ | ✅ | coarse² |
| Ruby — gem | ❌ | ✅ | coarse² |
| PHP — composer | ❌ | ✅ | coarse² |
| Homebrew — brew | ❌ | ❌ | use `hiveguard brew` |

¹ via `cargo audit`.  ² coarse = checks the named package via the OSV API (no full
dependency tree). Blocks on malicious (`MAL-`), warns on CVEs.

---

## Install

```bash
git clone https://github.com/maximhoffman/hiveguard.git
cd hiveguard
./install.sh            # links tools into ~/bin, schedules the daily scan at 10:00
```

Options:

```bash
./install.sh --no-agent      # don't install the launchd daily scan
./install.sh --hour 9        # daily scan at 09:00 instead of 10:00
```

The installer symlinks `hiveguard` (plus the short aliases `hg` and `hvg`) into `~/bin`,
backs up any pre-existing file of the same name, and writes reports/logs to
`~/.hiveguard/`. If you installed an older version that placed separate `safe-add` /
`deps-audit` / `osv-daily` / `brew-changelog` commands on your `PATH`, the installer
removes those obsolete links — everything is a `hiveguard` subcommand now.

**`~/bin` must be on your `PATH`.** If it isn't (the installer warns you), the commands
only resolve by full path. Add this to your `~/.zshrc` and open a new terminal:

```bash
export PATH="$HOME/bin:$PATH"
```

### Updating

`hiveguard` in `~/bin` is a **symlink** into your clone, so updating is just a pull:

```bash
hiveguard update       # git pull + re-run installer (scripts AND launchd agent)
```

Under the hood that's `git -C <repo> pull` followed by `install.sh`. Because the
command is a symlink, script changes take effect immediately; re-running the installer
also refreshes the launchd agent and cleans up any obsolete links. A changed report
layout (like collapsible projects) shows up on the **next scan** — wait for the daily
run, or trigger one now:

```bash
hiveguard daily        # regenerate ~/.hiveguard/osv-projects.html right away
```

If you'd rather not use the `hiveguard` command, the manual equivalent is:

```bash
cd /path/to/hiveguard && git pull && ./install.sh
```

### Prerequisites

Required:

```bash
brew install jq osv-scanner
```

Optional but recommended:

- **gh** (`brew install gh`, then `gh auth login`) — `hiveguard brew` uses it to pull
  release notes from GitHub.
- **bumblebee** — the install-time gate. It's a separate upstream tool: a Go binary
  plus a threat-intel catalog. Install the binary (`go install …`) and clone the
  catalog to `~/bumblebee-src`, then source the guard in your shell:

  ```bash
  # ~/.zshrc
  source "$HOME/bin/bumblebee-guard.sh"
  ```

  Without it, `hiveguard add`/`scan` still work (OSV layer only) — you just lose the
  install-moment gating on npm/pip/go/cargo.

---

## Usage

Everything runs through the single `hiveguard` command (or `hg` / `hvg`):

```bash
hiveguard add   npm react-router     # gated install
hiveguard scan  ~/Projects/app       # scan a project for known vulns
hiveguard daily                      # full scan → HTML report
hiveguard brew                       # changelogs before brew upgrade
hg brew                              # same thing, short alias
```

### `hiveguard add` — gated install

```bash
hiveguard add npm  react-router     # extra args pass through: hiveguard add npm react-router -g
hiveguard add pip  requests
hiveguard add uv   serena-agent     # uv tool install — covers the bumblebee gap
hiveguard add gem  nokogiri         # coarse (name-only) check

hiveguard add npm  lodash@4.17.4 --check-only   # scan only, don't install
hiveguard add npm  something --force            # install despite critical/MAL (deliberate)
```

Policy:

- **`MAL-` (malicious package)** → hard stop.
- **critical (CVSS ≥ 9)** → stop (override with `--force`).
- other CVEs → warn, install proceeds.

Example — a package with high-but-not-critical issues installs with a warning; one with
a critical CVE is blocked:

```
$ hiveguard add npm react-router@7.13.0 --check-only
vulnerable packages in tree: 1
  CVE   react-router@7.13.0   GHSA-2j2x-hqr9-3h42,GHSA-337j-9hxr-rhxg,…
⚠ vulnerabilities present (12; high: 6), none critical — proceeding

$ hiveguard add npm lodash@4.17.4 --check-only
  CRIT  lodash@4.17.4         GHSA-jf85-cpcp-j695,…
✖ critical (CVSS≥9): 1
Install cancelled. Override deliberately with --force
```

### `hiveguard scan` — scan on demand

```bash
hiveguard scan                 # scan the project in the current directory
hiveguard scan ~/Projects/app  # scan a specific project
hiveguard scan --global        # scan global installs (npm -g, uv tools)
hiveguard scan --no-refresh    # skip refreshing the bumblebee catalog
```

### `hiveguard daily` — the scheduled scan

```bash
hiveguard daily            # scan ~/Projects → HTML report + notification
hiveguard daily ~/work     # scan another tree
```

Report: `~/.hiveguard/osv-projects.html`. Log: `~/.hiveguard/osv-daily.log`.
The launchd agent (`com.hiveguard.osv-daily`) runs it daily; if the Mac was asleep,
launchd runs it on wake. Run it now to test:

```bash
launchctl kickstart -k gui/$(id -u)/com.hiveguard.osv-daily
```

The report groups findings by project, sorted by severity, with the fixed-in version and
osv.dev links for every advisory (theme-aware — adapts to light/dark):

![osv-daily report — vulnerabilities grouped by project and sorted by severity, each with max severity, fixed-in version, and links to osv.dev](docs/screenshots/osv-daily.png)

#### Muting old projects

An old project you don't run still has vulnerable pinned versions — but you don't need a
fresh alert about it every morning. **Mute** it: muted projects and findings stop counting
toward the totals and the notification, and move to a collapsed **Acknowledged** section
so nothing is ever lost.

```bash
hiveguard ack ~/Projects/old-app/package-lock.json          # mute a whole project
hiveguard ack ~/Projects/app/requirements.txt django        # mute one package/finding
hiveguard ack --list                                        # what's currently muted
hiveguard ack --remove ~/Projects/old-app/package-lock.json # bring it back
```

Every row in the report carries a **mute** button that copies the exact command for that
project or package — click, paste, run. Acknowledgements persist in
`~/.hiveguard/osv-acks.json`, so the next scan and the daily agent both honour them. When
everything found is acknowledged, the report shows zero and the daily notification stays
quiet. The `<path>` is the source path (lockfile/manifest) shown on each project row.

### `hiveguard brew` — read before you upgrade

```bash
hiveguard brew                 # all outdated formulae → HTML page, majors on top
hiveguard brew --no-update     # skip `brew update` first (faster)
hiveguard brew --refresh       # ignore the cache, refetch changelogs from GitHub
hiveguard brew --no-cache      # don't read or write the cache
ONLY=z3,ffmpeg hiveguard brew  # only these
```

Each formula card shows a **one-line description** (what the package is), its changelog
across the version range, and a **copy button** with the exact `brew upgrade <formula>`
command — click it, paste into your terminal, upgrade just that one. Nothing is upgraded
automatically — it's a read-first tool.

**Changelog cache.** Release notes are cached per formula + target version under
`~/.hiveguard/cache/brew-releases/`, so re-running within the TTL (default 6h) skips the
network. A real version bump changes the cache key and refetches — you never see a stale
changelog for a new upgrade. Tune with `BREW_CHANGELOG_TTL` (seconds) and
`BREW_CHANGELOG_CACHE` (dir); bypass with `--refresh` / `--no-cache`.

Major jumps are separated from minor/patch updates; each card carries the package
description, its changelog for the version range, and a copy-ready `brew upgrade` command:

![brew changelog report — outdated formulae with descriptions, version ranges, expandable release notes, and a copy-to-clipboard upgrade command; major jumps highlighted](docs/screenshots/brew-changelog.png)

---

## How `hiveguard add` resolves without installing

Per ecosystem it computes the full dependency tree **without touching your system**,
then scans the result:

- **npm/pnpm/yarn/bun** — `npm install <pkg> --package-lock-only --ignore-scripts` in a
  temp dir → `package-lock.json` → osv-scanner.
- **pip** — `pip install <pkg> --dry-run --report` → `requirements.txt` → osv-scanner.
- **uv** — `uv pip compile` → `requirements.txt` → osv-scanner.
- **others** — OSV API query on the named package (no tree).

If clean (or `--force`), it sources the bumblebee guard and runs the real install, so
on npm/pip/go/cargo you get **both** databases at once.

---

## Limitations

- Coarse mode (gem/cargo/go/composer) checks only the top-level package, not its
  dependencies. Full-tree support needs a lockfile-generation step per manager.
- OSV finds only **known** issues. A brand-new attack not yet in OSV (or the bumblebee
  catalog) passes.
- Paths assume Apple Silicon Homebrew (`/opt/homebrew`). Adjust `PATH` in the scripts
  for Intel Macs (`/usr/local`).
- The `real install` step of `hiveguard add` runs in the current directory — run it from
  the root of the target project, like a normal `npm install`.

---

## License

MIT — see [LICENSE](./LICENSE).

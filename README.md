# 🐝 hiveguard

**Supply-chain safety for local dev on macOS** — two independent layers of protection
around the packages you install, wrapped in four small commands.

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

| Tool | What it does |
|---|---|
| `safe-add` | Install a package **only after** OSV clears it. Resolves the dependency tree *without installing*, scans it, then installs if clean. Layers on top of bumblebee. |
| `deps-audit` | On-demand scan of a project (or global installs) for known vulnerabilities. Refreshes the bumblebee catalog too. |
| `osv-daily` | The scheduled scan: one pass over `~/Projects` → compact HTML report + macOS notification on findings. Driven by a launchd agent at 10:00. |
| `brew-changelog` | Before `brew upgrade`: collects changelogs of outdated formulae into one HTML page, **major** version jumps highlighted. |
| `hiveguard` | Single entry point — `add` / `scan` / `daily` / `brew` dispatch to the tools below, plus `update` to self-update. |

---

## Coverage by ecosystem

`safe-add`/`deps-audit` cover what osv-scanner can read; bumblebee gates a subset at
install time.

| Ecosystem / manager | bumblebee (install-gate) | OSV (scan) | safe-add mode |
|---|:---:|:---:|---|
| Node — npm / pnpm / yarn / bun | ✅ | ✅ | full tree |
| Python — pip | ✅ | ✅ | full tree |
| Python — uv / uv tool | ❌ | ✅ | full tree |
| Rust — cargo | ✅¹ | ✅ | coarse² |
| Go — go install | ✅ | ✅ | coarse² |
| Ruby — gem | ❌ | ✅ | coarse² |
| PHP — composer | ❌ | ✅ | coarse² |
| Homebrew — brew | ❌ | ❌ | use `brew-changelog` |

¹ via `cargo audit`.  ² coarse = checks the named package via the OSV API (no full
dependency tree). Blocks on malicious (`MAL-`), warns on CVEs.

---

## Install

```bash
git clone https://github.com/<you>/hiveguard.git
cd hiveguard
./install.sh            # links tools into ~/bin, schedules the daily scan at 10:00
```

Options:

```bash
./install.sh --no-agent      # don't install the launchd daily scan
./install.sh --hour 9        # daily scan at 09:00 instead of 10:00
```

The installer symlinks `bin/*` into `~/bin`, backs up any pre-existing files, and
writes reports/logs to `~/.hiveguard/`.

**`~/bin` must be on your `PATH`.** If it isn't (the installer warns you), the commands
only resolve by full path. Add this to your `~/.zshrc` and open a new terminal:

```bash
export PATH="$HOME/bin:$PATH"
```

### Updating

The tools in `~/bin` are **symlinks** into your clone, so updating is just a pull:

```bash
hiveguard update       # git pull + re-run installer (scripts AND launchd agent)
```

Under the hood that's `git -C <repo> pull` followed by `install.sh`. Because the
commands are symlinks, script changes take effect immediately; re-running the installer
also refreshes the launchd agent and re-links any newly added tools. A changed report
layout (like collapsible projects) shows up on the **next scan** — wait for the daily
run, or trigger one now:

```bash
osv-daily              # regenerate ~/.hiveguard/osv-projects.html right away
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

- **gh** (`brew install gh`, then `gh auth login`) — `brew-changelog` uses it to pull
  release notes from GitHub.
- **bumblebee** — the install-time gate. It's a separate upstream tool: a Go binary
  plus a threat-intel catalog. Install the binary (`go install …`) and clone the
  catalog to `~/bumblebee-src`, then source the guard in your shell:

  ```bash
  # ~/.zshrc
  source "$HOME/bin/bumblebee-guard.sh"
  ```

  Without it, `safe-add`/`deps-audit` still work (OSV layer only) — you just lose the
  install-moment gating on npm/pip/go/cargo.

---

## Usage

Everything is reachable through the single `hiveguard` command, or by calling each
tool directly — they're equivalent:

```bash
hiveguard add   npm react-router     # = safe-add npm react-router
hiveguard scan  ~/Projects/app       # = deps-audit ~/Projects/app
hiveguard daily                      # = osv-daily
hiveguard brew                       # = brew-changelog
```

### `safe-add` — gated install

```bash
safe-add npm  react-router          # extra args pass through: safe-add npm react-router -g
safe-add pip  requests
safe-add uv   serena-agent          # uv tool install — covers the bumblebee gap
safe-add gem  nokogiri              # coarse (name-only) check

safe-add npm  lodash@4.17.4 --check-only   # scan only, don't install
safe-add npm  something --force            # install despite critical/MAL (deliberate)
```

Policy:

- **`MAL-` (malicious package)** → hard stop.
- **critical (CVSS ≥ 9)** → stop (override with `--force`).
- other CVEs → warn, install proceeds.

Example — a package with high-but-not-critical issues installs with a warning; one with
a critical CVE is blocked:

```
$ safe-add npm react-router@7.13.0 --check-only
vulnerable packages in tree: 1
  CVE   react-router@7.13.0   GHSA-2j2x-hqr9-3h42,GHSA-337j-9hxr-rhxg,…
⚠ vulnerabilities present (12; high: 6), none critical — proceeding

$ safe-add npm lodash@4.17.4 --check-only
  CRIT  lodash@4.17.4         GHSA-jf85-cpcp-j695,…
✖ critical (CVSS≥9): 1
Install cancelled. Override deliberately with --force
```

### `deps-audit` — scan on demand

```bash
deps-audit                 # scan the project in the current directory
deps-audit ~/Projects/app  # scan a specific project
deps-audit --global        # scan global installs (npm -g, uv tools)
deps-audit --no-refresh    # skip refreshing the bumblebee catalog
```

### `osv-daily` — the scheduled scan

```bash
osv-daily            # scan ~/Projects → HTML report + notification
osv-daily ~/work     # scan another tree
```

Report: `~/.hiveguard/osv-projects.html`. Log: `~/.hiveguard/osv-daily.log`.
The launchd agent (`com.hiveguard.osv-daily`) runs it daily; if the Mac was asleep,
launchd runs it on wake. Run it now to test:

```bash
launchctl kickstart -k gui/$(id -u)/com.hiveguard.osv-daily
```

### `brew-changelog` — read before you upgrade

```bash
brew-changelog                 # all outdated formulae → HTML page, majors on top
brew-changelog --no-update     # skip `brew update` first (faster)
ONLY=z3,ffmpeg brew-changelog  # only these
```

Nothing is upgraded — it's a read-first tool. Review majors, then run `brew upgrade`.

---

## How `safe-add` resolves without installing

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
- The `real install` step of `safe-add` runs in the current directory — run it from the
  root of the target project, like a normal `npm install`.

---

## License

MIT — see [LICENSE](./LICENSE).

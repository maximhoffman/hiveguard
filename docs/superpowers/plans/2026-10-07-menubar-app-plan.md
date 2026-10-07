# Menu bar app — implementation plan

Status: ready to dispatch (design resolved, tasks agent-ready)
Date: 2026-10-07 (revised same day: app in its own repository)
Spec: `docs/superpowers/specs/2026-10-07-menubar-app-design.md` (approved product
design, commit `53d4998` + same-day revision)

This document is the design for implementers. Agents are dispatched straight from it
and must not redesign. Section 1 resolves the remaining architecture questions; section
2 is the shared contract (names, formats, signatures, test scaffold) every task must
match byte-for-byte; section 3 is the task list in waves, split by repository; section 4
is the orchestrator's independent verification per wave with commit boundaries per
repo; section 5 lists the gates still open with the maintainer; section 6 is the
real-machine finish that runs only on an explicit go-ahead.

Conventions used throughout:

- Two repositories, two paths:
  - `HG` = the engine. Work on branch `feat/menubar-support` in a **git worktree** at
    `/Users/mh/Projects/Develop/hiveguard/.claude/worktrees/menubar-support` (work
    format 2; built-in Read/Edit with absolute worktree paths, no Serena symbolic edits).
    Reason: the real launchd agent, the `hiveguard` on PATH and the strict-mode shell hook
    all run from the main checkout `/Users/mh/Projects/Develop/hiveguard`, so half-done
    engine edits must never sit in its working tree. The main checkout stays on `main`
    until gate G2 merges the branch.
  - `APP` = `/Users/mh/Projects/Develop/hiveguard-menubar` — the app, a **new local git
    repository** (created by task A0), branch `main`, no remote unless asked later.
    Nothing of the app lives in `HG`; nothing of the engine lives in `APP`.
- Parallel tasks in one wave are safe because **no two tasks in a wave write the same
  file**, and tasks in different repos never share files. Each task's "Owns" list is
  exhaustive and exclusive. Agents never run `git add`/`git commit`/`git checkout`/
  `git init`; the orchestrator does (A0 is the one exception: it runs `git init` because
  that *is* the task, and nothing else).
- Every test and every verification command runs with an **isolated HOME**
  (`HOME=$(mktemp -d)` canonicalised with `pwd -P`) and **all** the `HIVEGUARD_*`
  overrides of section 2.4, with `HIVEGUARD_TOOL_PATH` pointing at a stub directory, so
  no scan touches the network, no notification is sent, no `launchctl` call reaches the
  real domain, and the real `~/.hiveguard`, `~/.zshrc`, launchd agent
  `com.hiveguard.osv-daily`, Login Items and notification center are never touched.
  `doctor` is only ever run without `--fix`. The app binary is only ever run in tests
  with `--dump-state` (no status item, no notification center, no login item).
- The app's end-to-end test needs the engine: it takes `HIVEGUARD_REPO` (default
  `../hiveguard` relative to the app repo) and runs that checkout's real `bin/osv-daily`,
  `bin/status`, `bin/hiveguard` under the isolated HOME. With the sibling layout above the
  default resolves to `HG`.
- bash 3.2 everywhere (no associative arrays; guard empty arrays under `set -u` with
  `"${arr[@]+"${arr[@]}"}"`), no `timeout` (poll with `sleep 1`), BSD `date -r`, `awk`,
  `sed`, `shasum`, `md5 -q`, `stat -f %m`.
- `swift` and `make` are strict-mode-intercepted names. Both repos sit under the
  scheduled `~/Projects` and are not flagged, so they run; in a shell where the hook
  loaded only partially the wrapper fails with `command not found:
  _hiveguard_strict_gate` — use `command swift …` / `command make …` there (bypasses the
  shell function, not the policy: the project is green).
- Swift toolchain: Xcode 26.3 / Swift 6.2 at `/Applications/Xcode.app`, host macOS 15.8.

---

## 1. Architecture decisions (resolved)

### 1.1 Cross-repo contract: `hiveguard status --json` is versioned, hiveguard owns it

- The document carries `schema` (integer, initially `1`) and `hiveguard.version` /
  `hiveguard.method`. The normative description is `HG/docs/status-json.md` (new, task
  H2): field table with types and null-ability, the compatibility rule, schema history.
  `bin/status` and that file change in the same commit.
- Compatibility rule (verbatim in the doc): additive change → same `schema`; breaking
  change (key removed/renamed/retyped/re-meant) → bump. The app declares
  `supportedSchemas: ClosedRange<Int> = 1...1`; a document with `schema` missing or out of
  range is not interpreted → yellow `unsupported status format N`. Unknown keys are
  ignored by the app's decoder.
- Too-old detection: the dispatcher prints `unknown command: status (see: hiveguard
  help)` to stderr and exits 2 → the app maps `rc == 2 && stderr.contains("unknown
  command: status")` to `StatusError.tooOld` → yellow `hiveguard is too old`. Minimum
  version named in the menu = the first hiveguard release that ships `status` (the next
  release after 1.5.0; the app reads the string from a constant `minimumHiveguardVersion`).
- The hiveguard repo's suite never needs the app. The app repo's e2e test (task A6) is the
  drift detector: structural equality of key paths between the real document and the
  richest fixture, and equality of `schema`.

### 1.2 App repo layout and package structure

```
hiveguard-menubar/                   # APP
  .gitignore                         # .build/  dist/  .DS_Store  *.xcodeproj  .swiftpm/
  README.md                          # see spec §10; links ../hiveguard/docs/... by sibling path
  Package.swift                      # swift-tools-version 6.0; platforms: [.macOS(.v14)]
  Makefile                           # build | app | install | run | test | e2e | uninstall | clean
  Resources/Info.plist               # template; version patched by `make app`
  Sources/HiveGuardCore/             # library target, pure logic + Codable types + protocols, NO AppKit UI
    Status.swift                     # Codable mirror of status --json; schema check; StatusError
    Rules.swift                      # deriveState / confirmation / notificationDecision / cliArguments (pure)
    Services.swift                   # protocols: NotificationSink, LoginItemService, Presence; value types
    CLIRunner.swift                  # locate + run + spawnDetached (Foundation Process)
    AppModel.swift                   # @Observable @MainActor model: refresh, actions, watcher, timer
    DumpState.swift                  # `--dump-state`
  Sources/HiveGuard/                 # executable target (UI)
    main.swift                       # argv dispatch: --dump-state / --unregister-login-item / UI
    HiveGuardApp.swift  MenuContent.swift  IconLabel.swift  Confirmations.swift  DoctorWindow.swift
    UNNotifier.swift  SMLoginItem.swift  PidPresence.swift
  Tests/HiveGuardCoreTests/
    Fixtures/*.json                  # status documents (section 2.5)
    StatusDecodingTests.swift  RulesTests.swift  ConfirmationTests.swift  NotificationTests.swift  DumpStateTests.swift
  tests/e2e.test.sh                  # bash; needs HIVEGUARD_REPO (default ../hiveguard)
```

Library + executable: XCTest links the library (`@testable import HiveGuardCore`)
without AppKit scenes; the executable is a thin shell. `main.swift` (not `@main`) so
`--dump-state` exits before any `NSApplication`/`UNUserNotificationCenter` is touched —
the raw `swift build` binary is **unbundled** and `UNUserNotificationCenter.current()`
aborts outside a bundle, so UI mode is only ever launched from the `.app` made by
`make app`.

### 1.3 Bundle assembly (`make app`) and install (`make install`) — app repo

- `swift build -c release` → `.build/release/HiveGuard`.
- `make app`: create `dist/HiveGuard.app/Contents/{MacOS,Resources}`, copy the binary to
  `Contents/MacOS/HiveGuard`, render `Resources/Info.plist` with
  `CFBundleVersion`/`CFBundleShortVersionString` = `git describe --tags --always --dirty`
  of the **app** repo (falls back to `0.0.0-dev` with no tags), then
  `codesign --force --deep --sign - dist/HiveGuard.app`. Info.plist keys (exact):
  `CFBundleIdentifier com.hiveguard.menubar`, `CFBundleName HiveGuard`,
  `CFBundleExecutable HiveGuard`, `CFBundlePackageType APPL`, `LSUIElement true`,
  `LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable true`, `NSHumanReadableCopyright`.
- `make install`: `pkill -x HiveGuard || true`; `rm -rf ~/Applications/HiveGuard.app`;
  `mkdir -p ~/Applications`; `cp -R dist/HiveGuard.app ~/Applications/`;
  `open ~/Applications/HiveGuard.app`. Fixed path on purpose (login-item registration is
  tied to the bundle location).
- `make uninstall`: if the installed binary exists run it with `--unregister-login-item`
  (hidden flag → `SMAppService.mainApp.unregister()`, print status, exit), `pkill -x
  HiveGuard || true`, remove the bundle, remove `~/.hiveguard/menubar.pid`.
- `make run` = `open dist/HiveGuard.app`; `make test` = `swift test`; `make e2e` =
  `make app` then `HIVEGUARD_APP_BIN=dist/HiveGuard.app/Contents/MacOS/HiveGuard bash
  tests/e2e.test.sh`; `make clean`.

### 1.4 Icon rendering

A regular hexagon drawn with `Path` inside a `Canvas`, rendered to an `NSImage`
(18×18 pt, 2× scale) once per `IconState` case: calm = outline, `isTemplate = true`;
red = filled, `.systemRed`, with the count as `Text` after the image in the
`MenuBarExtra` label; yellow = filled with a small exclamation cut-out, `.systemYellow`;
scanning = outline with one of 4 arc segments highlighted, frame chosen by
`TimelineView(.periodic(from: .now, by: 0.25))`. The label is
`Label { Text(countOrEmpty) } icon: { Image(nsImage: frame) }`.

### 1.5 Refresh and concurrency

- `AppModel` is `@MainActor @Observable`: `status: Status?`, `statusError: StatusError?`,
  `derived: DerivedState`, `busyAction: MenuAction?`, `sentKeys: Set<NotificationKey>`,
  `lastGood: Status?`, `lastActionError: (MenuAction, String)?`.
- `refresh()` coalesces: in flight → set `pendingRefresh`; rerun once when done.
- Triggers: `DispatchSource.makeFileSystemObjectSource` on `open(~/.hiveguard, O_EVTONLY)`
  (`.write`), debounced 500 ms; a 60 s `Timer`; menu about to open; after every action.
  Missing directory → retry arming every 60 s.
- Actions run on a serial `actor ActionQueue`; `checkNow` is detached via
  `CLIRunner.spawnDetached` (stdin `/dev/null`, stdout+stderr appended to
  `~/.hiveguard/menubar.log`), polled every 1 s for termination; rc ≠ 0 → alert.
- `CLIRunner.run`: 30 s timeout (`terminate()`, then `kill -9` after 2 s), `rc = -1` on
  timeout, pipes drained asynchronously.

### 1.6 `status --json`: ack classification (exact) — hiveguard repo

For each `unseen` entry `(src, pkg, ids)` and each `id`:

```
acked(id) :=
   ( .projects[src] exists  and ( .projects[src].ids == null
                                   or ((.projects[src].ids[pkg] // []) | index(id)) != null ) )
or ( .packages[src][pkg] exists and ( .packages[src][pkg].ids == null
                                   or (.packages[src][pkg].ids | index(id)) != null ) )
```

The ack store is read through the same v1→v2 `to_v2` jq function `osv-ack` uses (copy
`MIGRATE` verbatim into `bin/status`). `ids_open` = not acked, `ids_acked` = the rest;
drop entries with empty `ids_open`; `attention_ids` = Σ `ids_open`; `crit` = `sev >= 9`;
sort by `sev` desc, then `project`, `pkg`.

### 1.7 `osv-daily`: `unseen` carry-over (exact) — hiveguard repo

In the report python, after `cur_findings` and `new_ids` are known (non-probe only):

```
prev     = json.load(RUN) if readable else None
opened   = int(open(OPENED).read().strip()) if readable else 0
carry    = prev["unseen"] if prev and opened < prev.get("finished_epoch", 0) else []
carry    = [e for e in carry if any((e["src"], e["pkg"], i) in cur_keys for i in e["ids"])]
           with each e["ids"] filtered to the ids still in cur_keys
merged   = { (e["src"], e["pkg"]): e for e in carry }
for n in this_run_new:                       # this run's metadata wins, ids unioned
    k = (n["src"], n["pkg"]); m = merged.get(k)
    merged[k] = n if m is None else {**n, "ids": sorted(set(m["ids"]) | set(n["ids"]))}
unseen   = list(merged.values()) sorted by sev desc, src, pkg
```

`this_run_new` = one entry per active package fragment with non-empty `new_ids`:
`{src, root: finding_root(src), pkg, version, eco, sev, fix, ids: new_ids, anchor,
project_anchor}`. On a failed run `unseen = prev["unseen"] if prev else []`.

### 1.8 Anchors (exact)

`h12(s) = hashlib.sha1(s.encode()).hexdigest()[:12]`; project card `id="p-"+h12(src)`;
package row `id="f-"+h12(src+"\0"+pkg)`. In bash: `printf '%s' "$src" | shasum | cut
-c1-12` and `printf '%s\0%s' "$src" "$pkg" | shasum | cut -c1-12`. Rows in both the
active and acknowledged sections carry ids; when the same `(src,pkg)` appears in both,
the active row wins the id and the acked row gets suffix `-k`.

### 1.9 `osv-daily` failure path (exact)

Non-probe, `SCAN_OK=0`: write `osv-run.json` (`ok:false`, `rc`, `error`, `counts:null`,
`roots:null`, `new:[]`, `unseen` carried), append `[$STAMP] FAILED rc=<rc> (<first error
line or "no output">)` to `osv-daily.log`, print the existing interactive warning
(unchanged), `echo "✖ scan failed (rc=<rc>) — previous report and state kept"`, exit 0.
**Skip**: the python report step, `folder-mark sync`, coverage (already skipped), the
notification. Stderr is captured to `$ERRFILE` in both branches (`2>"$ERRFILE"` replaces
`2>/dev/null` in the non-interactive branch). The probe path is untouched.

### 1.10 Decisions worth flagging (made, not deferred)

- `status` is **read-only** even where `strict status` prunes pauses: it filters expired
  rows in output and never writes. Tests assert the pause file's md5 is unchanged.
- The app passes **every** `HIVEGUARD_*` variable from its own environment to the CLI
  untouched and prepends `/opt/homebrew/bin:/usr/local/bin:$HOME/bin` to `PATH`. That is
  the only isolation mechanism for the app and it is sufficient for `--dump-state`.
- The app never looks for hiveguard relative to its own bundle or any checkout
  (`HIVEGUARD_BIN` → `~/bin` → brew prefixes, nothing else).
- `--dump-state` never constructs `UNNotifier`, `SMLoginItem` or `PidPresence`; it reports
  what the notification rule *would* send.
- Two app instances: `PidPresence.acquire()` returns `false` when the pid file names a
  live pid that is not ours → the second instance exits 0 silently.
- `Launch at login` is wired to `SMAppService` only when the bundle path contains
  `/Applications/`; from `dist/` it shows as disabled "(install first: make install)".
- The hiveguard CHANGELOG lists hiveguard-side changes only, plus one line that a
  companion app exists; the app repo has no CHANGELOG yet (personal, untagged).

---

## 2. Shared contracts (every task must match these exactly)

### 2.1 Names

| Thing | Name |
|---|---|
| Engine branch (in `HG`) | `feat/menubar-support` |
| App repo / branch | `/Users/mh/Projects/Develop/hiveguard-menubar` / `main` |
| Contract document (owner: hiveguard) | `HG/docs/status-json.md` |
| Run outcome file | `${HIVEGUARD_RUN:-$HOME/.hiveguard/osv-run.json}` |
| Scan pid file | `${HIVEGUARD_SCAN_PID:-$HOME/.hiveguard/osv-daily.pid}` |
| Report opened stamp | `${HIVEGUARD_REPORT_OPENED:-$HOME/.hiveguard/osv-report-opened}` |
| App presence pid file | `${HIVEGUARD_APP_PID:-$HOME/.hiveguard/menubar.pid}` |
| App log | `$HOME/.hiveguard/menubar.log` (fixed, like `strict.log`) |
| Tool stub PATH prefix | `HIVEGUARD_TOOL_PATH` (tests only) |
| CLI location override for the app | `HIVEGUARD_BIN` (existing name) |
| Engine checkout for the app's e2e test | `HIVEGUARD_REPO` (default `../hiveguard` relative to `APP`) |
| New subcommand / script | `hiveguard status [--json]` → `HG/bin/status` |
| New `daily` flag | `--at <anchor>` (only with `--open`; anchor `^[pf]-[0-9a-f]{12}$`) |
| Anchor ids | `p-<h12(src)>`, `f-<h12(src\0pkg)>` |
| launchd label (read-only use) | `com.hiveguard.osv-daily` |
| Bundle id / app name / executable | `com.hiveguard.menubar` / `HiveGuard` / `HiveGuard` |
| Install path | `$HOME/Applications/HiveGuard.app` |
| SPM targets | `HiveGuardCore` (library), `HiveGuard` (executable), `HiveGuardCoreTests` |
| Hidden app flags | `--dump-state`, `--unregister-login-item` |
| Supported schema range (app constant) | `supportedSchemas = 1...1` |
| Minimum hiveguard (app constant, shown in the too-old reason) | `minimumHiveguardVersion = "1.6.0"` (the release that ships `status`; update if the release number differs) |
| Stale-scan threshold | 36 h = 129600 s (`staleAfter: TimeInterval = 129_600`) |
| Pause durations offered | `1h`, `2h` (passed verbatim to `strict pause --for`) |
| Commit trailer (both repos) | `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` |

### 2.2 File formats (exact; the spec's JSON examples in §2.1 and §2.5 are normative)

- `osv-run.json` (schema 1): keys `schema, ok, rc, error, started_epoch, finished_epoch,
  stamp, target, counts, roots, new, unseen`. `counts` verbatim as in
  `osv-last-scan.json`. `roots[root] = {status, active_vulns, crit_pkgs, acked_vulns}`.
  Entry shape (`new`/`unseen`): `{src, root, pkg, version, eco, sev (number), fix
  (string, "" when none), ids [string], anchor, project_anchor}`. Written atomically
  (`.tmp` + `os.replace`); `started_epoch` taken right before `osv-scanner` starts,
  `finished_epoch` at write time.
- `osv-daily.pid`: decimal pid. Written right before the scanner starts, removed by the
  EXIT trap.
- `osv-report-opened`: one decimal epoch, newline-terminated, atomic (`printf > tmp; mv`).
- `menubar.pid`: decimal pid of the app.
- `status --json` (schema 1): keys and nesting exactly as spec §2.5 — top level
  `schema, hiveguard{version,method}, now_epoch, scan{running,pid,last}, attention[],
  attention_ids, report{path,exists,opened_epoch}, schedule{configured,loaded,hour,minute,
  folders}, strict{enabled,hook_sourced,hook_hint,blocked[],paused[]}, app{running}`.
  Absent inputs → `null` (`scan.last`, `report.opened_epoch`, `hook_hint`), never missing
  keys. `hour`/`minute` integers; `folders` XML-unescaped. `hiveguard.method` ∈
  `git|brew|unknown`.
- `status` human output (plain mode), exactly these lines in this order:
  `Last scan: <stamp> — ok — <N> project(s) with problems, <C> critical` |
  `Last scan: <stamp> — FAILED (rc=<n>) — <first error line>` | `No scan has completed yet`;
  `New findings: <ids> advisory id(s) in <pkgs> package(s)` | `New findings: none`;
  `Protection: ok` | `Protection: NOT WORKING — <reasons joined by "; ">` with reasons from
  {`daily scan not scheduled`, `agent not loaded`, `last scan failed`, `last scan <H>h ago`,
  `no scan yet`}; `Strict mode: on, <N> paused` | `Strict mode: off`;
  `Scan running: yes (pid <n>)` only when running.
- `--dump-state` output: one JSON line
  `{"icon":"calm|red|yellow|scanning","count":<int>,"reasons":[<string>…],"warning":<string|null>,"notify":{"kind":"red|yellow","title":"…","body":"…"}|null,"schema":<int|null>}`
  then exit 0; exit 3 when the status could not be obtained or is incompatible (icon is
  `yellow` and the line is still printed).

### 2.3 Swift API contract (`HiveGuardCore`)

```swift
public struct Status: Codable, Equatable { … mirrors status --json (snake_case → camelCase) … ; public static let supportedSchemas: ClosedRange<Int> = 1...1
  public static func decode(_ data: Data) throws -> Status   // throws StatusError.unsupportedSchema when schema missing/out of range, .decode on malformed JSON }
public enum StatusError: Error, Equatable { case cliNotFound(searched: [String]), tooOld(stderr: String), unsupportedSchema(found: Int?, supported: ClosedRange<Int>), exit(Int32, String), timeout, decode(String) }
public let minimumHiveguardVersion = "1.6.0"
public enum YellowReason: Equatable { case cliNotFound([String]), tooOld, unsupportedSchema(found: Int?), statusUnreadable(String), scheduleOff, scheduleNotLoaded, neverScanned, lastScanFailed(String), stale(hours: Int) }
public enum IconState: Equatable { case calm, scanning, red(count: Int), yellow(YellowReason) }
public struct DerivedState: Equatable { public let icon: IconState; public let warning: YellowReason?; public let attention: [AttentionEntry]; public let schema: Int? }
public func deriveState(_ input: Result<Status, StatusError>, now: Date, checkNowRunning: Bool) -> DerivedState

public enum MenuAction: Equatable { case ackFinding(AttentionEntry), ackProject(root: String), pause(root: String, duration: String), resume(root: String), strictOn, strictOff, checkNow, openReport(anchor: String?), doctor }
public struct ConfirmationSpec: Equatable { public let title: String; public let message: String; public let confirmLabel: String }
public func confirmation(for action: MenuAction, status: Status) -> ConfirmationSpec?

public struct NotificationKey: Hashable { public let kind: String; public let detail: String }
public struct AppNotification: Equatable { public enum Kind { case red, yellow }; public let kind: Kind; public let key: NotificationKey; public let title: String; public let body: String }
public func notificationDecision(previous: DerivedState?, current: DerivedState, alreadySent: Set<NotificationKey>) -> AppNotification?
public func cliArguments(for action: MenuAction, status: Status) -> [[String]]   // ackProject → one `ack <src>` per distinct src under root

public protocol NotificationSink: AnyObject { func requestPermission() async -> Bool; func send(_ n: AppNotification) }
public enum LoginItemState: Equatable { case enabled, disabled, requiresApproval, unavailable(String) }
public protocol LoginItemService: AnyObject { var state: LoginItemState { get }; func setEnabled(_ on: Bool) throws; func refresh() }
public protocol Presence: AnyObject { func acquire() -> Bool; func release() }

public struct CLIResult: Equatable { public let rc: Int32; public let stdout: String; public let stderr: String }
public final class CLIRunner: Sendable { public init(environment: [String: String]); public func locate() -> URL?; public var searched: [String] { get }
  public func run(_ args: [String], timeout: TimeInterval) async throws -> CLIResult; public func spawnDetached(_ args: [String], logURL: URL) throws -> Process
  public func fetchStatus(timeout: TimeInterval) async -> Result<Status, StatusError> }   // maps not-found / rc 2 "unknown command: status" / timeout / decode
```

### 2.4 Isolated environment for all tests and verification (both repos use this verbatim)

```bash
HG=/Users/mh/Projects/Develop/hiveguard                 # in the app repo: HG="${HIVEGUARD_REPO:-$(cd "$(dirname "$0")/../../hiveguard" && pwd)}"
T="$(cd "$(mktemp -d)" && pwd -P)"; export HOME="$T/home"; mkdir -p "$HOME/.hiveguard" "$T/stubs" "$T/proj/app/.git"
export HIVEGUARD_CONFIG="$HOME/.hiveguard/config"           HIVEGUARD_MARKERS="$HOME/.hiveguard/osv-markers.tsv"
export HIVEGUARD_PAUSES="$HOME/.hiveguard/strict-pauses.tsv" HIVEGUARD_COVERAGE="$HOME/.hiveguard/osv-coverage.tsv"
export HIVEGUARD_STRICT_ATTEMPTS="$HOME/.hiveguard/strict-attempts.tsv"
export HIVEGUARD_STATE="$HOME/.hiveguard/osv-last-scan.json" HIVEGUARD_ACKS="$HOME/.hiveguard/osv-acks.json"
export HIVEGUARD_RUN="$HOME/.hiveguard/osv-run.json"         HIVEGUARD_SCAN_PID="$HOME/.hiveguard/osv-daily.pid"
export HIVEGUARD_REPORT_OPENED="$HOME/.hiveguard/osv-report-opened" HIVEGUARD_APP_PID="$HOME/.hiveguard/menubar.pid"
export HIVEGUARD_SCHED_PLIST="$T/sched.plist"                # a file under $T, never the real plist
export HIVEGUARD_TOOL_PATH="$T/stubs"                        # stubs win over /opt/homebrew/bin
export HIVEGUARD_BIN="$HG/bin/hiveguard"
printf 'mark_finder=0\n' > "$HIVEGUARD_CONFIG"
REPORT="$HOME/.hiveguard/osv-projects.html"; SRC="$T/proj/app/package-lock.json"; : > "$SRC"

# --- stubs (all executable) ---
cat > "$T/stubs/osv-scanner" <<'EOF'
#!/bin/sh
# STUB_JSON=file to emit, STUB_RC=exit (default 1), STUB_SLEEP=seconds, STUB_FAIL=1 → stderr only, exit 128
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
echo "Scanned $PWD/x and found 2 packages" >&2
if [ "${STUB_FAIL:-0}" = 1 ]; then echo "no package sources found" >&2; echo "fatal: giving up" >&2; exit 128; fi
cat "$STUB_JSON"; exit "${STUB_RC:-1}"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_NOTIFY"\n' > "$T/stubs/terminal-notifier"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_OSASCRIPT"; exit "${STUB_OSASCRIPT_RC:-0}"\n' > "$T/stubs/osascript"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$T_LOG_OPEN"\n' > "$T/stubs/open"
printf '#!/bin/sh\nexit "${STUB_LAUNCHCTL_RC:-0}"\n' > "$T/stubs/launchctl"
chmod +x "$T"/stubs/*
export T_LOG_NOTIFY="$T/notify.log" T_LOG_OSASCRIPT="$T/osascript.log" T_LOG_OPEN="$T/open.log"

# --- scanner fixtures (one lockfile, two packages; the python merges by source.path) ---
mk_fixture() {  # $1=out file, $2=extra fast-uri id ("" for none)
  extra=""; extra_ids=""
  [ -n "$2" ] && { extra=",{\"id\":\"$2\",\"affected\":[]}"; extra_ids=",\"$2\""; }
  cat > "$1" <<EOF
{"results":[{"source":{"path":"$SRC","type":"lockfile"},"packages":[
 {"package":{"name":"fast-uri","version":"3.0.1","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-AAAA-0001","affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"3.0.6"}]}]}]},{"id":"GHSA-AAAA-0002","affected":[]}$extra],
  "groups":[{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"$extra_ids],"max_severity":"7.5"}]},
 {"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-BBBB-0001","affected":[{"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}],
  "groups":[{"ids":["GHSA-BBBB-0001"],"max_severity":"9.1"}]}]}]}
EOF
}
mk_fixture "$T/run1.json" ""; mk_fixture "$T/run2.json" "GHSA-AAAA-0003"

# --- schedule plist fixture (same layout daily-schedule writes) ---
cat > "$HIVEGUARD_SCHED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.hiveguard.osv-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HG/bin/hiveguard</string>
    <string>daily</string>
    <string>$T/proj</string>
    <string>--if-due</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
EOF

h12() { printf '%s' "$1" | shasum | cut -c1-12; }
h12pkg() { printf '%s\0%s' "$1" "$2" | shasum | cut -c1-12; }
scan() { STUB_JSON="$1" "$HG/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null; }
```

Expected after `scan run1` then `scan run2`: `new_vulns=1` (`GHSA-AAAA-0003`),
`roots["$T/proj/app"].crit_pkgs=1`, anchors `f-$(h12pkg "$SRC" fast-uri)` and
`p-$(h12 "$SRC")`.

**Seed for a "red" status without a scan** (used by H2, A3, A6): write `osv-run.json`
by hand with two `unseen` entries (fast-uri, 3 ids, sev 7.5; lodash, 1 id, sev 9.1),
`roots` with `crit_pkgs 1`, `ok:true`, `finished_epoch = now-7200`; markers row
`"$T/proj/app"<TAB>active<TAB>4 active vulnerabilities (1 critical)`; pauses with one
running, one expired and one `garbage` row; config `strict=1`. The exact heredoc is in
H2's acceptance block; A6 copies it.

### 2.5 Status fixtures for the Swift tests (`APP/Tests/HiveGuardCoreTests/Fixtures/`)

Complete `status --json` documents, all `schema: 1`, `hiveguard: {"version":"v1.6.0",
"method":"git"}`, fixed clock `now = 1791400000`: `calm.json` (ok scan 2 h ago, no
attention, schedule on+loaded, strict off), `red-6.json` (two attention entries, 6 open
ids, 1 crit, opened_epoch null, one blocked root, one running pause — the **richest**
fixture, used for the structural drift check), `red-partially-acked.json`
(`ids_acked` non-empty, `attention_ids` 2), `red-opened.json` (opened_epoch >
finished), `yellow-schedule-off.json`, `yellow-not-loaded.json`, `yellow-never.json`
(`scan.last` null, `report.exists` false), `yellow-failed.json` (`ok:false`, error
text), `yellow-stale.json` (finished 40 h before `now`), `scanning.json`
(`running:true`), `red-and-schedule-off.json` (red wins, warning set),
`strict-on-hook-missing.json`, plus three **negative** fixtures that must be rejected:
`bad-schema-0.json`, `bad-schema-2.json`, `bad-schema-missing.json`.

---

## 3. Tasks

Task ids: `H*` = hiveguard repo (`HG`), `A*` = app repo (`APP`). Model tiers: `sonnet`
= mechanical, fully specified; `opus` = stateful/subtle or cross-cutting. No two tasks
in one wave write the same file; `H*` and `A*` tasks never share a file. Every task is
test-first: write the failing test from the acceptance block **before** the
implementation, run it red, implement, run it green, then run the whole suite of its
repo.

### Wave 1 (parallel: H1, H2, A0)

---

#### H1 — `osv-daily`: run outcome file, scan pid, failure path, notifier handoff

- **Model:** opus — stateful python (baseline, acks, markers); carry-over and failure
  path threaded through without disturbing any existing output or exit code.
- **Owns:** `HG/bin/osv-daily`, `HG/tests/osv-run.test.sh`, `HG/tests/notify-handoff.test.sh`,
  `HG/tests/strict-integration.test.sh` (scaffold + step-10 allowlist only)
- **Depends on:** nothing

**Do:**

1. PATH line becomes
   `export PATH="${HIVEGUARD_TOOL_PATH:+$HIVEGUARD_TOOL_PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"`.
2. New path vars next to `STATE`/`COVERAGE`: `RUN="${HIVEGUARD_RUN:-$HOME/.hiveguard/osv-run.json}"`,
   `SCAN_PID="${HIVEGUARD_SCAN_PID:-$HOME/.hiveguard/osv-daily.pid}"`,
   `OPENED="${HIVEGUARD_REPORT_OPENED:-$HOME/.hiveguard/osv-report-opened}"`,
   `APP_PID="${HIVEGUARD_APP_PID:-$HOME/.hiveguard/menubar.pid}"`.
3. Right before the scan (both branches), non-probe only: `STARTED="$(date +%s)"`;
   `printf '%s' "$$" > "$SCAN_PID"`; the EXIT trap also removes `$SCAN_PID` for non-probe
   runs.
4. Non-interactive scan branch: `2>/dev/null` → `2>"$ERRFILE"`.
5. **Failure path** (section 1.9), after `SCAN_OK` is computed and before the empty-JSON
   fallback, guarded by `[ "$probe_flag" = 0 ] && [ "$SCAN_OK" = 0 ]`: write `$RUN` via a
   small python heredoc (reads previous `$RUN` for `unseen`; `error` = last 5 lines of
   `$ERRFILE` not starting with `Scanned `, joined by `\n`, or `null`), log the FAILED
   line, print warning + `✖` line, `exit 0`.
6. Success path: export `RUN`, `OPENED`, `STARTED` to the python block; **only when
   `STATE` is non-empty (non-probe)**: build `this_run_new` (section 1.7; anchors per
   1.8), compute `unseen`, write `$RUN` atomically with every key of section 2.2.
   `roots` = `root_agg` → `{status, active_vulns: av, crit_pkgs: ac, acked_vulns: kv}`.
7. **Notifier handoff**: `app_running() { [ -f "$APP_PID" ] && kill -0 "$(cat "$APP_PID"
   2>/dev/null)" 2>/dev/null; }` → notify only when `! app_running`. Log line and done-line
   unchanged.
8. Header comment: one sentence each for `osv-run.json` (+ override), the scan pid file,
   the notifier handoff, the failed-scan behaviour. `help.awk` rendering intact.
9. `tests/strict-integration.test.sh`: add `HIVEGUARD_RUN`, `HIVEGUARD_SCAN_PID`,
   `HIVEGUARD_REPORT_OPENED`, `HIVEGUARD_APP_PID` to the scaffold and `osv-run.json` to the
   step-10 allowlist of files `osv-daily` may create. **Nothing else** in that file.
10. Tests `tests/osv-run.test.sh`, `tests/notify-handoff.test.sh`: bash 3.2, scaffold 2.4
    inline (copy, do not source), `ok`/`FAIL` lines, non-zero exit on any FAIL.

**Acceptance criteria** (orchestrator, fresh 2.4 scaffold):

```bash
scan "$T/run1.json"; echo "rc=$?"                                                      # rc=0
jq -r '.ok, .rc, .error, (.new|length), (.unseen|length), .counts.active.vulns, .counts.new_vulns' "$HIVEGUARD_RUN" | paste -sd' ' -   # true 1 null 0 0 3 0
jq -r --arg r "$T/proj/app" '.roots[$r] | "\(.status) \(.active_vulns) \(.crit_pkgs) \(.acked_vulns)"' "$HIVEGUARD_RUN"   # active 3 1 0
[ ! -e "$HIVEGUARD_SCAN_PID" ] && echo pid-gone                                        # pid-gone
scan "$T/run2.json"; echo "rc=$?"                                                      # rc=0
jq -r '.counts.new_vulns, (.new|length), .new[0].pkg, (.new[0].ids|join(",")), .new[0].sev, .new[0].fix, .new[0].root' "$HIVEGUARD_RUN" | paste -sd' ' -   # 1 1 fast-uri GHSA-AAAA-0003 7.5 3.0.6 $T/proj/app
[ "$(jq -r '.new[0].anchor' "$HIVEGUARD_RUN")" = "f-$(h12pkg "$SRC" fast-uri)" ] && echo anchor-ok          # anchor-ok
[ "$(jq -r '.new[0].project_anchor' "$HIVEGUARD_RUN")" = "p-$(h12 "$SRC")" ] && echo panchor-ok             # panchor-ok
jq -r '(.unseen|length), (.unseen[0].ids|join(","))' "$HIVEGUARD_RUN" | paste -sd' ' -                      # 1 GHSA-AAAA-0003
scan "$T/run2.json"; jq -r '.counts.new_vulns, (.unseen|length), (.unseen[0].ids|join(","))' "$HIVEGUARD_RUN" | paste -sd' ' -   # 0 1 GHSA-AAAA-0003   (carry-over, never opened)
sleep 1; date +%s > "$HIVEGUARD_REPORT_OPENED"; sleep 1; scan "$T/run2.json"; jq -r '.unseen|length' "$HIVEGUARD_RUN"   # 0   (opened after previous run)
rm -f "$HIVEGUARD_REPORT_OPENED"; scan "$T/run1.json"; scan "$T/run2.json"; scan "$T/run1.json"; jq -r '.unseen|length' "$HIVEGUARD_RUN"   # 0   (id disappeared)
jq -r 'if (.finished_epoch >= .started_epoch) and ((now|floor) - .finished_epoch) < 120 then "epochs-ok" else "bad" end' "$HIVEGUARD_RUN"   # epochs-ok
STUB_SLEEP=3 STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" "$T/proj" >/dev/null 2>&1 </dev/null & sleep 1
[ -s "$HIVEGUARD_SCAN_PID" ] && kill -0 "$(cat "$HIVEGUARD_SCAN_PID")" && echo pid-live; wait                 # pid-live
scan "$T/run2.json"; R1="$(md5 -q "$REPORT")"; S1="$(md5 -q "$HIVEGUARD_STATE")"; M1="$(md5 -q "$HIVEGUARD_MARKERS")"
STUB_FAIL=1 scan "$T/run1.json"; echo "rc=$?"                                                               # rc=0
jq -r '.ok, .rc, (.error|split("\n")|length), .counts, (.new|length), (.unseen|length)' "$HIVEGUARD_RUN" | paste -sd' ' -   # false 128 2 null 0 1
jq -r '.error' "$HIVEGUARD_RUN" | grep -c '^Scanned'                                                         # 0
[ "$R1" = "$(md5 -q "$REPORT")" ] && [ "$S1" = "$(md5 -q "$HIVEGUARD_STATE")" ] && [ "$M1" = "$(md5 -q "$HIVEGUARD_MARKERS")" ] && echo kept   # kept
tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c 'FAILED rc=128'                                          # 1
rm -f "$HIVEGUARD_RUN"; STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --probe "$T/proj/app" >/dev/null 2>&1; [ ! -e "$HIVEGUARD_RUN" ] && echo probe-no-run   # probe-no-run
scan "$T/run1.json"; rm -f "$HIVEGUARD_RUN"; STUB_JSON="$T/run1.json" "$HG/bin/osv-daily" --if-due "$T/proj" >/dev/null 2>&1; [ ! -e "$HIVEGUARD_RUN" ] && echo ifdue-no-run   # ifdue-no-run
rm -f "$T_LOG_NOTIFY"; scan "$T/run1.json"; grep -c 'vulnerabilities found' "$T_LOG_NOTIFY"               # 1
printf '99999' > "$HIVEGUARD_APP_PID"; rm -f "$T_LOG_NOTIFY"; scan "$T/run1.json"; grep -c 'vulnerabilities found' "$T_LOG_NOTIFY"   # 1  (dead pid → notify)
printf '%s' "$$" > "$HIVEGUARD_APP_PID"; rm -f "$T_LOG_NOTIFY"; scan "$T/run1.json"; [ ! -e "$T_LOG_NOTIFY" ] && echo suppressed      # suppressed
tail -n1 "$HOME/.hiveguard/osv-daily.log" | grep -c 'projects=1 pkgs=2 vulns=3'                              # 1
bash "$HG/tests/osv-run.test.sh"; echo "rc=$?"                                                               # rc=0
bash "$HG/tests/notify-handoff.test.sh"; echo "rc=$?"                                                        # rc=0
"$HG/bin/osv-daily" --help | grep -c 'osv-run.json'                                                          # ≥1
bash -n "$HG/bin/osv-daily" && echo syntax-ok                                                                 # syntax-ok
git -C "$HG" diff --stat -- tests/strict-integration.test.sh | tail -n1                                       # a handful of insertions, no deletions beyond the allowlist line
```

**Do not:** change the report HTML (H3 owns anchors), the `--open` path, the
notification text, the state-file schema, any existing exit code, or the probe path;
do not write the opened stamp (read only); do not touch `folder-mark`.

---

#### H2 — `bin/status` (new) + dispatcher verb + contract document

- **Model:** opus — merges seven sources with jq, must replicate the ack rule exactly,
  stay read-only, and author the versioned contract.
- **Owns:** `HG/bin/status` (new, executable), `HG/bin/hiveguard` (one `case` line + one
  help line), `HG/docs/status-json.md` (new), `HG/tests/status.test.sh`
- **Depends on:** nothing (fixtures shaped per section 2.2)

**Do:**

1. `bin/status`: header comment in the house style (what it is, `--json`, read-only, every
   file read with its env override, pointer to `docs/status-json.md`), `set -euo pipefail`,
   the PATH line of H1 step 1, `command -v jq || exit 1`, symlink-chain resolution of
   `BINDIR`/`REPO` (copy from `strict-mode`). Args: none → human; `--json`; `-h|--help` →
   header via `help.awk`; anything else → exit 2.
2. Facts:
   - `hiveguard.version` = output of `"$BINDIR/hiveguard" version` (trimmed; the `(brew)`
     suffix removed); `hiveguard.method` = the dispatcher's `install_method` logic (copy).
   - `now=$(date +%s)`; scan running: `[ -f "$SCAN_PID" ] && kill -0 "$(cat …)"` → pid|null.
   - `scan.last`: `$RUN` if `jq -e . "$RUN"` else null; keys `ok rc error started_epoch
     finished_epoch stamp target counts`.
   - `attention`: jq over `$RUN.unseen` × `$ACKS` (to_v2 copied from `osv-ack`) per
     section 1.6; `project` = root with `$HOME/Projects/` stripped, else `$HOME` → `~`.
   - `report`: `REPORT="$HOME/.hiveguard/osv-projects.html"`, exists, opened epoch from
     `$OPENED` (integer|null).
   - `schedule`: `SCHED_PLIST="${HIVEGUARD_SCHED_PLIST:-$HOME/Library/LaunchAgents/com.hiveguard.osv-daily.plist}"`;
     configured = exists; folders via `osv-daily`'s awk + `xml_unescape`; hour/minute via
     `daily-schedule`'s sed; loaded = `launchctl print "gui/$(id -u)/com.hiveguard.osv-daily"`.
   - `strict`: `enabled` (`config_get strict 0` = 1), `hook_sourced` (`grep -q
     'hiveguard-hook\.zsh' "$HOME/.zshrc"`), `hook_hint` (`source "<hook_script_path>"`
     when not sourced, else null; copy `hook_script_path` from `strict-mode`), `blocked`
     (marker rows with `active` → `{root, summary, crit_pkgs}`; `crit_pkgs` =
     `$RUN.roots[root].crit_pkgs // (summary|capture("\\((?<n>[0-9]+) critical\\)").n|tonumber) // 0`),
     `paused` (rows with `NF>=2`, numeric `$2`, `$2 > now` → `{root, until_epoch}`).
     **Never rewrite the pause file.**
   - `app.running` = `$APP_PID` alive.
3. Assemble with one `jq -n` call; `--json` prints compact; plain mode derives the human
   lines (section 2.2) from the same document.
4. `bin/hiveguard`: `  status)   exec "$BIN/status" "$@" ;;` after `doctor)`; help line
   `#   hiveguard status [--json]   # last scan, new findings, protection, strict — machine-readable with --json`
   under "Management:" before `update`.
5. `docs/status-json.md`: title, "owner: hiveguard; consumed by the companion menu bar app
   (separate repo)"; the compatibility rule (section 1.1, verbatim); a field table (path,
   type, nullable, meaning) covering every key of section 2.2; the too-old detection
   sentence; `## Schema history` with `1 — 2026-10 — initial`. Link to the spec by repo
   path.
6. `tests/status.test.sh` (bash 3.2, scaffold 2.4 inline, hand-written run/ack fixtures —
   no scan).

**Acceptance criteria** (fresh 2.4 scaffold; seed by hand):

```bash
NOW=$(date +%s); cat > "$HIVEGUARD_RUN" <<EOF
{"schema":1,"ok":true,"rc":1,"error":null,"started_epoch":$((NOW-7230)),"finished_epoch":$((NOW-7200)),"stamp":"x","target":"$T/proj",
 "counts":{"active":{"projects":1,"pkgs":2,"vulns":4,"crit":1},"acked":{"projects":0,"pkgs":0,"vulns":0,"crit":0},"new_vulns":4,"resolved_vulns":0},
 "roots":{"$T/proj/app":{"status":"active","active_vulns":4,"crit_pkgs":1,"acked_vulns":0}},
 "new":[],"unseen":[
  {"src":"$SRC","root":"$T/proj/app","pkg":"fast-uri","version":"3.0.1","eco":"npm","sev":7.5,"fix":"3.0.6","ids":["GHSA-AAAA-0001","GHSA-AAAA-0002","GHSA-AAAA-0003"],"anchor":"f-000000000001","project_anchor":"p-000000000002"},
  {"src":"$SRC","root":"$T/proj/app","pkg":"lodash","version":"4.17.20","eco":"npm","sev":9.1,"fix":"4.17.21","ids":["GHSA-BBBB-0001"],"anchor":"f-000000000003","project_anchor":"p-000000000002"}]}
EOF
printf '%s\tactive\t4 active vulnerabilities (1 critical)\n' "$T/proj/app" > "$HIVEGUARD_MARKERS"
printf '%s\t%s\n%s\t%s\ngarbage\n' "$T/proj/app" "$((NOW+600))" "$T/other" "$((NOW-600))" > "$HIVEGUARD_PAUSES"; P1="$(md5 -q "$HIVEGUARD_PAUSES")"
printf 'mark_finder=0\nstrict=1\n' > "$HIVEGUARD_CONFIG"
S="$("$HG/bin/hiveguard" status --json)"; jq -e . <<<"$S" >/dev/null && echo valid-json                       # valid-json
jq -r '.schema, (.hiveguard.version|length > 0), .hiveguard.method, .scan.running, .scan.pid, .scan.last.ok, .attention_ids, (.attention|length), .attention[0].pkg, .attention[0].crit' <<<"$S" | paste -sd' ' -   # 1 true git false null true 4 2 lodash true
jq -r '.attention[1] | .pkg, (.ids_open|length), (.ids_acked|length)' <<<"$S" | paste -sd' ' -                 # fast-uri 3 0
jq -r '.report.exists, .report.opened_epoch, .schedule.configured, .schedule.loaded, .schedule.hour, .schedule.minute, .schedule.folders[0]' <<<"$S" | paste -sd' ' -   # false null true true 10 0 $T/proj
jq -r '.strict.enabled, .strict.hook_sourced, (.strict.hook_hint|startswith("source ")), (.strict.blocked|length), .strict.blocked[0].crit_pkgs, (.strict.paused|length), .strict.paused[0].root, .app.running' <<<"$S" | paste -sd' ' -   # true false true 1 1 1 $T/proj/app false
[ "$P1" = "$(md5 -q "$HIVEGUARD_PAUSES")" ] && echo pauses-untouched                                          # pauses-untouched
printf '{"schema":2,"projects":{"%s":{"ids":null,"since":"2026-10-07"}},"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"
"$HG/bin/hiveguard" status --json | jq -r '.attention_ids, (.attention|length)' | paste -sd' ' -               # 0 0
printf '{"schema":2,"projects":{},"packages":{"%s":{"fast-uri":{"ids":["GHSA-AAAA-0001","GHSA-AAAA-0002"],"since":"x"}}}}\n' "$SRC" > "$HIVEGUARD_ACKS"
"$HG/bin/hiveguard" status --json | jq -r '.attention_ids, (.attention|length), (.attention[]|select(.pkg=="fast-uri")|(.ids_open|join(",")), (.ids_acked|length))' | paste -sd' ' -   # 2 2 GHSA-AAAA-0003 2
printf '{"projects":["%s"],"packages":{}}\n' "$SRC" > "$HIVEGUARD_ACKS"; "$HG/bin/hiveguard" status --json | jq -r '.attention_ids'   # 0   (v1 store → open-ended)
rm -f "$HIVEGUARD_ACKS"
: > "$REPORT"; printf '%s\n' "$NOW" > "$HIVEGUARD_REPORT_OPENED"; "$HG/bin/hiveguard" status --json | jq -r '.report.exists, .report.opened_epoch' | paste -sd' ' -   # true $NOW
STUB_LAUNCHCTL_RC=1 "$HG/bin/hiveguard" status --json | jq -r '.schedule.loaded'                                # false
mv "$HIVEGUARD_SCHED_PLIST" "$T/p.bak"; "$HG/bin/hiveguard" status --json | jq -r '.schedule.configured, (.schedule.folders|length)' | paste -sd' ' -; mv "$T/p.bak" "$HIVEGUARD_SCHED_PLIST"   # false 0
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; "$HG/bin/hiveguard" status --json | jq -r '.scan.running, .scan.pid' | paste -sd' ' -   # true $$
printf '99999' > "$HIVEGUARD_SCAN_PID"; "$HG/bin/hiveguard" status --json | jq -r '.scan.running'; rm -f "$HIVEGUARD_SCAN_PID"   # false
mv "$HIVEGUARD_RUN" "$T/r.bak"; "$HG/bin/hiveguard" status --json | jq -r '.scan.last, .attention_ids, (.attention|length)' | paste -sd' ' -   # null 0 0
"$HG/bin/hiveguard" status | head -n1; mv "$T/r.bak" "$HIVEGUARD_RUN"                                           # No scan has completed yet
jq '.ok=false | .rc=128 | .error="no package sources found\nfatal: giving up" | .counts=null | .roots=null' "$HIVEGUARD_RUN" > "$T/f.json"; cp "$T/f.json" "$HIVEGUARD_RUN"
"$HG/bin/hiveguard" status | sed -n '1p;3p'                                                                       # Last scan: x — FAILED (rc=128) — no package sources found / Protection: NOT WORKING — last scan failed
ls -A "$HOME/.hiveguard" | sort | tr '\n' ' '                                                                     # only files the seed created
time "$HG/bin/hiveguard" status --json >/dev/null                                                                 # real < 1.0s
"$HG/bin/hiveguard" status --bogus >/dev/null 2>&1; echo "rc=$?"                                                  # rc=2
"$HG/bin/hiveguard" help | grep -c 'hiveguard status'                                                              # 1
# contract document is complete: every top-level key of the JSON appears in the field table
for k in $(jq -r 'keys[]' <<<"$S"); do grep -q "\`$k" "$HG/docs/status-json.md" || echo "MISSING $k"; done        # no output
grep -c '^## Schema history' "$HG/docs/status-json.md"                                                             # 1
grep -ci 'additive' "$HG/docs/status-json.md"                                                                      # ≥1
bash "$HG/tests/status.test.sh"; echo "rc=$?"                                                                     # rc=0
bash -n "$HG/bin/status" && echo syntax-ok                                                                          # syntax-ok
```

**Do not:** write any file; call `launchctl` with anything but `print`; prune pauses;
touch `osv-ack`, `strict-mode`, `daily-schedule`, `doctor`; read the real plist when
`HIVEGUARD_SCHED_PLIST` is set.

---

#### A0 — App repo bootstrap and scaffold

- **Model:** sonnet — fully specified structure; no behaviour.
- **Owns:** the new repository `APP` in its entirety at this wave (`git init`, `.gitignore`,
  `README.md`, `Package.swift`, `Makefile`, `Resources/Info.plist`,
  `Sources/HiveGuardCore/{Status,Services}.swift`, `Sources/HiveGuard/main.swift`
  placeholder, `Tests/HiveGuardCoreTests/Fixtures/*.json`,
  `Tests/HiveGuardCoreTests/StatusDecodingTests.swift`)
- **Depends on:** nothing (the contract is in section 2; the real CLI is not needed)

**Do:**

1. `mkdir -p /Users/mh/Projects/Develop/hiveguard-menubar && cd there && git init -b main`.
   This is the only git command the task may run. No remote.
2. `.gitignore`: `.build/`, `dist/`, `.swiftpm/`, `*.xcodeproj`, `.DS_Store`.
3. `README.md` per spec §10 (app repo): purpose and non-goals (personal build, ad-hoc
   signed, not distributed), requirements (Xcode 26+, hiveguard ≥ `minimumHiveguardVersion`
   on the machine), `make build|app|install|run|test|e2e|uninstall`, `HIVEGUARD_REPO` for
   the e2e test (default `../hiveguard`), the strict-intercepts-`swift`/`make` note, the
   ad-hoc-signing caveat for Login Items, "UI mode only from the bundle", the supported
   `status` schema range, and links by sibling path:
   `../hiveguard/docs/superpowers/specs/2026-10-07-menubar-app-design.md`,
   `../hiveguard/docs/superpowers/plans/2026-10-07-menubar-app-plan.md`,
   `../hiveguard/docs/status-json.md`.
4. `Package.swift`: `// swift-tools-version: 6.0`, name `HiveGuard`, platforms
   `[.macOS(.v14)]`, executable product `HiveGuard`; targets `HiveGuardCore` (library),
   `HiveGuard` (executableTarget, depends on Core), `HiveGuardCoreTests` (testTarget,
   `resources: [.copy("Fixtures")]`).
5. `Sources/HiveGuardCore/Status.swift`: the `Status` Codable tree (section 2.3) with
   nested `Hiveguard{version,method}`, `Scan`, `LastScan`, `Counts`, `CountBlock`,
   `AttentionEntry`, `Report`, `Schedule`, `Strict`, `BlockedRoot`, `Pause`, `AppInfo`;
   `supportedSchemas`; `decode(_:)` that first reads `schema` from a lightweight probe
   struct and throws `StatusError.unsupportedSchema(found:supported:)` before full
   decoding; `StatusError`; `minimumHiveguardVersion`.
6. `Sources/HiveGuardCore/Services.swift`: protocols, `LoginItemState`, `NotificationKey`,
   `AppNotification` (section 2.3).
7. `Sources/HiveGuard/main.swift` placeholder: `--dump-state` → `print("{}"); exit(0)`;
   else `print("UI not wired yet"); exit(0)`. (A2 replaces the dump branch; A5 the UI
   branch.)
8. `Resources/Info.plist` (section 1.3 keys, `__VERSION__` placeholder), `Makefile`
   (section 1.3 targets; `install`/`uninstall`/`run` never invoked by `test`/`e2e`).
9. Fixtures — all fifteen of section 2.5, schema-complete per section 2.2.
   `StatusDecodingTests`: every positive fixture decodes; `yellow-never.json` has
   `scan.last == nil`; an unknown extra key is ignored; the three negative fixtures throw
   `unsupportedSchema` with the right `found`; malformed JSON throws `decode`.

**Acceptance criteria:**

```bash
APP=/Users/mh/Projects/Develop/hiveguard-menubar
git -C "$APP" rev-parse --abbrev-ref HEAD; git -C "$APP" remote | wc -l | tr -d ' '          # main / 0
git -C "$APP" log --oneline | wc -l | tr -d ' '                                                # 0  (orchestrator makes the first commit)
cd "$APP" && command swift build 2>&1 | tee "$T/build.log" | tail -n1                          # Build complete!
grep -c 'warning:' "$T/build.log"                                                               # 0
command swift test 2>&1 | tail -n1                                                             # Executed N tests, with 0 failures  (N ≥ 18)
ls Tests/HiveGuardCoreTests/Fixtures | wc -l | tr -d ' '                                       # 15
for f in Tests/HiveGuardCoreTests/Fixtures/[a-z]*-*.json; do case "$f" in *bad-*) ;; *) jq -e '.schema==1 and has("hiveguard") and has("attention_ids") and has("app")' "$f" >/dev/null || echo "BAD $f";; esac; done   # no output
command make app >/dev/null && codesign -dv dist/HiveGuard.app 2>&1 | grep -c 'Signature=adhoc'   # 1
plutil -p dist/HiveGuard.app/Contents/Info.plist | grep -cE '"LSUIElement" => 1|"CFBundleIdentifier" => "com.hiveguard.menubar"'   # 2
git -C "$APP" status --porcelain | grep -c '\.build\|dist/'                                     # 0
grep -c 'hiveguard/docs/status-json.md' README.md                                               # ≥1
grep -c 'HIVEGUARD_REPO' README.md Makefile                                                      # ≥2 total
ls "$HG" | grep -c '^app$'                                                                      # 0   (nothing of the app in hiveguard)
```

**Do not:** run `make install`/`make run`; commit; import AppKit/UserNotifications/
ServiceManagement in `HiveGuardCore`; add dependencies; write anything under `HG`.

---

### Wave 2 (parallel: H3 · A1, A2, A4) — after wave 1 is verified and committed in both repos

---

#### H3 — `osv-daily`: report anchors, hash script, `--open --at`, opened stamp

- **Model:** sonnet — mechanical edits with exact formulas.
- **Owns:** `HG/bin/osv-daily`, `HG/tests/report-open.test.sh`
- **Depends on:** H1

**Do:**

1. Arg parsing: `--at <anchor>` → `AT_ANCHOR`; `--at` without `--open` → exit 2
   (`osv-daily: --at requires --open`); anchor not matching `^[pf]-[0-9a-f]{12}$` → exit 2.
2. `write_opened()` (mkdir, `date +%s > tmp; mv tmp "$OPENED"`) and `open_report()`:
   with `AT_ANCHOR` → `osascript -e "open location \"file://$REPORT#$AT_ANCHOR\"" >/dev/null 2>&1 || open "$REPORT"`,
   else `open "$REPORT"`; then `write_opened`. Replace both `open "$REPORT"` call sites.
3. Python: `h12`, ids on `<details class="proj">` and package `<tr>` per section 1.8;
   append to the report script: on `load`/`hashchange`, find `location.hash` element, open
   every `details` ancestor, `scrollIntoView({block:'center'})`, class `hl` for 3 s
   (CSS `.hl{outline:2px solid var(--accent);outline-offset:2px}`).
4. Header comment: `--open [--at <anchor>]` + one sentence for the opened stamp.
5. `tests/report-open.test.sh` (scaffold 2.4; one stub scan for a report).

**Acceptance criteria** (fresh 2.4 scaffold):

```bash
scan "$T/run2.json"
grep -c "id=\"p-$(h12 "$SRC")\"" "$REPORT"; grep -c "id=\"f-$(h12pkg "$SRC" fast-uri)\"" "$REPORT"; grep -c "id=\"f-$(h12pkg "$SRC" lodash)\"" "$REPORT"   # 1 / 1 / 1
grep -c 'hashchange' "$REPORT"                                                                  # ≥1
rm -f "$T_LOG_OPEN" "$T_LOG_OSASCRIPT" "$HIVEGUARD_REPORT_OPENED"
"$HG/bin/osv-daily" --open >/dev/null 2>&1; echo "rc=$?"; cat "$T_LOG_OPEN"                     # rc=0 / $REPORT
[ -s "$HIVEGUARD_REPORT_OPENED" ] && [ "$(( $(date +%s) - $(cat "$HIVEGUARD_REPORT_OPENED") ))" -lt 5 ] && echo stamp-ok   # stamp-ok
A="f-$(h12pkg "$SRC" fast-uri)"; rm -f "$T_LOG_OPEN" "$T_LOG_OSASCRIPT"
"$HG/bin/osv-daily" --open --at "$A" >/dev/null 2>&1; echo "rc=$?"                              # rc=0
grep -c "open location \"file://$REPORT#$A\"" "$T_LOG_OSASCRIPT"; [ ! -e "$T_LOG_OPEN" ] && echo no-plain-open   # 1 / no-plain-open
rm -f "$T_LOG_OPEN"; STUB_OSASCRIPT_RC=1 "$HG/bin/osv-daily" --open --at "$A" >/dev/null 2>&1; cat "$T_LOG_OPEN"   # $REPORT  (fallback)
"$HG/bin/osv-daily" --at "$A" >/dev/null 2>&1; echo "rc=$?"                                      # rc=2
"$HG/bin/osv-daily" --open --at 'x-1' >/dev/null 2>&1; echo "rc=$?"                              # rc=2
bash "$HG/tests/report-open.test.sh" && bash "$HG/tests/osv-run.test.sh" && bash "$HG/tests/notify-handoff.test.sh" && echo green   # green
"$HG/bin/osv-daily" --help | grep -c -- '--at'                                                    # ≥1
```

**Do not:** change counts, the state file, `osv-run.json` contents, or the probe path.

---

#### A1 — Core rules: icon state, confirmations, notifications, CLI argv mapping

- **Model:** opus — the whole product logic with precedence and edge cases.
- **Owns:** `APP/Sources/HiveGuardCore/Rules.swift`,
  `APP/Tests/HiveGuardCoreTests/{RulesTests,ConfirmationTests,NotificationTests}.swift`
- **Depends on:** A0

**Do** (section 2.3 signatures; pure; `now` is a parameter, no `Date()`):

1. `deriveState`: order of spec §1.2. `.failure`: `cliNotFound` → `.yellow(.cliNotFound(paths))`;
   `tooOld` → `.yellow(.tooOld)`; `unsupportedSchema(found,_)` → `.yellow(.unsupportedSchema(found))`;
   `exit/timeout/decode` → `.yellow(.statusUnreadable(short))`. `scanning` when
   `scan.running || checkNowRunning`. Red when `attentionIds > 0 && (opened == nil || opened
   < last.finishedEpoch)`, count = `attention_ids`. Yellow reasons in order: `scheduleOff`,
   `scheduleNotLoaded`, `neverScanned`, `lastScanFailed(first error line | "unknown error")`,
   `stale(hours)` when `now − finished > 129_600`. `warning` = first yellow reason that holds
   even when red/scanning. Future `finished_epoch` clamps to `now`. `schema` = decoded value.
2. `confirmation(for:status:)` — spec §6 rows, texts:
   - ackFinding (crit): `Mark \(pkg) \(version) as known?` / `\(project) · CRITICAL \(sev) · \(n) new advisory id(s): \(ids)\n\nThis also covers the package's other known advisories.` / `Mark as known`
   - ackProject (any crit under root): `Mark \(project) as known?` / `\(pkgCount) package(s), \(idCount) advisory id(s), \(critCount) critical.` / `Mark as known`
   - pause (blocked root, `crit_pkgs > 0`): `Pause strict mode for \(project)?` / `\(summary)\nRuns and builds will be allowed for \(duration).` / `Pause \(duration)`
   - strictOff: `Turn strict mode off?` / `Every flagged project runs again in every terminal at its next prompt.` / `Turn off`
   - else nil.
3. `notificationDecision`: red when current is `.red(n)` and (previous not red or previous
   count < n); key `("red","\(n)")`; title `\(n) new vulnerabilit\(n==1 ? "y" : "ies")`;
   body up to 3 `project (k new)` + ` +m more`. Yellow when current is `.yellow(r)` and
   (previous not yellow or reason differs); key `("yellow", reasonText)`; title `hiveguard
   protection is not working`; reasonText ∈ {`daily scan is off`, `daily scan agent is not
   loaded`, `no scan has completed yet`, `last scan failed: \(err)`, `last scan was \(h) h
   ago`, `hiveguard not found (looked in: …)`, `hiveguard is too old — needs \(minimumHiveguardVersion)
   or newer (hiveguard status)`, `unsupported status format \(found ?? "none") — app supports
   \(supportedSchemas)`, `cannot read hiveguard status: \(detail)`}. Never when key ∈
   `alreadySent`.
4. `cliArguments(for:status:)`: ackFinding → `[["ack", src, pkg]]`; ackProject → one
   `["ack", src]` per distinct src under root (sorted); pause → `[["strict","pause",root,"--for",d]]`;
   resume → `[["strict","resume",root]]`; strictOn/Off → `[["strict","on"]]`/`[["strict","off"]]`;
   checkNow → `[["daily","--rescan"]]`; openReport(nil) → `[["daily","--open"]]`,
   openReport(a) → `[["daily","--open","--at",a]]`; doctor → `[["doctor"]]`.
5. Tests with `now = Date(timeIntervalSince1970: 1_791_400_000)`: every row of spec §1.5
   (incl. the three compatibility rows via `.failure`), 35 h 59 min vs 36 h 01 min,
   red-and-schedule-off → `.red(6)` + `warning == .scheduleOff`, `checkNowRunning` →
   scanning, confirmation matrix (4 confirm, 4 nil), notification matrix (calm→red fires,
   red 6→4 no, red 4→6 fires, yellow reason change fires, alreadySent suppresses, red→calm
   nil, calm→scanning nil, tooOld fires yellow), argv mapping for every action, ackProject
   with two srcs → two argvs.

**Acceptance criteria:**

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'                                       # 0
command swift test --filter 'RulesTests|ConfirmationTests|NotificationTests' 2>&1 | tail -n1    # Executed N tests, with 0 failures (N ≥ 34)
grep -c 'Date()' Sources/HiveGuardCore/Rules.swift                                               # 0
grep -cE '^import (AppKit|SwiftUI|UserNotifications|ServiceManagement)' Sources/HiveGuardCore/Rules.swift   # 0
```

**Do not:** edit `Status.swift`/`Services.swift` (A0's — if a field is missing, stop and
report); perform I/O.

---

#### A2 — `CLIRunner`, `AppModel`, `--dump-state`

- **Model:** opus — processes, timeouts, file watching, coalescing, actor isolation,
  compatibility mapping.
- **Owns:** `APP/Sources/HiveGuardCore/{CLIRunner,AppModel,DumpState}.swift`,
  `APP/Sources/HiveGuard/main.swift` (dump branch only),
  `APP/Tests/HiveGuardCoreTests/DumpStateTests.swift`
- **Depends on:** A0; compiles against A1's signatures (same wave; the orchestrator builds
  at wave end)

**Do:**

1. `CLIRunner` (section 2.3): `locate()` order `HIVEGUARD_BIN`, `~/bin/hiveguard`,
   `/opt/homebrew/bin/hiveguard`, `/usr/local/bin/hiveguard` — **never** a path derived
   from `Bundle.main` or the executable's location; `searched` lists them. `run`:
   `Process`, `standardInput = FileHandle.nullDevice`, env = passed env with `PATH`
   prepended; async pipe drains; timeout per section 1.5. `spawnDetached` appends to
   `logURL`. `fetchStatus`: not located → `.cliNotFound`; rc 2 and stderr contains `unknown
   command: status` → `.tooOld(stderr)`; rc ≠ 0 otherwise → `.exit`; timeout → `.timeout`;
   then `Status.decode` (which throws `unsupportedSchema`/`decode`).
2. `AppModel` (section 1.5): `refresh()` → `fetchStatus(timeout: 30)` → `deriveState(…,
   now: Date(), checkNowRunning:)` → `notificationDecision` → record key, forward to the
   injected `NotificationSink?` (nil in dump mode). `perform(_:)` → `cliArguments` → serial
   queue → rc ≠ 0 → `lastActionError` → `refresh()`. `checkNow` detached + 1 s poll.
   Watcher + 60 s timer + `start()`/`stop()`.
3. `DumpState.run(env:timeout:) async -> Int32`: fetch once, derive with `Date()`,
   notification against empty previous/sent, print the section 2.2 line, return 0, or 3 on
   any `StatusError`.
4. `main.swift` dump branch: `exit(await DumpState.run(env: ProcessInfo.processInfo.environment, timeout: 30))`
   via a top-level `Task` + semaphore; no `NSApplication`.
5. `DumpStateTests` with a fake `hiveguard` script written to a temp dir (`HIVEGUARD_BIN`):
   `cat`s `red-6.json` → line has `"icon":"red","count":6` and `"notify":{"kind":"red"`;
   `calm.json` → `"notify":null`; script prints `unknown command: status` to stderr and
   exits 2 → rc 3, `"icon":"yellow"`, reasons[0] starts with `hiveguard is too old`;
   `bad-schema-2.json` → rc 3, reason starts with `unsupported status format 2`; exit 7 →
   rc 3; `sleep 40` with a 2 s injected timeout → rc 3; `HIVEGUARD_BIN=/nonexistent` → rc
   3 + `hiveguard not found`. `CLIRunner.locate()` honours `HIVEGUARD_BIN` and lists
   `searched`.

**Acceptance criteria** (2.4 scaffold with H2's seed; `HG` on the wave-1 commit):

```bash
cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1   # 0 / 0 failures
BIN="$APP/.build/debug/HiveGuard"
"$BIN" --dump-state; echo "rc=$?"                                      # {"icon":"red","count":4,…"notify":{"kind":"red"…},"schema":1}  rc=0
printf '%s\n' "$(date +%s)" > "$HIVEGUARD_REPORT_OPENED"; "$BIN" --dump-state | jq -r '.icon'   # calm
STUB_LAUNCHCTL_RC=1 "$BIN" --dump-state | jq -r '.icon, .reasons[0]' | paste -sd' ' -           # yellow daily scan agent is not loaded
printf '%s' "$$" > "$HIVEGUARD_SCAN_PID"; "$BIN" --dump-state | jq -r '.icon'; rm -f "$HIVEGUARD_SCAN_PID"   # scanning
HIVEGUARD_BIN=/nonexistent "$BIN" --dump-state; echo "rc=$?"                                     # …"icon":"yellow"…"hiveguard not found…  rc=3
printf '#!/bin/sh\necho "unknown command: status (see: hiveguard help)" >&2; exit 2\n' > "$T/oldhg"; chmod +x "$T/oldhg"
HIVEGUARD_BIN="$T/oldhg" "$BIN" --dump-state | jq -r '.icon, .reasons[0]' | paste -sd' ' -      # yellow hiveguard is too old — needs 1.6.0 or newer (hiveguard status)
ls -A "$HOME/.hiveguard" | grep -c 'menubar'                                                       # 0
grep -cE '^import (AppKit|SwiftUI|UserNotifications|ServiceManagement)' Sources/HiveGuardCore/*.swift   # 0
grep -c 'Bundle.main' Sources/HiveGuardCore/CLIRunner.swift                                        # 0
```

**Do not:** construct any UI/notification/login-item object in dump mode; write under
`~/.hiveguard` from dump mode; edit `Rules.swift`.

---

#### A4 — Services: notifier, login item, presence

- **Model:** sonnet — three small adapters with the platform states spelled out.
- **Owns:** `APP/Sources/HiveGuard/{UNNotifier,SMLoginItem,PidPresence}.swift`
- **Depends on:** A0

**Do:**

1. `UNNotifier: NotificationSink` — `requestAuthorization([.alert, .sound])`; `send` →
   `UNMutableNotificationContent`, `userInfo["kind"]`, identifier `key.kind + ":" + key.detail`;
   delegate forwards clicks to `onActivate: (AppNotification.Kind) -> Void`. **Guard**:
   `init?()` returns nil unless `Bundle.main.bundleURL.pathExtension == "app"`.
2. `SMLoginItem: LoginItemService` — maps `SMAppService.mainApp.status` (`.enabled`,
   `.notRegistered/.notFound → .disabled`, `.requiresApproval`); bundle path without
   `/Applications/` → `.unavailable("install first: make install")`; `setEnabled` →
   `register()/unregister()`; `refresh()`; `openLoginItemsSettings()`.
3. `PidPresence: Presence` — path from `HIVEGUARD_APP_PID` or default; `acquire()` false
   when a live foreign pid holds the file; atomic write; `release()` only if ours.
4. All `@MainActor final class`.

**Acceptance criteria:** `command swift build` → 0 warnings; `grep -c 'bundleURL.pathExtension'
Sources/HiveGuard/UNNotifier.swift` → 1; `grep -c '/Applications/' Sources/HiveGuard/SMLoginItem.swift`
→ ≥1. Behaviour is exercised only in section 6.

**Do not:** call these from tests; register anything from a non-`/Applications/` path.

---

### Wave 3 (parallel: H4 · A5) — after wave 2 is verified and committed in both repos

---

#### H4 — hiveguard docs and CHANGELOG

- **Model:** sonnet
- **Owns:** `HG/README.md`, `HG/CHANGELOG.md`
- **Depends on:** H1, H2, H3

**Do:**

1. README: `hiveguard status [--json]` row in the subcommand table; in `hiveguard daily`:
   `--open --at`, the failed-scan behaviour, the notification handoff sentence; in "Where
   hiveguard keeps its data": `osv-run.json`, `osv-daily.pid`, `osv-report-opened`,
   `menubar.pid`, `menubar.log`; a `### Companion menu bar app` paragraph: separate
   repository (`hiveguard-menubar`, sibling checkout, built from source, personal), what it
   reads (`hiveguard status --json`, contract in `docs/status-json.md`), that
   notifications hand over while it runs.
2. CHANGELOG `## [Unreleased]` → `### Added`: `hiveguard status [--json]` + `docs/status-json.md`
   (versioned contract, schema 1); `osv-run.json`; scan-in-progress pid file; report
   opened stamp; `daily --open --at <anchor>` + report anchors; "a companion menu bar app
   (separate repository) consumes `status --json`". `### Changed`: a failed scan no longer
   overwrites the report, diff baseline or Finder markers; the per-scan notification is
   suppressed while the companion app is running. **Nothing about the app's own code.**

**Acceptance criteria:**

```bash
grep -c 'hiveguard status' "$HG/README.md"; grep -c '^### Companion menu bar app' "$HG/README.md"   # ≥2 / 1
grep -c 'osv-run.json\|osv-report-opened\|menubar.pid' "$HG/README.md"                              # ≥3
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -c 'status\|osv-run\|companion\|no longer overwrites'   # ≥4
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$HG/CHANGELOG.md" | grep -ci 'swiftui\|Package.swift\|Makefile'   # 0
```

**Do not:** cut a version section; edit any script.

---

#### A5 — UI: menu bar scene, menu, icon, confirmations, doctor window, wiring

- **Model:** opus — the integration point; `MenuBarExtra` quirks, NSAlert from menu
  actions, lifecycle.
- **Owns:** `APP/Sources/HiveGuard/{HiveGuardApp,MenuContent,IconLabel,Confirmations,DoctorWindow}.swift`,
  `APP/Sources/HiveGuard/main.swift` (UI branch + `--unregister-login-item`)
- **Depends on:** A1, A2, A4

**Do:**

1. `main.swift`: `--unregister-login-item` → `SMLoginItem().setEnabled(false)`, print
   state, exit. Else `PidPresence().acquire()` or `exit(0)`; `HiveGuardApp.main()`.
2. `HiveGuardApp: App` — `AppModel(runner: CLIRunner(environment: env), sink: UNNotifier())`;
   `MenuBarExtra { MenuContent(model) } label: { IconLabel(model.derived) }.menuBarExtraStyle(.menu)`;
   on launch: `requestPermission()`, `model.start()`, login item `if state == .disabled {
   try? setEnabled(true) }`; termination → `model.stop()`, `presence.release()`.
3. `MenuContent` — spec §3 tree exactly, including the footer line `hiveguard
   \(status.hiveguard.version) (\(method))` and, for the compatibility yellows, a header
   line with the reason and only *Open report* (when the file exists), *Launch at login*,
   *Quit* enabled. Severity labels = report buckets.
4. Actions: `confirmation(for:status:)` → `Confirmations.ask(spec)` (NSAlert, `.warning`,
   buttons `[confirmLabel, "Cancel"]`, Cancel default/Escape) → `model.perform`.
   `lastActionError` → NSAlert `"<action> failed"` + stderr tail; `checkNow` rc 2 → the
   "No folders to scan…" text.
5. `IconLabel` per section 1.4. `DoctorWindow`: `Window` scene id `doctor`, monospaced
   read-only text in a `ScrollView`, verdict line, `Run again`; opened from the menu and
   from a yellow notification click. `UNNotifier.onActivate`: red → `openReport(nil)`;
   yellow → doctor window.

**Acceptance criteria** (build-level; behaviour is section 6):

```bash
cd "$APP" && command swift build -c release 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1   # 0 / 0 failures
command make app >/dev/null && codesign -dv dist/HiveGuard.app 2>&1 | grep -c 'Signature=adhoc'               # 1
dist/HiveGuard.app/Contents/MacOS/HiveGuard --dump-state | jq -r .icon                                         # per seeded fixture; still works from the bundle
ls -A "$HOME/.hiveguard" | grep -c menubar                                                                      # 0
grep -c 'menuBarExtraStyle(.menu)' Sources/HiveGuard/HiveGuardApp.swift; grep -c 'Cancel' Sources/HiveGuard/Confirmations.swift   # 1 / ≥1
grep -cE '"--fix"' Sources/HiveGuard/*.swift Sources/HiveGuardCore/*.swift                                       # 0
grep -c 'hiveguard.version' Sources/HiveGuard/MenuContent.swift                                                  # ≥1
```

**Do not:** run the UI from `dist/` against the real HOME in this task; add `doctor --fix`,
`schedule`, or `ack --remove` actions.

---

### Wave 4 (A6) — after wave 3 is verified and committed in both repos

---

#### A6 — App end-to-end test against a real hiveguard checkout (fixture honesty)

- **Model:** sonnet
- **Owns:** `APP/tests/e2e.test.sh` (new), `APP/Makefile` (the `e2e` target body only, if
  A0 left it as a stub)
- **Depends on:** H1, H2, H3 (in `HG`), A2, A5

**Do:**

1. `tests/e2e.test.sh`: `HG="${HIVEGUARD_REPO:-$(cd "$(dirname "$0")/../../hiveguard" && pwd)}"`;
   fail with a clear message if `$HG/bin/status` or `$HG/bin/osv-daily` is missing; require
   `HIVEGUARD_APP_BIN` (default `$(dirname "$0")/../dist/HiveGuard.app/Contents/MacOS/HiveGuard`;
   fail if missing). Scaffold 2.4 inline. Steps:
   - **Fixture honesty**: seed the red state (H2's seed block) so the real document has
     attention, blocked and paused entries; `real="$("$HG/bin/hiveguard" status --json)"`;
     `paths() { jq -c '[paths | map(if type=="number" then 0 else . end) | join(".")] | unique | sort' "$@"; }`;
     assert `paths <<<"$real"` equals `paths "$APP/Tests/HiveGuardCoreTests/Fixtures/red-6.json"`;
     assert `jq .schema <<<"$real"` equals every positive fixture's `.schema`; print the
     diff of path sets on failure.
   - **Engine-driven states**: `scan run1`, `scan run2` → `--dump-state` red count 1,
     notify red; `"$HG/bin/osv-daily" --open` (stub `open`) → calm; `STUB_LAUNCHCTL_RC=1` →
     yellow; live scan pid → scanning; `STUB_FAIL=1 scan` → yellow with `last scan failed`;
     re-seed red then `"$HG/bin/hiveguard" ack "$SRC" fast-uri` → count drops without a
     rescan; `HIVEGUARD_BIN=/nonexistent` → yellow + rc 3.
   - **Hygiene**: no `menubar.*` under `$HOME/.hiveguard`; no `Library/LaunchAgents` under
     `$HOME`; `$T_LOG_NOTIFY` absent for every scan while `HIVEGUARD_APP_PID` holds `$$`.
2. `Makefile` `e2e`: `$(MAKE) app && HIVEGUARD_APP_BIN=dist/HiveGuard.app/Contents/MacOS/HiveGuard bash tests/e2e.test.sh`.

**Acceptance criteria:**

```bash
cd "$APP" && command make e2e; echo "rc=$?"                                                       # all ok, rc=0 (HG defaults to ../hiveguard)
HIVEGUARD_REPO=/nonexistent bash tests/e2e.test.sh; echo "rc=$?"                                 # clear "hiveguard checkout not found" message, rc≠0
# honesty check bites: temporarily corrupt a fixture key path, expect failure, restore
cp Tests/HiveGuardCoreTests/Fixtures/red-6.json "$T/bk"; jq 'del(.app)' "$T/bk" > Tests/HiveGuardCoreTests/Fixtures/red-6.json
HIVEGUARD_APP_BIN=dist/HiveGuard.app/Contents/MacOS/HiveGuard bash tests/e2e.test.sh >/dev/null 2>&1; echo "rc=$?"; cp "$T/bk" Tests/HiveGuardCoreTests/Fixtures/red-6.json   # rc≠0
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # G3: network test skipped per wave; expect no FAIL lines                                                             # rc=0 (engine suite still green; needs network for the strict integration test)
```

**Do not:** build inside the test (the Makefile target does); write under `HG`.

---

## 4. Verification plan (orchestrator) and commit boundaries

Before wave 1, record the real machine's state to prove non-leakage at the end:

```bash
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"
stat -f '%m %N' ~/.hiveguard/osv-last-scan.json ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/config ~/Library/LaunchAgents/com.hiveguard.osv-daily.plist
ls -A ~/.hiveguard | sort > /tmp/hg-before.txt
sfltool dumpbtm 2>/dev/null | grep -c HiveGuard                                                    # 0
git -C /Users/mh/Projects/Develop/hiveguard status --porcelain                                    # clean (the two docs committed first: see below)
git -C /Users/mh/Projects/Develop/hiveguard worktree add "$HG" -b feat/menubar-support            # HG = the worktree path (conventions)
# APP may already exist, pre-seeded by the orchestrator with a git repo and a local
# (excluded) CLAUDE.md only; A0 treats an existing empty repo as already bootstrapped.
git -C /Users/mh/Projects/Develop/hiveguard-menubar log --oneline 2>&1 | head -1                  # no commits yet
```

The revised spec and this plan are committed to `HG` `main` **before** branching
(`docs: menu bar app — app moves to its own repo; implementation plan`), so the plan the
agents read is the committed one.

Run each task's acceptance block verbatim in a **fresh** 2.4 scaffold. Per wave:

### Wave 1

```bash
bash "$HG/tests/osv-run.test.sh" && bash "$HG/tests/notify-handoff.test.sh" && bash "$HG/tests/status.test.sh" && echo hg-wave1-ok
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # G3: network test skipped per wave; expect no FAIL lines                       # rc=0 (see gate G3 for the network test)
git -C "$HG" status --porcelain                              # only: bin/osv-daily bin/status bin/hiveguard docs/status-json.md tests/{osv-run,notify-handoff,status,strict-integration}.test.sh
bash -n "$HG/bin/osv-daily" "$HG/bin/status" "$HG/bin/hiveguard"; grep -n 'declare -A\|\btimeout\b' "$HG/bin/status" "$HG"/tests/*.test.sh   # no output
(cd "$APP" && command swift test 2>&1 | tail -n1)           # 0 failures
git -C "$APP" status --porcelain | grep -c '\.build\|dist/'  # 0
ls "$HG" | grep -c '^app$'                                   # 0
```

Commits:
- `HG` #1 `feat(daily): record run outcome, scan pid, failed-scan keeps state, notifier handoff` — `bin/osv-daily`, `tests/osv-run.test.sh`, `tests/notify-handoff.test.sh`, `tests/strict-integration.test.sh`
- `HG` #2 `feat(status): hiveguard status --json with versioned contract (docs/status-json.md)` — `bin/status`, `bin/hiveguard`, `docs/status-json.md`, `tests/status.test.sh`
- `APP` #1 `feat: bootstrap HiveGuard menu bar app (SPM scaffold, Core types, fixtures, Makefile)` — everything A0 made (first commit of the repo)

### Wave 2

```bash
bash "$HG/tests/report-open.test.sh" && bash "$HG/tests/osv-run.test.sh" && echo h3-ok
(cd "$APP" && command swift build 2>&1 | grep -c 'warning:'; command swift test 2>&1 | tail -n1)   # 0 / 0 failures, N ≥ 50
# A2 dump block (seeded red → red/calm/yellow/scanning; too-old and not-found → rc 3)
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # G3: network test skipped per wave; expect no FAIL lines                        # rc=0
git -C "$HG" status --porcelain; git -C "$APP" status --porcelain    # only wave-2 owned files, each in its repo
```

Commits:
- `HG` #3 `feat(daily): report anchors and --open --at, report-opened stamp` — `bin/osv-daily`, `tests/report-open.test.sh`
- `APP` #2 `feat: core rules, CLI runner with compatibility mapping, app model, --dump-state, platform services` — A1/A2/A4 files

### Wave 3

```bash
(cd "$APP" && command swift build -c release 2>&1 | grep -c 'warning:' && command make app >/dev/null && codesign -dv dist/HiveGuard.app 2>&1 | grep -c adhoc)   # 0 then 1
# A5 dump block from the bundled binary in a fresh scaffold; H4 doc greps
git -C "$HG" status --porcelain                              # README.md CHANGELOG.md only
```

Commits:
- `HG` #4 `docs: status subcommand, companion app, failed-scan behaviour; CHANGELOG` — `README.md`, `CHANGELOG.md`
- `APP` #3 `feat: menu bar UI, confirmations, doctor window, notifications, login item` — A5 files

### Wave 4

```bash
(cd "$APP" && command make e2e); echo "rc=$?"                 # rc=0
for t in "$HG"/tests/*.test.sh "$HG"/tests/*.test.zsh; do case "$t" in *strict-integration*) continue;; *.zsh) zsh -f "$t";; *) bash "$t";; esac || echo "FAIL $t"; done   # G3: network test skipped per wave; expect no FAIL lines                         # rc=0
# non-leakage, whole effort:
launchctl print "gui/$(id -u)/com.hiveguard.osv-daily" >/dev/null 2>&1; echo "real-agent-rc=$?"   # same as recorded
stat -f '%m %N' ~/.hiveguard/osv-acks.json ~/.hiveguard/osv-markers.tsv ~/.hiveguard/config ~/Library/LaunchAgents/com.hiveguard.osv-daily.plist   # unchanged (osv-last-scan.json may have been refreshed by the REAL scheduled 10:00 scan — expected)
ls -A ~/.hiveguard | sort | diff /tmp/hg-before.txt -         # empty, or only osv-run.json if the real scheduled scan ran with the new osv-daily on PATH (note it)
sfltool dumpbtm 2>/dev/null | grep -c HiveGuard                # 0
```

Commit `APP` #4 `test: end-to-end against a hiveguard checkout (fixture drift check, dump-state states)`.

Then stop every agent of the wave (session hygiene) and move to the gates.

**Note on the real scheduled scan:** the real launchd agent runs `bin/hiveguard daily
… --if-due` at 10:00 from the **main checkout**, which stays on `main` during all waves
(engine work happens in the worktree). The real scan therefore keeps running the released
code until gate G2 merges the branch; from then on it produces the real `osv-run.json` and
`osv-daily.pid` — product behaviour, not a leak.

---

## 5. Gates (decided by the maintainer 2026-10-07)

- **G1 — Real-machine finish (section 6):** STOP and ask the maintainer before section 6;
  proceed only on an explicit "go".
- **G2 — Branch handling:** after the engine waves are verified, MERGE
  `feat/menubar-support` into `main` in the main checkout (fast-forward if possible), then
  remove the worktree. The app's end-to-end test (A6) runs against the main checkout and
  therefore waits for this merge. (`APP` has no remote; nothing to push.)
- **G3 — Network strict integration test:** skip `strict-integration.test.sh` at every
  wave boundary; run the full suite including it ONCE at the end, before the G2 merge.

**Execution split:** engine tasks (H*) are orchestrated from the Claude session in the
hiveguard repo; app tasks (A*) from a separate Claude session started in `APP`. A0, A1,
A2, A4, A5 need only fixtures and can run in parallel with the engine waves; A6 waits for
the G2 merge.

---

## 6. Real-machine finish (orchestrator, ONLY after gate G1 is opened)

The only step that touches the real HOME, installs to `~/Applications`, registers a
login item and may send real notifications.

1. `cd $APP && command make install` → `~/Applications/HiveGuard.app` launches. Verify:
   `pgrep -x HiveGuard` (one pid), `cat ~/.hiveguard/menubar.pid` equals it, icon visible
   with the expected colour (`hiveguard status --json | jq .attention_ids` tells you
   red-or-not; the footer shows `hiveguard <version> (git)`).
2. Notification permission prompt → maintainer allows. Login item: `sfltool dumpbtm | grep
   -c HiveGuard` ≥ 1, or the menu's *Launch at login* reads enabled (if `requiresApproval`,
   approve in System Settings).
3. Menu smoke: *Open report* opens the report and `cat ~/.hiveguard/osv-report-opened` is
   fresh; a per-finding *Open in report* lands on the highlighted row (if the fragment is
   dropped, the fallback still shows the report — note which happened); *Check installation
   health…* shows doctor output.
4. Suppression (maintainer's call — **real scan of ~/Projects, several minutes, refreshes
   the real report**): `hiveguard daily --rescan` → icon animates, settles; **no**
   terminal-notifier banner; the app notifies only on a state change. Quit the app →
   `menubar.pid` gone.
5. Rollback (always available): `cd $APP && command make uninstall` → login item
   unregistered, bundle removed, pid file removed; `sfltool dumpbtm | grep -c HiveGuard` → 0;
   hiveguard notifications resume on the next scan.
6. Record the outcome; no ad-hoc patches — a defect becomes a task.

---

## 7. Out of scope / follow-ups (open as issues, do not implement here)

- A `doctor` line for the companion app (pid alive, login item state).
- Shipping the app (signing, notarization, cask, GitHub remote) — out of scope by decision.
- A CHANGELOG and tags for the app repo once it is more than a personal build.
- Carry-over of unseen findings across a change of scan target.
- `ack` of individual advisory ids (the menu's *Mark as known* acks the package).
- A `status` field for strict-mode probe activity.

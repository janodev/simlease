<p align="center">
  <img src="assets/banner.svg" alt="SimLease — stop your AI agents from fighting over iOS simulators" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/macOS-27+-000000?logo=apple&logoColor=white" alt="macOS 27+">
  <img src="https://img.shields.io/badge/license-MIT-2dd4bf" alt="MIT license">
</p>

When several coding agents build and test iOS apps in parallel, one can install
over another's simulator, change its state, or close it mid-test. SimLease gives
each complete workflow a private disposable simulator and keeps ownership for as
long as the workflow runs.

For macOS UI testing, SimLease also provides one host-wide lock so agents do not
steal keyboard focus, move windows, or capture each other's screenshots.

- 🔒 **Crash-safe sessions** — `simlease run` creates a new simulator, retains a
  kernel lock, waits for boot readiness, supervises a command, then deletes the
  simulator.
- 🖥️ **Exclusive macOS UI** — `simlease macos-ui` queues complete desktop UI
  workflows behind one crash-released host lock.
- 🏷️ **Recognizable windows** — session names include the task and a short
  session ID, such as `🔒 checkout-redesign [A1B2C3D4] · iPhone 17 Pro`.
- 📋 **A menubar board** — SimLease.app shows leases and session state, focuses
  windows, reports status or cleanup errors, and can retry cleanup.

<p align="center">
  <img src="assets/hero.png" alt="Two simulator windows named after their tasks" width="85%">
</p>

## Companion tools

Run multiple coding agents on one Mac with less resource contention, lighter
simulators, and less disk clutter. Competing builds and desktop UI tests take
turns while independent work continues in parallel.

- [AgentBuild](https://github.com/janodev/agentbuild) coordinates builds and tests, reuses caches, and records results.
- [AgentLease](https://github.com/janodev/agentlease) coordinates access to shared resources, reducing contention and preventing conflicting work.
- [SimLease](https://github.com/janodev/simlease) provides disposable simulators, cleans them up afterward, and queues macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim) disables unneeded Simulator background services to reduce memory use.

AgentLease, SimLease, and SimSlim work independently. AgentBuild is a build driver
that runs supported project workflows and coordinates the other tools as needed.

## Install

This is a private repository; cloning requires access to `janodev/simlease`.

```bash
git clone https://github.com/janodev/simlease.git
cd simlease
make install          # installs the CLI at ~/Developer/tools/simlease
make app              # builds dist/SimLease.app
open dist/SimLease.app
```

Add `~/Developer/tools` to `PATH`. Set `BIN_DIR` to choose another command
directory; an explicit `PREFIX` still selects `PREFIX/bin`.

Requires macOS 27+ and Xcode with an available iOS Simulator runtime.
New simulators use the newest available iOS runtime whose supported device types
include the requested device. Device-specific runtimes, such as an iPhone-only
runtime, are skipped for iPad requests.

When upgrading from the original schema-1 release, replace both the CLI and
SimLease.app. The first v2 mutation migrates the registry to schema 2. The
migration briefly speaks v1's directory-lock protocol while ordinary v2 work
uses a separate kernel-lock path. After migration, v1 fails closed with an
unsupported-schema error.

## Quickstart

Put the entire simulator workflow beneath one supervisor. A child script or
shell receives the session variables after the private device is boot-ready:

```bash
simlease run --label "checkout-redesign" -- zsh -lc '
  set -euo pipefail
  xcodebuild -scheme MyApp -destination "id=$SIMULATOR_ID" build
  xcrun simctl install "$SIMULATOR_ID" path/to/MyApp.app
  xcrun simctl launch "$SIMULATOR_ID" com.example.MyApp
'
```

`simlease with` is an alias for `simlease run`. For exploratory work, start a
child shell and keep it open for the complete workflow:

```bash
simlease run --label "checkout-redesign" -- zsh
```

Inside the child, SimLease exports:

| Variable | Value |
|---|---|
| `SIMULATOR_ID` | The private simulator UDID. |
| `SIMULATOR_UDID` | Alias of `SIMULATOR_ID` for tool compatibility. |
| `SIMLEASE_SESSION_ID` | The unique lifecycle/session identifier. |

Exiting the command or shell triggers checked shutdown and deletion. A nonzero
child status is preserved; any concurrent cleanup failure is also reported and
retained as quarantine state.

### macOS UI testing

Wrap the complete focus-sensitive workflow in the fixed host-wide gate:

```bash
simlease macos-ui --label "checkout-redesign" -- caffeinate -dimsu zsh -lc '
  set -euo pipefail
  make build-macos
  make test-ui-file FILE=MyAppUITests METHOD=testCheckout
'
```

A second agent waits by default. The command directly inherits the kernel lock,
so normal exit, failure, or a crash releases it automatically while preserving
the command's exact exit status. Use `--wait 0` to fail immediately when busy or
a bound such as `--wait 90m`. Keep build, launch, interaction, screenshots, and
teardown inside the command. See the [macOS UI lock playbook](Docs/macos-ui-lock.md).

When the user asks to launch a macOS app for manual testing, build it through
the project's managed build route and open the resulting app normally, without
`simlease macos-ui`. The desktop lease coordinates agent UI interaction and
tests; release it after that interaction and teardown rather than retaining it
through the user's app session. Simulator isolation and compilation locks keep
their existing scope.

## Using it with coding agents

This repository ships an agent skill:

```bash
cp -r skills/simlease ~/.codex/skills/
# or install it in another agent's supported skill directory
```

The essential instruction is:

```markdown
Run the whole simulator workflow under `simlease run --label "<task>" -- ...`.
Use only the exported `SIMULATOR_ID`; never select or touch another 🔒 simulator.
```

Wrapping the whole workflow matters. Capturing a cooperative claim and running
unrelated commands later does not retain the crash-safe session lock.

## Crash and cleanup behavior

- Normal completion, a child failure, or a boot-readiness failure attempts
  checked shutdown and deletion before ownership is released.
- On `SIGINT` or `SIGTERM`, SimLease forwards the signal to the child, waits for
  it to finish, cleans the simulator, and returns a signal-derived status.
- If the supervisor crashes or receives `SIGKILL` after publishing the session,
  the kernel releases its lock automatically. The direct child may survive, and
  the registry row remains abandoned and delete-only; the next `simlease gc`,
  `claim`, or `run` attempts simulator cleanup.
- If deletion fails, the row remains quarantined with failure information. Run
  `simlease gc` to retry, or use **Retry Cleanup** in SimLease.app.

TTL never revokes a live session lock. One narrow gap remains: a crash after
Simulator creation but before registry publication can leave an unregistered
`🔒` device. It is excluded from allocation, but cannot yet be automatically
proven safe to delete. See [current limitations](Docs/current-architecture.md).

## The menubar board

SimLease.app is a menu-only utility that watches the shared registry:

<p align="center">
  <img src="assets/menubar.svg" alt="SimLease menubar board" width="80%">
</p>

- Shows boot state, label, device, agent, and session lifecycle state.
- Focuses a selected Simulator window and copies its UDID.
- Shows registry/status and cleanup errors instead of silently hiding them.
- Allows release for cooperative leases and retry cleanup for quarantined
  sessions; active `run` sessions remain controlled by their supervisor.
- Runs GC periodically and offers **Run GC** for immediate reconciliation.

## CLI reference

| Command | Behavior |
|---|---|
| `simlease run` / `simlease with` | Create a private disposable simulator, wait for readiness, run one command, and clean up. Options: `--label`, `--agent`, `--device`. |
| `simlease macos-ui` | Wait for exclusive macOS UI automation access, then directly run one complete workflow. Options: `--label`, `--agent`, `--wait`. |
| `simlease status` | Show cooperative leases and session ID/state; use `--json` for the registry document. |
| `simlease gc` | Reap expired legacy leases and retry delete-only abandoned or quarantined sessions. Never reaps a lock-held session. |
| `simlease focus <label\|udid>` | Bring a leased Simulator window to the front; omit the argument for the current worktree's cooperative lease. |
| `simlease claim` | Lower-safety compatibility command: claim or reuse a sticky simulator for this worktree. Prints its UDID on stdout. |
| `simlease renew` | Extend the current worktree's cooperative lease TTL. |
| `simlease release` | Release a cooperative lease, restore a reused name, or delete a device SimLease created. Active sessions reject external release. |

## How it works

- The CLI and app share schema-2 JSON at `~/.simlease/registry.json`. Schema 1
  loads migrate on the next save. Set `SIMLEASE_HOME` to isolate state in tests.
- Mutations use a Darwin `flock` at `~/.simlease/registry.lock`. The first
  schema-2 write briefly uses v1's directory barrier at `~/.simlease/lock`.
  Each foreground session also holds
  `~/.simlease/device-locks/<UDID>.lock` across boot, child work, and cleanup.
- Lock files are persistent regular files. SimLease closes descriptors to
  release ownership and never steals or unlinks a lock by age.
- macOS UI workflows share one flock at
  `~/.simlease/host-locks/macos-ui.lock`. Its descriptor intentionally survives
  `exec` so the workflow command owns it until exit.
- Allocation-critical Simulator discovery validates process status and JSON.
  Existing unreadable, corrupt, or unsupported registry data fails closed rather
  than becoming an empty ownership view.
- Registered lockless sessions are abandoned and delete-only. They can be
  deleted during reconciliation but never reused.

## Cooperative compatibility commands

`claim`, `renew`, and `release` remain available for workflows that cannot fit
beneath one foreground supervisor. A claim is sticky to its Git worktree and has
a TTL, but it does not retain a kernel lock after the command exits. Processes
in one worktree may share it, an expired lease can be reclaimed while still in
use, and tools that ignore SimLease remain outside its protection.

Use a distinct worktree, pass the exact returned UDID to every command, renew
before TTL expiry, and release explicitly. Prefer `run` whenever possible.

## Documentation

Architecture, development guidance, evidence, and remaining decisions are
indexed in [`Docs/index.md`](Docs/index.md).

## License

MIT — see [LICENSE](LICENSE).

Based on [SimLease by Alexis Santos](https://github.com/alexissan/simlease).
The original copyright notice is retained in [LICENSE](LICENSE).

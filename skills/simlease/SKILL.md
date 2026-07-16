---
name: simlease
description: Coordinate isolated iOS Simulator workflows and exclusive macOS UI automation with SimLease. Use whenever device work or desktop interaction could overlap another agent; prefer one crash-safe command boundary around the complete workflow.
---

# SimLease

Use [SimLease](https://github.com/janodev/simlease) to prevent parallel workflows
from sharing an iOS simulator. Never select an arbitrary UDID.

## Run the complete workflow

Wrap every simulator-dependent step in one foreground session:

```bash
simlease run --label "<short task name>" -- zsh -lc '
  set -euo pipefail
  xcodebuild -scheme MyApp -destination "id=$SIMULATOR_ID" build
  xcrun simctl install "$SIMULATOR_ID" path/to/MyApp.app
  xcrun simctl launch "$SIMULATOR_ID" com.example.MyApp
'
```

Use `simlease with` as an equivalent alias. Use a ticket, branch, or concise
task name as the label; omit it to use the current Git branch.

Keep the entire build, install, launch, test, inspection, screenshot, and log
collection inside the child command. SimLease creates and boots a private
disposable simulator before starting the child, then shuts it down and deletes
it after the child exits.

Use these exported variables for every device operation:

* `SIMULATOR_ID` - private simulator UDID;
* `SIMULATOR_UDID` - equivalent compatibility name; and
* `SIMLEASE_SESSION_ID` - unique session identifier for evidence and logs.

For interactive work, run `simlease run --label "<task>" -- zsh` and keep that
child shell open. Exiting it ends the session and triggers cleanup.

## Handle interruption and recovery

Allow ordinary command exit to return control to the supervisor so it can clean
up. SimLease forwards `SIGINT` and `SIGTERM` to the direct child, then waits and
cleans up. If a supervisor crashes or is killed, run:

```bash
simlease status
simlease gc
```

A published abandoned session is delete-only; never adopt its simulator. If GC
reports a cleanup failure, preserve the UDID and diagnostics for investigation
and retry later. A live kernel lock remains authoritative even if its TTL or
metadata looks stale, and corrupt registry content blocks mutation. Never
manually take a simulator whose name begins with `🔒`.

## Use legacy claims only when necessary

If simulator operations must span unrelated commands that cannot run below one
supervisor, use the lower-safety cooperative flow:

```bash
SIMULATOR_ID=$(simlease claim --label "<short task name>")
# Pass "$SIMULATOR_ID" to every operation.
simlease renew
simlease release
```

Claims are sticky per Git worktree and TTL-based. They do not retain a kernel
lock after `claim` exits, same-worktree processes share the lease, and TTL can
expire during active work. Use a distinct worktree, renew during long tasks,
release on every exit path, and prefer `simlease run` whenever possible.

Use `simlease status` for ownership and lifecycle evidence. Use
`simlease focus <label-or-udid>` to raise the corresponding Simulator window.

## Serialize macOS UI automation

macOS UI tests share the host's keyboard, pointer, focus, windows, and screenshot
surface. Wrap the complete workflow in the one fixed desktop gate:

```bash
simlease macos-ui --label "<short task name>" -- caffeinate -dimsu zsh -lc '
  set -euo pipefail
  make build-macos
  make test-ui-file FILE=AppUITests METHOD=testExample
'
```

Keep build, launch, fixture setup, interaction, inspection, screenshots, and
teardown inside that command. A second agent waits by default. The child
receives `SIMLEASE_HOST_RESOURCE=macos-ui`, `SIMLEASE_MACOS_UI=1`, and a unique
`SIMLEASE_SESSION_ID`. Exit or crash releases the inherited kernel lock. Use
`--wait 0` only when failing immediately on contention is preferable to waiting.

---
name: simlease
description: Run isolated iOS Simulator build, install, launch, test, inspection, or screenshot workflows with SimLease. Use whenever simulator work could overlap another agent or process; prefer one crash-safe `simlease run` session around the complete workflow, and use cooperative `claim` only when unrelated invocations cannot be supervised together.
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

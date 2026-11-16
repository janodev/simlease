---
type: Operational Playbook
title: Exclusive macOS UI Automation
description: Defines the host-wide lock that serializes macOS UI testing across cooperating agents.
tags: [macos, ui-testing, concurrency, locking, agents]
timestamp: 2026-10-12T00:00:00Z
status: implemented
---

# Purpose

macOS UI automation shares one keyboard, pointer, frontmost application, window
server, pasteboard, and screenshot surface. Separate app builds do not prevent
two agents from changing focus or typing into each other's windows. SimLease
therefore provides one deliberately coarse host-wide gate:

```bash
simlease macos-ui --label "notika-format-menu" -- caffeinate -dimsu zsh -lc '
  set -euo pipefail
  make build-macos
  make test-ui-file FILE=NotikaUITests METHOD=testCodeFormatting
'
```

Every cooperating agent on the Mac uses the same `macos-ui` resource. A second
invocation waits by default until the current workflow exits.

# User App Launches

Launching a macOS app for the user's manual testing does not require this gate.
Use the project's managed build-only route, then open the exact newly built
app normally and leave it available to the user. A supervised run command that
requires the desktop lease belongs to the agent automation workflow; use a
build followed by a normal launch for the user instead.

The gate coordinates agents that operate the keyboard, pointer, accessibility
or screenshot surface. The user can recognize visible UI testing and avoid
interference. Release the gate after the agent's interaction and required
teardown; do not extend it across manual testing or waits for user input.
Compilation coordination remains independent, and Simulator work still needs
its own private device session.

# Ownership Contract

The lock is a Darwin `flock` on the persistent regular file
`~/.simlease/host-locks/macos-ui.lock`. `SIMLEASE_HOME` changes that root for
isolated tests; production agents must use the same home to coordinate.

After acquiring the lock, SimLease directly replaces itself with the requested
command and intentionally leaves the lock descriptor open across `exec`. This
has three useful consequences:

* the actual workflow process owns the kernel lock rather than depending on a
  separate supervisor;
* the command's normal exit status and signals are preserved exactly; and
* exit, crash, or `SIGKILL` releases ownership when the inherited descriptor
  closes, without a stale-lock timeout or manual unlock.

The lock file remains on disk and must never be removed to release ownership.
Closing its descriptor is the only release operation.

# Workflow Boundary

Place the complete focus-sensitive lifecycle under one command:

1. build the macOS app and UI-test runner;
2. launch the app with deterministic window frame and sidebar flags;
3. install fixtures and establish test state;
4. interact, inspect accessibility, and collect screenshots or logs;
5. terminate the app and clean temporary state.

A foreground `zsh -lc` block is the simplest boundary for several commands.
For unattended work, place `caffeinate -dimsu` inside the gate as shown above;
queued agents then do not keep the Mac awake. Do not start the UI workflow in
the background and let the wrapper exit: the lease is defined by the lifetime
of the command tree holding the inherited file descriptor.

The command receives:

| Variable | Value |
|---|---|
| `SIMLEASE_HOST_RESOURCE` | `macos-ui` |
| `SIMLEASE_MACOS_UI` | `1` |
| `SIMLEASE_SESSION_ID` | Unique identifier for correlating evidence and logs. |

Use `--wait 0` for an immediate busy failure, a duration such as `90m` for a
bounded queue, or `--wait forever` for the default unbounded wait.

# Limits

This is cooperative exclusion, not operating-system policy. A process that
bypasses `simlease macos-ui` can still control the desktop. All participating
agents must invoke the command with the same macOS account and `SIMLEASE_HOME`.

The host lock is intentionally independent of Simulator sessions and the JSON
registry. It does not create a device, appear in the menubar board, or prevent
parallel non-UI builds. One fixed resource name avoids agents accidentally
choosing different lock names for the same global desktop.

For Simulator isolation, continue to use `simlease run`; combine the two only
when a workflow truly needs both a private Simulator and exclusive control of
the Mac desktop.

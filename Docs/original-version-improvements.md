---
type: Comparison Reference
title: Improvements Over the Original Version
description: Compares the original cooperative SimLease release with the current crash-safe foreground-session architecture.
tags: [architecture, comparison, history, safety]
timestamp: 2026-07-15T00:00:00Z
status: current
---

# Outcome

SimLease changed from a cooperative lease tracker into a crash-safe Simulator
supervisor. The original baseline is commit `7df4924`; the current comparison
target is the current `main` branch.

# Comparison

| Area | Original version | Improved version |
|---|---|---|
| Ownership | Worktree-sticky registry entry with TTL. | Live per-UDID kernel `flock` held for the complete workflow. |
| Isolation | Reused existing simulators when possible. | Every `simlease run` receives a unique disposable simulator. |
| Concurrency | Same-worktree processes could collide. | Concurrent runs, including runs from one worktree, receive distinct devices. |
| macOS UI coordination | No desktop-wide ownership primitive. | One fixed `macos-ui` kernel lock serializes focus-sensitive workflows across cooperating agents. |
| Lock recovery | A removable directory lock could be stolen after ten seconds. | Persistent kernel locks are released automatically on process death and are never stolen by age. |
| Lifecycle | Callers used `claim`, unrelated manual commands, and `release`. | One supervisor creates, boots, runs, cleans, and deletes. |
| Readiness | Booting was separate from the caller's complete lifecycle. | Checked boot and blocking `bootstatus` finish before child work starts. |
| Crash handling | TTL or worktree cleanup could reclaim a device still in use. | Live locks override TTL; abandoned sessions are delete-only and reconciled conservatively. |
| Process handling | Callers managed commands independently. | Sessions inherit terminal streams, export identifiers, forward signals, and preserve deterministic exit status. |
| Cleanup | Several `simctl` failures were ignored. | Checked shutdown and deletion failures retain quarantined state for retry. |
| Registry | Schema 1 could interpret unreadable or corrupt state as empty. | Schema 2 fails closed for unreadable, corrupt, or unsupported state. |
| Upgrade safety | No ownership compatibility boundary existed. | A one-time v1-compatible migration barrier prevents old binaries from racing the schema-2 fence. |
| Device selection | An exact request could silently fall back. | An exact `--device` request matches or fails. |
| Subprocess output | Large simultaneous stdout and stderr could deadlock. | Both pipes drain concurrently. |
| Menu app | A basic synchronous lease board performed periodic reaping. | An Observation-based board loads status off the main actor, coalesces refreshes, presents errors, retries cleanup, focuses windows, copies UDIDs, and tears down resources. |
| Agent workflow | Guidance recommended cooperative claims first. | Guidance prefers one `simlease run` boundary with `caffeinate`, exact UDIDs, deterministic UI-test state, and automatic cleanup. |
| Evidence | Coverage and architecture guidance were limited. | Validation includes broad XCTest and Swift Testing coverage, strict lint, release and signed-app checks, real-Simulator smoke testing, and an OKF knowledge bundle. |

# Compatibility Commands

`claim`, `renew`, and `release` remain available for workflows that cannot stay
under one foreground supervisor. They are intentionally documented as the
lower-safety cooperative model.

# Remaining Boundaries

The current version still has:

* a narrow crash window between Simulator creation and registry publication;
* no forced escalation when a child ignores a forwarded termination signal;
* no persistent broker for reconnecting across unrelated commands; and
* global-lock serialization during legacy and abandoned-session reconciliation.

See [current architecture](current-architecture.md) for operational detail and
[session architecture](session-architecture.md) for the safety invariants.

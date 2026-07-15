---
type: Architecture Reference
title: Current Architecture and Limitations
description: Describes the implemented foreground-session and cooperative-lease models, their ownership authority, and recovery boundaries.
tags: [architecture, current-state, concurrency, recovery]
timestamp: 2026-07-15T00:00:00Z
status: implemented
---

# Scope

This document describes the current source. The foreground session runner was
introduced in commit `92213b6`. SimLease has two deliberately different safety
classes:

* `simlease run` and its `simlease with` alias supervise one complete workflow
  on a new disposable simulator while retaining a kernel lock.
* `claim`, `renew`, and `release` remain cooperative compatibility commands.
  Their ownership is registry metadata with a TTL, not a workflow-wide lock.

Prefer `run` whenever one command or child shell can contain the whole build,
install, launch, test, inspection, and screenshot workflow.

# Components

| Component | Implemented responsibility |
|---|---|
| `simlease` CLI | Starts supervised sessions, manages legacy leases, reports status, runs GC, and focuses Simulator windows. |
| `SessionManager` and `SimulatorSession` | Create a private simulator, retain its per-UDID lock, persist lifecycle state, and perform checked cleanup. |
| `Allocator` | Serializes registry mutations, manages legacy claims, excludes session devices, and reconciles registered abandoned sessions delete-only. |
| `RegistryTransaction` | Holds the v2 global kernel lock and performs the one-time schema fence through the v1-compatible migration barrier. |
| `FileLock` | Holds Darwin `flock` locks on persistent regular files with monotonic acquisition deadlines and close-on-exec descriptors. |
| `LegacyMigrationLock` | Briefly uses v1's removable-directory protocol only while fencing schema 1 to schema 2. |
| `RegistryStore` | Persists schema-2 JSON, migrates schema 1, and fails closed when an existing path is unreadable, corrupt, or uses an unsupported schema. |
| `Simctl` | Validates discovery output and exposes checked create, boot-readiness, shutdown, and deletion operations. |
| `SimLease.app` | Uses Observation for a titled menu-only board, displays leases plus status/cleanup errors, focuses windows, retries cleanup, and tears down its timers and watcher with the model lifecycle. |

The implementation lives in [`Sources/SimLeaseCore`](../Sources/SimLeaseCore/),
[`Sources/simlease`](../Sources/simlease/), and
[`Sources/SimLeaseApp`](../Sources/SimLeaseApp/).

# Foreground Session Lifecycle

`simlease run [options] -- <command...>` performs this sequence:

1. Acquire the global `registry.lock`, fence schema 1 when needed, load the
   registry, and reconcile eligible
   registered abandoned sessions.
2. Resolve the requested device type and newest available iOS runtime, then
   create a uniquely named disposable simulator.
3. Acquire that UDID's kernel lock and persist a record in `created` state.
4. Release the global lock, transition through `booting`, run checked `boot` and
   blocking `bootstatus -b`, then transition to `running`.
5. Start the child with inherited standard streams and export
   `SIMULATOR_ID`, `SIMULATOR_UDID`, and `SIMLEASE_SESSION_ID`.
6. After the child exits, briefly reacquire the global lock to persist
   `cleaning`, release it for checked shutdown and deletion, then reacquire it to
   remove the registry record. Release the per-UDID lock last.

Each invocation receives a new session ID and simulator, including concurrent
or sequential runs from the same Git worktree. Names are presentation hints;
every operation uses the exact UDID.

# Ownership Authority

For a foreground session, the live per-UDID kernel lock is authoritative. TTL,
worktree existence, process metadata, the registry record, and the simulator name
cannot revoke it. Allocation probes lock files without waiting and treats any
probe error as owned, so an inaccessible lock fails closed.

The v2 global kernel lock at `~/.simlease/registry.lock` serializes registry and
allocation transitions. Per-device locks live under
`~/.simlease/device-locks/`. Lock files are mode `0600`, remain on disk, and are
never unlinked. Ownership ends when the descriptor closes, including on process
death.

The registry is observability and recovery state, not proof that a device is
free. Session records include an ID, lifecycle state, and optional failure. A
corrupt registry is retained in place, copied to `.corrupt`, and causes mutation
to fail instead of being replaced with an empty registry. An existing path that
cannot be read also fails closed; only a genuinely absent path means an empty
registry.

Schema 2 is an ownership compatibility fence. New code accepts schema 1 and
writes schema 2 before the next mutation. That one short write acquires v1's
removable-directory barrier at `~/.simlease/lock` while v2's permanent kernel
lock remains on the distinct `registry.lock` inode. Once schema 2 is written,
v1 readers reject it rather than deleting sessions whose new lifecycle fields
they do not understand. Upgrade the CLI and menu app together so the old app
does not remain in an unsupported-schema retry state.

V2 never applies v1's age-based stealing rule to the migration barrier. If the
directory remains held, migration times out and fails closed. Removing a
leftover legacy directory is a manual recovery action only after proving no v1
process is still using it.

# Failure and Recovery

| Event | Implemented behavior |
|---|---|
| Child exits nonzero | Cleanup still runs and the child status is preserved. A concurrent cleanup failure is reported separately and retains quarantine state. |
| Boot or readiness fails | The child is not started; checked cleanup still runs. |
| Supervisor receives `SIGINT` or `SIGTERM` | The signal is forwarded to the child; after the child exits, cleanup runs and the conventional `128 + signal` status is returned. |
| Supervisor receives `SIGKILL` or crashes | The kernel releases its lock. The direct child may survive because an uncatchable death cannot forward a signal. The registered session remains abandoned and delete-only; the next successful `gc`, `claim`, or session start attempts cleanup. |
| TTL expires while the session lock is held | GC leaves the session untouched. |
| Shutdown or deletion fails | The record remains in `quarantined` state with failure detail and is never reused. Later GC may retry delete-only cleanup. |
| Registry is unreadable or cannot decode | Mutating operations fail closed; corrupt bytes remain available for diagnosis. |
| Legacy migration barrier remains held or has an incompatible file type | Schema 1 remains unchanged and mutation fails closed; v2 never removes the path by age. |

Recovery never adopts an abandoned session simulator into a later session or
legacy claim. Legacy allocation also excludes every `🔒`-prefixed simulator and
every UDID whose per-device lock appears held.

# Cooperative Legacy Leases

`claim` keeps its prior sticky-worktree behavior. The global lock protects the
short allocation transaction, then the command returns a UDID without retaining
a per-device lock for the caller's workflow. `renew` extends its TTL and
`release` restores a reused device's name or deletes a device SimLease created.

This compatibility path is useful when operations cannot run beneath one
supervisor, but it is lower safety:

* processes in the same worktree share the sticky lease;
* TTL can expire while a caller still uses the device;
* an agent that ignores SimLease can operate on the device; and
* the caller must explicitly renew, release, and pass the UDID to every command.

# Known Gaps

* Creation returns a UDID before the per-device lock and registry record can be
  written. A crash in that narrow window can leave an unregistered
  `🔒`-prefixed simulator. Legacy allocation excludes it, but automatic recovery
  cannot yet identify it as safe to delete.
* Sessions are tied to the foreground supervisor. There is no broker, attach,
  reconnect, or multi-invocation ownership protocol.
* Catchable signals are forwarded without a timeout or escalation. If the child
  ignores the signal, the supervisor keeps waiting and retains ownership.
* Foreground final cleanup releases the global lock around shutdown and
  deletion. Legacy cleanup and abandoned-session reconciliation still run under
  the global lock, so a slow Simulator command can delay unrelated transitions.
* The menubar app shows session state and errors and offers retry cleanup through
  global GC. It has no per-UDID cancellation, forced recovery, or cleanup
  history, so recovery control remains deliberately limited.

See [session architecture](session-architecture.md) for invariants and
[roadmap and decisions](roadmap-and-decisions.md) for planned recovery work.

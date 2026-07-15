---
type: Architecture Reference
title: Current Architecture and Limitations
description: Describes SimLease behavior implemented at commit 7df4924 and the boundaries of its cooperative lease model.
tags: [architecture, current-state, concurrency, recovery]
timestamp: 2026-07-15T00:00:00Z
status: implemented-baseline
---

# Scope

This document describes commit `7df492412215e3bc6c2a1cc98bde31623386717e`.
It is the implemented baseline, not the [target session architecture](session-architecture.md).

SimLease currently coordinates cooperative claims. It does not hold a lock across
build, install, launch, test, inspection, screenshot, and cleanup.

# Components

| Component | Implemented responsibility |
|---|---|
| `simlease` CLI | Resolves the Git worktree, invokes allocator operations, and boots after a claim. |
| `Allocator` | Serializes registry mutations, reaps stale records, selects or creates a simulator, and changes lease metadata. |
| `FileLock` | Uses atomic directory creation at `~/.simlease/lock` as a short global mutex. |
| `RegistryStore` | Persists schema-1 JSON at `~/.simlease/registry.json` using a temporary file and replacement. |
| `Simctl` | Runs `xcrun simctl` discovery and lifecycle commands. |
| `SimLease.app` | Displays registry rows, refreshes state, and invokes GC at startup and every 60 seconds. |

The implementation lives in [`Sources/SimLeaseCore`](../Sources/SimLeaseCore/),
[`Sources/simlease`](../Sources/simlease/), and
[`Sources/SimLeaseApp`](../Sources/SimLeaseApp/).

# Claim Lifecycle

`Allocator.claim` performs this sequence while holding the global registry lock:

1. Load the registry and list present simulators.
2. Reap records that are expired, refer to a missing worktree after the grace
   period, or refer to a vanished simulator.
3. Return and renew the first lease whose `workdir` matches the request, if any.
4. Otherwise select an available unregistered simulator by preferred name.
5. If none is available, create a simulator on the newest available iOS runtime.
6. Save the registry and rename a reused simulator where requested.
7. Release the global lock when `claim` returns.

The CLI then calls `simctl boot` outside the allocator lock. Boot errors are
ignored and boot readiness is not awaited. The caller receives a UDID and runs
all later commands independently.

# Ownership and Concurrency

The registry is keyed by UDID. Sticky ownership lookup is keyed by the Git
top-level worktree path; `label` and `agent` are descriptive metadata.

Under normal short critical sections, cooperative claims from different
worktrees are serialized and select different registered UDIDs. Repeating a
claim from the same worktree returns the same UDID and renews its TTL. Therefore:

* Separate worktrees normally receive separate simulators.
* Two processes in the same worktree share one sticky lease and may interfere.
* A process that ignores SimLease can operate on any simulator.
* A lease is advisory metadata after `claim`; no kernel lock remains held for
  the caller's workflow.
* `status` reads the registry without taking the allocator lock.

# Expiration and Recovery

| Event | Implemented behavior | Consequence |
|---|---|---|
| Agent exits without release | Record remains until TTL expiry unless its worktree disappears. | A surviving worktree keeps the lease for the full TTL. |
| Lease expires | The next `claim` or `gc` reaps it; the app invokes GC every minute while running. | Expiry is passive, not a live heartbeat. |
| Worktree disappears | GC may reap after 60 seconds measured from `claimedAt`. | The grace period is not measured from disappearance time. |
| Simulator vanishes | The next reap removes its record. | No simulator cleanup is possible. |
| Reused simulator is released | SimLease attempts to restore its stored original name. | Rename failure is nonfatal and the record is still removed. |
| Created simulator is released | SimLease attempts shutdown and deletion. | Failures are ignored and the record is still removed. |
| Registry JSON cannot decode | The file is moved to `.corrupt` and an empty registry is returned. | Existing ownership is not reconstructed. |
| Registry schema is newer | Loading throws an unsupported-schema error. | Newer data is preserved rather than discarded. |

TTL does not protect an active workflow. If a lease expires while its original
process still uses the simulator, a concurrent claim or GC can restore, delete,
or reassign that simulator.

# Lock Limitations

`FileLock` creates a directory atomically, polls every 200 milliseconds, times
out after 20 seconds, and treats a directory older than 10 seconds as stale.
It does not store an owner token or PID and does not refresh the directory mtime.

Consequently, a live allocator transaction longer than 10 seconds can be
mistaken for a dead owner. A contender may remove and replace its lock directory;
the original owner can later remove the contender's directory during its own
unconditional release. This breaks mutual exclusion precisely during slow
registry or Simulator operations.

# Simulator and Persistence Failure Boundaries

The current `Simctl` wrapper has asymmetric error handling:

* `create` rejects a nonzero exit status.
* JSON list commands do not inspect exit status and treat malformed output as an
  empty object.
* `boot`, `shutdown`, and `delete` ignore thrown errors and exit status.
* `rename` returns failure and writes a warning, but allocator callers continue.

Partial-operation windows also exist:

* A newly created simulator exists before its registry record is saved. A crash
  or save failure can leave an unregistered, locked-name simulator.
* Release and reap perform Simulator cleanup before saving registry removal. A
  crash can leave stale registry metadata after side effects occurred.
* Registry corruption returns an empty registry without reconciling active names
  or simulator state, so a later allocation can lose prior ownership knowledge.

# Current Operational Guidance

Until the target session runner is implemented:

1. Give each concurrent task a distinct Git worktree.
2. Repeat `claim` from that worktree to recover the sticky UDID and renew TTL.
3. Pass the exact UDID to every Simulator and build command.
4. Renew before a long build or test and do not let an active workflow cross TTL.
5. Release explicitly on success, failure, or cancellation.
6. Treat successful claim output as reservation only; separately verify boot
   readiness and each requested operation.

See the [testing strategy](testing-strategy.md) for the gaps that must be closed.

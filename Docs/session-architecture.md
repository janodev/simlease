---
type: Architecture Decision
title: Foreground Session Architecture
description: Defines the implemented simlease run lifecycle, ownership invariants, failure semantics, and remaining recovery work.
tags: [architecture, sessions, locking, safety]
timestamp: 2026-07-15T00:00:00Z
status: implemented-v1
implemented: true
---

# User Contract

The safe workflow entry point is:

```bash
simlease run [options] -- <command> [arguments...]
```

`simlease with` is an equivalent alias. A session:

* creates a uniquely named disposable simulator and unique session ID;
* holds a per-UDID kernel lock from immediately after creation through cleanup;
* waits for Simulator boot readiness before starting the child;
* exports `SIMULATOR_ID`, `SIMULATOR_UDID`, and `SIMLEASE_SESSION_ID`;
* preserves the child's standard input, output, and error streams;
* uses checked shutdown and deletion before releasing ownership; and
* remains independent from every other run, including runs in the same worktree.

The disposable model favors predictable isolation over warm-device reuse.

# Authority Model

Ownership sources are ordered by strength:

1. A live per-UDID Darwin `flock` is authoritative.
2. Registry session metadata records lifecycle and recovery state.
3. TTL, worktree, agent, label, and simulator name are diagnostic hints.

No metadata condition may displace a live kernel owner. A lockless registered
session is abandoned and delete-only; it is never a reusable simulator.

# Implemented Lifecycle

1. **Create** - Under the global registry lock, resolve the device type and
   runtime and create a uniquely named private simulator.
2. **Own** - Acquire the UDID lock without waiting and persist the session in
   `created` state. If locking or persistence fails, attempt immediate shutdown
   and deletion.
3. **Boot** - Release the global lock, persist `booting`, execute `boot`, and
   block on `bootstatus <UDID> -b` while retaining the UDID lock.
4. **Run** - Persist `running` and start the child with the session environment
   and inherited streams.
5. **Clean** - Reacquire the global registry lock, persist `cleaning`, perform
   checked shutdown and deletion while both locks are held, then remove the
   registry record and release the global lock.
6. **Unlock** - Release the UDID lock only after successful cleanup. On cleanup
   failure, persist `quarantined`, report the error, and retain ownership until
   the supervisor ends.

The registry has no completed row: successful deletion removes the record.

# Safety Invariants

| ID | Implemented invariant |
|---|---|
| S1 | Every `run` creates a new disposable simulator; sessions never reuse pooled or abandoned devices. |
| S2 | After `create` returns, the per-UDID lock is acquired before publication, boot, or child launch and remains held through cleanup. |
| S3 | Same-worktree runs have distinct session IDs and UDIDs. |
| S4 | Lock ownership ends by descriptor close, never by unlinking or age-based stealing. |
| S5 | Allocation-critical `simctl` discovery rejects nonzero status, malformed JSON, unexpected shapes, and missing required identifiers. |
| S6 | The child starts only after checked boot readiness succeeds. |
| S7 | Cleanup failure retains a quarantined, delete-only record instead of reporting release success. |
| S8 | GC does not reclaim a lock-held session regardless of TTL or worktree state. |
| S9 | A lockless registered session may only be deleted, never adopted. |
| S10 | After creation, all Simulator lifecycle operations use the explicit session UDID; names are presentation hints. |
| S11 | Existing corrupt or unsupported registry data blocks mutation instead of becoming an empty ownership view. |

# Kernel Locks

The global registry lock and per-UDID locks are persistent regular files opened
with `O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW`, mode `0600`, and held with
Darwin `flock`. Acquisition uses a monotonic deadline and retries interrupted
system calls. Only `EWOULDBLOCK` and `EAGAIN` mean contention.

Lock files stay in place after release. This prevents split-inode ownership,
where one process retains an old inode while another locks a replacement at the
same path. Close-on-exec prevents the child from inheriting the supervisor's
ownership descriptor.

The global lock covers registry transitions, reconciliation, device resolution,
creation, and initial publication. It is released before boot and child work so
independent sessions can proceed on separate per-device locks. Final cleanup
currently reacquires it across shutdown and deletion, serializing that boundary
with allocation and other cleanup.

# Process and Exit Semantics

The child runs through `/usr/bin/env` with ordinary terminal streams attached.
When it exits normally, its status is returned after successful cleanup. If it
dies from an uncaught signal, the supervisor returns `128 + signal`.

The supervisor installs dispatch signal sources for `SIGINT` and `SIGTERM`,
forwards those signals to the active child, remembers the first forwarded
signal, waits for the child, cleans the simulator, then returns `128 + signal`.
There is currently no grace deadline or forced escalation for a child that
ignores a forwarded signal.

If setup and cleanup both fail, diagnostics retain the setup error and also emit
the cleanup warning. If a child exits nonzero and cleanup then fails, cleanup is
an infrastructure failure and may determine the reported command failure. Code
must continue to test both diagnostics and final state when changing precedence.

# Recovery Semantics

| Failure | Implemented response |
|---|---|
| Setup fails before child launch | Skip the child and attempt checked cleanup while the lock remains held. |
| Child exits nonzero | Attempt cleanup and preserve the child status when cleanup succeeds. |
| Catchable termination | Forward to the child, wait, clean, and return the signal-derived status. |
| Supervisor crash or `SIGKILL` after publication | Kernel ownership drops; the direct child may survive; the registry row remains and the next mutating reconciliation deletes the simulator. |
| Existing registry bytes cannot decode, or use a newer schema | Retain the original and fail closed for lifecycle mutation. |
| Cleanup fails | Persist `quarantined` plus failure detail; keep the simulator delete-only. |
| TTL expires during a live session | Ignore expiry while its UDID lock is held. |

# Compatibility Boundary

`claim`, `renew`, and `release` remain cooperative legacy commands. They do not
inherit foreground-session guarantees. Legacy allocation must still exclude
active, quarantined, abandoned, and visibly locked session simulators.

See [current architecture](current-architecture.md) for operational tradeoffs.

# Remaining Design Work

The implemented lifecycle does not yet persist intent before `simctl create`.
Therefore, a crash between creation and registry publication can leave a locked-
name simulator that is safely excluded from allocation but cannot be proven safe
for automatic deletion. A future intent journal or conservative name-to-intent
reconciler must close this window.

The following remain future work:

* a broker or Unix-domain-socket service for reconnectable sessions across
  unrelated invocations;
* bounded signal grace periods and explicit escalation policy;
* a narrower final-cleanup registry transaction that preserves recovery state
  without holding the global lock across Simulator commands;
* per-UDID cancel, forced recovery, and cleanup history beyond the menubar app's
  current error presentation and global-GC retry; and
* stronger recovery testing around persistence failures and real Simulator
  partial-operation boundaries.

Track delivery in [roadmap and decisions](roadmap-and-decisions.md) and evidence
in [testing strategy](testing-strategy.md).

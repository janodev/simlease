---
type: Architecture Decision
title: Target Session-Oriented Architecture
description: Defines the accepted workflow-wide isolation model for simlease run and its safety invariants.
tags: [architecture, target-state, sessions, locking, safety]
timestamp: 2026-07-15T00:00:00Z
status: accepted-target
implemented: false
---

# Status Boundary

This is the accepted target design. It is not implemented at the baseline in
[current architecture](current-architecture.md). Future code and user-facing
documentation must not describe these guarantees as available until their tests
and implementation land together.

# User Contract

The safe workflow entry point is:

```bash
simlease run [options] -- <command> [arguments...]
```

An optional `with` alias may be added if the CLI framework supports it cleanly.
The alias is not part of the required contract.

Each `run` session:

* creates a unique disposable simulator;
* owns a unique session ID;
* holds a per-UDID kernel lock from creation through command completion and
  cleanup;
* waits until the simulator is boot-ready before starting the child command;
* exports `SIMULATOR_ID`, `SIMULATOR_UDID`, and `SIMLEASE_SESSION_ID` to the
  child;
* preserves the child process's standard input, output, and error streams;
* shuts down and deletes the simulator before releasing ownership on normal
  completion; and
* treats same-worktree runs as independent sessions.

The disposable model deliberately trades warm-device reuse for a narrow,
auditable lifecycle with no prior app or settings state.

# Authority Model

Ownership sources, strongest first:

1. The live per-UDID kernel lock is authoritative.
2. Session metadata records lifecycle phase, owner diagnostics, and cleanup state.
3. TTL, worktree, label, PID, and simulator name are observational or recovery
   hints; none may revoke a live kernel lock.

The registry is not a substitute for the live lock. Registry corruption, clock
jumps, an expired TTL, or a missing worktree must never make a lock-held simulator
available.

# Session Lifecycle

The target supervisor performs these phases:

1. **Intent** - Generate a session ID and persist enough intent to identify an
   interrupted creation attempt.
2. **Create** - Under the short global control lock, resolve the requested device
   type and runtime, create a uniquely named disposable simulator, acquire its
   per-UDID lock, and persist the UDID and session metadata.
3. **Boot** - Release the global lock, boot the explicit UDID, and block on
   `bootstatus` readiness while retaining the per-UDID lock.
4. **Run** - Start the child with the three session environment variables and
   retain the per-UDID lock until the child exits.
5. **Clean** - With ownership still held, perform checked shutdown and deletion.
   Persist completion only after cleanup succeeds.
6. **Unlock** - Release the per-UDID lock last. Closing the descriptor, including
   process exit or `SIGKILL`, releases the kernel lock; the lock file itself is
   never unlinked.

The supervisor owns the lock descriptor and marks it close-on-exec so the child
cannot accidentally extend ownership beyond the supervisor's lifecycle.

# Safety Invariants

| ID | Invariant |
|---|---|
| S1 | Every `run` creates a unique disposable simulator; no active or abandoned session simulator is reused. |
| S2 | The per-UDID kernel lock is acquired immediately after `create` returns, before publication or boot, and is retained through successful deletion or quarantine transition. |
| S3 | Same-worktree concurrency does not imply shared ownership; each run has a distinct session ID and simulator. |
| S4 | Locks are released by closing descriptors, never by unlinking a path and never by age-based stealing. |
| S5 | All allocation-critical `simctl` commands reject nonzero status, malformed JSON, and missing required payload shapes. Empty inventory is data, not a failure fallback. |
| S6 | The child never starts before successful boot readiness. |
| S7 | Cleanup failure is not reported as release success. The session becomes quarantined and remains delete-only. |
| S8 | A lockless abandoned session is never returned to the allocation pool; reconciliation may only finish deleting it. |
| S9 | GC cannot reclaim a simulator whose per-UDID lock is held, regardless of TTL or metadata. |
| S10 | Durable recovery state preserves enough phase information to distinguish intent, active, cleaning, quarantined, and completed states. |
| S11 | All Simulator operations use the explicit session UDID; names are presentation and recovery hints only. |
| S12 | Setup, child, cleanup, and infrastructure failures are distinguishable in diagnostics and exit behavior. |

# Kernel Lock Requirements

Both the short global control lock and per-UDID session locks use a persistent
regular file opened with `O_RDWR | O_CREAT | O_CLOEXEC`, mode `0600`, and held by
Darwin `flock`.

Acquisition uses a monotonic deadline. It retries interrupted system calls and
treats only `EWOULDBLOCK` or `EAGAIN` as contention. The lock file is never
removed, avoiding split-inode ownership where old and new processes lock
different files at the same path.

The global lock protects selection and metadata transitions only. It is not held
during boot, child execution, or Simulator cleanup. Per-device locks preserve
parallelism across independent sessions.

# Simulator Command Requirements

The session supervisor uses checked APIs:

* List operations validate exit status, JSON syntax, root type, and expected
  payload shape.
* Boot is `boot` followed by blocking `bootstatus <UDID> -b`.
* Shutdown and deletion return actionable failures.
* Errors include command, exit status, and stderr without silently converting a
  tool failure into an empty device inventory.

Source-compatible nonthrowing APIs may remain for legacy callers, but the session
path must not use them.

# Failure and Recovery Semantics

| Failure | Target response |
|---|---|
| Setup fails before child launch | Do not run the child; clean or quarantine the disposable simulator while ownership is held. |
| Child exits nonzero | Preserve its outcome, still perform cleanup, and report cleanup failure separately if present. |
| Supervisor receives a catchable termination signal | Forward or terminate the child according to the process policy, then clean before unlocking. |
| Supervisor is killed without cleanup | Kernel ownership drops automatically; the durable session becomes abandoned and delete-only. |
| Registry is unreadable | Fail closed for lifecycle mutation; do not infer that recorded or lock-held devices are free. |
| Cleanup command fails | Persist quarantine with the failure detail; never emit successful release and never reuse the simulator. |
| TTL expires while lock is held | Keep the session active. TTL cannot steal kernel ownership. |

Recovery must recognize an interrupted creation by session metadata and unique
simulator naming. It may acquire an abandoned simulator's per-UDID lock and delete
the simulator; it must never promote that simulator into a future run.

# Compatibility Boundary

The existing `claim`, `renew`, and `release` commands implement the cooperative
legacy model. They must remain described as such while present. Adding `run` must
not silently strengthen claims about legacy commands. Every legacy allocation
path must nevertheless exclude active and quarantined session simulators; a
legacy command cannot bypass the session lock authority.

Any future legacy deprecation or migration belongs in the
[roadmap and decision log](roadmap-and-decisions.md).

# Explicit Future Work

The following are proposals, not part of the accepted initial `run` contract:

* a daemon or Unix-domain-socket broker for sessions spanning unrelated CLI
  invocations;
* warm disposable templates or cloning optimizations; and
* attach, resume, or remote session-control protocols.

They may be designed only after the foreground session lifecycle and its
[failure matrix](testing-strategy.md) are proven.

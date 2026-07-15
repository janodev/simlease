---
type: Test Strategy
title: Testing Strategy and Failure Matrix
description: Records current evidence and remaining validation for cooperative leasing, kernel locking, session supervision, and recovery.
tags: [testing, concurrency, fault-injection, simulator, recovery]
timestamp: 2026-07-15T00:00:00Z
status: current-guidance
---

# Current Coverage

The package uses both XCTest and Apple's Swift Testing framework. Current tests
cover legacy allocator behavior, strict `simctl` parsing and lifecycle errors,
schema-1-to-2 registry migration, schema-2 round trips, fail-closed
unreadable/corrupt paths, session transitions, quarantine and retry, and
command-level session supervision.

Important evidence crosses process boundaries rather than relying only on
in-process fakes:

* file-lock tests launch an independent XCTest process to prove contention and
  automatic release after `SIGKILL`;
* CLI integration tests launch the built `simlease` executable with an isolated
  `SIMLEASE_HOME` and scripted `xcrun`;
* command tests verify environment export, boot-readiness gating, child exit
  propagation, `SIGTERM` forwarding, cleanup, and delete-only GC after killing
  the supervisor; and
* injected `Simctl` tests make nonzero status, malformed JSON, missing fields,
  and checked lifecycle failures explicit.

Run `make test` for the complete suite. Do not rely on a fixed test count; add
focused evidence when behavior or a failure boundary changes.

# Test Layers

| Layer | Purpose |
|---|---|
| Pure unit | Parsing, state transitions, registry schema, error construction, selection, and cleanup decisions. |
| Filesystem unit | Persistence, corrupt data, permissions, temporary artifacts, and lock-path behavior in isolated directories. |
| Subprocess | Real `flock` contention, timeout, signal, process death, and descriptor lifetime. |
| CLI integration | Argument parsing, exported environment, child outcomes, signal forwarding, isolated state, and lifecycle orchestration with scripted Simulator commands. |
| Simulator integration | Boot readiness, explicit-UDID use, shutdown, deletion, and observable cleanup on a uniquely created real simulator. |

Use injected clocks for persisted time behavior. Use real monotonic deadlines
only when kernel waiting behavior is under test. Every test owns unique temporary
state and must never use `~/.simlease`.

# Coverage Matrix

| Scenario | Current evidence | Status |
|---|---|---|
| Kernel contention and release | Independent helper process cannot enter; it can enter after owner release. | Covered |
| Kernel owner `SIGKILL` | Killing a lock-holder process releases ownership promptly. | Covered |
| Old timestamp and zero-timeout probe | A live lock is not stolen by age; probes fail immediately. | Covered |
| Strict Simulator discovery | Nonzero status, invalid JSON, unexpected root, and missing UDID throw. | Covered |
| Boot readiness and checked cleanup | Command ordering and known idempotent Simulator responses are tested. | Covered |
| Independent same-worktree sessions | Session-manager tests produce distinct IDs and UDIDs. | Covered at core layer |
| Active session crosses TTL | GC and external release cannot displace a held per-UDID lock. | Covered at core layer |
| Environment and child status | Executable-level tests verify all exported variables, arguments, cleanup, a known nonzero status, and child-status precedence when cleanup also fails. | Covered |
| Boot-readiness failure | Child is skipped and cleanup runs. | Covered |
| Catchable termination | `SIGTERM` reaches the child; cleanup runs; signal-derived status is returned. | Covered |
| Supervisor `SIGKILL` | Registry remains abandoned; subsequent GC deletes and clears it. | Covered with scripted Simulator |
| Cleanup failure and retry | Session becomes quarantined; later cleanup succeeds; failed GC retains quarantine. | Covered at core layer |
| Foreground final-cleanup lock scope | A cleanup hook acquires the registry lock while checked shutdown is running. | Covered at core layer |
| Reconciliation lock scope | Legacy and abandoned-session Simulator cleanup still runs under the global registry lock. | Remaining availability work |
| Registry unreadable or corrupt | Existing unreadable paths fail closed; corrupt original and backup remain; repeated corrupt loads fail closed. | Covered without an active subprocess session |
| Registry compatibility fence | A real v1-style helper delays migration; an artificially old held directory times out without unlink or migration; afterward a v1 lock cycle cannot split the v2 flock inode. | Covered across subprocess, persistence, and path layers |
| Concurrent executable-level runs | Multiple simultaneous `simlease run` processes receive distinct real or scripted UDIDs. | Remaining |
| Close-on-exec inheritance | A long-lived child is proven unable to retain the lock after supervisor death. | Remaining focused subprocess test |
| Create succeeds before publication fails | Orphan is found or conservatively quarantined without reuse. | Remaining architecture and test work |
| Registry persistence interruption | Complete old/new state or fail-closed behavior at every replace boundary. | Remaining filesystem fault injection |
| Child ignores forwarded signal | Documented no-escalation behavior and future bounded policy. | Remaining focused subprocess test |
| Real disposable Simulator lifecycle | Exact UDID works after readiness and is absent after cleanup. | Manual smoke passed 2026-07-15; automation remains opt-in |

# Real Simulator Test Rules

Real integration tests are opt-in and must:

1. Create a uniquely named disposable simulator for the test session.
2. Record and use its exact UDID for every command.
3. Never rename, erase, shut down, or delete a simulator not created by the test.
4. Wait for `bootstatus` rather than sleeping for an assumed duration.
5. Verify absence after successful deletion.
6. On cleanup failure, print the UDID and quarantine state for manual recovery.
7. Skip with a clear reason when Xcode or a matching runtime is unavailable.

The 2026-07-15 smoke used `simlease run` with an exact iPhone 17 Pro device
type, verified all exported session variables, ran `simctl spawn` against that
UDID after readiness, confirmed deletion afterward, and preserved an existing
cooperative lease while fencing the live registry from schema 1 to schema 2.

# Assertions and Evidence

Concurrency tests must assert both exclusivity and progress. Capture every
process exit status; do not count only successful unique results and silently
drop contenders.

Fault tests should assert:

* final registry and session state;
* lock acquireability or continued contention;
* exact Simulator commands and ordering;
* whether the child started;
* cleanup or quarantine outcome; and
* stdout, stderr, and exit status contracts.

Run focused tests while iterating, then `make lint`, `make test`, and `make build`
before handoff. Record deliberately deferred rows in
[roadmap and decisions](roadmap-and-decisions.md).

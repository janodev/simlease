---
type: Test Strategy
title: Testing Strategy and Failure Matrix
description: Defines evidence required for cooperative leasing, kernel locking, session supervision, and recovery behavior.
tags: [testing, concurrency, fault-injection, simulator, recovery]
timestamp: 2026-07-15T00:00:00Z
status: target-guidance
---

# Baseline Coverage

At commit `7df4924`, the package has 24 XCTest methods in the core test target.
They cover basic lock-directory behavior, short in-process contention, allocator
selection, sticky claims, expiry, dead-worktree GC, registry encoding and corrupt
backup, and successful fake `simctl` parsing.

The baseline does not exercise CLI subprocesses, independent process contention,
process death, long lock holders, real Simulator lifecycle, malformed or failed
Simulator commands, a complete multi-command workflow, or rollback after partial
side effects. `FakeRunner` returns success for every unstubbed command, so failure
tests must always stub an explicit result or throw.

# Test Layers

| Layer | Purpose |
|---|---|
| Pure unit | Parsing, state transitions, registry schema, error construction, selection, and cleanup decisions. |
| Filesystem unit | Atomic persistence, corrupt data, permissions, stale temporary files, and lock-path behavior in an isolated directory. |
| Subprocess | Real `flock` ownership, timeout, signal, `SIGKILL`, close-on-exec, and cross-process contention. |
| CLI integration | Argument parsing, environment export, stream forwarding, child exit behavior, temporary home/registry, and lifecycle orchestration with a scripted runner. |
| Simulator integration | Boot readiness, explicit-UDID lifecycle, shutdown, deletion, and observable cleanup on a uniquely created disposable simulator. |

Tests should use injected clocks for persisted times and monotonic real deadlines
only where kernel waiting behavior itself is under test. Every test owns a unique
temporary state directory; no test uses the developer's live registry.

# Required Failure Matrix

| Scenario | Injection or setup | Required result | Minimum layer |
|---|---|---|---|
| Global lock contention | Two independent processes contend. | Exactly one owner; waiter acquires only after close or times out. | Subprocess |
| Slow live global owner | Hold longer than the former 10-second threshold. | No stale theft; mutual exclusion remains intact. | Subprocess |
| Global owner `SIGKILL` | Kill the holding process. | Kernel releases ownership and a waiter acquires promptly. | Subprocess |
| Lock descriptor inheritance | Owner launches a long-lived child. | Close-on-exec prevents accidental ownership extension. | Subprocess |
| Concurrent `run` in one worktree | Start two sessions together. | Distinct session IDs and disposable UDIDs. | CLI integration |
| Concurrent `run` across worktrees | Start several sessions together. | Every live session owns a distinct UDID. | CLI integration |
| Active session crosses TTL | Advance metadata time while per-UDID lock is held. | GC does not reclaim, rename, delete, or reuse the simulator. | CLI integration |
| Registry corrupt during active session | Replace registry with malformed bytes. | No lock-held or recorded simulator becomes allocatable; mutation fails closed or reconstructs safely. | CLI integration |
| `simctl list` nonzero | Return status and stderr. | Discovery throws; registry remains unchanged. | Unit |
| `simctl list` malformed JSON or shape | Return invalid JSON, a non-object root, or missing expected key. | Discovery throws rather than returning empty inventory. | Unit |
| Create succeeds, persistence fails | Return a UDID, then fail registry save. | Unique simulator is found and deleted or remains quarantined; it is never reused. | CLI integration |
| Boot fails | Nonzero `boot` result. | Child does not start; cleanup or quarantine runs. | CLI integration |
| Boot readiness fails | `boot` succeeds and `bootstatus` fails. | Child does not start; diagnostics identify readiness failure. | CLI integration |
| Child exits nonzero | Scripted child returns a known code. | Cleanup still runs; child outcome is preserved unless infrastructure policy deliberately overrides it. | CLI integration |
| Catchable termination | Signal the supervisor with an active child. | Child handling and cleanup follow the documented signal policy; lock is released last. | Subprocess |
| Supervisor `SIGKILL` | Kill after boot or during child execution. | Lock drops automatically; durable record becomes lockless abandoned and delete-only. | Subprocess |
| Shutdown or delete fails | Checked cleanup returns nonzero. | Session is quarantined, command reports infrastructure failure, and no release-success message appears. | CLI integration |
| Abandoned session reconciliation | Seed a lockless abandoned record and matching simulator. | Reconciler acquires its lock and deletes it; allocator never adopts it. | CLI integration |
| Registry replace interrupted | Leave old registry and temporary artifacts at each persistence boundary. | Loader sees a complete supported state or fails closed; no partial registry is accepted. | Filesystem unit |
| Unsupported newer schema | Load a future schema. | Explicit upgrade error; file remains intact. | Unit |
| End-to-end disposable session | Run a child that records exported variables. | Boot-ready explicit UDID is usable, variables agree, and the simulator is deleted afterward. | Simulator integration |

# Real Simulator Test Rules

Real integration tests are opt-in and must:

1. Create a uniquely named disposable simulator for the test session.
2. Record and use its exact UDID for every command.
3. Never rename, erase, shut down, or delete a simulator not created by the test.
4. Wait for `bootstatus` rather than sleeping for an assumed duration.
5. Verify absence after successful deletion.
6. On cleanup failure, print the UDID and quarantine state for manual recovery.
7. Skip with a clear reason when Xcode or a matching runtime is unavailable.

# Assertions and Evidence

Concurrency tests must assert both exclusivity and progress. Counting only unique
results is insufficient if failed contenders are silently dropped. Capture every
process exit status and require the expected number of successful sessions.

Fault tests should assert:

* final registry or session state;
* lock acquireability or continued contention;
* exact Simulator commands and ordering;
* whether the child started;
* cleanup or quarantine outcome; and
* stdout, stderr, and exit status contracts.

Run focused tests while iterating and `make test` before handoff. Session work is
not complete until all applicable rows above are automated or an explicit
remaining gap is recorded in the [roadmap](roadmap-and-decisions.md).
